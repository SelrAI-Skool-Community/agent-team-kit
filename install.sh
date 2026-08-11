#!/usr/bin/env bash
# Set up your agent team in Buzz. Safe to run more than once.
#
#   ./install.sh
#
# It checks what you already have, fills in what it can, creates the channels,
# and tells you plainly about anything only you can provide.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
no()   { printf '  [--]   %s\n' "$*"; }
head2(){ printf '\n%s\n' "$*"; }

say "Agent team for Buzz: setup"

# ---------------------------------------------------------------- 1. python
head2 "1. Python"
if command -v python3 >/dev/null; then
    ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"
else
    no "python3 not found. Install Python 3.9 or newer, then run this again."
    exit 1
fi

# ------------------------------------------------------------------ 2. buzz
head2 "2. Buzz command-line tool"
BUZZ_BIN="${BUZZ_BIN:-$(command -v buzz || true)}"
if [ -n "$BUZZ_BIN" ] && [ -x "$BUZZ_BIN" ]; then
    ok "found at $BUZZ_BIN"
else
    no "not found."
    say "         Build it once from the Buzz source:"
    say "           git clone https://github.com/block/buzz && cd buzz"
    say "           cargo build --release -p buzz-cli"
    say "         then either put target/release/buzz on your PATH,"
    say "         or set BUZZ_BIN to its full path and run this again."
fi

# ------------------------------------------------------------------- 3. env
head2 "3. Settings"
if [ ! -f .env ]; then
    cp .env.example .env
    ok "created .env from the example. Open it and fill in the blanks"
else
    ok ".env already exists, leaving it alone"
fi
# shellcheck disable=SC1091
[ -f .env ] && . ./.env

[ -n "${BUZZ_RELAY_URL:-}" ] && ok "relay: $BUZZ_RELAY_URL" || no "BUZZ_RELAY_URL is empty in .env"
[ -n "${BUZZ_PRIVATE_KEY:-}" ] && ok "identity: set" || no "BUZZ_PRIVATE_KEY is empty in .env"

# ----------------------------------------------------------------- 4. brain
head2 "4. The brain"
BRAIN=""
for v in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    [ -n "${!v:-}" ] && BRAIN="$v" && break
done
if [ -n "$BRAIN" ]; then
    ok "using $BRAIN"
elif command -v claude >/dev/null; then
    ok "using the Claude Code CLI already on this machine"
elif command -v codex >/dev/null; then
    ok "using the Codex CLI already on this machine"
elif curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "using Ollama running locally"
else
    no "no brain found."
    say "         Any ONE of these is enough. Put a key in .env, or install a CLI:"
    say "           OPENAI_API_KEY=...     or  ANTHROPIC_API_KEY=..."
    say "           OPENROUTER_API_KEY=... or  the Claude Code / Codex CLI"
    say "           or run Ollama locally (ollama serve)"
fi

# --------------------------------------------------------------- 5. agents
head2 "5. Agents"
if [ ! -f agents.json ]; then
    cp agents.example.json agents.json
    ok "created agents.json from the starter set"
else
    ok "agents.json already exists, leaving it alone"
fi
python3 - <<'PY'
import json, sys
try:
    d = json.load(open("agents.json"))
    names = [a["name"] for a in d["agents"]]
    print(f"  [ok]   {len(names)} agents: {', '.join(names)}")
except Exception as e:
    print(f"  [--]   agents.json is not valid: {e}")
    sys.exit(1)
PY

# -------------------------------------------------------------- 6. channels
head2 "6. Channels"
if [ -n "${BUZZ_BIN:-}" ] && [ -x "${BUZZ_BIN:-}" ] && [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_PRIVATE_KEY:-}" ]; then
    export BUZZ_RELAY_URL BUZZ_PRIVATE_KEY
    if "$BUZZ_BIN" channels list >/dev/null 2>&1; then
        ok "connected to the relay"
        ./bin/make-channels.sh || no "channel setup hit a problem, see above"
    else
        no "could not reach the relay with that identity."
        say "         Two usual causes: the relay address is wrong, or this identity"
        say "         has not been added to the workspace yet. Add its public key as a"
        say "         member in the Buzz app, then run this again."
    fi
else
    no "skipped: needs the Buzz tool, a relay address and an identity first"
fi

head2 "Done."
say "Check everything:   ./bin/agent-engine.py doctor"
say "Talk to an agent:   ./bin/agent-engine.py ask money \"how are we doing?\""
say "Post an update:     ./bin/agent-engine.py brief money"
say "Run on a schedule:  ./bin/schedule.sh"
