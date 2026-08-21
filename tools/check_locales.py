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
# L["some.prefix_" .. variable] — the concatenated form. Everything
# sharing the prefix is potentially reached, so none of it is unused.
_PREFIX = re.compile(r'L\[\s*"([^"]*)"\s*\.\.')
# L[variable] — nothing static can say which keys this reaches.
# The lookbehind matters: without it this also matches the tail of an
# unrelated identifier such as STAT_KEY_FROM_LABEL[label].
_DYNAMIC = re.compile(r'(?<![A-Za-z0-9_])L\[\s*[a-zA-Z_][a-zA-Z0-9_.]*\s*\]')


def scan_uses() -> tuple[set[str], set[str], list[str]]:
    """(literal keys, concatenated prefixes, files using L[variable])."""
    keys: set[str] = set()
    prefixes: set[str] = set()
    dynamic: list[str] = []
    for path in REPO.rglob("*.lua"):
        rel = path.relative_to(REPO)
        if rel.parts and rel.parts[0] in SKIP_DIRS:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        keys |= set(_USE.findall(text))
        prefixes |= {p for p in _PREFIX.findall(text) if p}
        for number, line in enumerate(text.splitlines(), 1):
            if _DYNAMIC.search(line):
                dynamic.append(f"{rel}:{number}")
    return keys, prefixes, dynamic


def defined_keys(path: Path) -> set[str]:
    return set(_DEF.findall(path.read_text(encoding="utf-8", errors="replace")))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--show-unused", action="store_true")
    args = ap.parse_args()

    base = LOCALES / "enUS.lua"
    english = defined_keys(base)
    used, prefixes, dynamic = scan_uses()
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

    # A key reached only by concatenation is used, even though no literal
    # L["that.key"] appears anywhere. Deleting one leaves the UI showing
    # the raw key name, because ns.L's __index returns the key itself —
    # four broken menu entries and no error to notice them by.
    reached = {key for key in english
               if any(key.startswith(prefix) for prefix in prefixes)}
    unused = sorted(english - used - reached)

    print(f"  {len(unused)} defined and not referenced")
    if prefixes:
        print(f"  {len(reached)} more reached by {len(prefixes)} concatenated "
              f"prefix(es): {', '.join(sorted(prefixes))}")
    if args.show_unused:
        for key in unused:
            print(f"      {key}")

    if dynamic:
        print(f"\n  Caveat: {len(dynamic)} lookup(s) build the key from a bare\n"
              "  variable, so the list above is candidates to review, not keys\n"
              "  that are safe to delete unread:")
        for where in dynamic:
            print(f"    - {where}")

    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
