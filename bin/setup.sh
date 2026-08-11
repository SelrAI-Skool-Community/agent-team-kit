#!/usr/bin/env bash
# One command for local agents, with optional Buzz channel questions.
#
#   ./bin/setup.sh
#
# Safe to run again. It keeps anything you have already set.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  ✓ %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
# Ask a question. Returns empty if there is no terminal to ask on (piped install,
# ssh without a tty) rather than crashing or reusing a previous answer.
ask() {
    local answer=""
    printf '%s ' "$1" >&2
    if { exec 3</dev/tty; } 2>/dev/null; then
        read -r answer <&3 || answer=""
        exec 3<&-
    else
        printf '(no terminal, skipped)\n' >&2
    fi
    printf '%s' "$answer"
}

setenv() {  # setenv KEY value: replace or append in .env, never duplicate
    local k="$1" v="$2"
    touch .env
    if grep -q "^${k}=" .env 2>/dev/null; then
        python3 - "$k" "$v" <<'PY'
import io, re, sys
k, v = sys.argv[1], sys.argv[2]
s = io.open(".env").read()
io.open(".env", "w").write(re.sub(rf'^{re.escape(k)}=.*$', f'{k}={v}', s, flags=re.M))
PY
    else
        printf '%s=%s\n' "$k" "$v" >> .env
    fi
}

clear 2>/dev/null || true
bold "Your command-line agent team"
echo "Five agents that answer questions from your own data."
echo "Buzz chat channels are optional. Press return to skip anything you do not use."

# ---------------------------------------------------------------- prerequisites
step "Checking what you already have"
command -v python3 >/dev/null || { warn "Python 3 is needed. Install it, then run this again."; exit 1; }
ok "Python $(python3 -V 2>&1 | awk '{print $2}')"
if command -v jq >/dev/null; then ok "jq (optional, for Buzz channels)"; else
    warn "jq is missing. Command-line mode works; optional Buzz channels need jq."
    echo "         To add channels later: brew install jq"
fi

[ -f .env ] || { cp .env.example .env; chmod 600 .env; }
[ -f agents.json ] || cp agents.example.json agents.json
# Load .env without clobbering anything already exported in the shell:
# a key the user exported beats an empty template line in .env.
load_env() {
    while IFS='=' read -r k v; do
        case "$k" in ''|\#*) continue ;; esac
        [ -n "${!k:-}" ] || export "$k=$v"
    done < .env
}
load_env 2>/dev/null || true

BUZZ_BIN="${BUZZ_BIN:-$(command -v buzz || true)}"
if [ -n "$BUZZ_BIN" ]; then ok "Buzz tool found"; else warn "Buzz tool not found. You can still use the agents from the command line"; fi

# ----------------------------------------------------------------------- brain
step "1. The brain"
BRAIN_OK=""
for v in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    [ -n "${!v:-}" ] && BRAIN_OK="$v" && break
done
if [ -n "$BRAIN_OK" ]; then
    ok "Using the key already in your settings ($BRAIN_OK)"
elif command -v claude >/dev/null && claude -p --tools "" "reply with exactly: ok" >/dev/null 2>&1; then
    ok "Using Claude Code, already on this machine. Nothing to enter"
    BRAIN_OK=cli
elif command -v claude >/dev/null && { warn "Claude Code is here but not answering (not logged in?). Run: claude /login"; false; }; then
    :
elif command -v codex >/dev/null; then
    ok "Using Codex, already on this machine. Nothing to enter"
    BRAIN_OK=cli
elif curl -s --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    ok "Using the models running on this machine"
    BRAIN_OK=local
else
    echo "  The agents need a model to think with. Paste any one of these keys."
    echo "  (an OpenAI key starts sk-, an Anthropic key starts sk-ant-)"
    K="$(ask '  Paste a key, or press return to skip:')"
    if [ -n "$K" ]; then
        case "$K" in
            sk-ant-*) setenv ANTHROPIC_API_KEY "$K"; ok "Anthropic key saved" ;;
            sk-or-*)  setenv OPENROUTER_API_KEY "$K"; ok "OpenRouter key saved" ;;
            *)        setenv OPENAI_API_KEY "$K"; ok "OpenAI key saved" ;;
        esac
        BRAIN_OK=key
    else
        warn "Skipped. The agents will not answer until a key is added to .env"
    fi
fi

# -------------------------------------------------------------------- identity
step "2. Optional Buzz identity"
if [ -n "${BUZZ_PRIVATE_KEY:-}" ]; then
    ok "Already have one"
else
    KEY="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import os;print(os.urandom(32).hex())')"
    setenv BUZZ_PRIVATE_KEY "$KEY"
    ok "Made one. Your agents post as themselves, never as you."
fi

# ----------------------------------------------------------------------- relay
step "3. Optional Buzz workspace"
if [ -n "${BUZZ_RELAY_URL:-}" ]; then
    ok "Already pointed at $BUZZ_RELAY_URL"
else
    echo "  In the Buzz app, right-click your workspace and choose Copy community URL."
    R="$(ask '  Paste it, or press return to skip:')"
    if [ -n "$R" ]; then
        case "$R" in ws://*|wss://*) : ;; *) R="wss://${R#https://}"; R="${R#http://}" ;; esac
        setenv BUZZ_RELAY_URL "$R"; ok "Saved"
    else
        warn "Skipped. Agents will work from the command line but not post to channels."
    fi
fi
load_env 2>/dev/null || true

# ---------------------------------------------------------------- add the agent
if [ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_PRIVATE_KEY:-}" ] && [ -n "$BUZZ_BIN" ]; then
    step "4. Letting your agents into the workspace"
    export BUZZ_RELAY_URL BUZZ_PRIVATE_KEY
    if "$BUZZ_BIN" channels list >/dev/null 2>&1; then
        ok "Already a member"
    else
        echo "  Your agents need to be let in once. Here is their ID:"
        echo
        ./bin/pubkey.sh 2>/dev/null | sed -n '3p'
        echo
        echo "  In the Buzz app: right-click your workspace → Invite to community →"
        echo "  paste that in → Invite."
        ask '  Press return once you have done that:' >/dev/null
        if "$BUZZ_BIN" channels list >/dev/null 2>&1; then
            ok "In. Creating the channels..."
            ./bin/make-channels.sh
        else
            warn "Still cannot get in. Run ./bin/setup.sh again once the invite is done."
        fi
    fi
fi

# ------------------------------------------------------------------- try it out
step "Trying it out"
mkdir -p sample-data memory .state
if [ ! -f sample-data/invoices.csv ]; then
    cat > sample-data/invoices.csv <<'CSV'
invoice,customer,amount,due_date,status
INV-1043,Northline Freight,4820.00,2026-07-12,overdue
INV-1051,Harbour Dental,1290.50,2026-08-09,open
INV-1052,Volt Electrical,7400.00,2026-08-14,open
INV-1039,Cedar Interiors,2150.00,2026-06-30,overdue
CSV
    ok "Put some sample invoices in sample-data/ so you can see it work"
fi

if [ ! -f sample-data/pipeline.csv ]; then
    cat > sample-data/pipeline.csv <<'CSV'
opportunity,customer,value,stage,owner,last_activity
Website refresh,Harbour Dental,12500.00,proposal,Mia,2026-08-06
Fleet reporting,Northline Freight,24000.00,discovery,Sam,2026-08-01
Service rollout,Volt Electrical,8600.00,quote,Mia,2026-08-07
Office fitout,Cedar Interiors,5100.00,lead,Sam,2026-07-22
CSV
    ok "Put a sample sales pipeline in sample-data/"
fi

if [ ! -f sample-data/ad-spend.csv ]; then
    cat > sample-data/ad-spend.csv <<'CSV'
campaign,period,spend,leads
Search - Brisbane,2026-08-01 to 2026-08-07,840.00,21
LinkedIn - Operations,2026-08-01 to 2026-08-07,625.50,9
Remarketing,2026-08-01 to 2026-08-07,310.00,14
CSV
    ok "Put sample advertising results in sample-data/"
fi

if [ ! -f sample-data/tasks.csv ]; then
    cat > sample-data/tasks.csv <<'CSV'
task,owner,status,opened,due_date
Confirm September roster,Asha,open,2026-07-18,2026-08-05
Replace warehouse scanner,Noah,blocked,2026-07-24,2026-08-02
Review supplier agreement,Mia,open,2026-07-29,2026-08-12
Update client onboarding checklist,Sam,open,2026-08-03,2026-08-15
CSV
    ok "Put a sample task board in sample-data/"
fi

if [ -n "$BRAIN_OK" ]; then
    echo
    ./bin/agent-engine.py ask money "In two lines: what am I owed and what is overdue?" 2>&1 | head -6
fi

step "You're set up."
cat <<'EOF'
  Ask an agent something     ./bin/agent-engine.py ask money "what's overdue?"
  Teach it something         ./bin/agent-engine.py remember money "Acme always pays late"
  Point it at your own data  ./bin/connect.sh
  Post to Buzz every morning ./bin/schedule.sh
  Check everything           ./bin/agent-engine.py doctor
EOF
