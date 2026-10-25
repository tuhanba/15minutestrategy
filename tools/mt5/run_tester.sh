#!/usr/bin/env bash
# usage: run_tester.sh <name> <from YYYY.MM.DD> <to YYYY.MM.DD> [model: 4=real ticks (default), 1=1 minute OHLC, 0=every tick]
# Collects report, EA trades/journal (Common\Files\RBOTE), terminal + tester agent logs into runs/<name>/
set -uo pipefail
. "$(dirname "$0")/env.sh"
NAME=$1; FROM=$2; TO=$3; MODEL=${4:-4}
OUT=$T/runs/$NAME; rm -rf "$OUT"; mkdir -p "$OUT"
[ -e /tmp/.X11-unix/X91 ] && pgrep -x Xvfb >/dev/null || { rm -f /tmp/.X91-lock /tmp/.X11-unix/X91; setsid nohup Xvfb :91 -screen 0 1024x768x24 </dev/null >/dev/null 2>&1 & sleep 2; }
cp "$T/rbote_cmp.set" "$MT5/MQL5/Profiles/Tester/rbote_cmp.set"
rm -rf "$COMMON/Files/RBOTE"; mkdir -p "$MT5/reports"
sed -e "s/@MODEL@/$MODEL/" -e "s/@FROM@/$FROM/" -e "s/@TO@/$TO/" -e "s/@NAME@/$NAME/" "$T/tester_template.ini" | sed 's/$/\r/' > "$MT5/tester_run.ini"
cp "$MT5/tester_run.ini" "$OUT/tester.ini"
start=$(date +%s)
cd "$MT5"
timeout ${TESTER_TIMEOUT:-3600} "$WINE" terminal64.exe /portable /config:'C:\MT5\tester_run.ini' >/dev/null 2>&1; echo "terminal rc=$? after $(( $(date +%s)-start ))s"
"$WINESERVER" -k 2>/dev/null || true
d=$(date -u +%Y%m%d)
cp -a "$MT5/reports/$NAME"* "$OUT/" 2>/dev/null
cp -a "$COMMON/Files/RBOTE/." "$OUT/" 2>/dev/null
for f in "$MT5/logs/$d.log" "$MT5/Tester/logs/$d.log"; do [ -f "$f" ] && iconv -f UTF-16 -t UTF-8 "$f" | tr -d '\r' > "$OUT/$(basename $(dirname $(dirname $f)))_$(basename $(dirname $f))_$d.log"; done
for f in "$MT5"/Tester/Agent-*/logs/$d.log; do [ -f "$f" ] && iconv -f UTF-16 -t UTF-8 "$f" | tr -d '\r' > "$OUT/agent_$(basename $(dirname $(dirname $f)))_$d.log"; done
ls -la "$OUT"
