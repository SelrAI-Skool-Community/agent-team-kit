#!/usr/bin/env bash
# Create one channel per agent and write the ids back into .env.
# Safe to run again. An existing channel is reused, never duplicated.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Load settings ourselves so this works standalone, not only via install.sh.
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
export BUZZ_RELAY_URL BUZZ_PRIVATE_KEY
BUZZ_BIN="${BUZZ_BIN:-$(command -v buzz)}"
[ -n "${BUZZ_RELAY_URL:-}" ] && [ -n "${BUZZ_PRIVATE_KEY:-}" ] || {
    echo "  [--]   no relay or identity in .env. Run ./bin/setup.sh first"; exit 1; }
command -v jq >/dev/null || { echo "  [--]   jq is needed here. Install jq and run again"; exit 1; }

existing="$("$BUZZ_BIN" channels list 2>/dev/null)"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT; chmod 600 "$tmp"
grep -vE '^CH_' .env > "$tmp" 2>/dev/null || true

LIST="$(mktemp)"
python3 - "$ROOT" <<'PY' > "$LIST"
import json, sys
d = json.load(open(f"{sys.argv[1]}/agents.json"))
for a in d["agents"]:
    print(f"{a.get('channel_env','')}|{a.get('channel','').lstrip('#')}|{a.get('purpose','')}")
PY

while IFS='|' read -r env name purpose; do
    [ -n "$env" ] && [ -n "$name" ] || continue
    id="$(printf '%s' "$existing" | jq -r --arg n "$name" \
        'if type=="array" then (.[]|select(.name==$n)|.channel_id) else empty end' 2>/dev/null | head -1)"
    if [ -z "$id" ] || [ "$id" = "null" ]; then
        id="$("$BUZZ_BIN" channels create --name "$name" --type stream --visibility open 2>/dev/null | jq -r '.channel_id // empty')"
        [ -n "$id" ] && [ -n "$purpose" ] && "$BUZZ_BIN" channels purpose --channel "$id" --purpose "$purpose" >/dev/null 2>&1
    fi
    if [ -n "$id" ]; then
        printf '%s=%s\n' "$env" "$id" >> "$tmp"
        printf '  [ok]   #%s\n' "$name"
    else
        printf '  [--]   #%s could not be created\n' "$name"
    fi
done < "$LIST"

if grep -qE '^CH_.+=.' "$tmp"; then
    cp "$tmp" .env; chmod 600 .env
    echo "  [ok]   channel ids written to .env"
else
    echo "  [--]   no channels were created. Your settings are exactly as they were"
fi
rm -f "$LIST"

# Give the agent identity a readable name so posts never show as bare hex.
ME="$(./bin/pubkey.sh 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
if [ -n "$ME" ]; then
    has_name="$("$BUZZ_BIN" users get --pubkey "$ME" 2>/dev/null \
        | jq -r '.[0].display_name // empty' 2>/dev/null)"
    [ -n "$has_name" ] || "$BUZZ_BIN" users set-profile --name "Agent Team" \
        --about "Posts briefs and answers questions in its channels." >/dev/null 2>&1 || true
fi

# A channel only appears in someone's app if they are a member. Add the human
# who owns the workspace's #general channel to every agent channel as admin.
gen="$(printf '%s' "$existing" | jq -r \
    'if type=="array" then (.[]|select(.name=="general")|.channel_id) else empty end' 2>/dev/null | head -1)"
owner=""
[ -n "$gen" ] && owner="$("$BUZZ_BIN" channels members --channel "$gen" 2>/dev/null \
    | jq -r '.[]|select(.role=="owner")|.pubkey' 2>/dev/null | head -1)"
if [ -n "$owner" ]; then
    added=0
    while IFS='=' read -r k v; do
        case "$k" in CH_*)
            "$BUZZ_BIN" channels add-member --channel "$v" --pubkey "$owner" \
                --role admin >/dev/null 2>&1 && added=$((added+1)) ;;
        esac
    done < .env
    [ "$added" -gt 0 ] && echo "  [ok]   added you to $added channels so they show up in your app"
else
    echo "  [--]   could not tell which member is you. Open the app's channel browser and join them"
fi
