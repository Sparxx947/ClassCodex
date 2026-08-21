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

# Solo Shuffle has no tank bracket, and some specs are too rare in it to
# produce a sample. Those pages still exist and still return 200 — they
# just come back with navigation and nothing else — so the fallback has
# to be driven by whether a page carries data, not by its status code.
BRACKETS = ("solo", "3v3", "blitz", "2v2", "rbg")


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
    base = target["url"].rsplit("/", 1)[0]
    wanted = target["url"].rsplit("/", 1)[-1]
    order = [wanted] + [b for b in BRACKETS if b != wanted]

    for bracket in order:
        url = f"{base}/{bracket}"
        try:
            page = fetch(url)
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                log(f"  ! {name} {bracket}: HTTP {exc.code}")
            continue
        stats = parse_stats(page)
        gear = parse_gear(page)
        if not stats and not gear:
            continue
        data: dict = {"bracket": bracket}
        if stats:
            data["statPriority"] = stats
        if gear:
            data["bisGear"] = dict(sorted(gear.items()))
        note = "" if bracket == wanted else f"  (fell back from {wanted})"
        log(f"  {name}: {len(stats)} stats, {len(gear)} slots "
            f"[{bracket}]{note}")
        data["_url"] = url
        return data

    log(f"  ! {name}: no bracket carries data")
    return {}


_MURLOK_LINK = re.compile(r'(murlok = \{ pvp = ")([^"]+)(" \})')


def update_source_links(class_dir: str, specs: dict[str, dict]) -> int:
    """Repoint sources.lua at whichever bracket actually has data.

    Kept here rather than in refresh_sources.py because only this tool
    can tell an empty murlok page from a populated one, and linking a
    tank at a Solo Shuffle page sends the player somewhere blank.
    """
    path = DATA / class_dir / "sources.lua"
    text = path.read_text(encoding="utf-8")
    changed = 0
    for spec, data in specs.items():
        url = data.get("_url")
        if not url:
            continue
        start = text.find(f'["{spec}"] = {{')
        if start < 0:
            continue
        # The next spec block, found on its full line prefix. Searching
        # for a bare '"] = {' would match this spec's own closing quote
        # whenever the slug is short enough, truncating the chunk to
        # nothing — silently skipping every six-letter spec.
        end = text.find('\n  ["', start + 1)
        chunk = text[start:end if end > 0 else len(text)]
        new_chunk, hits = _MURLOK_LINK.subn(rf"\g<1>{url}\g<3>", chunk)
        if hits and new_chunk != chunk:
            text = text[:start] + new_chunk + text[start + len(chunk):]
            changed += 1
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


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
        relinked = update_source_links(class_dir, specs)
        payload = {spec: {k: v for k, v in data.items() if k != "_url"}
                   for spec, data in sorted(specs.items())}
        write_lua(DATA / class_dir / "murlok-pvp.lua", "ClassCodexMurlokPvp",
                  CLASS_DIRS[class_dir], payload, header="Source: murlok.io")
        note = f", {relinked} link(s) repointed" if relinked else ""
        log(f"wrote Data/{class_dir}/murlok-pvp.lua{note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
