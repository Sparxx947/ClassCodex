#!/usr/bin/env python3
"""Regenerate the Icy Veins data files for every class and specialisation.

  Data/<Class>/talents-icyveins.lua  ClassCodexIcyVeinsTalentData
  Data/<Class>/gear-icyveins.lua     ClassCodexIcyVeinsData

Icy Veins renders both server-side, so a plain HTML fetch is enough. The
page URLs are role-dependent (…-pve-dps- / -pve-healer- / -pve-tank-) and
are read from Data/*/sources.lua instead of being reconstructed.

Usage:
    python3 tools/refresh_icyveins.py [--classes Hunter] [--jobs 6]
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

from ccutil import CLASS_DIRS, DATA, SLUG_TO_DIR, fetch, log, write_lua  # noqa: E402

# The addon buckets Icy Veins builds into these contexts; anything else
# is shown as "General".
CONTEXTS = ("Raid", "Mythic+", "Delves", "Leveling")

_EXPORT = re.compile(
    r'export-string__title">(.*?)</span>.*?export-string__code">([A-Za-z0-9+/=]+)<',
    re.S)
_TAB = re.compile(r'id="(bis_\d+_\d+)_button">(.*?)</span>')
_PANEL = re.compile(r'id="(bis_\d+_\d+)"')
_ITEM = re.compile(
    r'<span data-wowhead="item=(\d+)((?:&amp;[a-z-]+=[^"]*)*)"[^>]*>(.*?)</span>')
_ENTRY = re.compile(r'<div class="bis_item[ "]')
_SLOT = re.compile(r'bis_item_slot">(.*?)</span>', re.S)
_DROP = re.compile(r'bis_item_drop">(.*?)</span>\s*(?:<span|</div)', re.S)
_TAG = re.compile(r"<[^>]+>")


def text(raw: str) -> str:
    return htmllib.unescape(_TAG.sub("", raw)).strip()


def bonus_ids(query: str) -> list[int]:
    m = re.search(r"bonus=([\d:]+)", htmllib.unescape(query))
    if not m:
        return []
    return [int(x) for x in m.group(1).split(":") if x.isdigit()]


def context_for(title: str) -> tuple[str, str]:
    """Split "Beast Mastery Mythic+ - Pack Leader" into (context, label)."""
    plain = text(title)
    context = "General"
    for name in CONTEXTS:
        if name.lower() in plain.lower():
            context = name
            break
    label = plain
    if " - " in plain:
        label = plain.split(" - ", 1)[1].strip() or plain
    return context, label


# ---------------------------------------------------------------------------

def parse_talents(page: str, *, leveling: bool = False) -> list[dict]:
    out: list[dict] = []
    seen: set[str] = set()
    for title, code in _EXPORT.findall(page):
        if code in seen:
            continue
        seen.add(code)
        context, label = context_for(title)
        entry = {"context": "Leveling" if leveling else context,
                 "buildLabel": label, "exportString": code}
        if leveling or context == "Leveling":
            entry["leveling"] = True
        out.append(entry)
    return out


def parse_gear(page: str) -> list[dict]:
    """The BiS panels ("Overall" / "Mythic+" / "Raid") with their slots."""
    labels = {pid: text(name) for pid, name in _TAB.findall(page)}
    if not labels:
        return []

    # Panel bodies run from one id="bis_x_y" to the next.
    marks = [(m.group(1), m.start()) for m in _PANEL.finditer(page)
             if m.group(1) in labels]
    marks.sort(key=lambda kv: kv[1])

    tabs: list[dict] = []
    for i, (pid, start) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else len(page)
        body = page[start:end]
        slots: list[dict] = []
        # One entry per <div class="bis_item ...">. Splitting on the bare
        # class prefix would also cut on bis_item_slot, bis_item_footer
        # and friends, so the opening div is matched in full.
        for chunk in _ENTRY.split(body)[1:]:
            slot = _SLOT.search(chunk)
            # The icon and the name are two links carrying the same item;
            # take the first whose text is the name rather than an <img>.
            item = next((m for m in _ITEM.finditer(chunk) if text(m.group(3))),
                        None)
            if not slot or not item:
                continue
            item_id, query, name = item.groups()
            entry: dict = {
                "slot": text(slot.group(1)),
                "item": {"itemId": int(item_id), "name": text(name)},
            }
            bonuses = bonus_ids(query)
            if bonuses:
                entry["item"]["bonusIDs"] = bonuses
            drop = _DROP.search(chunk)
            if drop:
                source = text(drop.group(1))
                if source:
                    entry["source"] = source
            slots.append(entry)
        if slots:
            tabs.append({"label": labels[pid], "slots": slots})
    return tabs


# ---------------------------------------------------------------------------

_SRC = re.compile(
    r'\["([a-z-]+)"\] = \{.*?icyveins = \{([^}]*)\}', re.S)
_URL = re.compile(r'(\w+) = "([^"]+)"')


def targets() -> list[dict]:
    out: list[dict] = []
    for path in sorted(DATA.glob("*/sources.lua")):
        class_dir = path.parent.name
        for spec_key, body in _SRC.findall(path.read_text(encoding="utf-8")):
            urls = dict(_URL.findall(body))
            out.append({"classDir": class_dir, "specKey": spec_key, "urls": urls})
    return out


def scrape_spec(target: dict) -> dict:
    name = f"{target['classDir']}/{target['specKey']}"
    data: dict = {}

    talents: list[dict] = []
    for key, is_leveling in (("talents", False), ("leveling", True)):
        url = target["urls"].get(key)
        if not url:
            continue
        try:
            page = fetch(url)
        except urllib.error.HTTPError as exc:
            log(f"  ! {name} {key}: HTTP {exc.code}")
            continue
        have = {t["exportString"] for t in talents}
        for entry in parse_talents(page, leveling=is_leveling):
            if entry["exportString"] not in have:
                have.add(entry["exportString"])
                talents.append(entry)
    if talents:
        data["talents"] = talents

    url = target["urls"].get("bis")
    gear: list[dict] = []
    if url:
        try:
            gear = parse_gear(fetch(url))
        except urllib.error.HTTPError as exc:
            log(f"  ! {name} bis: HTTP {exc.code}")
    if gear:
        data["bisGear"] = gear

    log(f"  {name}: {len(talents)} builds, "
        f"{len(gear)} gear tabs ({sum(len(g['slots']) for g in gear)} slots)")
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
        token = CLASS_DIRS[class_dir]
        talents = {s: {"talents": d["talents"]}
                   for s, d in sorted(specs.items()) if d.get("talents")}
        if talents:
            write_lua(DATA / class_dir / "talents-icyveins.lua",
                      "ClassCodexIcyVeinsTalentData", token, talents,
                      header="Source: icy-veins.com")
        gear = {s: {"bisGear": d["bisGear"]}
                for s, d in sorted(specs.items()) if d.get("bisGear")}
        if gear:
            write_lua(DATA / class_dir / "gear-icyveins.lua",
                      "ClassCodexIcyVeinsData", token, gear,
                      header="Source: icy-veins.com")
        log(f"wrote Data/{class_dir}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
