#!/usr/bin/env python3
"""Agent engine: run a team of AI agents inside Buzz channels.

Each agent lives in one channel, reads real data from your own systems, and
answers questions there. Agents are defined in agents.json, not in code, so you
add one by writing a few lines of config.

    agent-engine.py doctor              check the setup, say exactly what is missing
    agent-engine.py list                show the agents you have
    agent-engine.py ask <name> "..."    ask on the command line, nothing is posted
    agent-engine.py brief <name>        post that agent's update to its channel
    agent-engine.py watch <name>        answer questions asked in its channel
    agent-engine.py watch-all           one pass over every agent
    agent-engine.py remember <name> "..."  tell an agent something for good
    agent-engine.py forget <name>       wipe what it was told
    agent-engine.py pending             jobs waiting for your approval
    agent-engine.py approve <n>         run one
    agent-engine.py reject <n>          bin one

Agents read and report. Anything that would change something is queued for a
person to approve. Nothing runs on its own.

Bring your own brain: the engine uses whichever of these it finds first,
an OpenAI key, an Anthropic key, the Claude Code CLI, the Codex CLI, or Ollama
running locally. Nothing to configure if you already have one of them.
"""
import csv
import datetime
import decimal
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONFIG = os.environ.get("AGENT_CONFIG", os.path.join(ROOT, "agents.json"))
STATE = os.environ.get("AGENT_STATE", os.path.join(ROOT, ".state"))
MEMORY = os.environ.get("AGENT_MEMORY", os.path.join(ROOT, "memory"))
BUZZ = os.environ.get("BUZZ_BIN", "buzz")

HOUSE_STYLE = """You are an agent on a team, sitting in a chat channel with the people
who run this business.

How to write:
- Lead with the answer. The first line IS the answer, never a preamble.
- Short lines. A blank line between points. Never a wall of text.
- Real numbers, always.
- No hedging, no apologising.
- If something needs a decision, one plain line at the end saying so.

The rule that overrides everything: every figure, name and date you state must appear
in the facts you were given. If a question needs something you were not given, say the
data does not cover it. Never estimate, never fill a gap, never invent a target or a
threshold. Being wrong is far worse than saying you do not know.

You never change anything. You read, you report, you recommend. A person decides.
"""


# ------------------------------------------------------------------- helpers
def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def load_env_file(path):
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                v = v.strip().strip('"').strip("'")
                if v:                       # a blank line in .env means "not set"
                    os.environ.setdefault(k.strip(), v)


def have_cli(name):
    return subprocess.run(["which", name], capture_output=True).returncode == 0


# ------------------------------------------------------- model, whatever you have
def _openai(system, user, key, base="https://api.openai.com/v1",
            model=None):
    model = model or os.environ.get("AGENT_MODEL") or "gpt-5.4-mini"
    body = json.dumps({"model": model, "messages": [
        {"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(f"{base}/chat/completions", data=body, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


def _anthropic(system, user, key):
    model = os.environ.get("AGENT_MODEL") or "claude-sonnet-5"
    body = json.dumps({"model": model, "max_tokens": 1500, "system": system,
                       "messages": [{"role": "user", "content": user}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body,
                                 headers={"x-api-key": key,
                                          "anthropic-version": "2023-06-01",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        blocks = json.load(r)["content"]
    # Reasoning models may lead with non-text blocks; keep every text block.
    return "\n".join(b.get("text", "") for b in blocks
                     if b.get("type") == "text").strip()


_HELP_CACHE = {}


def _cli_help(binary):
    if binary not in _HELP_CACHE:
        try:
            probe = [binary, "--help"] if binary == "claude" else [binary, "exec", "--help"]
            out = subprocess.run(probe, capture_output=True, text=True, timeout=30)
            _HELP_CACHE[binary] = out.stdout + out.stderr
        except Exception:
            _HELP_CACHE[binary] = ""
    return _HELP_CACHE[binary]


def _cli_args(binary, prompt, help_text=None):
    """Build a headless command that ignores the user's agent configuration.

    Older CLI versions miss some isolation flags (claude 2.1.x has no
    --safe-mode), so only flags the installed binary advertises are passed.
    The rest still isolate MCP servers, tools, and settings.
    """
    if help_text is None:
        help_text = _cli_help(binary)
    if binary == "claude":
        args = [binary, "-p"]
        if "--safe-mode" in help_text:
            args.append("--safe-mode")
        for flag in (["--strict-mcp-config"],
                     ["--mcp-config", '{"mcpServers":{}}'],
                     ["--settings", "{}"],
                     ["--tools", ""],
                     ["--no-session-persistence"]):
            if flag[0] in help_text:
                args.extend(flag)
        return args + [prompt]
    args = [binary, "exec", "--skip-git-repo-check"]
    for flag in (["--ephemeral"], ["--ignore-user-config"], ["--ignore-rules"],
                 ["--sandbox", "read-only"]):
        if flag[0] in help_text:
            args.extend(flag)
    return args + [prompt]


def _cli(binary, system, user):
    """Claude Code or Codex, driven headlessly and in isolation."""
    prompt = system + "\n\n---\n\n" + user
    args = _cli_args(binary, prompt)
    with tempfile.TemporaryDirectory(prefix="buzz-agent-") as workdir:
        out = subprocess.run(args, capture_output=True, text=True, timeout=300,
                             cwd=workdir)
    if out.returncode != 0:
        return (f"(the {binary} command failed: "
                f"{(out.stderr or out.stdout).strip()[:200]})")
    return (out.stdout or "").strip()


def model_backend():
    """Return (label, callable). First one available wins."""
    if os.environ.get("OPENAI_API_KEY"):
        key = os.environ["OPENAI_API_KEY"]
        return "OpenAI API", lambda s, u: _openai(s, u, key)
    if os.environ.get("ANTHROPIC_API_KEY"):
        key = os.environ["ANTHROPIC_API_KEY"]
        return "Anthropic API", lambda s, u: _anthropic(s, u, key)
    if os.environ.get("OPENROUTER_API_KEY"):
        key = os.environ["OPENROUTER_API_KEY"]
        return "OpenRouter", lambda s, u: _openai(
            s, u, key, "https://openrouter.ai/api/v1",
            os.environ.get("AGENT_MODEL") or "anthropic/claude-sonnet-5")
    if have_cli("claude"):
        return "Claude Code CLI", lambda s, u: _cli("claude", s, u)
    if have_cli("codex"):
        return "Codex CLI", lambda s, u: _cli("codex", s, u)
    try:
        urllib.request.urlopen("http://localhost:11434/api/tags", timeout=3)
        return "Ollama (local)", lambda s, u: _openai(
            s, u, "ollama", "http://localhost:11434/v1",
            os.environ.get("AGENT_MODEL") or "llama3.2")
    except Exception:
        pass
    return None, None


# ------------------------------------------------------------- data sources
def src_memory(args):
    """What this agent has been told to remember. Plain text, one note per line."""
    name = args[0] if args else ""
    path = os.path.join(MEMORY, f"{name}.md")
    if not os.path.exists(path):
        return "(nothing remembered yet)"
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()[:6000]


def remember(agent_name, note):
    """Append a note. Agents never write here. Only a person does, via `remember`."""
    os.makedirs(MEMORY, exist_ok=True)
    path = os.path.join(MEMORY, f"{agent_name}.md")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(note.rstrip() + "\n")
    return path


def src_shell(args):
    """Run a shell command and use its output. Defined per agent in agents.json."""
    cmd = args[0] if args else ""
    if not cmd:
        return ""
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
    except subprocess.SubprocessError as e:
        return f"(the command could not run: {str(e)[:90]})"
    if out.returncode != 0:
        return (f"(the command failed with code {out.returncode}. This is a broken "
                f"source, NOT an absence of data: {(out.stderr or '').strip()[:200]})")
    return (out.stdout or "").strip() or "(the command ran but printed nothing)"


def _http_header_prefix(url):
    """Stable env prefix for secrets belonging to one HTTP source."""
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:16].upper()
    return f"AGENT_HEADER_{digest}_"


def src_http(args):
    """GET a URL with only the headers assigned to that source."""
    url = args[0] if args else ""
    if not url:
        return ""
    headers = {}
    prefix = _http_header_prefix(url)
    for k, v in os.environ.items():
        if k.startswith(prefix):
            headers[k[len(prefix):].replace("_", "-")] = v
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=45) as r:
            return _truncate(r.read().decode("utf-8", "replace"), url)
    except Exception as e:
        return f"(could not reach {url}: {str(e)[:80]})"


MAX_SOURCE_CHARS = 12000


def _truncate(text, what):
    """Cut oversized input, and say loudly that it was cut.

    An agent handed the first 200 rows of a 900-row export will total those 200
    and state the figure as fact. It must be told the data is partial."""
    if len(text) <= MAX_SOURCE_CHARS:
        return text
    kept = text[:MAX_SOURCE_CHARS]
    shown, total = kept.count("\n"), text.count("\n")
    return (kept + f"\n\n*** INCOMPLETE: only the first {shown} of {total} lines of "
            f"{what} fit. Any total you calculate from this is PARTIAL. You must say "
            f"so and must not present it as the full figure. ***")


def _csv_summary(text):
    """Return authoritative totals for consistently numeric CSV columns."""
    try:
        reader = csv.DictReader(io.StringIO(text))
        rows = list(reader)
    except csv.Error:
        return ""
    columns = [column for column in (reader.fieldnames or []) if column]
    if not rows or not columns:
        return ""
    totals = {}
    for column in columns:
        values = [(row.get(column) or "").strip() for row in rows]
        if not values or any(not value for value in values):
            continue
        try:
            totals[column] = sum((decimal.Decimal(value.replace(",", ""))
                                  for value in values), decimal.Decimal())
        except decimal.InvalidOperation:
            continue
    if not totals:
        return ""

    def number(value):
        return format(value, ".2f")

    lines = ["*** AUTHORITATIVE CSV TOTALS (computed in Python from all rows) ***",
             f"row count: {len(rows)}"]
    lines.extend(f"{column} total: {number(total)}"
                 for column, total in totals.items())
    status_column = next((column for column in columns
                          if column.lower() == "status"), None)
    if status_column:
        statuses = sorted({(row.get(status_column) or "").strip() for row in rows})
        for status in statuses:
            if not status:
                continue
            matching = [row for row in rows
                        if (row.get(status_column) or "").strip() == status]
            for column in totals:
                subtotal = sum((decimal.Decimal(row[column].replace(",", ""))
                                for row in matching), decimal.Decimal())
                lines.append(f"{column} total where {status_column}={status}: "
                             f"{number(subtotal)}")
    lines.append("Use these totals as final. Do not re-add or infer totals from the rows below.")
    return "\n".join(lines)


def src_file(args):
    """Read a local file: a CSV export, a notes file, anything."""
    path = os.path.expanduser(args[0] if args else "")
    if not path or not os.path.exists(path):
        return f"(no file at {path})"
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    summary = _csv_summary(text)
    rows = _truncate(text, os.path.basename(path))
    return summary + "\n\n" + rows if summary else rows


def src_buzz_channel(args):
    """Recent messages from another Buzz channel, so agents can read each other."""
    ch = os.environ.get(args[0]) if args else None
    if not ch:
        return ""
    out = subprocess.run([BUZZ, "--format", "compact", "messages", "get",
                          "--channel", ch, "--limit", "20"],
                         capture_output=True, check=False)
    try:
        msgs = json.loads(out.stdout or b"[]")
        return "\n".join(f"  {m.get('content', '')[:200]}" for m in msgs)
    except json.JSONDecodeError:
        return ""


SOURCES = {"memory": src_memory, "shell": src_shell, "http": src_http, "file": src_file,
           "channel": src_buzz_channel}


def gather(agent):
    blocks = []
    notes = src_memory([agent["name"]])
    if notes and not notes.startswith("(nothing"):
        blocks.append("--- What you have been told to remember ---\n" + notes)
    for spec in agent.get("sources", []):
        kind, _, arg = spec.partition(":")
        fn = SOURCES.get(kind)
        if not fn:
            blocks.append(f"(unknown source type '{kind}')")
            continue
        label = agent.get("source_labels", {}).get(spec, spec)
        blocks.append(f"--- {label} ---\n{fn([arg])}")
    blocks.append("NOT AVAILABLE: anything not listed above. Say so rather than guess.")
    return "\n\n".join(b for b in blocks if b.strip())


# --------------------------------------------------------------------- buzz
def agent_pubkey():
    """This agent team's own public key, so we never reply to ourselves."""
    key = os.environ.get("BUZZ_PRIVATE_KEY", "")
    if not key:
        return None
    out = subprocess.run([BUZZ, "--format", "compact", "users", "get"],
                         capture_output=True, check=False)
    try:
        rows = json.loads(out.stdout or b"[]")
        return rows[0].get("pubkey") if rows else None
    except (json.JSONDecodeError, AttributeError, IndexError):
        return None


def channel_id(agent):
    env = agent.get("channel_env")
    if env and os.environ.get(env):
        return os.environ[env]
    return agent.get("channel_id", "")


def post(agent, text):
    ch = channel_id(agent)
    if not ch:
        print(f"(no channel configured for {agent['name']}; not posted)\n{text}")
        return
    out = subprocess.run([BUZZ, "messages", "send", "--channel", ch, "--content", "-"],
                         input=text.encode(), check=False, capture_output=True)
    if out.returncode != 0:
        err = (out.stderr or out.stdout or b"").decode("utf-8", "replace")[:200]
        print(f"(could not post to the channel: {err})")
        return False
    return True


def recent(agent, limit=15):
    ch = channel_id(agent)
    if not ch:
        return []
    out = subprocess.run([BUZZ, "--format", "compact", "messages", "get",
                          "--channel", ch, "--limit", str(limit)],
                         capture_output=True, check=False)
    try:
        return json.loads(out.stdout or b"[]")
    except json.JSONDecodeError:
        return []


# ------------------------------------------------------------------ the ask
def extract_proposals(agent, text):
    """An agent can end a line with PROPOSE: <what> || <command>. It never runs."""
    kept = []
    for line in text.splitlines():
        if line.strip().startswith("PROPOSE:") and "||" in line:
            body = line.split("PROPOSE:", 1)[1]
            what, _, cmd = body.partition("||")
            n = propose(agent, what.strip(), cmd.strip())
            kept.append(f"Waiting for your approval ({n}): {what.strip()}")
        else:
            kept.append(line)
    return "\n".join(kept)


def run_agent(agent, question):
    label, call = model_backend()
    if not call:
        die("No model available. Run: agent-engine.py doctor")
    today = datetime.date.today().isoformat()
    system = (HOUSE_STYLE + f"\n\nToday's date is {today}."
              + "\n\nWho you are:\n" + agent["persona"])
    if agent.get("rules"):
        system += "\n\nStanding rules that override the numbers:\n" + agent["rules"]
    facts = gather(agent)
    user = ("FACTS, the complete set you may quote:\n\n" + facts[:18000]
            + "\n\n---\n\n" + question)
    if agent.get("can_propose"):
        system += ("\n\nIf a job would genuinely help and you know the exact command, "
                   "you may end your reply with a line:\n"
                   "PROPOSE: what it does || the command\n"
                   "It will NOT run. A person sees it and approves it. Propose nothing "
                   "unless you are certain of the command.")
    try:
        reply = call(system, user)
        return extract_proposals(agent, reply) if agent.get("can_propose") else reply
    except urllib.error.HTTPError as e:
        hint = {401: "That key was rejected. Check the key in .env.",
                429: "You have hit a rate or usage limit. Wait, or use a different key.",
                404: "That model name was not found. Clear AGENT_MODEL in .env to use the default."}
        return (f"Could not reach the model ({e.code}). "
                + hint.get(e.code, "Run: agent-engine.py doctor"))
    except Exception as e:
        return (f"Could not reach the model: {str(e)[:110]}\n"
                "Run: agent-engine.py doctor")


# ------------------------------------------------------------------ commands
def load_agents():
    if not os.path.exists(CONFIG):
        die(f"No agents.json at {CONFIG}. Copy agents.example.json to start.")
    try:
        with open(CONFIG) as fh:
            data = json.load(fh)
    except json.JSONDecodeError as e:
        die(f"There is a typo in {CONFIG}\n"
            f"  line {e.lineno}, column {e.colno}: {e.msg}\n"
            "  Usually a missing comma, a stray quote, or a // comment "
            "(JSON does not allow comments).")
    try:
        return {a["name"]: a for a in data["agents"]}
    except (KeyError, TypeError):
        die(f"{CONFIG} is valid JSON but has no \"agents\" list in it.")


def cmd_doctor(*_):
    required_ok = True
    print("Agent engine: setup check\n")

    print("Required for command-line questions:")

    label, call = model_backend()
    if call:
        print(f"  [ok]   brain: {label}")
    else:
        required_ok = False
        print("  [--]   brain: none found")
        print("         Set one of OPENAI_API_KEY, ANTHROPIC_API_KEY or")
        print("         OPENROUTER_API_KEY, or install the Claude Code or Codex CLI,")
        print("         or run Ollama locally. Any one of them is enough.")

    wants_channels = bool(os.environ.get("BUZZ_RELAY_URL")) or have_cli(BUZZ)

    if os.path.exists(CONFIG):
        agents = load_agents()
        print(f"  [ok]   agents: {len(agents)} defined ({', '.join(agents)})")
        # Only worth mentioning to someone who is actually setting channels up.
        # Command-line users have no channels by design and should not be nagged.
        if wants_channels:
            for a in agents.values():
                if not channel_id(a):
                    print(f"         note: '{a['name']}' has no channel id yet")
    else:
        required_ok = False
        print(f"  [--]   agents: no config at {CONFIG}")

    print("\nOptional for Buzz chat channels:")
    if have_cli(BUZZ) or os.path.exists(BUZZ):
        print(f"  [ok]   optional Buzz CLI: {BUZZ}")
    else:
        print(f"  [--]   optional Buzz CLI: not found at '{BUZZ}'")
        print("         Command-line questions still work. Build Buzz only for channels.")

    relay = os.environ.get("BUZZ_RELAY_URL")
    key = os.environ.get("BUZZ_PRIVATE_KEY")
    print(f"  [{'ok' if relay else '--'}]   optional Buzz relay: {relay or 'BUZZ_RELAY_URL not set'}")
    print(f"  [{'ok' if key else '--'}]   optional Buzz identity: {'set' if key else 'BUZZ_PRIVATE_KEY not set'}")

    print("\n" + ("Ready. Try: agent-engine.py ask <name> \"how are we doing?\""
                  if required_ok else
                  "Fix the required [--] lines above. Optional Buzz items only affect channels."))
    sys.exit(0 if required_ok else 1)


def cmd_list(agents, _):
    for a in agents.values():
        ch = channel_id(a) or "(no channel)"
        print(f"  {a['name']:12s} {a.get('channel', ch):16s} "
              f"{a['persona'].splitlines()[0][:56]}")


def cmd_ask(agents, argv):
    if not argv:
        die("usage: agent-engine.py ask <name> \"your question\"")
    a = agents.get(argv[0]) or die(f"no agent called '{argv[0]}'")
    print(run_agent(a, " ".join(argv[1:]) or "How are things?"))


def is_model_error(text):
    """True for the engine's own failure strings. Never post these to a channel."""
    return text.startswith(("Could not reach the model",
                            "(the claude command failed",
                            "(the codex command failed"))


def cmd_brief(agents, argv):
    a = agents.get(argv[0]) if argv else None
    if not a:
        die("usage: agent-engine.py brief <name>")
    text = run_agent(a, a.get("brief_prompt", "Post a short update on your area."))
    if is_model_error(text):
        die(text)
    if post(a, text):
        print(text)


def cmd_watch(agents, argv):
    a = agents.get(argv[0]) if argv else None
    if not a:
        die("usage: agent-engine.py watch <name>")
    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, a["name"])
    seen = set(open(path).read().split()) if os.path.exists(path) else set()
    fresh = [m for m in recent(a) if m.get("id") not in seen and m.get("content")]
    if not seen and fresh:
        # First ever pass: mark everything read rather than replying to a whole
        # backlog at once.
        with open(path, "a") as fh:
            for m in fresh:
                fh.write(m["id"] + "\n")
        print(f"[{a['name']}] first run: marked {len(fresh)} existing messages as read")
        return
    mine = agent_pubkey()
    questions = [m for m in fresh
                 if "?" in m["content"] and m.get("pubkey") != mine]
    answered = set()
    for m in questions:
        reply = run_agent(a, m["content"])
        if is_model_error(reply):
            # Leave the question unread so the next pass retries it.
            print(f"[{a['name']}] model unavailable, will retry: {reply.splitlines()[0]}")
            continue
        post(a, reply)
        answered.add(m["id"])
        print(f"[{a['name']}] {m['content'][:60]!r}\n{reply}\n")
    with open(path, "a") as fh:
        for m in fresh:
            if m["id"] in answered or m not in questions:
                fh.write(m["id"] + "\n")
    if not questions:
        print(f"[{a['name']}] nothing to answer")


def cmd_watch_all(agents, _):
    for name in agents:
        try:
            cmd_watch(agents, [name])
        except SystemExit:
            raise
        except Exception as e:
            print(f"[{name}] failed: {str(e)[:120]}")


def cmd_remember(agents, argv):
    if len(argv) < 2:
        die('usage: agent-engine.py remember <name> "the thing to remember"')
    a = agents.get(argv[0]) or die(f"no agent called '{argv[0]}'")
    path = remember(a["name"], "- " + " ".join(argv[1:]))
    print(f"{a['name']} will remember that. ({path})")


def cmd_forget(agents, argv):
    a = agents.get(argv[0]) if argv else None
    if not a:
        die("usage: agent-engine.py forget <name>")
    path = os.path.join(MEMORY, f"{a['name']}.md")
    if os.path.exists(path):
        os.remove(path)
    print(f"{a['name']} has forgotten everything it was told.")


# ------------------------------------------------------------------- actions
def actions_file():
    os.makedirs(STATE, exist_ok=True)
    return os.path.join(STATE, "pending-actions.json")


def load_actions():
    p = actions_file()
    if not os.path.exists(p):
        return []
    try:
        with open(p) as fh:
            return json.load(fh)
    except json.JSONDecodeError:
        return []


def save_actions(items):
    with open(actions_file(), "w") as fh:
        json.dump(items, fh, indent=2)


def propose(agent, label, command):
    """An agent asks to do something. Nothing runs until a person approves it."""
    items = load_actions()
    items.append({"id": len(items) + 1, "agent": agent["name"],
                  "what": label, "command": command, "state": "waiting"})
    save_actions(items)
    return items[-1]["id"]


def cmd_pending(agents, _):
    waiting = [a for a in load_actions() if a["state"] == "waiting"]
    if not waiting:
        print("Nothing waiting for approval.")
        return
    print("Waiting for you to approve:\n")
    for a in waiting:
        print(f"  {a['id']}. [{a['agent']}] {a['what']}")
        print(f"     runs: {a['command']}\n")
    print("Approve with:  agent-engine.py approve <number>")
    print("Reject with:   agent-engine.py reject <number>")


def cmd_approve(agents, argv):
    if not argv:
        die("usage: agent-engine.py approve <number>")
    items = load_actions()
    for a in items:
        if str(a["id"]) == argv[0] and a["state"] == "waiting":
            print(f"Running: {a['command']}")
            out = subprocess.run(a["command"], shell=True, capture_output=True,
                                 text=True, timeout=300)
            a["state"] = "done" if out.returncode == 0 else "failed"
            a["result"] = (out.stdout or out.stderr)[:2000]
            save_actions(items)
            print(a["result"] or "(no output)")
            ag = agents.get(a["agent"])
            if ag:
                post(ag, f"Approved and run: {a['what']}\n\n{a['result'][:800]}")
            return
    die(f"Nothing waiting with number {argv[0]}")


def cmd_reject(agents, argv):
    items = load_actions()
    for a in items:
        if argv and str(a["id"]) == argv[0]:
            a["state"] = "rejected"
            save_actions(items)
            print(f"Rejected: {a['what']}")
            return
    die("usage: agent-engine.py reject <number>")


if __name__ == "__main__":
    for f in (".env", "buzz.env"):
        load_env_file(os.path.join(ROOT, f))
    mode = sys.argv[1] if len(sys.argv) > 1 else "doctor"
    if mode == "doctor":
        cmd_doctor()
    cmds = {"list": cmd_list, "ask": cmd_ask, "brief": cmd_brief,
            "watch": cmd_watch, "watch-all": cmd_watch_all,
            "remember": cmd_remember, "forget": cmd_forget,
            "pending": cmd_pending, "approve": cmd_approve,
            "reject": cmd_reject}
    fn = cmds.get(mode)
    if not fn:
        die(__doc__)
    fn(load_agents(), sys.argv[2:])
