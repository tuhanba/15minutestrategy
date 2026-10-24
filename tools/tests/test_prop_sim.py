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
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.01)
    assert out.reason == "max_loss"
    assert out.trading_days == 7


def test_trailing_floor_follows_peak():
    # Thunderbolt: +4% then losses; the floor trails the peak (104k - 6k = 98k) instead of 94k
    days = days_from([[(4.0, 0.0)]] + [[(-1.0, -1.0)]] * 10)
    out = ps.attempt(it(days), ps.PROGRAMS["thunderbolt"], 0.01)
    assert out.reason == "max_loss"
    assert out.trading_days <= 8


def test_inactivity():
    days = days_from([[]] * 30)
    out = ps.attempt(it(days), ps.PROGRAMS["phoenix"], 0.005)
    assert out.reason == "inactivity"
    assert out.trading_days == 25  # 25 trading days * 7/5 = 35 calendar days


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
    # +1R per day at 0.25% risk needs 8 trading days for 2%; a 7-calendar-day limit (5 trading days) fails
    prog = ps.Program("turbo-like", (0.02,), 0.03, 0.06, True, 35, 7)
    out = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog, 0.0025)
    assert not out.passed and out.reason == "timeout" and out.trading_days == 5
    prog2 = ps.Program("turbo-like", (0.02,), 0.03, 0.06, True, 35, 14)
    out2 = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog2, 0.0025)
    assert out2.passed and out2.trading_days == 8


def test_ash_turbo_seven_trading_days():
    prog = ps.PROGRAMS["ash_turbo"]
    assert prog.max_active_days == 7 and prog.time_limit_trading_days == 21 and prog.targets == (0.02,)
    # +1R per traded day at 0.25%: 2% needs 8 traded days -> fails after the 7th traded day
    out = ps.attempt(it(days_from([[(1.0, -0.2)]] * 20)), prog, 0.0025)
    assert out.reason == "timeout" and out.trading_days == 7
    # days without a closed trade do not use up the 7 trading days (only the 21-weekday limit)
    mixed = []
    for _ in range(10):
        mixed += [[(1.0, -0.2)], []]
    out = ps.attempt(it(days_from(mixed)), prog, 0.003)
    assert out.passed and out.trading_days == 13
    # strict reading: 7 weekdays in total -> the same sequence fails
    out = ps.attempt(it(days_from(mixed)), ps.PROGRAMS["ash_turbo_strict"], 0.003)
    assert out.reason == "timeout"


def test_turbo_daily_limit_is_fixed_amount():
    # balance first grows to 101.4k; next day a -3.0R dip at 1% risk = -3 042 $:
    # breaches the fixed 3 000 $ limit, but would NOT breach 3% of the 101.4k day reference (3 042 $)
    days = days_from([[(1.4, 0.0)], [(-1.0, -3.0)]])
    assert ps.attempt(it(days), ps.PROGRAMS["ash_turbo"], 0.01).reason == "daily"
    relative = ps.Program("relative", (0.02,), 0.03, 0.06, True, 35, 0, 21, 7, False)
    assert ps.attempt(it(days), relative, 0.01).reason != "daily"
