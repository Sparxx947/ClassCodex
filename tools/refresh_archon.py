#!/usr/bin/env python3
"""Regenerate the Archon.gg data files for every class and specialisation.

Archon ships its whole page model as a __NEXT_DATA__ JSON blob, including
the list of specs, the list of dungeons and raid bosses of the *current*
season, and the difficulty slugs. The scraper therefore discovers the
season layout instead of hard-coding it: when a season rotates, running
this again is enough.

Written files, per class folder:

    Data/<Class>/archon-stats.lua    ClassCodexArchonStats
    Data/<Class>/archon-talents.lua  ClassCodexArchonData
    Data/<Class>/gear-archon.lua     ClassCodexArchonGearData

Usage:
    python3 tools/refresh_archon.py [--classes Hunter,Mage] [--jobs 6]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccutil import (  # noqa: E402
    CLASS_DIRS, DATA, SLUG_TO_DIR, Keyed, fetch, log, lua_str, next_data,
    strip_markup, write_lua,
)

BASE = "https://www.archon.gg"

# Which raid difficulty wins when several are published for the same spec.
# Early in a season only Normal exists, then Heroic, then Mythic.
DIFFICULTY_RANK = {"normal": 1, "heroic": 2, "mythic": 3}
SEED = f"{BASE}/wow/builds/beast-mastery/hunter/mythic-plus/overview/10/all-dungeons/this-week"

# Archon's stat labels -> the keys the addon's StatTargets module reads.
STAT_KEYS = {
    "crit": "crit",
    "critical strike": "crit",
    "haste": "haste",
    "mastery": "mastery",
    "vers": "versatility",
    "versatility": "versatility",
    "leech": "leech",
    "speed": "speed",
    "avoidance": "avoidance",
}

_GEAR_ID = re.compile(r"id=\{(\d+)\}")
_GEAR_NAME = re.compile(r">([^<>]+)</GearIcon>")


def page(url: str) -> dict:
    return next_data(fetch(url))["props"]["pageProps"]["page"]


def sections(pg: dict) -> dict:
    return {s["navigationId"]: s["props"] for s in pg["sections"] if s.get("navigationId")}


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def discover_specs() -> list[dict]:
    """Every (class, spec) Archon publishes, with its slugs, from specOptions."""
    pg = page(SEED)
    specs: list[dict] = []
    for group in pg["specOptions"]:
        class_label = strip_markup(group["className"])
        for opt in group["options"]:
            # /wow/builds/<spec-slug>/<class-slug>/<zone>/...
            parts = opt["url"].strip("/").split("/")
            spec_slug, class_slug = parts[2], parts[3]
            class_dir = SLUG_TO_DIR.get(class_slug)
            if not class_dir:
                log(f"  ! unknown class slug {class_slug!r}, skipped")
                continue
            specs.append({
                "specSlug": spec_slug,
                "classSlug": class_slug,
                "classDir": class_dir,
                "classToken": CLASS_DIRS[class_dir],
                "specLabel": strip_markup(opt["label"]),
                "classLabel": class_label,
                "specId": opt["value"],
            })
    return specs


def build_url(spec: dict, zone: str, category: str, difficulty: str,
              encounter: str) -> str:
    tail = "/this-week" if zone == "mythic-plus" else ""
    return (f"{BASE}/wow/builds/{spec['specSlug']}/{spec['classSlug']}/{zone}"
            f"/{category}/{difficulty}/{encounter}{tail}")


def discover_contexts(spec: dict) -> list[tuple[str, str, str, str, str]]:
    """(zoneType, difficulty, difficultyLabel, encounter, encounterLabel)."""
    out: list[tuple[str, str, str, str, str]] = []
    for zone, seed_diff in (("mythic-plus", "10"), ("raid", "heroic")):
        try:
            pg = page(build_url(spec, zone, "overview", seed_diff, "all-dungeons"
                                if zone == "mythic-plus" else "all-bosses"))
        except Exception as exc:  # noqa: BLE001
            log(f"  ! {spec['classSlug']}/{spec['specSlug']} {zone}: {exc}")
            continue
        diffs = [(d["value"], strip_markup(d["label"])) for d in pg["difficultyOptions"]] \
            or [(pg["selectedDifficulty"], pg["selectedDifficulty"])]
        encs = [(e["value"], strip_markup(e["label"])) for e in pg["encounterOptions"]]
        for dval, dlabel in diffs:
            for eval_, elabel in encs:
                out.append((zone, dval, dlabel, eval_, elabel))
    return out


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def hero_tree_names(pg: dict) -> dict[int, str]:
    names: dict[int, str] = {}
    for bp in (pg.get("talentTreeBlueprints") or {}).values():
        for tree in bp.get("heroTrees") or []:
            if tree.get("id") is not None:
                names[tree["id"]] = strip_markup(tree.get("name"))
    return names


def extract_stats(sec: dict) -> dict | None:
    stats = (sec.get("stats") or {}).get("stats")
    if not stats:
        return None
    targets: dict[str, int] = {}
    for entry in stats:
        key = STAT_KEYS.get(strip_markup(entry.get("name")).lower())
        value = entry.get("value")
        if key and isinstance(value, (int, float)) and value > 0:
            targets[key] = int(value)
    if not targets:
        return None
    return {"targets": {k: targets[k] for k in
                        ("crit", "haste", "mastery", "versatility", "leech",
                         "speed", "avoidance") if k in targets}}


def extract_builds(sec: dict, heroes: dict[int, str]) -> list[dict]:
    """Best build per hero talent tree, ranked by Archon's popularity."""
    talents = sec.get("talents")
    if not talents:
        return []
    best: dict[str, tuple[float, dict]] = {}
    for build_set in talents.get("talentTreeBuildSets") or []:
        for alt in build_set.get("alternatives") or []:
            tree = alt.get("talentTree") or {}
            code = (tree.get("exportCodeParams") or {}).get("exportCode")
            if not code:
                continue
            hero_id = (tree.get("dehydratedBuild") or {}).get("heroSpecId")
            hero = heroes.get(hero_id) or "All"
            try:
                pop = float(str(alt.get("popularity", "0")).rstrip("%"))
            except ValueError:
                pop = 0.0
            # Archon's own pick wins ties against a marginally more popular tree.
            score = pop + (100.0 if alt.get("isDefaultSelection") else 0.0)
            entry = {"heroTalent": hero, "exportString": code}
            if alt.get("isDefaultSelection"):
                entry["recommended"] = True
            if hero not in best or score > best[hero][0]:
                best[hero] = (score, entry)
    return [v[1] for v in sorted(best.values(), key=lambda kv: -kv[0])]


def extract_gear(sec: dict) -> list[dict] | None:
    """Weapon, armour and trinkets in the addon's slot order."""
    gear = sec.get("gear-overview")
    if not gear:
        return None
    slots: list[dict] = []
    for bucket in ("weapons", "gear", "trinkets"):
        for entry in gear.get(bucket) or []:
            if entry.get("isPlaceholder"):
                continue
            icon = entry.get("icon") or ""
            m = _GEAR_ID.search(icon)
            if not m:
                continue
            item: dict = {"itemId": int(m.group(1))}
            name = _GEAR_NAME.search(icon)
            if name:
                item["name"] = name.group(1).strip()
            slots.append({"item": item})
    return slots or None


# ---------------------------------------------------------------------------
# Per-spec scrape
# ---------------------------------------------------------------------------

def scrape_spec(spec: dict) -> dict:
    label = f"{spec['specLabel']} {spec['classLabel']}"
    result: dict = {
        "label": label,
        "contexts": {},
        "contextOrder": [],
        "stats": {},
        "bisGear": [],
        "lastUpdated": None,
        "_rank": {},
    }
    contexts = discover_contexts(spec)
    if not contexts:
        return result

    for zone, diff, dlabel, enc, elabel in contexts:
        url = build_url(spec, zone, "overview", diff, enc)
        try:
            pg = page(url)
        except Exception as exc:  # noqa: BLE001
            log(f"  ! {label} {zone}/{diff}/{enc}: {exc}")
            continue
        sec = sections(pg)
        builds = extract_builds(sec, hero_tree_names(pg))
        if builds:
            result["contextOrder"].append(f"{zone}:{diff}:{enc}")
            result["contexts"][f"{zone}:{diff}:{enc}"] = {
                "zoneType": zone,
                "encounter": enc,
                "encounterLabel": elabel,
                "difficulty": diff,
                "difficultyLabel": dlabel,
                "builds": builds,
            }
        if pg.get("lastUpdated"):
            result["lastUpdated"] = pg["lastUpdated"]

        # Stat targets and BiS gear only come from the aggregate pages.
        if enc in ("all-dungeons", "all-bosses"):
            bucket = "Mythic+" if zone == "mythic-plus" else "Raid"
            rank = DIFFICULTY_RANK.get(diff, 0)
            stats = extract_stats(sec)
            if stats and rank >= result["_rank"].get(("stats", bucket), -1):
                result["stats"][bucket] = stats
                result["_rank"][("stats", bucket)] = rank
            slots = extract_gear(sec)
            if slots and rank >= result["_rank"].get(("gear", bucket), -1):
                existing = next((g for g in result["bisGear"]
                                 if g["label"] == bucket), None)
                if existing is None:
                    result["bisGear"].append({"label": bucket, "slots": slots})
                else:
                    existing["slots"] = slots
                result["_rank"][("gear", bucket)] = rank

    prune_normal_duplicates(result)
    return result


def prune_normal_duplicates(result: dict) -> None:
    """Drop raid Normal entries that a higher difficulty already covers.

    The addon buckets every non-Mythic raid context together, so keeping
    both Normal and Heroic for the same boss would list it twice. Normal
    is still kept where nothing else exists — early in a season the last
    boss of a raid is often published on Normal alone.
    """
    covered = {key.split(":")[2] for key in result["contexts"]
               if key.startswith(("raid:heroic:", "raid:mythic:"))}
    drop = [key for key in result["contexts"]
            if key.startswith("raid:normal:") and key.split(":")[2] in covered]
    for key in drop:
        del result["contexts"][key]
    if drop:
        dropped = set(drop)
        result["contextOrder"] = [k for k in result["contextOrder"]
                                  if k not in dropped]


# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

def write_class(class_dir: str, specs: dict[str, dict], stamp: str) -> None:
    token = CLASS_DIRS[class_dir]
    out = DATA / class_dir
    header = f"Source: archon.gg | scraped {stamp}"

    talents = {slug: {"label": d["label"],
                      "contextOrder": d["contextOrder"],
                      "contexts": Keyed(d["contexts"])}
               for slug, d in specs.items() if d["contexts"]}
    if talents:
        write_lua(out / "archon-talents.lua", "ClassCodexArchonData", token,
                  talents, header=header)

    stats = {slug: Keyed(d["stats"]) for slug, d in specs.items() if d["stats"]}
    if stats:
        write_lua(out / "archon-stats.lua", "ClassCodexArchonStats", token,
                  stats, header=header)

    gear = {slug: {"bisGear": d["bisGear"]} for slug, d in specs.items() if d["bisGear"]}
    if gear:
        write_lua(out / "gear-archon.lua", "ClassCodexArchonGearData", token,
                  gear, header=header)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes", help="comma-separated class folder names")
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    only = set(args.classes.split(",")) if args.classes else None

    log("discovering specs from Archon ...")
    specs = [s for s in discover_specs() if not only or s["classDir"] in only]
    log(f"  {len(specs)} specs across "
        f"{len({s['classDir'] for s in specs})} classes")

    by_class: dict[str, dict[str, dict]] = {}
    stamp = ""
    done = 0
    with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = {pool.submit(scrape_spec, s): s for s in specs}
        for fut in futures.as_completed(jobs):
            spec = jobs[fut]
            data = fut.result()
            done += 1
            log(f"  [{done}/{len(specs)}] {spec['classDir']}/{spec['specSlug']}: "
                f"{len(data['contexts'])} contexts, {len(data['stats'])} stat sets, "
                f"{len(data['bisGear'])} gear sets")
            by_class.setdefault(spec["classDir"], {})[spec["specSlug"]] = data
            stamp = data.get("lastUpdated") or stamp

    for class_dir, specs_data in sorted(by_class.items()):
        write_class(class_dir, dict(sorted(specs_data.items())), stamp or "unknown")
        log(f"wrote Data/{class_dir}/")
    print(stamp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
