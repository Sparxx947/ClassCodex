#!/usr/bin/env python3
"""Check the generated data for completeness and staleness.

A scrape that silently produced nothing for one spec looks exactly like a
successful run — the file is still valid Lua, it just has a hole in it.
This walks every generated file and reports what is missing, so a gap has
to be a decision rather than an accident.

Exit code 1 if anything is missing or the data is older than --max-age.

Usage:
    python3 tools/check_data.py [--max-age 14]
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccutil import CLASS_DIRS, DATA  # noqa: E402

# file -> (global, a marker every spec's entry must contain)
EXPECTED = {
    "sources.lua": ("ClassCodexSources", "wowhead ="),
    "guide.lua": ("ClassCodexData", "talents ="),
    "gear-wowhead.lua": ("ClassCodexGearData", "bisGear ="),
    "archon-stats.lua": ("ClassCodexArchonStats", "targets ="),
    "archon-talents.lua": ("ClassCodexArchonData", "contexts ="),
    "gear-archon.lua": ("ClassCodexArchonGearData", "bisGear ="),
    "crafting.lua": ("ClassCodexCraftingData", "crafts ="),
    "talents-icyveins.lua": ("ClassCodexIcyVeinsTalentData", "exportString ="),
    "gear-icyveins.lua": ("ClassCodexIcyVeinsData", "bisGear ="),
    "murlok-pvp.lua": ("ClassCodexMurlokPvp", "statPriority ="),
    "bnet-pvp-talents.lua": ("ClassCodexBnetPvpTalents", "brackets ="),
}

_SPEC_KEY = re.compile(r'^  \["([a-z-]+)"\] = \{', re.M)

# Gaps that are properties of the source, not of the scrape. Listed here
# so the check still reports them but does not fail on them — a check
# that is permanently red stops being read. Re-verify each at a season
# rollover; a source that starts publishing should drop off this list.
KNOWN_GAPS = {
    ("murlok-pvp.lua", "Monk/brewmaster"):
        "murlok.io has no sample in any bracket (solo/3v3/blitz/2v2/rbg); "
        "Brewmaster is effectively absent from rated PvP this early in the season",
}


def specs_per_class() -> dict[str, set[str]]:
    """The spec list, taken from sources.lua as the reference."""
    out: dict[str, set[str]] = {}
    for class_dir in CLASS_DIRS:
        path = DATA / class_dir / "sources.lua"
        if path.exists():
            out[class_dir] = set(_SPEC_KEY.findall(path.read_text(encoding="utf-8")))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--max-age", type=int, default=14,
                    help="days before the scrape date counts as stale")
    args = ap.parse_args()

    problems: list[str] = []
    reference = specs_per_class()
    total_specs = sum(len(s) for s in reference.values())
    print(f"{total_specs} specs across {len(reference)} classes")

    for filename, (_, marker) in EXPECTED.items():
        missing: list[str] = []
        for class_dir, specs in reference.items():
            path = DATA / class_dir / filename
            if not path.exists():
                missing.extend(f"{class_dir}/{s}" for s in sorted(specs))
                continue
            text = path.read_text(encoding="utf-8")
            present = set(_SPEC_KEY.findall(text))
            for spec in sorted(specs - present):
                missing.append(f"{class_dir}/{spec}")
            # A present-but-empty entry is the failure mode that hides.
            for spec in sorted(specs & present):
                start = text.index(f'["{spec}"] = {{')
                nxt = _SPEC_KEY.search(text, start + 1)
                body = text[start:nxt.start() if nxt else len(text)]
                if marker not in body:
                    missing.append(f"{class_dir}/{spec} (no {marker.strip(' =')})")
        known = [e for e in missing if (filename, e) in KNOWN_GAPS]
        unexpected = [e for e in missing if e not in known]
        if unexpected:
            status = f"MISSING {len(unexpected)}"
        elif known:
            status = f"ok ({len(known)} known gap)"
        else:
            status = "ok"
        print(f"  {filename:26} {total_specs - len(missing):3}/{total_specs}  {status}")
        for entry in unexpected[:8]:
            print(f"      {entry}")
        if len(unexpected) > 8:
            print(f"      ... and {len(unexpected) - 8} more")
        for entry in known:
            print(f"      known: {entry} — {KNOWN_GAPS[(filename, entry)]}")
        if unexpected:
            problems.append(filename)

    stamp = (DATA / "Generated.lua").read_text(encoding="utf-8")
    m = re.search(r'ClassCodex_LastScrape = "(\d{4}-\d{2}-\d{2})"', stamp)
    if not m:
        problems.append("Generated.lua has no scrape date")
        print("  scrape date               MISSING")
    else:
        age = (dt.date.today() - dt.date.fromisoformat(m.group(1))).days
        state = "ok" if age <= args.max_age else f"STALE (> {args.max_age} days)"
        print(f"  scrape date {m.group(1)}    {age} days old  {state}")
        if age > args.max_age:
            problems.append("stale data")

    if problems:
        print(f"\n{len(problems)} problem(s): {', '.join(problems)}")
        return 1
    print("\nall generated data present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
