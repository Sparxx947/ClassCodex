#!/usr/bin/env python3
"""Find out whether Blizzard's API still exposes talent loadouts.

Everything needed to regenerate Data/*/bnet-pvp-talents.lua hangs on one
unanswered question: does the character specializations endpoint still
return a `loadouts` array with `talent_loadout_code`?

It stopped doing so in patch 11.2 (reported 2025-08-07 on the API bug
forum, never answered by Blizzard). Whether that was fixed since cannot
be established from outside — the endpoint needs credentials. Rather than
write a scraper against an API that may not carry the data, this probe
answers the question first, in one run.

Set up:

  1. https://develop.battle.net/access/clients — create a client.
     Any name, no redirect URL needed for client_credentials.
  2. Put the two values in ~/.config/bnet/credentials (chmod 600), or
     set BNET_CLIENT_ID and BNET_CLIENT_SECRET in the environment. See
     ccutil.bnet_credentials.
  3. python3 tools/probe_bnet.py

Nothing here prints the credentials.

It makes at most four requests and writes nothing.

Exit code 0 if loadouts are present (the scraper in #7 is worth writing),
1 if they are absent (it is not), 2 if the probe could not run.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccutil import bnet_credentials  # noqa: E402

REGION = os.environ.get("BNET_REGION", "eu")
LOCALE = "en_GB" if REGION == "eu" else "en_US"
OAUTH = "https://oauth.battle.net/token"
API = f"https://{REGION}.api.blizzard.com"


def die(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def token() -> str:
    # bnet_credentials exits 1 on its own; that code means "loadouts are
    # absent" here, so a missing key file must not be read as an answer
    # about the API.
    try:
        client_id, secret = bnet_credentials()
    except SystemExit as exc:
        die(str(exc), 2)
    data = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
    req = urllib.request.Request(OAUTH, data=data)
    import base64
    basic = base64.b64encode(f"{client_id}:{secret}".encode()).decode()
    req.add_header("Authorization", f"Basic {basic}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)["access_token"]
    except urllib.error.HTTPError as exc:
        die(f"could not get a token: HTTP {exc.code} — check the credentials")


def get(path: str, namespace: str, access: str) -> dict:
    url = f"{API}{path}?namespace={namespace}-{REGION}&locale={LOCALE}"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {access}")
    with urllib.request.urlopen(req, timeout=45) as resp:
        return json.load(resp)


def main() -> int:
    access = token()
    print("token obtained")

    seasons = get("/data/wow/pvp-season/index", "dynamic", access)
    season = seasons["current_season"]["id"]
    print(f"current PvP season: {season}")

    board = get(f"/data/wow/pvp-season/{season}/pvp-leaderboard/3v3",
                "dynamic", access)
    entries = board.get("entries") or []
    print(f"3v3 leaderboard: {len(entries)} entries")
    if not entries:
        die("leaderboard is empty — cannot probe a character", 2)

    top = entries[0]["character"]
    realm = top["realm"]["slug"]
    name = urllib.parse.quote(top["name"].lower())
    print(f"probing {top['name']}-{realm}")

    try:
        specs = get(f"/profile/wow/character/{realm}/{name}/specializations",
                    "profile", access)
    except urllib.error.HTTPError as exc:
        die(f"specializations endpoint returned HTTP {exc.code}", 2)

    groups = specs.get("specializations") or []
    print(f"specializations returned: {len(groups)}")

    loadouts = [lo for group in groups for lo in (group.get("loadouts") or [])]
    codes = [lo.get("talent_loadout_code") for lo in loadouts
             if lo.get("talent_loadout_code")]
    pvp_slots = specs.get("pvp_talent_slots") or []

    print(f"  loadouts: {len(loadouts)}")
    print(f"  talent_loadout_code present: {len(codes)}")
    print(f"  pvp_talent_slots: {len(pvp_slots)}")

    if codes:
        print("\nLoadouts ARE exposed. Writing the scraper for #7 is worth it:")
        print(f"  example code: {codes[0][:48]}…")
        return 0

    print("\nLoadouts are NOT exposed — the field is missing, as reported for\n"
          "patch 11.2. bnet-pvp-talents.lua cannot be regenerated from this\n"
          "API until Blizzard restores it. Keys present in a specialization\n"
          "group were:")
    if groups:
        print(f"  {sorted(groups[0].keys())}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
