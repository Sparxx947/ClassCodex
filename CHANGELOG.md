# Changelog

Notable changes to this continuation. The addon code is jfstn's work; only
the changes listed here depart from upstream v0.36.3.

## Unreleased

### Added

* `bnet-pvp-talents.lua` is generated again, for all 40 specs. It was the
  one file still carrying upstream data from 2026-07-02. `refresh_bnet.py`
  reads the PvP leaderboards and each listed character's profile — the
  heaviest scraper here, because there is no aggregate endpoint.
  `refresh_all.sh` skips it cleanly when no Blizzard credentials are set,
  so a data refresh never fails over the one source that needs a key.

### Changed

* Removed 21 locale keys across all ten languages that nothing reaches.
  Nine were rotation context labels for a data model that no longer
  exists — the guides now supply their own free-text tab names.

### Fixed

* `tools/check_locales.py` no longer reports dynamically built keys as
  unused. It listed the four `title_bar.menu.width_*` keys, which are
  assembled by concatenation; deleting them would have left the width
  menu showing raw key names in every language, silently.

### Added

* `tools/probe_bnet.py` — establishes whether Blizzard's API still
  exposes talent loadouts, which is the open question behind #7. It reads
  credentials from `~/.config/bnet/credentials`, so a key never has to go
  through a shell history or a transcript, and refuses to read the file
  if it is readable beyond its owner.

## 0.38.2 — 2026-08-21

### Added

* Downloadable releases. A tagged push builds `ClassCodex-<version>.zip`
  and publishes it, so installing no longer requires git — extract and
  drop the `ClassCodex` folder into `Interface/AddOns/`.
* `tools/check_policy.py` — checks the addon against Blizzard's add-on
  policy on every push. The audit that found the original Patreon
  violation was a one-off; this makes it repeatable, so the same thing
  cannot come back through a careless edit or a merge from upstream.
  Verified by running it against the unmodified upstream tree, where it
  reports exactly the violation that was found by hand.

### Changed

* The Credits tab's locale key is `about.credits` rather than
  `about.supporters`. The value already said "Credits"; the key still
  said otherwise, which the policy check flagged. The internal tab key
  stays `supporters` on purpose — it is persisted as
  `ClassCodexCharDB.activeTab`, so renaming it would invalidate the
  remembered tab for anyone who had it open.

## 0.38.1 — 2026-08-21

### Changed

* The Credits tab now names who maintains the addon, not only who wrote
  it. It listed jfstn as "Original author" and stopped there, which read
  as though he still maintained it — the data refresh, the toolchain and
  the fixes come from this repository.
* The tab's description states the lineage explicitly: that this
  continues the addon originally written by jfstn, and where it is
  maintained. Naming the origin in the addon itself, rather than only in
  the README, means a player who never opens the repository still sees
  whose work this is built on.

## 0.38.0 — 2026-08-21

### Fixed

* **Blizzard policy rule 5 violation, inherited from upstream.** The addon
  shipped a "Support on Patreon" button and a panel tab listing Patreon
  backers. The policy is explicit: "Add-ons may not include requests for
  donations ... such requests should be limited to the add-on website or
  distribution site and should not appear in the game." Both are removed.
  Two further reasons beyond the policy: the Patreon belongs to the
  discontinued upstream project, so it asked users to fund an addon that
  is no longer maintained; and the backer list hard-coded fifteen real
  names of people who pledged to jfstn, not to this repository.

### Changed

* The Supporters tab is now a **Credits** tab. Removing the tab outright
  would have meant unpicking it from six places in `ClassCodex.lua` with
  no way to test the result in-game, and credit for the work is worth
  showing regardless. It names the original author, the project this
  addon derives code from, and the four sites the data comes from.
* The Discord card in the About tab now points at this repository's issue
  tracker. The old link went to the discontinued project's server.

### Added

* `NOTICE.md` — third-party components, their authors and their licences.
  `Shared/ReduceTaint.lua` and `Shared/ImportExport.lua` derive from
  NumyAddon's TalentLoadoutManager (MIT), which requires its copyright
  notice to travel with the code; `LICENSE` named only jfstn.
* A policy section in the README recording what was checked and why the
  remaining rules hold.

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
