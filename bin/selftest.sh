#!/usr/bin/env bash
# Prove the whole thing works, end to end, without touching your real data.
#
#   ./bin/selftest.sh
#
# Runs every part against a throwaway copy and tells you plainly what passed.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
p() { PASS=$((PASS+1)); printf '  ✓ %s\n' "$*"; }
f() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$*"; }
bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_STATE="$TMP/state" AGENT_MEMORY="$TMP/memory" AGENT_CONFIG="$TMP/agents.json"
cp agents.json "$TMP/agents.json" 2>/dev/null || cp agents.example.json "$TMP/agents.json"

# This kit ships in two editions from one set of files. The starter edition has no
# Buzz channels and no persona pack; the full edition has both. Checks that only
# apply to the full edition are skipped, never silently, when its files are absent.
if [ -d pack ]; then EDITION=full; else EDITION=starter; fi
s() { PASS=$((PASS+1)); printf '  ~ %s (not in the %s edition)\n' "$*" "$EDITION"; }

bold "Files"
for x in bin/agent-engine.py bin/setup.sh bin/connect.sh \
         agents.example.json .env.example README.md; do
    [ -f "$x" ] && p "$x" || f "$x is missing"
done
if [ "$EDITION" = full ]; then
    for x in bin/pubkey.sh bin/make-channels.sh bin/schedule.sh install.sh; do
        [ -f "$x" ] && p "$x" || f "$x is missing"
    done
fi

bold "Code is valid"
python3 -m py_compile bin/agent-engine.py 2>/dev/null && p "engine" || f "engine has a syntax error"
for x in bin/*.sh; do bash -n "$x" 2>/dev/null && p "$(basename "$x")" || f "$(basename "$x") has a syntax error"; done
python3 -c "import json;json.load(open('agents.example.json'))" 2>/dev/null \
    && p "starter agents are valid" || f "agents.example.json is not valid JSON"
if [ "$EDITION" = starter ]; then s "persona pack matches the starter agent names"; else
python3 - <<'PY' >/dev/null 2>&1 \
    && p "persona pack matches the starter agent names" \
    || f "persona pack and starter agent names do not match"
import glob
import json
import os
import re

config_names = {agent["name"] for agent in json.load(open("agents.example.json"))["agents"]}
files = glob.glob("pack/agents/*.persona.md")
file_names = {os.path.basename(path).removesuffix(".persona.md") for path in files}
persona_names = set()
for path in files:
    text = open(path).read()
    match = re.search(r"^name:\s*([^\s]+)\s*$", text, re.MULTILINE)
    assert match
    persona_names.add(match.group(1))
assert file_names == persona_names == config_names
assert "chief" not in file_names
PY
fi
python3 - <<'PY' >/dev/null 2>&1 \
    && p "setup provides data for every file-backed demo agent" \
    || f "a demo agent points at sample data setup does not create"
import json

import os

config = json.load(open("agents.example.json"))
setup = open("bin/setup.sh").read()
agents = {agent["name"]: agent for agent in config["agents"]}
# The starter edition ships one agent on purpose. The full edition ships five.
if os.path.exists("pack"):
    assert set(agents) == {"money", "sales", "marketing", "ops", "systems"}
else:
    assert set(agents) == {"money"}
# Whatever ships, every file-backed agent must point at data setup actually creates,
# or a stranger's first run is an empty answer.
for name, agent in agents.items():
    for source in agent["sources"]:
        assert source in agent["source_labels"]
        if source.startswith("file:sample-data/"):
            assert f"cat > {source[5:]} <<'CSV'" in setup
        else:
            assert source.startswith("shell:") or source.startswith("http:")
PY
python3 - <<'PY' >/dev/null 2>&1 \
    && p "API model defaults are current" || f "API model defaults are stale or missing"
text = open("bin/agent-engine.py").read()
for stale in ("gpt-4o" + "-mini", "claude-sonnet-4-5-" + "20250929",
              "anthropic/claude-3" + ".5-sonnet"):
    assert stale not in text
for current in ("gpt-5.4-mini", "claude-sonnet-5",
                "anthropic/claude-sonnet-5"):
    assert current in text
PY
python3 - <<'PY' >/dev/null 2>&1 \
    && p "README config examples are valid JSON" \
    || f "README has an invalid or commented JSON config example"
import json
import os
import re

text = open("README.md").read()
blocks = re.findall(r"^```json\s*$\n(.*?)^```\s*$", text, re.MULTILINE | re.DOTALL)
# The starter edition's README carries no JSON config examples on purpose.
# Whatever is there must still parse.
assert blocks or not os.path.exists("pack")
for block in blocks:
    assert "//" not in block
    json.loads(block)
PY
if [ "$EDITION" = starter ]; then
python3 - <<'PY' >/dev/null 2>&1 \
    && p "README asks for nothing the starter edition does not ship" \
    || f "starter README mentions Buzz, Rust or a file that is not in this repo"
import os
import re

text = open("README.md").read()
for word in ("buzz", "cargo", "rust", "relay", "nostr", "channel"):
    assert not re.search(rf"\b{word}", text, re.IGNORECASE), word
assert "./start.sh" in text
assert "./bin/agent-engine.py ask money" in text
assert "./bin/connect.sh" in text
# Every path the README tells someone to run has to exist in this repo.
for path in set(re.findall(r"\./[A-Za-z0-9_./-]+\.(?:sh|py)", text)):
    assert os.path.exists(path.lstrip("./")) or os.path.exists(path), path
PY
else
python3 - <<'PY' >/dev/null 2>&1 \
    && p "README starts with a command-line path and keeps Buzz optional" \
    || f "README does not present the no-Buzz quick start first"
text = open("README.md").read()
quick = text.index("## Quick start: command line only")
optional = text.index("## Optional: add Buzz chat channels")
cargo = text.index("cargo build --release -p buzz-cli")
assert quick < optional < cargo
section = text[quick:optional]
assert "./bin/setup.sh" in section
assert './bin/agent-engine.py ask money "what is overdue?"' in section
assert "./bin/connect.sh" in section
assert "do not need Rust" in section
setup = open("bin/setup.sh").read()
doctor = open("bin/agent-engine.py").read()
assert "Buzz chat channels are optional" in setup
assert "optional Buzz CLI" in doctor
PY
fi
python3 - <<'PY' >/dev/null 2>&1 \
    && p "ship copy has no long dashes and warns before data connection" \
    || f "ship copy has a long dash or a late privacy notice"
import re

import glob, os
paths = ["README.md", "agents.example.json", ".env.example", "install.sh",
         "bin/setup.sh", "bin/connect.sh", "bin/agent-engine.py"] \
    + sorted(glob.glob("docs/*.md")) + sorted(glob.glob("pack/**/*.md", recursive=True))
for path in paths:
    if not os.path.exists(path):
        continue
    text = open(path).read()
    # The provenance line is a fixed format we do not own the punctuation of.
    text = re.sub(r"^Router key `[^`]+`.*$", "", text, flags=re.MULTILINE)
    assert not re.search(r"[—–]|\\u201[34]", text, re.IGNORECASE), path
# Whatever the edition, the reader has to be warned before the first thing that
# would send their data anywhere. Wording differs; the ordering does not.
readme = open("README.md").read().lower()
notice = readme.index("leave your machine")
assert "model provider" in readme[notice:notice + 400]
assert notice < readme.index("./bin/connect.sh")
PY
env -u BUZZ_RELAY_URL -u BUZZ_PRIVATE_KEY OPENAI_API_KEY=selftest \
    BUZZ_BIN="$TMP/no-buzz-cli" ./bin/agent-engine.py doctor > "$TMP/doctor.out" 2>&1
DOCTOR_STATUS=$?
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && grep -q "Required for command-line questions" "$TMP/doctor.out" \
    && grep -q "Optional for Buzz chat channels" "$TMP/doctor.out" \
    && grep -q "Ready. Try:" "$TMP/doctor.out"; then
    p "doctor accepts a healthy command-line-only setup"
else
    f "doctor rejects a healthy command-line-only setup"
fi
python3 - <<'PY' >/dev/null 2>&1 \
    && p "CLI brains ignore user configuration" || f "CLI brain isolation flags are missing"
import importlib.util
import os
from unittest import mock
s = importlib.util.spec_from_file_location("e", "bin/agent-engine.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
FULL = ("--safe-mode --strict-mcp-config --mcp-config --settings --tools "
        "--no-session-persistence --ephemeral --ignore-user-config "
        "--ignore-rules --sandbox")
claude = m._cli_args("claude", "prompt", help_text=FULL)
codex = m._cli_args("codex", "prompt", help_text=FULL)
assert all(x in claude for x in ("--safe-mode", "--strict-mcp-config", "--mcp-config",
                                  '{"mcpServers":{}}', "{}", "--settings", "--tools",
                                  "--no-session-persistence"))
assert all(x in codex for x in ("--ephemeral", "--ignore-user-config",
                                 "--ignore-rules", "--sandbox", "read-only"))
old = m._cli_args("claude", "prompt",
                  help_text="--strict-mcp-config --mcp-config --settings --tools")
assert "--safe-mode" not in old and "--strict-mcp-config" in old
assert old[-1] == "prompt"
seen = {}
def run(args, **kwargs):
    seen.update(args=args, kwargs=kwargs)
    return type("Result", (), {"returncode": 0, "stdout": "ok", "stderr": ""})()
with mock.patch.object(m.subprocess, "run", run):
    assert m._cli("claude", "system", "user") == "ok"
assert seen["args"][-1] == "system\n\n---\n\nuser"
assert os.path.basename(seen["kwargs"]["cwd"]).startswith("buzz-agent-")
assert not os.path.exists(seen["kwargs"]["cwd"])
PY
python3 - <<'PY' >/dev/null 2>&1 \
    && p "CSV totals are computed exactly in Python" || f "CSV total computation is wrong"
import importlib.util
import os
import tempfile
s = importlib.util.spec_from_file_location("e", "bin/agent-engine.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
sample = """invoice,customer,amount,due_date,status
INV-1043,Northline Freight,4820.00,2026-07-12,overdue
INV-1051,Harbour Dental,1290.50,2026-08-09,open
INV-1052,Volt Electrical,7400.00,2026-08-14,open
INV-1039,Cedar Interiors,2150.00,2026-06-30,overdue
"""
summary = m._csv_summary(sample)
assert "amount total: 15660.50" in summary
assert "amount total where status=overdue: 6970.00" in summary
assert "Do not re-add" in summary
with tempfile.TemporaryDirectory() as directory:
    path = os.path.join(directory, "invoices.csv")
    large = sample + ("INV-X,Extra,1.00,2026-08-20,open\n" * 500)
    with open(path, "w") as fh:
        fh.write(large)
    result = m.src_file([path])
assert "amount total: 16160.50" in result
assert "INCOMPLETE" in result
PY
python3 - <<'PY' >/dev/null 2>&1 \
    && p "HTTP headers stay with their source" || f "HTTP source headers are leaking"
import importlib.util
import os
from unittest import mock
s = importlib.util.spec_from_file_location("e", "bin/agent-engine.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
first = "https://vendor-a.example/report"
second = "https://vendor-b.example/report"
env = {
    m._http_header_prefix(first) + "AUTHORIZATION": "Bearer token-a",
    m._http_header_prefix(second) + "X_API_KEY": "token-b",
    "AGENT_HEADER_AUTHORIZATION": "Bearer legacy-leak",
}
seen = []
class Response:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def read(self): return b"ok"
def open_url(request, timeout):
    seen.append((request.full_url, dict(request.header_items())))
    return Response()
with mock.patch.dict(os.environ, env, clear=True), \
     mock.patch.object(m.urllib.request, "urlopen", open_url):
    assert m.src_http([first]) == "ok"
    assert m.src_http([second]) == "ok"
assert seen == [
    (first, {"Authorization": "Bearer token-a"}),
    (second, {"X-api-key": "token-b"}),
]
PY

bold "Identity"
if [ -f bin/pubkey.sh ]; then
    K="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import os;print(os.urandom(32).hex())')"
    OUT="$(BUZZ_PRIVATE_KEY="$K" ./bin/pubkey.sh 2>&1)"
    printf '%s' "$OUT" | grep -q "npub1" && p "makes a valid ID from a key" || f "could not make an ID"
else
    s "makes a valid ID from a key"
fi

bold "Memory"
./bin/agent-engine.py remember money "selftest note, safe to delete" >/dev/null 2>&1
[ -f "$TMP/memory/money.md" ] && p "remembers what it is told" || f "memory did not save"
./bin/agent-engine.py forget money >/dev/null 2>&1
[ -f "$TMP/memory/money.md" ] && f "forget left the notes behind" || p "forgets on request"

bold "Approval queue"
python3 - <<'PY' >/dev/null 2>&1
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("e", "bin/agent-engine.py")
m = importlib.util.module_from_spec(s); sys.modules["e"] = m; s.loader.exec_module(m)
m.propose({"name": "money"}, "selftest job", "echo hello")
PY
./bin/agent-engine.py pending 2>/dev/null | grep -q "selftest job" \
    && p "an agent can propose a job" || f "proposals are not queueing"
./bin/agent-engine.py approve 1 2>/dev/null | grep -q "hello" \
    && p "approving runs it" || f "approve did not run the job"

bold "The brain"
B="$(./bin/agent-engine.py doctor 2>&1 | grep -m1 'brain' || true)"
printf '%s' "$B" | grep -q '\[ok\]' && p "${B#*brain: }" || f "no model available. Set a key in .env"

python3 - <<'PY' >/dev/null 2>&1 \
    && p "model errors are never posted to a channel" \
    || f "is_model_error misses an engine failure string"
import importlib.util, sys
s = importlib.util.spec_from_file_location("e", "bin/agent-engine.py")
m = importlib.util.module_from_spec(s); sys.modules["e"] = m; s.loader.exec_module(m)
assert m.is_model_error("Could not reach the model (401). x")
assert m.is_model_error("(the claude command failed: boom)")
assert not m.is_model_error("Total owed: $15,660.50")
PY

bold "A real question"
if [ "${SELFTEST_SKIP_LIVE:-0}" = "1" ]; then
    p "SKIPPED (SELFTEST_SKIP_LIVE=1): live model question, run without the flag before shipping"
    p "SKIPPED (SELFTEST_SKIP_LIVE=1): live refusal check, run without the flag before shipping"
    bold "Result"
    if [ "$FAIL" -eq 0 ]; then
        printf '  %s checks passed (2 live checks skipped).\n' "$PASS"
        exit 0
    fi
    printf '  %s passed, %s failed. Fix the ✗ lines above and run this again.\n' "$PASS" "$FAIL"
    exit 1
fi
mkdir -p "$TMP/d"
printf 'invoice,customer,amount,status\nA-1,Test Co,100.00,overdue\nA-2,Other Co,250.00,open\n' > "$TMP/d/i.csv"
python3 - "$TMP" <<'PY'
import json, sys
p = f"{sys.argv[1]}/agents.json"; d = json.load(open(p))
for a in d["agents"]:
    if a["name"] == "money":
        a["sources"] = [f"file:{sys.argv[1]}/d/i.csv"]
        a["source_labels"] = {f"file:{sys.argv[1]}/d/i.csv": "test invoices"}
json.dump(d, open(p, "w"))
PY
A="$(./bin/agent-engine.py ask money "What is the total owed? Give the number only." 2>&1 | head -4)"
printf '%s' "$A" | grep -qE '350|\$350' && p "answers correctly from a file (350 total)" \
    || f "wrong or no answer. Got: $(printf '%s' "$A" | head -1)"

bold "Will not make things up"
A2="$(./bin/agent-engine.py ask money "What was our profit margin last quarter?" 2>&1 | head -3)"
REFUSAL="can.t|cannot|don.t|doesn.t|won.t|unable|not (in|available|covered|provided|something)|no (data|payment|record|information|profit|margin|benchmark)|does not (cover|have|include)|isn.t (in|available)"
printf '%s' "$A2" | grep -qiE "$REFUSAL" && p "refuses what it does not have" \
    || f "it may have invented an answer. Check: $(printf '%s' "$A2" | head -1)"

bold "Result"
if [ "$FAIL" -eq 0 ]; then
    printf '  %s checks passed. Everything works.\n' "$PASS"
    exit 0
fi
printf '  %s passed, %s failed. Fix the ✗ lines above and run this again.\n' "$PASS" "$FAIL"
exit 1
