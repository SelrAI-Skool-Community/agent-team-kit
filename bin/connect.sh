#!/usr/bin/env bash
# Point an agent at your real data. Pick from a list, answer one question.
#
#   ./bin/connect.sh
#
# Nothing here needs you to edit a file or know a path format.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ask() { printf '%s ' "$1" >&2; read -r REPLY </dev/tty; printf '%s' "$REPLY"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "Connect an agent to your data"
echo
python3 - <<'PY'
import json
d = json.load(open("agents.json"))
for i, a in enumerate(d["agents"], 1):
    srcs = ", ".join(s.split(":", 1)[0] for s in a.get("sources", [])) or "nothing yet"
    print(f"  {i}. {a['name']:<10} {a.get('purpose','')[:46]:<48} [{srcs}]")
PY
echo
N="$(ask 'Which agent? (number)')"
AGENT="$(python3 - "$N" <<'PYPICK'
import json, sys
d = json.load(open("agents.json"))
try:
    print(d["agents"][int(sys.argv[1]) - 1]["name"])
except (ValueError, IndexError, KeyError):
    print("")
PYPICK
)"
[ -n "$AGENT" ] || { echo "That wasn't one of the numbers."; exit 1; }

echo
bold "Where does $AGENT's data come from?"
cat <<'EOF'
  1. A spreadsheet or CSV file on this computer
  2. A report I can export whenever I want
  3. A web address that returns data
  4. A command I already run to get the numbers
  5. Google Sheets (published to the web)
EOF
echo
K="$(ask 'Which one? (number)')"

case "$K" in
  1|2)
      P="$(ask 'Drag the file here, or paste its path:')"
      P="${P%\'}"; P="${P#\'}"; P="$(printf '%s' "$P" | xargs 2>/dev/null || printf '%s' "$P")"
      [ -f "$P" ] || { echo "Cannot find a file there."; exit 1; }
      L="$(ask 'In a few words, what is in it?')"
      SRC="file:$P" ;;
  3)
      U="$(ask 'Paste the web address:')"
      L="$(ask 'In a few words, what does it return?')"
      SRC="http:$U"
      H="$(ask 'Does it need a password or token? Paste it, or press return for none:')"
      if [ -n "$H" ]; then
        HEADER_KEY="$(python3 - "$U" <<'PYKEY'
import hashlib, sys
digest = hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:16].upper()
print(f"AGENT_HEADER_{digest}_AUTHORIZATION")
PYKEY
)"
        ./bin/set-env.py "$HEADER_KEY" "Bearer $H"
      fi ;;
  4)
      C="$(ask 'Paste the command:')"
      L="$(ask 'In a few words, what does it print?')"
      SRC="shell:$C" ;;
  5)
      echo "  In Sheets: File → Share → Publish to web → choose Comma-separated values."
      U="$(ask 'Paste the address it gives you:')"
      L="$(ask 'In a few words, what is in the sheet?')"
      SRC="http:$U" ;;
  *)  echo "That wasn't one of the numbers."; exit 1 ;;
esac

python3 - "$AGENT" "$SRC" "${L:-data}" <<'PY'
import json, sys
name, src, label = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open("agents.json"))
for a in d["agents"]:
    if a["name"] == name:
        a.setdefault("sources", [])
        if src not in a["sources"]:
            a["sources"].append(src)
        a.setdefault("source_labels", {})[src] = label
json.dump(d, open("agents.json", "w"), indent=2)
print(f"\n  ✓ {name} is now reading: {label}")
PY

echo
echo "  Try it:  ./bin/agent-engine.py ask $AGENT \"what does this tell me?\""
echo "  Add more sources by running this again."
