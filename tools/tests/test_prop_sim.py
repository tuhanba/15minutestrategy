import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import prop_sim as ps  # noqa: E402


def days_from(seq):
    d0 = date(2024, 1, 1)
    return [ps.Day(d0 + timedelta(days=i), list(t)) for i, t in enumerate(seq)]


def it(days):
    yield from days
    while True:
        yield ps.Day(date.max)


def test_phoenix_pass_two_phases():
    # +6R per day at 0.5% risk = +3% per day -> each 4% phase needs 2 days
    days = days_from([[(6.0, -0.2)]] * 10)
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.005)
    assert out.passed and out.reason == "passed"
    assert out.trading_days == 4 and out.trades == 4
    assert out.min_phase_trades == 2


def test_daily_breach_uses_floating_mae():
    # one trade at 1% risk whose intraday dip is -4.5R -> -4.5% < -4% daily limit
    days = days_from([[(1.0, -4.5)]])
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.01)
    assert out.reason == "daily"


def test_static_max_loss():
    # -1R per day at 1% risk: daily never breached (-1%), static -6% hit on day 7
    days = days_from([[(-1.0, -1.0)]] * 10)
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.01, personal_dd=0)
    assert out.reason == "max_loss"
    assert out.trading_days == 7


def test_trailing_floor_follows_peak():
    # Thunderbolt: +4% then losses; the floor trails the peak (104k - 6k = 98k) instead of 94k
    days = days_from([[(4.0, 0.0)]] + [[(-1.0, -1.0)]] * 10)
    out = ps.attempt(it(days), ps.PROGRAMS["thunderbolt"], 0.01, personal_dd=0)
    assert out.reason == "max_loss"
    assert out.trading_days <= 8


def test_inactivity_uses_real_dates():
    # 35 calendar days without a closed trade (real dates, not list entries)
    days = days_from([[]] * 40)
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.005)
    assert out.reason == "inactivity"
    assert out.trading_days == 35
    # sparse history: only weekday rows -> still fails on the 35th calendar day, after fewer entries
    d0 = date(2024, 1, 1)
    weekdays = [ps.Day(d0 + timedelta(days=i)) for i in range(60) if (d0 + timedelta(days=i)).weekday() < 5]
    out = ps.attempt(it(weekdays), ps.PROGRAMS["phoenix"], 0.005)
    assert out.reason == "inactivity" and out.trading_days == 25


def test_report_runs():
    days = days_from([[(6.0, -0.3)], [], [(-1.0, -1.0)], [(-1.0, -1.0)]] * 20)
    text = ps.report(days, "phoenix", [0.0025, 0.005], runs=200, seed=1)
    assert "Phoenix" in text and "Decision rule" in text


def test_custom_program_cli(tmp_path):
    t = tmp_path / "t.csv"
    t.write_text("close_time;r;mae_r\n" + "\n".join(f"2024.01.{d:02d} 10:00;6.0;-0.2" for d in range(1, 29)) + "\n")
    out = tmp_path / "rep.md"
    rc = ps.main([str(t), "--program", "custom", "--name", "Test 2-step", "--targets", "8,5", "--daily-pct", "5",
                  "--max-pct", "10", "--runs", "50", "--risks", "0.5", "-o", str(out)])
    assert rc == 0
    text = out.read_text()
    assert "Test 2-step" in text and "| 0.500% | Monte Carlo (50) | 100.0%" in text


def test_ash_two_percent_target():
    # Ash: 2% target in one phase; one +6R trade at 0.35% risk = +2.1% -> passes on day 1 with 1 trade
    days = days_from([[(6.0, -0.1)]] * 3)
    out = ps.attempt(it(days), ps.PROGRAMS["ash"], 0.0035)
    assert out.passed and out.trades == 1 and out.min_phase_trades == 1
    # daily 3%: one trade at 1% risk dipping -3.2R breaches
    out = ps.attempt(it(days_from([[(1.0, -3.2)]])), ps.PROGRAMS["ash"], 0.01)
    assert out.reason == "daily"


def test_time_limit_fails_slow_attempts():
    # +1R per day at 0.25% risk needs 8 days for 2%; a 7-calendar-day limit fails after 7 days
    prog = ps.Program("turbo-like", (0.02,), 0.03, 0.06, True, 35, 7)
    out = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog, 0.0025)
    assert not out.passed and out.reason == "timeout" and out.trading_days == 7
    prog2 = ps.Program("turbo-like", (0.02,), 0.03, 0.06, True, 35, 14)
    out2 = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog2, 0.0025)
    assert out2.passed and out2.trading_days == 8


def test_calendar_limit_counts_weekend_gaps():
    # Sunday-evening rows and weekend gaps: a 7-calendar-day limit ends on the date, not after 7 rows
    prog = ps.Program("turbo-like", (0.02,), 0.03, 0.06, True, 35, 7)
    d0 = date(2024, 1, 1)  # Monday
    rows = [ps.Day(d0 + timedelta(days=i), [(1.0, -0.2)]) for i in (0, 1, 2, 3, 4, 6, 7, 8)]  # Sun 7th, Mon 8th...
    out = ps.attempt(iter(rows), prog, 0.0025)
    assert out.reason == "timeout" and out.trading_days == 6 and out.calendar_days == 7


def test_ash_turbo_seven_trading_days():
    prog = ps.PROGRAMS["ash_turbo"]
    assert prog.max_active_days == 7 and prog.time_limit_days == 30 and prog.targets == (0.02,)
    # +1R per traded day at 0.25%: 2% needs 8 traded days -> fails after the 7th traded day
    out = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog, 0.0025)
    assert out.reason == "timeout" and out.trading_days == 7 and out.active_days == 7
    # days without a closed trade do not use up the 7 trading days (only the 30-calendar-day limit)
    mixed = []
    for _ in range(10):
        mixed += [[(1.0, -0.2)], []]
    out = ps.attempt(it(days_from(mixed)), prog, 0.003)
    assert out.passed and out.trading_days == 13 and out.active_days == 7
    # strict reading: 7 weekdays in total -> the same sequence fails
    out = ps.attempt(it(days_from(mixed)), ps.PROGRAMS["ash_turbo_strict"], 0.003)
    assert out.reason == "timeout"
    # 30 calendar days: one +1R trade every 5 days at 0.25% never gets there
    sparse = [[(1.0, -0.2)] if i % 5 == 0 else [] for i in range(40)]
    out = ps.attempt(it(days_from(sparse)), prog, 0.0025)
    assert out.reason == "timeout" and out.calendar_days == 30


def test_turbo_daily_limit_is_fixed_amount():
    # balance first grows to 101.4k; next day a -3.0R dip at 1% risk = -3 042 $:
    # breaches the fixed 3 000 $ limit, but would NOT breach 3% of the 101.4k day reference (3 042 $)
    days = days_from([[(1.4, 0.0)], [(-1.0, -3.0)]])
    assert ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01).reason == "daily"
    relative = ps.Program("relative", (0.02,), 0.03, 0.06, True, 35, 30, 0, 7, False)
    assert ps.attempt(it(days), relative, 0.01).reason != "daily"


def test_shield_follows_intraday_equity_peak():
    # audit probe: at 1% risk the trade first runs +5R (equity 105k -> shield 99k), then stops out
    # at -1.05R (slippage): equity 98.95k < 99k -> max-loss breach. Closed-balance peak would miss it.
    probe = [[(-1.05, -1.05, 5.0)]]
    out = ps.attempt(it(days_from(probe)), ps.PROGRAMS["ash"], 0.01)
    assert out.reason == "max_loss"
    out = ps.attempt(it(days_from([[(-1.05, -1.05, 0.5)]])), ps.PROGRAMS["ash"], 0.01)
    assert out.reason != "max_loss"
    assert ps.attempt(it(days_from(probe)), ps.PROGRAMS["ash_turbo"], 0.01).reason == "max_loss"


def test_size_multiplier_scales_risk():
    # a regime x0.5 trade risks half: -3.2R at 1% x 0.5 = -1.6% -> no 3% daily breach
    assert ps.attempt(it(days_from([[(1.0, -3.2, 1.0, 0.5)]])), ps.PROGRAMS["ash"], 0.01).reason != "daily"
    assert ps.attempt(it(days_from([[(1.0, -3.2, 1.0, 1.0)]])), ps.PROGRAMS["ash"], 0.01).reason == "daily"


def test_replay_censors_short_history():
    # 10 days of +1R at 0.25%: starts with >= 8 days left pass, the rest run out of history
    days = days_from([[(1.0, -0.2)]] * 10)
    s = ps.summarize(ps.replay(days, ps.PROGRAMS["ash"], 0.0025))
    starts = len(ps.replay_starts(days))
    assert s["censored"] > 0 and s["n"] + s["censored"] == starts
    assert s["passed"] == 1.0 and s["timeout"] == 0.0


def test_block_bootstrap_keeps_consecutive_days_and_gaps():
    import random
    d0 = date(2024, 1, 1)
    days = [ps.Day(d0 + timedelta(days=i), [(float(i), -0.1)]) for i in range(0, 30, 2)]  # every 2nd day
    gen = ps.block_days(days, 5, random.Random(3))
    sample = [next(gen) for _ in range(25)]
    for k in range(0, 25, 5):
        rs = [ps._trade(d.trades[0]).r for d in sample[k:k + 5]]
        assert rs == [rs[0] + 2 * j for j in range(5)]          # consecutive history inside a block
    gaps = {(b.day - a.day).days for a, b in zip(sample, sample[1:])}
    assert gaps == {2}                                          # calendar gaps carried


def test_load_days_reads_mfe_and_size(tmp_path):
    t = tmp_path / "t.csv"
    t.write_text("open_time;close_time;risk_money;net;r;mfe_r;mae_r;risk_pct\n"
                 "2024.01.02 10:00;2024.01.02 12:00;250;-250;-1.0;2.5;-1.0;0.250\n"
                 "2024.01.03 10:00;2024.01.03 12:00;124.69;748.14;6.0;6.0;-0.3;0.250\n")
    days = ps.load_days(t, None, 100000.0)
    a, b = days[0].trades[0], days[1].trades[0]
    assert a.mfe == 2.5 and abs(a.size - 1.0) < 1e-9
    assert abs(b.size - 0.5) < 1e-3          # 124.69 / (0.25% of 99 750) -> regime x0.5


def test_report_caps_grid_and_validates():
    days = days_from([[(6.0, -0.3)], [], [(-1.0, -1.0)], [(-1.0, -1.0)]] * 20)
    text = ps.report(days, "ash_turbo", [0.0025, 0.0035, 0.01], runs=100, seed=1, validation=days)
    assert "not simulated: 1.00%" in text and "| 1.000% |" not in text
    assert "capped at 0.35%" in text and "NOT used for the decision" in text


def test_personal_daily_guard_blocks_rest_of_day():
    # Ash Turbo, 1% risk: 2nd trade dips to 97 911 < 98 000 (personal 2% of initial) -> 3rd trade skipped,
    # firm daily (97 000) not hit; the attempt continues the next day
    days = days_from([[(-1.0, -1.0), (-1.0, -1.1), (-1.0, -1.0)], [(1.0, -0.2)], [(-1.0, -1.0)]])
    out = ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01)
    assert out.personal_daily_hit and out.skipped_trades == 1
    assert out.trades >= 3 and out.reason not in ("daily", "personal_stop")


def test_personal_trailing_floor_stops_attempt():
    # -1R per day at 1%: day 5 dips to ~95 099 < 96 000 (peak 100k - 4% of initial) -> EA stops,
    # long before the firm shield (94 000)
    days = days_from([[(-1.0, -1.0)]] * 6)
    out = ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01)
    assert out.reason == "personal_stop" and out.personal_dd_hit and out.trades == 5
    assert ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01, personal_dd=0).reason != "personal_stop"


def test_personal_stop_open_trade_can_still_pass():
    # peak 103k via MFE -> personal floor 99k; next trade dips to 98 475 then closes at 102 515 >= target
    days = days_from([[(1.0, 0.0, 3.0)], [(1.5, -2.5, 1.5)], [(1.0, -0.1)]])
    out = ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01)
    assert out.passed and out.personal_dd_hit and out.trades == 2


def _res(table):
    def s(passed, daily=0.0, max_loss=0.0):
        return {"n": 100.0, "passed": passed, "daily": daily, "max_loss": max_loss}
    return {r: {"replay": s(*rp), "mc": s(*mc)} for r, (rp, mc) in table.items()}


def test_decision_replay_primary_lower_risk_on_divergence():
    # agree on 0.35% and pass rates close -> 0.35%
    d = ps.decide_combined(_res({0.0025: ((0.30,), (0.28,)), 0.0035: ((0.40,), (0.36,))}))
    assert d.risk == 0.0035 and not d.notes
    # replay picks 0.35%, MC picks 0.25% -> lower risk
    d = ps.decide_combined(_res({0.0025: ((0.30,), (0.33,)), 0.0035: ((0.40,), (0.32,))}))
    assert d.replay_pick == 0.0035 and d.mc_pick == 0.0025 and d.risk == 0.0025 and d.notes
    # same pick but pass-rate gap 15 pp -> step down to the next risk that qualifies under both
    d = ps.decide_combined(_res({0.0025: ((0.30,), (0.27,)), 0.003: ((0.35, 0.06), (0.30,)),
                                 0.0035: ((0.50,), (0.35,))}))
    assert d.risk == 0.0025 and any("gap" in n for n in d.notes)
    # cap and constraints: MC max-loss 12% at 0.35% -> MC picks 0.25%, replay 0.35% -> 0.25%
    d = ps.decide_combined(_res({0.0025: ((0.30,), (0.30,)), 0.0035: ((0.40,), (0.42, 0.0, 0.12)),
                                 0.005: ((0.60,), (0.60,))}), cap=0.0035)
    assert d.risk == 0.0025
    # Monte Carlo finds nothing -> none qualifies
    d = ps.decide_combined(_res({0.0025: ((0.30,), (0.30, 0.06))}))
    assert d.risk is None
