#!/usr/bin/env bash
# Put the agents on a schedule: a briefing each morning, and a check for
# questions every few minutes. Run again to update; it never doubles up.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E="$ROOT/bin/agent-engine.py"
MARK="# agent-team"

current="$(crontab -l 2>/dev/null | grep -v "$MARK" || true)"
{
    printf '%s\n' "$current"
    # cron starts with a bare PATH, so a CLI-based brain would never be found.
    printf 'PATH=%s %s\n' "$PATH" "$MARK"
    printf "0 8 * * * cd '%s' && '%s' brief money >> '%s/.state/agents.log' 2>&1 %s\n" "$ROOT" "$E" "$ROOT" "$MARK"
    printf "5 8 * * * cd '%s' && '%s' brief sales >> '%s/.state/agents.log' 2>&1 %s\n" "$ROOT" "$E" "$ROOT" "$MARK"
    printf "*/5 * * * * cd '%s' && '%s' watch-all >> '%s/.state/agents.log' 2>&1 %s\n" "$ROOT" "$E" "$ROOT" "$MARK"
} | crontab -
mkdir -p "$ROOT/.state"
echo "Scheduled. Briefings at 8am, questions checked every 5 minutes."
echo "Note: a sleeping laptop runs nothing. Leave it awake, or put this on an always-on machine."
echo "Remove any time with:  crontab -l | grep -v '$MARK' | crontab -"
