#!/usr/bin/env bash
# usage: run_import.sh <csv> [<csv>...]   (Dukascopy M1 semicolon CSVs) -> custom symbol XAUUSD.DK
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ -e /tmp/.X11-unix/X91 ] && pgrep -x Xvfb >/dev/null || { rm -f /tmp/.X91-lock /tmp/.X11-unix/X91; setsid nohup Xvfb :91 -screen 0 1024x768x24 </dev/null >/dev/null 2>&1 & sleep 2; }
mkdir -p "$COMMON/Files/RBOTE_DATA" "$MT5/MQL5/Scripts/RBOTE_Tools"
names=()
for f in "$@"; do cp "$f" "$COMMON/Files/RBOTE_DATA/"; names+=("$(basename "$f")"); done
list=$(IFS=,; echo "${names[*]}")
cp "$T/RBOTE_ImportDukascopy.mq5" "$MT5/MQL5/Scripts/RBOTE_Tools/"
cd "$MT5"
timeout 300 "$WINE" MetaEditor64.exe /portable /compile:'C:\MT5\MQL5\Scripts\RBOTE_Tools\RBOTE_ImportDukascopy.mq5' /include:'C:\MT5\MQL5' /log:'C:\MT5\c_import.log' >/dev/null 2>&1 || true
iconv -f UTF-16 -t UTF-8 c_import.log | tr -d '\r' | grep -E "error|Result"
iconv -f UTF-16 -t UTF-8 c_import.log | grep -q "Result: 0 errors" || { echo "compile failed"; exit 1; }
printf 'InpSymbol=XAUUSD.DK\r\nInpDir=RBOTE_DATA\r\nInpFiles=%s\r\nInpTicks=true\r\nInpDigits=3\r\nInpTickSize=0.01\r\nInpTickVal=1.0\r\n' "$list" > "$MT5/MQL5/Presets/import_run.set"
printf '[StartUp]\r\nScript=RBOTE_Tools\\RBOTE_ImportDukascopy\r\nScriptParameters=import_run.set\r\nSymbol=EURUSD\r\nPeriod=H1\r\nShutdownTerminal=1\r\n' > "$MT5/import.ini"
timeout 3600 "$WINE" terminal64.exe /portable /config:'C:\MT5\import.ini' >/dev/null 2>&1 || true
"$WINESERVER" -k 2>/dev/null || true
iconv -f UTF-16 -t UTF-8 "MQL5/logs/$(date +%Y%m%d).log" | tr -d '\r' | grep RBOTE_ImportDukascopy | tail -40
