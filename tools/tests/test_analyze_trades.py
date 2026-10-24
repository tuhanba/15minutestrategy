import math
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import analyze_trades as at  # noqa: E402

HEADER = "open_time;close_time;dir;planned_entry;fill_price;sl;tp;volume;risk_money;net;r;signal_id;atr;zone_type;rr;stop_mode;exit_price"


def write_csv(path: Path, rows):
    lines = [HEADER]
    for i, (when, net, risk, atr) in enumerate(rows):
        lines.append(f"{when} 10:00;{when} 12:00;1;100;100;99;106;1.00;{risk};{net};{net / risk:.4f};RBOTE|B|{i};{atr};0;6.00;0;106")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_max_drawdown():
    assert at.max_drawdown([100, 120, 90, 130, 117]) == (120 - 90) / 120


def test_equity_curve_compounds():
    eq = at.equity_curve([6, -1], 0.01)
    assert math.isclose(eq[-1], 1.06 * 0.99)


def test_load_and_summarize(tmp_path):
    p = tmp_path / "run_trades.csv"
    write_csv(p, [("2024.01.02", -250, 250, 3.0), ("2024.01.03", 1500, 250, 4.0),
                  ("2024.01.03", -250, 250, 5.0), ("2025.02.01", -250, 250, 6.0)])
    trades = at.load_trades(p)
    assert len(trades) == 4
    s = at.summarize(trades, 0.0025, 100000.0, 0.01, runs=200)
    assert s.n == 4
    assert math.isclose(s.win_rate, 0.25)
    assert math.isclose(s.expectancy_r, (-1 + 6 - 1 - 1) / 4)
    assert math.isclose(s.profit_factor, 1500 / 750)
    assert math.isclose(s.net_money, 750)
    assert s.breach_days == 0


def test_daily_breach_detected(tmp_path):
    p = tmp_path / "t.csv"
    write_csv(p, [("2024.03.05", -600, 250, 1.0), ("2024.03.05", -500, 250, 1.0)])
    trades = at.load_trades(p)
    assert at.daily_breaches(trades, 100000.0, 0.01) == [datetime(2024, 3, 5).date()]


def test_acceptance_fails_on_small_sample(tmp_path):
    p = tmp_path / "t.csv"
    write_csv(p, [("2024.01.02", 1500, 250, 1.0)] * 10)
    trades = at.load_trades(p)
    s = at.summarize(trades, 0.0025, 100000.0, 0.01, runs=100)
    checks = at.acceptance(None, s, {"2024": (10, 6.0)}, at.Criteria())
    assert not all(ok for _, ok, _ in checks)
    assert checks[0][1] is False  # fewer than 100 trades


def test_report_split_and_verdict(tmp_path):
    p = tmp_path / "t.csv"
    rows = [("2023.05.01", -250, 250, 2.0), ("2024.05.01", -250, 250, 3.0), ("2024.06.01", 1500, 250, 4.0)]
    write_csv(p, rows)
    runs = {"6R": at.load_trades(p)}
    rep = at.build_report(runs, datetime(2024, 1, 1), 0.0025, 100000.0, 0.01, at.Criteria())
    assert "6R / IS" in rep and "6R / OOS" in rep
    assert "## 6R: FAIL" in rep


def test_cli(tmp_path, capsys):
    p = tmp_path / "t.csv"
    write_csv(p, [("2024.01.02", -250, 250, 1.0)])
    out = tmp_path / "rep.md"
    assert at.main([f"6R={p}", "-o", str(out)]) == 0
    assert out.exists() and "6R / all" in out.read_text()


def test_regime_breakdown(tmp_path):
    p = tmp_path / "t.csv"
    p.write_text(
        HEADER + ";regime;vol_ratio;er;risk_mult\n"
        "2024.01.02 10:00;2024.01.02 12:00;1;100;100;99;106;1.00;250;-250;-1.0;RBOTE|B|1;2.0;0;6.00;0;99;HIGH;1.8;0.5;0.50\n"
        "2024.01.03 10:00;2024.01.03 12:00;1;100;100;99;106;1.00;250;1500;6.0;RBOTE|B|2;1.0;0;6.00;0;106;NORMAL+RANGE;1.0;0.1;0.50\n",
        encoding="utf-8",
    )
    trades = at.load_trades(p)
    assert [t.regime for t in trades] == ["HIGH", "NORMAL+RANGE"]
    rep = at.build_report({"x": trades}, None, 0.0025, 100000.0, 0.01, at.Criteria())
    assert "| HIGH | 1 | -1.000 |" in rep and "| NORMAL+RANGE | 1 | 6.000 |" in rep


FULL_HEADER = (HEADER + ";regime;vol_ratio;er;risk_mult;exit_reason;mfe_r;mae_r;session;hour;weekday;zones_hit;"
               "wick_ratio;rb_range_atr;stop_atr;fill_delay_bars;risk_pct;edge_mult;scale_reason")


def test_why_section(tmp_path):
    p = tmp_path / "t.csv"
    rows = [FULL_HEADER]
    # 2 winners in London session with FVG, 2 losers in Asia with OB; one loser first reached +3.2R
    for i, (net, sess, zt, mfe, reason) in enumerate([
        (1500, "H06-11", 0, 6.1, "TP"), (1500, "H06-11", 0, 6.0, "TP"),
        (-250, "H00-05", 1, 3.2, "SL"), (-250, "H00-05", 1, 0.4, "SL"),
    ]):
        rows.append(f"2024.01.0{i + 1} 10:00;2024.01.0{i + 1} 12:00;1;100;100;99;106;1.00;250;{net};{net / 250:.4f};"
                    f"RBOTE|B|{i};1.0;{zt};6.00;0;106;NORMAL;1.0;0.5;1.00;{reason};{mfe};-0.3;{sess};9;2;1;"
                    f"0.6;1.2;0.8;2;0.250;1.000;BASE")
    p.write_text("\n".join(rows) + "\n", encoding="utf-8")
    trades = at.load_trades(p)
    assert trades[0].session == "H06-11" and trades[2].mfe_r == 3.2
    lines = "\n".join(at.why_section(trades, 0.0025, 100000.0))
    assert "| H06-11 (small) | 2 | 100.0% | 6.000 |" in lines
    assert "| OB (small) | 2 | 0.0% | -1.000 |" in lines
    assert "reached +3R first: 50.0%" in lines
    assert "same trades at flat 0.25% of start balance: 2,500.00" in lines
