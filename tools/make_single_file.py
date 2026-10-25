#!/usr/bin/env python3
"""Inline the project's local includes (<RBOTE/...> and "...") into one .mq5 file.

Standard-library includes such as <Trade/Trade.mqh> are kept. Each project header is inlined once
(include guards stay in place), so the result compiles without the Include/RBOTE folder.
usage: make_single_file.py <input.mq5> <output.mq5>
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INC = ROOT / "MQL5" / "Include"
PAT = re.compile(r'^\s*#include\s+([<"])([^>"]+)[>"]')


def inline(path: Path, seen: set, out: list) -> None:
    for line in path.read_text(encoding="utf-8").splitlines():
        m = PAT.match(line)
        if m:
            kind, name = m.groups()
            target = (INC / name) if kind == "<" else (path.parent / name)
            if kind == "<" and not name.startswith("RBOTE/"):
                out.append(line)          # standard library include
                continue
            target = target.resolve()
            if target in seen:
                continue
            seen.add(target)
            out.append(f"//==== begin {target.relative_to(ROOT)} ====")
            inline(target, seen, out)
            out.append(f"//==== end {target.relative_to(ROOT)} ====")
            continue
        out.append(line)


def main() -> int:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    out = [f"// SINGLE-FILE BUILD generated from {src.name} by tools/make_single_file.py - do not edit, regenerate."]
    inline(src.resolve(), set(), out)
    dst.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"wrote {dst} ({len(out)} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
