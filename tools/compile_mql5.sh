#!/usr/bin/env bash
# Compile the EA and the test script with MetaEditor under Wine, then run the MQL5 unit tests
# inside the terminal (headless). Linux only; see docs/BACKTEST.md "MetaEditor under Wine".
#
# Requirements (one-time):
#   - Wine 10+ from WineHQ (Ubuntu's Wine 9.0 triggers MetaEditor's anti-debug check)
#   - an MT5 install run once with /portable so that MQL5/ (standard library) exists
# Environment:
#   WINE   path to the wine binary          (default: wine)
#   MT5    unix path of the portable MT5 dir (required), e.g. $WINEPREFIX/drive_c/MT5
#   MT5WIN windows path of the same dir      (default: C:\MT5)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE="${WINE:-wine}"
: "${MT5:?set MT5 to the portable MetaTrader 5 directory}"
MT5WIN="${MT5WIN:-C:\\MT5}"
export WINEDEBUG=-all

for d in Experts Scripts Include Presets; do
  mkdir -p "$MT5/MQL5/$d"
  cp -a "$ROOT/MQL5/$d/." "$MT5/MQL5/$d/"
done

status=0
cd "$MT5"
for src in 'Experts\RBOTE\RBOTE_EA.mq5' 'Scripts\RBOTE\RBOTE_Tests.mq5'; do
  log="$MT5/compile_$(basename "${src//\\//}" .mq5).log"
  "$WINE" MetaEditor64.exe /portable /compile:"$MT5WIN\\MQL5\\$src" /include:"$MT5WIN\\MQL5" /log:"$MT5WIN\\$(basename "$log")" || true
  result=$(iconv -f UTF-16 -t UTF-8 "$log" | tr -d '\r' | grep -E "error|warning|Result:" || true)
  echo "== $src"; echo "$result"
  echo "$result" | grep -q "Result: 0 errors" || status=1
done

printf '[StartUp]\r\nScript=RBOTE\\RBOTE_Tests\r\nSymbol=EURUSD\r\nPeriod=H1\r\nShutdownTerminal=1\r\n' > "$MT5/run_tests.ini"
timeout 300 "$WINE" terminal64.exe /portable /config:"$MT5WIN\\run_tests.ini" || true
out=$(iconv -f UTF-16 -t UTF-8 "$MT5/MQL5/logs/$(date +%Y%m%d).log" | tr -d '\r' | grep "RBOTE tests" | tail -2 || true)
echo "== MQL5 unit tests"; echo "$out"
echo "$out" | grep -q "ALL PASSED" || status=1
exit $status
