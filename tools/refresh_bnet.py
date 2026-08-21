#!/usr/bin/env python3
"""Regenerate Data/<Class>/bnet-pvp-talents.lua from Blizzard's API.

What the top-rated players of each spec actually run in rated PvP:
their active talent loadout and their three PvP talents, taken from the
PvP leaderboards and each listed character's profile.

Two shapes of leaderboard, handled differently:

  * shuffle-<class>-<spec> and blitz-<class>-<spec> name the spec, so no
    guessing is needed.
  * 2v2, 3v3 and rbg mix every spec together, so each entry's spec comes
    from the character profile that is fetched anyway.

Credentials come from ~/.config/bnet/credentials or the environment; see
ccutil.bnet_credentials. Nothing here prints them.

This is by far the heaviest scraper in the toolchain — roughly 2,000
requests — because there is no aggregate endpoint: every player has to be
looked up individually. Responses are cached, so a second run is cheap.

Usage:
    python3 tools/refresh_bnet.py [--classes Hunter] [--top 20] [--jobs 8]
"""

from __future__ import annotations

import argparse
import base64
import collections
import concurrent.futures as futures
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccutil import (  # noqa: E402
    CACHE, CLASS_DIRS, DATA, Keyed, bnet_credentials, log, write_lua,
)

REGION = "eu"
API = f"https://{REGION}.api.blizzard.com"
OAUTH = "https://oauth.battle.net/token"
LOCALE = "en_GB"

# Bracket key in the addon's data -> how to reach it on the API.
# "per-spec" brackets name the spec in the leaderboard slug; the others
# mix specs and need the profile to tell them apart.
PER_SPEC_BRACKETS = {"pvp-shuffle": "shuffle", "pvp-blitz": "blitz"}
MIXED_BRACKETS = {"pvp-2v2": "2v2", "pvp-3v3": "3v3", "pvp-rbg": "rbg"}

# How many talent-set combinations the addon shows per bracket.
MAX_TALENT_SETS = 5

_token: str | None = None
_token_lock = threading.Lock()
# Blizzard allows 100 requests/second. Stay well under it — this runs for
# minutes and a throttle would cost more time than the restraint does.
_pace_lock = threading.Lock()
_last = [0.0]
MIN_INTERVAL = 0.02


def token() -> str:
    global _token
    with _token_lock:
        if _token:
            return _token
        client_id, secret = bnet_credentials()
        data = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
        req = urllib.request.Request(OAUTH, data=data)
        basic = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
        req.add_header("Authorization", f"Basic {basic}")
        with urllib.request.urlopen(req, timeout=30) as resp:
            _token = json.load(resp)["access_token"]
        return _token


def api(path: str, namespace: str = "dynamic", *, max_age: float = 43200.0) -> dict:
    """GET a JSON document, cached on disk like the other scrapers."""
    import gzip
    import hashlib
    import os

    key = hashlib.sha256(f"{path}|{namespace}".encode()).hexdigest()[:32]
    cached = CACHE / f"bnet-{key}.json.gz"
    if cached.exists() and (time.time() - cached.stat().st_mtime) < max_age:
        with gzip.open(cached, "rt", encoding="utf-8") as fh:
            return json.load(fh)

    url = f"{API}{path}?namespace={namespace}-{REGION}&locale={LOCALE}"
    last: Exception | None = None
    for attempt in range(4):
        with _pace_lock:
            wait = _last[0] + MIN_INTERVAL - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            _last[0] = time.monotonic()
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {token()}")
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                payload = json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code in (403, 404):
                raise
            last = exc
            time.sleep(1.5 * (attempt + 1))
            continue
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(1.5 * (attempt + 1))
            continue
        CACHE.mkdir(parents=True, exist_ok=True)
        os.makedirs(CACHE, exist_ok=True)
        with gzip.open(cached, "wt", encoding="utf-8") as fh:
            json.dump(payload, fh)
        return payload
    raise RuntimeError(f"giving up on {path}: {last}")


def current_season() -> int:
    return api("/data/wow/pvp-season/index")["current_season"]["id"]


def leaderboard(season: int, name: str) -> list[dict]:
    try:
        return api(f"/data/wow/pvp-season/{season}/pvp-leaderboard/{name}").get(
            "entries") or []
    except urllib.error.HTTPError as exc:
        log(f"  ! leaderboard {name}: HTTP {exc.code}")
        return []


def character_build(entry: dict, want_spec: str | None = None) -> dict | None:
    """One leaderboard entry's loadout and PvP talents.

    *want_spec* is the spec the leaderboard is for, as a display name.
    It matters: a player listed on shuffle-hunter-beastmastery may be
    logged out as Marksmanship, and taking their *active* spec would
    file a Marksmanship loadout — Sentinel hero talent and all — under
    Beast Mastery. Mixed brackets pass None and take the active spec,
    which is the only thing that identifies them.
    """
    char = entry["character"]
    realm = char["realm"]["slug"]
    name = urllib.parse.quote(char["name"].lower())
    try:
        data = api(f"/profile/wow/character/{realm}/{name}/specializations",
                   namespace="profile")
    except (urllib.error.HTTPError, RuntimeError):
        # Renamed, transferred or hidden profiles are normal at this
        # volume and are not worth reporting one by one.
        return None

    active = (data.get("active_specialization") or {}).get("name")
    wanted = (want_spec or active or "").lower()
    for group in data.get("specializations") or []:
        spec_name = (group.get("specialization") or {}).get("name") or ""
        if spec_name.lower() != wanted:
            continue

        loadouts = group.get("loadouts") or []
        chosen = next((lo for lo in loadouts
                       if lo.get("is_active") and lo.get("talent_loadout_code")), None)
        if chosen is None:
            chosen = next((lo for lo in loadouts if lo.get("talent_loadout_code")), None)

        # The hero talent has to come from the loadout, not from the
        # character's active_hero_talent_tree, for the same reason.
        hero = None
        if chosen:
            hero = (chosen.get("selected_hero_talent_tree") or {}).get("name")

        talents = [
            (slot.get("selected") or {}).get("talent", {}).get("id")
            for slot in group.get("pvp_talent_slots") or []
        ]
        talents = [t for t in talents if t]

        code = chosen.get("talent_loadout_code") if chosen else None
        if not code and not talents:
            return None
        return {"spec": spec_name, "heroTalent": hero, "exportString": code,
                "talents": talents, "rank": entry.get("rank", 9999)}
    return None


def summarise(builds: list[dict]) -> dict | None:
    """Fold many players' setups into what the addon shows.

    One build per hero talent, taken from the highest-ranked player
    running it — an "average" loadout code would be a code nobody plays.
    Talent sets are the genuinely popular combinations, so those are
    counted.
    """
    out: dict = {}
    by_hero: dict[str, dict] = {}
    for build in sorted(builds, key=lambda b: b["rank"]):
        if not build.get("exportString"):
            continue
        hero = build.get("heroTalent") or "All"
        if hero not in by_hero:
            by_hero[hero] = {"exportString": build["exportString"],
                             "heroTalent": hero}
    if by_hero:
        out["builds"] = list(by_hero.values())

    counter = collections.Counter(
        tuple(b["talents"]) for b in builds if len(b.get("talents") or []) == 3)
    if counter:
        out["pvpTalentSets"] = [{"talents": list(combo)}
                                for combo, _ in counter.most_common(MAX_TALENT_SETS)]
    return out or None


_SPEC_KEY = re.compile(r'^  \["([a-z-]+)"\] = \{', re.M)


def spec_list() -> list[tuple[str, str, str]]:
    """(class folder, class slug, spec slug) for every spec, from sources.lua."""
    out = []
    for path in sorted(DATA.glob("*/sources.lua")):
        text = path.read_text(encoding="utf-8")
        class_slug = ""
        m = re.search(r"https://murlok\.io/([a-z-]+)/", text)
        if m:
            class_slug = m.group(1)
        for spec in _SPEC_KEY.findall(text):
            out.append((path.parent.name, class_slug, spec))
    return out


def bracket_slug(kind: str, class_slug: str, spec_slug: str) -> str:
    """shuffle + death-knight + blood -> shuffle-deathknight-blood."""
    return f"{kind}-{class_slug.replace('-', '')}-{spec_slug.replace('-', '')}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes")
    ap.add_argument("--top", type=int, default=20,
                    help="players sampled per per-spec bracket")
    ap.add_argument("--mixed-top", type=int, default=0,
                    help="entries sampled per mixed bracket (2v2/3v3/rbg); "
                         "0 reads the whole leaderboard")
    ap.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args()

    only = set(args.classes.split(",")) if args.classes else None
    specs = [s for s in spec_list() if not only or s[0] in only]
    season = current_season()
    log(f"PvP season {season}, {len(specs)} specs")

    # spec name as the API reports it -> (class dir, spec slug)
    spec_lookup: dict[str, tuple[str, str]] = {}
    results: dict[tuple[str, str], dict[str, list[dict]]] = {}

    def collect(class_dir: str, spec_slug: str, bracket: str, build: dict) -> None:
        results.setdefault((class_dir, spec_slug), {}).setdefault(
            bracket, []).append(build)

    jobs: list[tuple] = []
    for class_dir, class_slug, spec_slug in specs:
        # "beast-mastery" -> "Beast Mastery", which is how the profile
        # endpoint names it.
        spec_name = spec_slug.replace("-", " ").title()
        for bracket_key, kind in PER_SPEC_BRACKETS.items():
            slug = bracket_slug(kind, class_slug, spec_slug)
            jobs.append(("per-spec", class_dir, spec_slug, bracket_key, slug,
                         spec_name))

    log(f"reading {len(jobs)} per-spec leaderboards ...")
    with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        def run_per_spec(job):
            _, class_dir, spec_slug, bracket_key, slug, spec_name = job
            entries = leaderboard(season, slug)[:args.top]
            found = []
            for entry in entries:
                build = character_build(entry, want_spec=spec_name)
                if build:
                    found.append(build)
            return class_dir, spec_slug, bracket_key, slug, found

        done = 0
        for class_dir, spec_slug, bracket_key, slug, found in pool.map(run_per_spec, jobs):
            done += 1
            for build in found:
                collect(class_dir, spec_slug, bracket_key, build)
            log(f"  [{done}/{len(jobs)}] {slug}: {len(found)} players")

    # Mixed brackets: the spec is only known once the profile is read.
    api_name_to_spec: dict[str, tuple[str, str]] = {}
    for class_dir, class_slug, spec_slug in specs:
        # "beast-mastery" -> "beast mastery"; matched case-insensitively
        api_name_to_spec[spec_slug.replace("-", " ")] = (class_dir, spec_slug)

    for bracket_key, slug in MIXED_BRACKETS.items():
        entries = leaderboard(season, slug)
        # Sampling the top N misses the specs that are rare in that
        # bracket entirely — the ones whose data is hardest to get
        # elsewhere. Reading the whole board is the only way to cover
        # them, and the boards are not that large: 5,008 / 3,601 / 172.
        if args.mixed_top:
            entries = entries[:args.mixed_top]
        log(f"reading {slug}: {len(entries)} entries ...")
        with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for build in pool.map(character_build, entries):
                if not build or not build.get("spec"):
                    continue
                target = api_name_to_spec.get(build["spec"].lower())
                if not target:
                    continue
                class_dir, spec_slug = target
                if only and class_dir not in only:
                    continue
                collect(class_dir, spec_slug, bracket_key, build)

    by_class: dict[str, dict[str, dict]] = {}
    for (class_dir, spec_slug), brackets in results.items():
        payload: dict = {}
        for bracket_key in list(PER_SPEC_BRACKETS) + list(MIXED_BRACKETS):
            summary = summarise(brackets.get(bracket_key) or [])
            if summary:
                payload[bracket_key] = summary
        if payload:
            by_class.setdefault(class_dir, {})[spec_slug] = {
                "brackets": Keyed(payload)}

    for class_dir, payload in sorted(by_class.items()):
        write_lua(DATA / class_dir / "bnet-pvp-talents.lua",
                  "ClassCodexBnetPvpTalents", CLASS_DIRS[class_dir],
                  dict(sorted(payload.items())),
                  header=f"Source: Blizzard API, PvP season {season}")
        covered = sum(len(v["brackets"]) for v in payload.values())
        log(f"wrote Data/{class_dir}/bnet-pvp-talents.lua "
            f"({len(payload)} specs, {covered} brackets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
