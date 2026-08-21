#!/usr/bin/env python3
"""Regenerate Data/<Class>/murlok-pvp.lua from murlok.io.

murlok.io publishes what the top-rated PvP players of each spec are
actually wearing and stacking. The page is server-rendered, so a plain
fetch and a few structural regexes are enough.

Written: ClassCodexMurlokPvp — the stat priority with the average rating
behind it, and the most-worn items per slot.

Usage:
    python3 tools/refresh_murlok.py [--classes Hunter] [--jobs 6]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import html as htmllib
import re
import sys
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccutil import CLASS_DIRS, DATA, fetch, log, write_lua  # noqa: E402

# Stat name -> the key the addon's PvP panel reads.
STAT_KEYS = {
    "critical strike": "crit", "crit": "crit", "haste": "haste",
    "mastery": "mastery", "versatility": "versatility", "leech": "leech",
    "speed": "speed", "avoidance": "avoidance",
}

_CHART = re.compile(
    r'guide-stats-chart-item[^"]*">\s*<span>[\d.]+%\s*([A-Za-z ]+?)</span>\s*'
    r'<span class="h3">\+?([\d,]+)</span>', re.S)
_SLOT_BLOCK = re.compile(r"<h3>([^<]{2,30})</h3>\s*<ol\b(.*?)</ol>", re.S)
_ITEM = re.compile(r'href="https://www\.wowhead\.com/item=(\d+)"')
_SRC = re.compile(r'\["([a-z-]+)"\] = \{.*?murlok = \{ pvp = "([^"]+)"', re.S)

# murlok lists every item seen in a slot; the addon only shows the top
# few, and past three the tail is noise.
MAX_ITEMS_PER_SLOT = 3


def parse_stats(page: str) -> list[dict]:
    out: list[dict] = []
    for name, rating in _CHART.findall(page):
        key = STAT_KEYS.get(htmllib.unescape(name).strip().lower())
        if not key:
            continue
        value = int(rating.replace(",", ""))
        # murlok charts every secondary, including the ones nobody
        # stacks. A zero rating is not a priority, so it is dropped.
        if value > 0:
            out.append({"key": key, "rating": value})
    # The chart is drawn smallest-first; the addon wants the priority.
    out.sort(key=lambda e: -e["rating"])
    return out


def parse_gear(page: str) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for slot, body in _SLOT_BLOCK.findall(page):
        slot = htmllib.unescape(slot).strip()
        ids: list[int] = []
        for raw in _ITEM.findall(body):
            item_id = int(raw)
            if item_id not in ids:
                ids.append(item_id)
        if ids:
            out[slot] = [{"itemId": i} for i in ids[:MAX_ITEMS_PER_SLOT]]
    return out


def targets() -> list[dict]:
    out: list[dict] = []
    for path in sorted(DATA.glob("*/sources.lua")):
        for spec_key, url in _SRC.findall(path.read_text(encoding="utf-8")):
            out.append({"classDir": path.parent.name, "specKey": spec_key,
                        "url": url})
    return out


def scrape_spec(target: dict) -> dict:
    name = f"{target['classDir']}/{target['specKey']}"
    try:
        page = fetch(target["url"])
    except urllib.error.HTTPError as exc:
        log(f"  ! {name}: HTTP {exc.code}")
        return {}
    data: dict = {}
    stats = parse_stats(page)
    if stats:
        data["statPriority"] = stats
    gear = parse_gear(page)
    if gear:
        data["bisGear"] = dict(sorted(gear.items()))
    log(f"  {name}: {len(stats)} stats, {len(gear)} slots")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes")
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    only = set(args.classes.split(",")) if args.classes else None
    todo = [t for t in targets() if not only or t["classDir"] in only]
    log(f"{len(todo)} specs")

    by_class: dict[str, dict[str, dict]] = {}
    with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = {pool.submit(scrape_spec, t): t for t in todo}
        for fut in futures.as_completed(jobs):
            t = jobs[fut]
            data = fut.result()
            if data:
                by_class.setdefault(t["classDir"], {})[t["specKey"]] = data

    for class_dir, specs in sorted(by_class.items()):
        write_lua(DATA / class_dir / "murlok-pvp.lua", "ClassCodexMurlokPvp",
                  CLASS_DIRS[class_dir], dict(sorted(specs.items())),
                  header="Source: murlok.io")
        log(f"wrote Data/{class_dir}/murlok-pvp.lua")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
