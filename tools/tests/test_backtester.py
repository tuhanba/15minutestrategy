"""End-to-end checks of the C++ backtester (backtest/rbote_bt.cpp) on hand-made M1 data.

Each M15 bar is expanded into 15 M1 bars: open, then the high, then the low, then the close
(bid prices); ask = bid + SPREAD. The bullish fixture is the same one used by the MQL5 unit
tests: bull FVG [100.6, 101.2] formed on bar 7, rejection candle on bar 10
(RB low 100.9, RB high 102.0) -> buy limit 101.13, SL 100.63 (0.50 fixed), TP 104.13 (6R).
"""
import csv
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPREAD = 0.05

BASE = [
    (100.0, 101.0, 99.0, 100.0), (100.0, 102.0, 99.5, 101.5), (101.5, 103.0, 101.0, 102.5),
    (102.5, 102.8, 100.5, 101.0), (101.0, 101.5, 99.8, 100.2), (100.2, 100.6, 99.0, 99.5),
    (99.5, 104.5, 99.4, 104.2), (104.2, 105.5, 101.2, 105.0), (105.0, 106.0, 104.5, 105.5),
    (105.5, 105.8, 103.0, 103.5), (102.3, 102.6, 100.9, 102.0),
]


@pytest.fixture(scope="module")
def binary(tmp_path_factory):
    out = tmp_path_factory.mktemp("bin") / "rbote_bt"
    subprocess.run(["g++", "-std=c++17", "-O1", "-x", "c++", str(ROOT / "backtest/rbote_bt.cpp"), "-o", str(out)],
                   check=True)
    return out


def write_m1(path: Path, m15_bars, start=datetime(2024, 1, 2, 0, 0)):
    rows = ["time;bid_open;bid_high;bid_low;bid_close;ask_open;ask_high;ask_low;ask_close;volume"]
    for k, (o, h, l, c) in enumerate(m15_bars):
        t0 = start + timedelta(minutes=15 * k)
        path_prices = [o, h, l] + [c] * 12  # 15 minutes: open, high, low, then close
        prev = o
        for j, p in enumerate(path_prices):
            mo, mc = prev, p
            mh, ml = max(mo, mc), min(mo, mc)
            prev = p
            t = (t0 + timedelta(minutes=j)).strftime("%Y-%m-%d %H:%M")
            rows.append(f"{t};{mo:.3f};{mh:.3f};{ml:.3f};{mc:.3f};{mo + SPREAD:.3f};{mh + SPREAD:.3f};"
                        f"{ml + SPREAD:.3f};{mc + SPREAD:.3f};1")
    path.write_text("\n".join(rows) + "\n")


def run(binary, tmp_path, bars, *extra):
    data = tmp_path / "m1.csv"
    write_m1(data, bars)
    trades = tmp_path / "trades.csv"
    res = subprocess.run([str(binary), "--data", str(data), "--from", "2024-01-01", "--to", "2024-02-01",
                          "--regime", "off", "--stop-dist", "0.5", "--out-trades", str(trades),
                          "--out-daily", str(tmp_path / "daily.csv"), *extra],
                         check=True, capture_output=True, text=True)
    with trades.open() as fh:
        return list(csv.DictReader(fh, delimiter=";")), res.stdout


def test_winning_trade_matches_hand_calculation(binary, tmp_path):
    bars = BASE + [(102.0, 102.2, 101.0, 101.5), (101.5, 104.5, 101.4, 104.4), (104.4, 104.6, 104.2, 104.5)]
    trades, out = run(binary, tmp_path, bars)
    assert len(trades) == 1, out
    t = trades[0]
    assert t["dir"] == "1"
    assert float(t["planned_entry"]) == pytest.approx(101.13)
    assert float(t["sl"]) == pytest.approx(100.63)
    assert float(t["tp"]) == pytest.approx(104.13)
    assert t["exit_reason"] == "TP"
    # lots: 250 / (0.50/0.01*1 + 6 commission + 10 ticks slippage) = 250/66 -> 3.78
    assert float(t["volume"]) == pytest.approx(3.78)
    net = 3.0 * 3.78 * 100 - 6 * 3.78
    assert float(t["net"]) == pytest.approx(net, abs=0.01)
    assert float(t["r"]) == pytest.approx(net / (3.78 * 66), abs=1e-3)


def test_same_minute_fill_and_stop_is_a_loss(binary, tmp_path):
    # bar 11 trades down through entry AND stop in the same minute -> loss with slippage
    bars = BASE + [(102.0, 102.2, 100.5, 101.5), (101.5, 104.5, 101.4, 104.4)]
    trades, out = run(binary, tmp_path, bars)
    assert len(trades) == 1, out
    t = trades[0]
    assert t["exit_reason"] == "SL"
    assert float(t["exit_price"]) == pytest.approx(100.63 - 0.10)
    # slippage and commission are part of the planned risk, so a full stop is exactly -1R
    assert float(t["r"]) == pytest.approx(-1.0, abs=1e-3)


def test_target_before_fill_cancels(binary, tmp_path):
    bars = BASE + [(102.0, 104.5, 101.9, 104.4), (104.4, 104.5, 100.95, 101.0)]
    trades, out = run(binary, tmp_path, bars)
    assert trades == []
    assert "CANCEL_TARGET_REACHED_BEFORE_FILL 1" in out


def test_breakeven_management(binary, tmp_path):
    # after fill price runs to +2.4R then back below entry: with BE at +2R the exit is near entry
    bars = BASE + [(102.0, 102.2, 101.0, 101.5), (101.5, 102.35, 101.4, 102.3), (102.3, 102.4, 100.0, 100.1)]
    trades, _ = run(binary, tmp_path, bars, "--be-r", "2", "--be-offset-r", "0.1")
    assert len(trades) == 1
    t = trades[0]
    assert t["exit_reason"] == "MGMT_SL"
    assert float(t["exit_price"]) == pytest.approx(101.18 - 0.10)
    assert float(t["mfe_r"]) == pytest.approx((102.40 - 101.13) / 0.5, abs=1e-6)  # best price: bar 13 high


def test_swap_and_end_close(binary, tmp_path):
    # start 18:00 UTC Tuesday: RB closes 20:45, fill in the 20:45 bar, held across the 21:00 rollover,
    # data ends at 21:15 -> position closed at the last bid with reason END, one night of swap charged
    bars = BASE + [(102.0, 102.2, 101.0, 101.5), (101.5, 101.6, 101.4, 101.5)]
    data = tmp_path / "m1.csv"
    write_m1(data, bars, start=datetime(2024, 1, 2, 18, 0))
    trades_path = tmp_path / "trades.csv"
    subprocess.run([str(binary), "--data", str(data), "--from", "2024-01-01", "--to", "2024-02-01", "--regime", "off",
                    "--stop-dist", "0.5", "--swap-long", "-45", "--swap-short", "-15",
                    "--out-trades", str(trades_path), "--out-daily", str(tmp_path / "d.csv")],
                   check=True, capture_output=True, text=True)
    with trades_path.open() as fh:
        trades = list(csv.DictReader(fh, delimiter=";"))
    assert len(trades) == 1
    t = trades[0]
    assert t["exit_reason"] == "END"
    lots = 3.78
    expected = (101.5 - 101.13) * lots * 100 - 6 * lots - 45 * lots
    assert float(t["net"]) == pytest.approx(expected, abs=0.01)
