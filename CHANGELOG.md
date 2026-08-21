# Changelog

Notable changes to this continuation. The addon code is jfstn's work; only
the changes listed here depart from upstream v0.36.3.

## 0.37.0 — 2026-08-21

First release of the community continuation, built on upstream v0.36.3
(2026-07-02).

### Data

* Refreshed every generated file for **Midnight 12.1 Season 2** across all
  40 specs and 13 classes. Upstream's data described 12.0.7 and season 1.
* Season 2 layout now covered: the eight current Mythic+ dungeons and the
  new raid. `bnet-pvp-talents.lua` is the one file still on upstream data.
* All 280 external guide links repointed and verified — 200 by HTTP and 80
  Wowhead links from a real browser session, since Wowhead answers 403 to
  non-browser clients whether or not the page exists.

### Fixed

* **Zone detection produced nothing against season 2 data.**
  `ComputeActiveContext` built its lookup keys with a hard-coded
  `mythic-plus:high-keys:…`, and Archon renamed that bracket to `10` for
  season 2. The bracket and the raid difficulty are now read back out of
  the loaded data, so a season rollover no longer needs a code change.
* Non-Mythic raid contexts other than Heroic fell through to no scope at
  all, hiding bosses that Archon has only published on Normal so far.
* `## Interface` raised to `120100`; the client would otherwise refuse to
  load the addon without "Load out of date AddOns" ticked.

### Added

* `tools/` — a complete, reproducible data refresh toolchain. Upstream
  never published its scraper, which is why the data went stale the moment
  the author stopped. Python 3.11+ standard library only.
* `tools/check_lua.sh` — parses every Lua file with a Lua 5.1 compiler.
* `tools/check_data.py` — completeness and staleness check. It found ten
  specs with no PvP data on its first run; nine are now covered by
  falling back to another rated bracket.
* README, this changelog, and `docs/data-sources.md`.

### Removed

* `packages/` — TypeScript development spikes and a Discord bot setup
  script that upstream shipped by accident. Not referenced by the TOC, so
  WoW never loaded them.
* CurseForge and Wago project ids, which point at a delisted project.
