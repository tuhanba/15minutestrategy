#!/usr/bin/env python3
"""Download Dukascopy M1 BID/ASK candles and merge them into one CSV per year.

Output columns (UTC):
    time;bid_open;bid_high;bid_low;bid_close;ask_open;ask_high;ask_low;ask_close;volume

Minutes with no trading (zero volume and flat on both sides) are dropped.
Raw .bi5 files are cached, so the script can be re-run to resume.

Data source: Dukascopy public datafeed (not the broker you will trade with:
spreads, session times and prices differ slightly from any MT5 broker).
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import lzma
import struct
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

URL = "https://datafeed.dukascopy.com/datafeed/{sym}/{y:04d}/{m:02d}/{d:02d}/{side}_candles_min_1.bi5"
DIVISOR = {"XAUUSD": 1000.0, "XAGUSD": 1000.0, "USA100IDXUSD": 1000.0}


def fetch(url: str, dest: Path, retries: int = 8) -> bytes | None:
    if dest.exists():
        data = dest.read_bytes()
        return data or None
    delay = 2.0
    for _ in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            dest.write_bytes(data)
            return data or None
        except urllib.error.HTTPError as e:
            if e.code == 404:
                dest.write_bytes(b"")
                return None
            if e.code in (429, 500, 502, 503, 504):
                time.sleep(delay)
                delay = min(delay * 2, 120)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            time.sleep(delay)
            delay = min(delay * 2, 120)
    raise RuntimeError(f"giving up on {url}")


def decode(data: bytes | None, divisor: float) -> dict[int, tuple[float, float, float, float, float]]:
    """offset seconds -> (open, high, low, close, volume). File order is open, close, low, high, volume."""
    out: dict[int, tuple[float, float, float, float, float]] = {}
    if not data:
        return out
    raw = lzma.decompress(data)
    for i in range(len(raw) // 24):
        t, o, c, lo, hi, v = struct.unpack(">IIIIIf", raw[i * 24:(i + 1) * 24])
        out[t] = (o / divisor, hi / divisor, lo / divisor, c / divisor, v)
    return out


def cache_path(cache: Path, sym: str, day: date, side: str) -> Path:
    return cache / f"{sym}_{day.isoformat()}_{side}.bi5"


def download(sym: str, day: date, side: str, cache: Path) -> str | None:
    """Returns an error text instead of raising, so one bad file never stops the whole run."""
    url = URL.format(sym=sym, y=day.year, m=day.month - 1, d=day.day, side=side)
    try:
        fetch(url, cache_path(cache, sym, day, side), retries=12)
        return None
    except Exception as e:  # noqa: BLE001 - reported and retried on the next run
        return f"{day.isoformat()} {side}: {e}"


def day_rows(sym: str, day: date, cache: Path, divisor: float) -> list[str]:
    rows: list[str] = []
    paths = [cache_path(cache, sym, day, s) for s in ("BID", "ASK")]
    if not all(p.exists() for p in paths):
        return rows
    bid = decode(paths[0].read_bytes() or None, divisor)
    ask = decode(paths[1].read_bytes() or None, divisor)
    base = datetime(day.year, day.month, day.day, tzinfo=timezone.utc)
    for off in sorted(set(bid) & set(ask)):
        b, a = bid[off], ask[off]
        flat = b[0] == b[1] == b[2] == b[3] and a[0] == a[1] == a[2] == a[3]
        if flat and b[4] == 0 and a[4] == 0:
            continue
        ts = (base + timedelta(seconds=off)).strftime("%Y-%m-%d %H:%M")
        rows.append(f"{ts};{b[0]:.3f};{b[1]:.3f};{b[2]:.3f};{b[3]:.3f};{a[0]:.3f};{a[1]:.3f};{a[2]:.3f};{a[3]:.3f};{b[4] + a[4]:.4f}")
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--start", required=True, help="YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD (inclusive)")
    ap.add_argument("--out", type=Path, default=Path("data"))
    ap.add_argument("--cache", type=Path, default=Path("data/cache"))
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args(argv)

    divisor = DIVISOR.get(args.symbol, 1000.0)
    args.out.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    days: list[date] = []
    d = date.fromisoformat(args.start)
    end = date.fromisoformat(args.end)
    while d <= end:
        if d.weekday() != 5:  # no Saturday session
            days.append(d)
        d += timedelta(days=1)
    jobs = [(day, side) for day in days for side in ("BID", "ASK")
            if not cache_path(args.cache, args.symbol, day, side).exists()]
    print(f"{len(days)} days, {len(jobs)} files to download", flush=True)
    done = 0
    failed: list[str] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for err in pool.map(lambda j: download(args.symbol, j[0], j[1], args.cache), jobs):
            done += 1
            if err:
                failed.append(err)
                print(f"FAILED {err}", flush=True)
            if done % 100 == 0:
                print(f"downloaded {done}/{len(jobs)} (failed {len(failed)})", flush=True)
    if failed:
        print(f"{len(failed)} files failed; re-run the same command to retry them. Days without both files are skipped.",
              flush=True)
    year_rows: dict[int, list[str]] = {}
    for day in days:
        year_rows.setdefault(day.year, []).extend(day_rows(args.symbol, day, args.cache, divisor))
    for y, rows in sorted(year_rows.items()):
        path = args.out / f"{args.symbol}_M1_{y}.csv"
        path.write_text("time;bid_open;bid_high;bid_low;bid_close;ask_open;ask_high;ask_low;ask_close;volume\n"
                        + "\n".join(rows) + "\n", encoding="utf-8")
        print(f"wrote {path} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
