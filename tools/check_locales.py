#!/usr/bin/env python3
"""Check localisation keys for holes.

Three failure modes, all of which show up in-game as a blank label or a
Lua error rather than as anything a compiler would catch:

  * the code asks for a key no locale defines
  * a translation is missing a key enUS has, so that client falls back
  * a key is defined but nothing uses it any more

Exit code 1 on the first two.

Usage:
    python3 tools/check_locales.py [--show-unused]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCALES = REPO / "Locales"
SKIP_DIRS = {".git", "tools", "Data", "Locales", "Libs"}

_USE = re.compile(r'L\["([^"]+)"\]')
_DEF = re.compile(r'^L\["([^"]+)"\]\s*=', re.M)


def used_keys() -> set[str]:
    keys: set[str] = set()
    for path in REPO.rglob("*.lua"):
        rel = path.relative_to(REPO)
        if rel.parts and rel.parts[0] in SKIP_DIRS:
            continue
        keys |= set(_USE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return keys


def defined_keys(path: Path) -> set[str]:
    return set(_DEF.findall(path.read_text(encoding="utf-8", errors="replace")))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--show-unused", action="store_true")
    args = ap.parse_args()

    base = LOCALES / "enUS.lua"
    english = defined_keys(base)
    used = used_keys()
    problems = 0

    missing = sorted(used - english)
    print(f"{len(used)} keys used, {len(english)} defined in enUS")
    if missing:
        problems += 1
        print(f"  MISSING from enUS ({len(missing)}):")
        for key in missing:
            print(f"      {key}")
    else:
        print("  every key the code asks for is defined")

    for path in sorted(LOCALES.glob("*.lua")):
        if path.name == "enUS.lua":
            continue
        keys = defined_keys(path)
        gap = sorted(english - keys)
        state = "ok" if not gap else f"MISSING {len(gap)}"
        print(f"  {path.name:12} {len(keys):3} keys  {state}")
        for key in gap[:5]:
            print(f"      {key}")
        if len(gap) > 5:
            print(f"      ... and {len(gap) - 5} more")
        if gap:
            problems += 1

    unused = sorted(english - used)
    print(f"  {len(unused)} defined but unused")
    if args.show_unused:
        for key in unused:
            print(f"      {key}")

    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
