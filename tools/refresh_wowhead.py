#!/usr/bin/env python3
"""Regenerate Data/<Class>/guide.lua from Wowhead's class guides.

Two pages per spec:

  * <spec>/<season>          the seasonal guide. Its [build] blocks are
                             fully attributed — hero talent, context tab,
                             stat priority and the Blizzard export string
                             — which makes them the reliable source for
                             stat priorities and recommended builds.
  * <spec>/rotation-...      the rotation page, whose priority lists become
                             the addon's rotation steps.

The per-spec subpage slugs differ by role (…-pve-dps / -pve-healer /
-pve-tank), so they are read out of the guide's own nav bar rather than
guessed.

Not scraped: the standalone talent-builds page. It is free-form prose
whose hero-talent grouping is only recoverable from icon file names, so
its extra builds are left to the Archon data, which carries a build per
hero talent from actual logs.

Usage:
    python3 tools/refresh_wowhead.py [--classes Hunter] [--jobs 6]
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
from ccutil import CLASS_DIRS, DATA, SLUG_TO_DIR, fetch, log, write_lua  # noqa: E402

BASE = "https://www.wowhead.com/guide/classes"

_HERO_IN_DATA = re.compile(r'heroTalent = "([^"]+)"')


def known_hero_talents() -> dict[str, set[str]]:
    """Hero talent names per class folder, harvested from the Archon data.

    Matching a name against a heading is far more robust than guessing
    from icon file names, and Archon already carries the full set for
    the live patch — so this needs no hand-maintained list.
    """
    out: dict[str, set[str]] = {}
    for path in DATA.glob("*/archon-talents.lua"):
        names = {n for n in _HERO_IN_DATA.findall(path.read_text(encoding="utf-8"))
                 if n != "All"}
        if names:
            out[path.parent.name] = names
    return out

_GUIDE_URL = re.compile(
    r"https://www\.wowhead\.com/guide/classes/([a-z-]+)/([a-z-]+)/([a-z0-9-]+)")


def guide_targets() -> list[dict]:
    """(class, spec, season slug) for every spec, read from sources.lua.

    sources.lua is the single place the season slug is recorded, so the
    two stay in step: refresh_sources.py sets it, this reads it back.
    """
    out: list[dict] = []
    for path in sorted(DATA.glob("*/sources.lua")):
        text = path.read_text(encoding="utf-8")
        for spec_key, url in re.findall(
                r'\["([a-z-]+)"\] = \{\s*\n\s*wowhead = \{ guide = "([^"]+)"', text):
            m = _GUIDE_URL.match(url)
            if not m:
                continue
            class_slug, spec_slug, season = m.groups()
            out.append({
                "classDir": SLUG_TO_DIR[class_slug],
                "classToken": CLASS_DIRS[SLUG_TO_DIR[class_slug]],
                "classSlug": class_slug,
                "specSlug": spec_slug,
                "specKey": spec_key,
                "season": season,
            })
    return out


def markup_for(target: dict, page: str) -> str | None:
    url = f"{BASE}/{target['classSlug']}/{target['specSlug']}/{page}"
    try:
        return W.extract(fetch(url))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


# ---------------------------------------------------------------------------
# Guide page: label, stat priorities, talent builds
# ---------------------------------------------------------------------------

def strip_spec_prefix(title: str, label: str) -> str:
    """"Beast Mastery Hunter Raid Build" -> "Raid Build"."""
    if label and title.startswith(label):
        title = title[len(label):]
    return re.sub(r"\s+", " ", title).strip(" -–—") or title


def parse_guide(markup: str) -> dict:
    builds = W.blocks(markup, "build")
    label = ""
    priorities: list[dict] = []
    talents: list[dict] = []
    seen_priority: set[tuple] = set()

    for attrs, _ in builds:
        spec_name = attrs.get("spec", "").strip()
        class_name = attrs.get("class", "").strip()
        if not label and spec_name and class_name:
            label = f"{spec_name} {class_name}"
        hero = attrs.get("hero", "").strip() or "All"
        context = attrs.get("tab", "").strip() or "General"

        ranks = W.stat_priority(attrs.get("stats", ""))
        if ranks:
            key = (hero, tuple(tuple(r) for r in ranks))
            if key not in seen_priority:
                seen_priority.add(key)
                priorities.append({"heroTalent": hero, "context": context,
                                   "stats": ranks})

        code = attrs.get("talents", "")
        if code.startswith("blizzard/"):
            code = code[len("blizzard/"):]
        code = code.strip()
        if code:
            entry = {"heroTalent": hero, "context": context}
            build_label = strip_spec_prefix(attrs.get("title", ""), label)
            if build_label:
                entry["buildLabel"] = build_label
            entry["exportString"] = code
            talents.append(entry)

    # A single stat priority shared by every build is not per-context
    # information; label it the way the addon labels a general one.
    if len(priorities) == 1:
        priorities[0]["context"] = "General"

    return {"label": label, "priorities": priorities, "talents": talents}


# ---------------------------------------------------------------------------
# Talent builds page
#
# This page carries the builds the seasonal guide leaves out — most
# importantly the alternative hero talent, which the guide only shows
# for its own recommendation. It is free-form prose, so unlike the
# guide's [build] blocks nothing here is attributed: the export strings
# sit in bare [dragonflight-talent-calc=blizzard/CODE] tags and the
# grouping has to be recovered from the surrounding tab and heading.
# ---------------------------------------------------------------------------

_CALC = re.compile(r"\[dragonflight-talent-calc=(?:blizzard/)?([A-Za-z0-9+/=]+)[^\]]*\]")
_H2 = re.compile(r'\[h2[^\]]*toc="([^"]+)"[^\]]*\]')

# Words that name a play context, longest first so "Raid Cleave" is not
# swallowed by "Raid".
CONTEXT_WORDS = (
    "Raid Cleave", "Mythic+", "Mythic Plus", "Delve", "Open World",
    "Leveling", "Raid", "PvP", "Single-Target", "Single Target", "AoE",
)


def context_from(text: str) -> str | None:
    lowered = text.lower()
    for word in CONTEXT_WORDS:
        if word.lower() in lowered:
            return {"Mythic Plus": "Mythic+", "Delve": "Delve/Open World",
                    "Open World": "Delve/Open World"}.get(word, word)
    return None


def parse_talent_page(markup: str, known_heroes: set[str]) -> list[dict]:
    """Extra builds from the talent-builds page, attributed by context."""
    heroes = hero_labels(markup)
    out: list[dict] = []

    # Heading in force at each offset, for calcs outside any tab.
    headings = [(m.start(), m.group(1)) for m in _H2.finditer(markup)]

    def heading_at(pos: int) -> str:
        current = ""
        for start, title in headings:
            if start <= pos:
                current = title
            else:
                break
        return current

    def hero_from(text: str) -> str | None:
        for name in sorted(known_heroes, key=len, reverse=True):
            if name.lower() in text.lower():
                return name
        return None

    def emit(code: str, hero: str, context: str, label: str) -> None:
        entry = {"heroTalent": hero or "All", "context": context or "General"}
        if label:
            entry["buildLabel"] = label
        entry["exportString"] = code
        out.append(entry)

    consumed: set[str] = set()
    for tab_attrs, tab_body in W.nested_blocks(markup, "tab"):
        name = (tab_attrs.get("name") or "").strip()
        section = heading_at(markup.find(tab_body[:60]) if tab_body else 0)
        for attrs, body in W.nested_blocks(tab_body, "div"):
            slug = attrs.get("display-options")
            if not slug:
                continue
            for code in _CALC.findall(body):
                consumed.add(code)
                hero = heroes.get(slug) or hero_from(name) or hero_from(section)
                emit(code, hero, context_from(name) or context_from(section),
                     name)
        for code in _CALC.findall(tab_body):
            if code in consumed:
                continue
            consumed.add(code)
            emit(code, hero_from(name) or hero_from(section),
                 context_from(name) or context_from(section), name)

    for m in _CALC.finditer(markup):
        code = m.group(1)
        if code in consumed:
            continue
        consumed.add(code)
        section = heading_at(m.start())
        emit(code, hero_from(section), context_from(section), section)

    return out


# ---------------------------------------------------------------------------
# Rotation page
# ---------------------------------------------------------------------------

_LIST = re.compile(r"\[(ol|ul)\](.*?)\[/\1\]", re.S)
_LI = re.compile(r"\[li\](.*?)\[/li\]", re.S)
_LEAD_CAST = re.compile(r"^(?:Cast|Use|Press)\s+", re.I)


def hero_labels(markup: str) -> dict[str, str]:
    """Hero-talent display-option slug -> display name.

    A rotation page toggles more than hero talents — Holy Priest, for
    instance, has a "Tot-ST" build variant switch. Only options declared
    with radio="Hero" name a hero talent; treating the others as one
    would put a build variant in the heroTalent field.
    """
    out: dict[str, str] = {}
    for attrs, inner in W.blocks(markup, "display-option"):
        slug = attrs.get("display-option")
        name = W.plain(inner)
        if slug and name and attrs.get("radio", "").lower() == "hero":
            out[slug] = name
    return out


def steps_from(chunk: str) -> list[str]:
    """The first priority list in *chunk*, as cleaned step strings."""
    for _, body in _LIST.findall(chunk):
        steps = []
        for raw in _LI.findall(body):
            text = _LEAD_CAST.sub("", W.plain(raw)).strip()
            if text:
                steps.append(text)
        if steps:
            return steps
    return []


def parse_rotation(markup: str) -> list[dict]:
    heroes = hero_labels(markup)
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()

    for tab_attrs, tab_body in W.nested_blocks(markup, "tab"):
        context = (tab_attrs.get("name") or "").strip()
        if not context:
            continue

        emitted = False
        for attrs, body in W.nested_blocks(tab_body, "div"):
            slug = attrs.get("display-options")
            if not slug:
                continue
            steps = steps_from(body)
            if not steps:
                continue
            if slug in heroes:
                hero, ctx = heroes[slug], context
            else:
                # A non-hero toggle names a build variant, not a hero
                # talent; it belongs in the context label.
                hero = "All"
                ctx = f"{context} ({slug})"
            key = (hero, ctx)
            if key not in seen:
                seen.add(key)
                out.append({"heroTalent": hero, "context": ctx, "steps": steps})
                emitted = True

        if not emitted:
            steps = steps_from(tab_body)
            key = ("All", context)
            if steps and key not in seen:
                seen.add(key)
                out.append({"heroTalent": "All", "context": context,
                            "steps": steps})
    return out


# ---------------------------------------------------------------------------

# Some guides carry Wowhead's own unresolved template placeholder in the
# nav bar — Blood Death Knight links "rotation-cooldowns-pve-$role". The
# role is not stated anywhere in the markup, so the candidates are tried
# in turn and the first that exists wins.
ROLES = ("dps", "tank", "healer")


def subpage_slugs(markup: str, prefix: str) -> list[str]:
    """Candidate subpage slugs starting with *prefix*, best guess first."""
    for attrs in W.self_blocks(markup, "nav-item"):
        slug = attrs.get("nav-item", "").rsplit("/", 1)[-1]
        if not slug.startswith(prefix):
            continue
        if "$role" in slug:
            return [slug.replace("$role", role) for role in ROLES]
        return [slug]
    return [f"{prefix}-pve-{role}" for role in ROLES]


def rotation_slugs(markup: str) -> list[str]:
    return subpage_slugs(markup, "rotation")


def scrape_spec(target: dict, heroes: set[str]) -> dict:
    name = f"{target['classDir']}/{target['specKey']}"
    guide_markup = markup_for(target, target["season"])
    if not guide_markup:
        log(f"  ! {name}: no guide markup")
        return {}
    data = parse_guide(guide_markup)

    # Builds the seasonal guide does not show — chiefly the alternative
    # hero talent. Deduplicated by export string, guide wins.
    extra = 0
    for slug in subpage_slugs(guide_markup, "talent-builds"):
        talent_markup = markup_for(target, slug)
        if not talent_markup:
            continue
        have = {b["exportString"] for b in data["talents"]}
        for build in parse_talent_page(talent_markup, heroes):
            if build["exportString"] not in have:
                have.add(build["exportString"])
                data["talents"].append(build)
                extra += 1
        break

    rot_markup = None
    for slug in rotation_slugs(guide_markup):
        rot_markup = markup_for(target, slug)
        if rot_markup:
            break
    if rot_markup:
        data["rotation"] = parse_rotation(rot_markup)

    log(f"  {name}: {len(data['priorities'])} priorities, "
        f"{len(data['talents'])} builds (+{extra} from the talents page), "
        f"{len(data.get('rotation') or [])} rotations")
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes")
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    only = set(args.classes.split(",")) if args.classes else None
    targets = [t for t in guide_targets() if not only or t["classDir"] in only]
    log(f"{len(targets)} specs")

    hero_names = known_hero_talents()
    by_class: dict[str, dict[str, dict]] = {}
    with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = {pool.submit(scrape_spec, t,
                            hero_names.get(t["classDir"], set())): t
                for t in targets}
        for fut in futures.as_completed(jobs):
            t = jobs[fut]
            data = fut.result()
            if data:
                by_class.setdefault(t["classDir"], {})[t["specKey"]] = data

    for class_dir, specs in sorted(by_class.items()):
        write_lua(DATA / class_dir / "guide.lua", "ClassCodexData",
                  CLASS_DIRS[class_dir], dict(sorted(specs.items())),
                  header="Source: wowhead.com class guides")
        log(f"wrote Data/{class_dir}/guide.lua ({len(specs)} specs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
