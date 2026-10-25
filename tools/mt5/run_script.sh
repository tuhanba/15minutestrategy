#!/usr/bin/env bash
# usage: run_script.sh <script.mq5 in $T> [set file]   compiles into MQL5\Scripts\RBOTE_Tools and runs it headless
set -uo pipefail
. "$(dirname "$0")/env.sh"
SRC=$1; B=$(basename "$SRC" .mq5); SET=${2:-}
[ -e /tmp/.X11-unix/X91 ] && pgrep -x Xvfb >/dev/null || { rm -f /tmp/.X91-lock /tmp/.X11-unix/X91; setsid nohup Xvfb :91 -screen 0 1024x768x24 </dev/null >/dev/null 2>&1 & sleep 2; }
mkdir -p "$MT5/MQL5/Scripts/RBOTE_Tools"; cp "$T/$SRC" "$MT5/MQL5/Scripts/RBOTE_Tools/"
cd "$MT5"
timeout 300 "$WINE" MetaEditor64.exe /portable /compile:"C:\\MT5\\MQL5\\Scripts\\RBOTE_Tools\\$B.mq5" /include:'C:\MT5\MQL5' /log:"C:\\MT5\\c_$B.log" >/dev/null 2>&1
iconv -f UTF-16 -t UTF-8 "c_$B.log" | tr -d '\r' | grep -E "error|Result"
iconv -f UTF-16 -t UTF-8 "c_$B.log" | grep -q "Result: 0 errors" || { "$WINESERVER" -k; exit 1; }
{ printf '[StartUp]\r\nScript=RBOTE_Tools\\%s\r\n' "$B"; [ -n "$SET" ] && { cp "$T/$SET" "$MT5/MQL5/Presets/"; printf 'ScriptParameters=%s\r\n' "$SET"; }; printf 'Symbol=EURUSD\r\nPeriod=H1\r\nShutdownTerminal=1\r\n'; } > "$MT5/script_run.ini"
timeout ${SCRIPT_TIMEOUT:-1800} "$WINE" terminal64.exe /portable /config:'C:\MT5\script_run.ini' >/dev/null 2>&1
"$WINESERVER" -k 2>/dev/null || true
iconv -f UTF-16 -t UTF-8 "MQL5/logs/$(date -u +%Y%m%d).log" | tr -d '\r' | grep "$B" | tail -5
