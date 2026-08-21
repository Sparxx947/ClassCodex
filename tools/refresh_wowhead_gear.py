#!/usr/bin/env python3
"""Regenerate Data/<Class>/gear-wowhead.lua from Wowhead.

Three pages per spec:

  * <spec>/bis-gear            BiS tables per source, and the trinket tier list
  * <spec>/enchants-gems-…     the enchant table and gem recommendations
  * <spec>/<season>            the seasonal guide, for the consumables list

Wowhead's markup names items by id only. The English names ride along in
the page's WH.Gatherer payload, which ccutil.wowhead_names decodes — so
the generated files stay readable without a second lookup service.

Usage:
    python3 tools/refresh_wowhead_gear.py [--classes Hunter] [--jobs 6]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import re
import sys
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import whmarkup as W  # noqa: E402
from ccutil import (  # noqa: E402
    CLASS_DIRS, DATA, fetch, log, wowhead_items, write_lua,
)
from refresh_wowhead import BASE, ROLES, guide_targets, subpage_slugs  # noqa: E402

def rows(body: str) -> list[list[str]]:
    """Table rows as lists of cell bodies.

    Nesting-aware on purpose: some BiS tables embed a table inside a
    cell, and a non-greedy [tr](.*?)[/tr] scan ends the outer row at the
    inner row's close tag — which silently shifts every column and drops
    the affected slots.
    """
    return [[cell for _, cell in W.nested_blocks(row, "td")]
            for _, row in W.nested_blocks(body, "tr")]
# A bare [item=…] is the gear piece. [url=item=…] is a link — used for
# the enchant column and for alternative-item links inside a gear cell —
# so it must not be picked up as the item itself.
_ITEM = re.compile(r"(?<!\[url=)\[item=(\d+)([^\]]*)\]")
_BONUS = re.compile(r"bonus=([\d:]+)")
_LIST_IDS = re.compile(r"\blist=([\d,]+)")
_H2 = re.compile(r'\[h2[^\]]*toc="([^"]+)"[^\]]*\]')

# Headings whose tables hold slot/item/source rows. "Recommended Gear"
# is the actual best-in-slot list; the per-source sections list further
# options for the same slots, which the addon merges into one list the
# way upstream's data did.
BIS_SECTIONS = ("Recommended Gear", "Raid Drops", "Mythic+ Drops",
                "Overall", "Best in Slot")

# Consumable slots are not labelled on the page. The item's icon slug
# says what it is far more reliably than its name does — "Light's
# Potential" is a combat potion but reads like food, while its icon is
# inv_12_profession_alchemy_lightpotion_yellow. Icon match first, name
# as fallback, food as the default.
CONSUMABLE_RULES = (
    ("augmentRune", ("enchanting_crystal", "augmentrune"), ("augment rune",)),
    ("flask", ("alchemy_flask", "_flask"), ("flask",)),
    ("combatPotion", ("potion",), ("potion",)),
    ("weaponBuff", ("manaoil", "_oil", "sharpening", "weightstone"),
     ("oil", "sharpening stone", "weightstone")),
)


def consumable_slot(name: str, icon: str) -> str:
    icon = icon.lower()
    name = name.lower()
    for slot, icon_needles, _ in CONSUMABLE_RULES:
        if any(n in icon for n in icon_needles):
            return slot
    for slot, _, name_needles in CONSUMABLE_RULES:
        if any(n in name for n in name_needles):
            return slot
    return "food"


def item_from(cell: str, items: dict[int, dict]) -> dict | None:
    m = _ITEM.search(cell)
    if not m:
        return None
    item_id = int(m.group(1))
    out: dict = {"itemId": item_id}
    record = items.get(item_id)
    if record:
        out["name"] = record["name"]
    bonus = _BONUS.search(m.group(2))
    if bonus:
        ids = [int(x) for x in bonus.group(1).split(":") if x.isdigit()]
        if ids:
            out["bonusIDs"] = ids
    return out


def sections(markup: str) -> list[tuple[str, str]]:
    """(heading, body) for every [h2 toc=...] section, in page order."""
    marks = [(m.group(1), m.end()) for m in _H2.finditer(markup)]
    out = []
    for i, (title, start) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else len(markup)
        out.append((title, markup[start:end]))
    return out


def parse_bis(markup: str, names: dict[int, str]) -> list[dict]:
    """Slot / item / source rows from the BiS tables."""
    slots: list[dict] = []
    seen: set[tuple[str, int]] = set()
    for title, body in sections(markup):
        if not any(title.startswith(s) for s in BIS_SECTIONS):
            continue
        for cells in rows(body):
            if len(cells) < 2:
                continue
            slot = W.plain(cells[0])
            # Column layout varies between specs: some tables insert an
            # enchant column between slot and item, so the item cell is
            # found by content, not by position.
            item = None
            item_index = None
            for index, cell in enumerate(cells[1:], start=1):
                candidate = item_from(cell, names)
                if candidate:
                    item, item_index = candidate, index
                    break
            if not slot or not item or slot.lower() in ("slot", "item"):
                continue
            key = (slot, item["itemId"])
            if key in seen:
                continue
            seen.add(key)
            entry = {"slot": slot, "item": item}
            for cell in reversed(cells[item_index + 1:]):
                source = W.plain(cell)
                if source and "[item=" not in cell:
                    entry["source"] = source
                    break
            slots.append(entry)
    return [{"label": "Overall", "slots": slots}] if slots else []


def parse_trinkets(markup: str, names: dict[int, str]) -> list[dict]:
    """The trinket tier list: id, tier letter and the contexts it applies to."""
    out: list[dict] = []
    for _, body in W.nested_blocks(markup, "tier-list"):
        for _, tier_body in W.nested_blocks(body, "tier"):
            label = ""
            for attrs, inner in W.blocks(tier_body, "tier-label"):
                label = W.plain(inner)
                break
            if not label:
                continue
            for attrs in W.self_blocks(tier_body, "icon-badge"):
                raw = attrs.get("icon-badge") or ""
                # An id can carry its bonus ids after a semicolon:
                # icon-badge=270175;13848
                head, _, bonus = raw.partition(";")
                if not head.isdigit():
                    continue
                item_id = int(head)
                entry: dict = {"itemId": item_id, "tier": label}
                record = names.get(item_id)
                if record:
                    entry["name"] = record["name"]
                bonus_ids = [int(x) for x in bonus.split(":") if x.isdigit()]
                if bonus_ids:
                    entry["bonusIDs"] = bonus_ids
                contexts = [c for c in
                            (attrs.get("display-options") or "").split(",") if c]
                if contexts:
                    entry["contexts"] = contexts
                out.append(entry)
    return out


def parse_enchants(markup: str, names: dict[int, str]) -> tuple[list[dict], dict]:
    """(enchant rows, gem recommendation) from the enchants/gems page."""
    enchants: list[dict] = []
    gems: dict = {}
    for cells in rows(markup):
        if len(cells) < 2:
            continue
        slot = W.plain(cells[0])
        if not slot or slot.lower() in ("slot", "best enchant"):
            continue
        items = [item_from(f"[item={m.group(1)}{m.group(2)}]", names)
                 for m in _ITEM.finditer(cells[1])]
        items = [i for i in items if i]
        if not items:
            continue
        if slot.lower().startswith("gem"):
            gems["primary"] = items[0]
            if len(items) > 1:
                gems["secondary"] = items[1:]
            continue
        enchants.append({"slot": slot, "best": items[0]})
    return enchants, gems


def parse_consumables(markup: str, items: dict[int, dict]) -> dict:
    """Flask / combat potion / food / weapon oil / augment rune.

    Wowhead lists them in recommendation order, so the first item that
    lands in a slot is the one kept.
    """
    out: dict = {}
    for attrs, inner in W.blocks(markup, "build-items"):
        if "consumable" not in W.plain(inner).lower():
            continue
        for token in (attrs.get("list") or "").split(","):
            token = token.strip()
            if not token.isdigit():
                continue
            item_id = int(token)
            record = items.get(item_id)
            if not record:
                continue
            slot = consumable_slot(record["name"], record["icon"])
            out.setdefault(slot, {"itemId": item_id, "name": record["name"]})
    return out


def scrape_spec(target: dict) -> dict:
    name = f"{target['classDir']}/{target['specKey']}"
    data: dict = {}

    def page(slug: str) -> tuple[str, dict[int, str]] | None:
        try:
            html = fetch(f"{BASE}/{target['classSlug']}/{target['specSlug']}/{slug}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        markup = W.extract(html)
        return (markup, wowhead_items(html)) if markup else None

    got = page("bis-gear")
    if got:
        markup, names = got
        bis = parse_bis(markup, names)
        if bis:
            data["bisGear"] = bis
        trinkets = parse_trinkets(markup, names)
        if trinkets:
            data["trinkets"] = trinkets

    guide = page(target["season"])
    if guide:
        markup, names = guide
        consumables = parse_consumables(markup, names)
        if consumables:
            data["consumables"] = consumables
        for slug in subpage_slugs(markup, "enchants"):
            got = page(slug)
            if not got:
                continue
            enchant_markup, enchant_names = got
            enchants, gems = parse_enchants(enchant_markup, enchant_names)
            if enchants:
                data["enchants"] = enchants
            if gems:
                data["gems"] = gems
            break

    bis_slots = sum(len(tab["slots"]) for tab in data.get("bisGear") or [])
    log(f"  {name}: {bis_slots} bis slots, "
        f"{len(data.get('enchants') or [])} enchants, "
        f"{len(data.get('trinkets') or [])} trinkets, "
        f"{len(data.get('consumables') or {})} consumables")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes")
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    only = set(args.classes.split(",")) if args.classes else None
    todo = [t for t in guide_targets() if not only or t["classDir"] in only]
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
        write_lua(DATA / class_dir / "gear-wowhead.lua", "ClassCodexGearData",
                  CLASS_DIRS[class_dir], dict(sorted(specs.items())),
                  header="Source: wowhead.com")
        log(f"wrote Data/{class_dir}/gear-wowhead.lua")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
