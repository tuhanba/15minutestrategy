#!/usr/bin/env python3
"""Trade-by-trade comparison: MT5 tester trades CSV (EA journal) vs C++ rbote_bt trades CSV.
usage: compare_trades.py <mt5_trades.csv> <cpp_trades.csv> [--mt5-commission-missing 6]
Both files use the EA journal schema (semicolon). Rows are joined on signal_id.
--mt5-commission-missing X : the custom-symbol tester charged no commission -> subtract X*lots from MT5 net
before comparing R (the EA's risk_money already includes commission in lot sizing)."""
import csv, sys
def load(p):
    with open(p, newline='') as f:
        return {r['signal_id']: r for r in csv.DictReader(f, delimiter=';')}
args = sys.argv[1:]
comm = 0.0
if '--mt5-commission-missing' in args:
    i = args.index('--mt5-commission-missing'); comm = float(args[i + 1]); del args[i:i + 2]
mt, cp = load(args[0]), load(args[1])
ids = sorted(set(mt) | set(cp), key=lambda s: int(s.split('|')[2]))
f = lambda r, k: float(r[k]) if r and r.get(k) not in (None, '') else float('nan')
print('%-22s %-5s %10s %10s %10s %6s %6s %-6s %-6s %8s %8s  %s' % ('signal_id', 'side', 'entry', 'sl', 'tp', 'lotM', 'lotC', 'exitM', 'exitC', 'R_mt5', 'R_cpp', 'note'))
nm = 0
for s in ids:
    a, b = mt.get(s), cp.get(s)
    notes = []
    if not a: notes.append('ONLY_CPP')
    if not b: notes.append('ONLY_MT5')
    rm = float('nan')
    if a:
        net = f(a, 'net') - comm * f(a, 'volume'); rm = net / f(a, 'risk_money') if f(a, 'risk_money') else float('nan')
    if a and b:
        for k in ('planned_entry', 'sl', 'tp'):
            if abs(f(a, k) - f(b, k)) > 0.005: notes.append(k + '_DIFF')
        if abs(f(a, 'volume') - f(b, 'volume')) > 1e-9: notes.append('LOTS_DIFF')
        if a['exit_reason'] != b['exit_reason']: notes.append('EXIT_DIFF')
        if a['open_time'].replace('.', '-') != b['open_time'].replace('.', '-'): notes.append('FILLTIME %s vs %s' % (a['open_time'], b['open_time']))
        if abs(rm - f(b, 'r')) > 0.05: notes.append('R_DIFF')
    if notes: nm += 1
    r = a or b
    print('%-22s %-5s %10s %10s %10s %6s %6s %-6s %-6s %8.3f %8.3f  %s' % (s, 'BUY' if r['dir'] == '1' else 'SELL', r['planned_entry'], r['sl'], r['tp'],
          a['volume'] if a else '-', b['volume'] if b else '-', a['exit_reason'] if a else '-', b['exit_reason'] if b else '-', rm, f(b, 'r'), ' '.join(notes)))
sm = sum((f(a, 'net') - comm * f(a, 'volume')) for a in mt.values()); sc = sum(f(b, 'net') for b in cp.values())
print('\nMT5 trades %d net %.2f | C++ trades %d net %.2f | rows with differences %d' % (len(mt), sm, len(cp), sc, nm))
