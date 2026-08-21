# Class Codex

In-game stat priorities, talent builds, rotation guides and gearing
recommendations for your current specialisation — all 40 specs across all
13 classes, refreshed for **Midnight 12.1 Season 2**.

This is a community continuation of [Class Codex](https://www.curseforge.com/wow/addons/class-codex)
by **jfstn**, whose last release (v0.36.3, 2026-07-02) targeted WoW 12.0.7
and whose CurseForge listing has since been taken down. The addon code is
jfstn's work under the MIT licence; what this repository adds is a live
data set and the toolchain to keep producing one.

> **Why the original stopped being useful.** All the value of this addon
> sits in its data, and the scraper that produced that data was never
> published — only its output. Once the author stepped away, the numbers
> froze on 2 July 2026 while the game moved on. The UI kept working; the
> recommendations quietly went stale. `tools/` in this repository exists so
> that cannot happen again: anyone can regenerate the whole data set.

## Installing

Close World of Warcraft, then clone into your AddOns folder:

```bash
git clone https://github.com/Sparxx947/ClassCodex.git \
  "<WoW>/_retail_/Interface/AddOns/ClassCodex"
```

The folder **must** be named `ClassCodex` — WoW matches the TOC file to the
directory name. Updating later is `git pull` in that folder.

Saved variables are `ClassCodexDB` and `ClassCodexCharDB`. To uninstall,
delete the folder; the saved variables are written on logout and can be
removed from `WTF/` separately.

## What it shows

| Panel | Content | Sources |
|---|---|---|
| Stats | Stat priority and stat targets for your spec | Wowhead, Archon |
| Talents | Loadouts you can import in one click, per context and hero talent | Wowhead, Icy Veins, Archon |
| Rotation | Priority lists per hero talent and situation | Wowhead |
| Gear | Best-in-slot lists, enchants, gems, consumables | Wowhead, Icy Veins, Archon |
| Crafting | Which crafted pieces and embellishments are worth making | Archon |
| PvP | Stat priority and most-worn gear in rated play | murlok.io, Blizzard |

Archon builds are keyed per encounter, so the addon can follow you: enter a
dungeon or pull a boss and it picks that encounter's build automatically.

## Refreshing the data

Everything under `Data/` is generated. Do not edit it by hand — run the
tools instead:

```bash
tools/refresh_all.sh                          # current season
tools/refresh_all.sh --season midnight-season-3   # after a season rollover
```

Python 3.11+ standard library only. No virtualenv, no npm, no headless
browser. A run takes roughly 15 minutes and caches every page under
`tools/.cache/`, so a second run is fast.

Individual scrapers, in the order `refresh_all.sh` runs them:

| Tool | Writes | Notes |
|---|---|---|
| `refresh_sources.py` | `sources.lua` | Must run first — records the season slug the others read back, and verifies all 280 guide links |
| `refresh_archon.py` | `archon-stats`, `archon-talents`, `gear-archon`, `crafting` | Must run before `refresh_wowhead.py` |
| `refresh_wowhead.py` | `guide.lua` | Stat priorities, talent builds, rotations |
| `refresh_wowhead_gear.py` | `gear-wowhead.lua` | BiS, enchants, gems, consumables, trinket tiers |
| `refresh_icyveins.py` | `talents-icyveins`, `gear-icyveins` | |
| `refresh_murlok.py` | `murlok-pvp.lua` | Rated PvP stats and gear |

Two checks run at the end of `refresh_all.sh`, and are worth running on
their own after any change:

* `tools/check_data.py` — every spec present in every generated file, and
  the scrape date not stale. A scrape that produced nothing for one spec
  otherwise looks exactly like a successful run.
* `tools/check_locales.py` — every key the code asks for is defined, and
  all ten translations carry the same set. A missing key shows up in-game
  as a blank label, not as an error.
* `tools/check_lua.sh` — parses every Lua file with a Lua 5.1 compiler,
  the version the WoW client runs. See [docs/data-sources.md](docs/data-sources.md)
for what each generated file contains and where each field comes from.

### After a season rollover

Seasons move more than the data. Two slugs change and both are read from
the data rather than hard-coded, so a plain rerun is usually enough:

* Wowhead's guide slug (`midnight-season-2`) — pass `--season`.
* Archon's Mythic+ bracket, which was `high-keys` in season 1 and `10` in
  season 2. `refresh_sources.py` reads the current one back out of the
  scraped Archon data, and the addon's zone detection does the same at
  runtime.

## Blizzard add-on policy

Checked against Blizzard's [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534).

Upstream broke rule 5, "add-ons may not solicit donations": it shipped a
"Support on Patreon" button and a panel tab listing Patreon backers. Both
are gone. That tab is now a Credits tab naming the original author, the
project this addon derives code from, and the four sites its data comes
from — credit without a donation request.

The rest of the rules hold. The addon is free and its source is open and
unobfuscated; it sends no chat or addon messages and registers no
permanent per-frame handler, so it cannot burden a realm; it ships no
Blizzard art or audio, referencing built-in icons by path instead; and it
contains nothing that conflicts with the game's rating. Its only
automation is applying a talent loadout you picked, through the public
`C_Traits` API.

## Known gaps

* `bnet-pvp-talents.lua` still carries the upstream data from 2026-07-02.
  It came from Blizzard's API by way of the PvP leaderboards, which needs
  API credentials and a very large number of requests. Tracked as an issue.
* Brewmaster Monk has no murlok PvP data: the site has no sample in any
  bracket this early in the season. `check_data.py` reports it as a known
  gap rather than failing on it.
* Wowhead stat priorities come from its `[build]` blocks, which cover the
  recommended hero talent. Its standalone stat-priority page is prose and
  is not machine-readable. Archon's stat targets cover every spec.
* Mythic raid data does not exist yet this season. Archon publishes Normal
  and Heroic; the scraper keeps Normal only for bosses Heroic has not
  reached, so nothing is listed twice.

## Licence and credit

MIT, © 2026 jfstn — see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for
third-party components. The addon code is unchanged upstream work apart
from the fixes listed in [CHANGELOG.md](CHANGELOG.md).
Data belongs to [Wowhead](https://www.wowhead.com),
[Icy Veins](https://www.icy-veins.com), [Archon](https://www.archon.gg) and
[murlok.io](https://murlok.io); this addon links back to each guide it
draws from. Not affiliated with Blizzard Entertainment.

---

## Deutsch

**Class Codex** zeigt im Spiel Statprioritäten, Talentbäume, Rotationen und
BiS-Listen für die gerade aktive Spezialisierung — für alle 40
Spezialisierungen der 13 Klassen, auf dem Stand von **Midnight 12.1
Saison 2**.

Das ist eine Fortführung des eingestellten Addons von **jfstn**. Dessen
letzte Fassung (v0.36.3 vom 02.07.2026) war für WoW 12.0.7 gebaut, und die
CurseForge-Seite gibt es nicht mehr. Der Addon-Code stammt von jfstn und
steht unter MIT; ergänzt wurden hier ein aktueller Datenbestand und die
Werkzeuge, um ihn immer wieder neu zu erzeugen.

**Warum das Original wertlos wurde:** Der ganze Nutzen steckt in den Daten,
und der Scraper dahinter wurde nie veröffentlicht — nur sein Ergebnis. Als
der Autor aufhörte, blieben die Zahlen beim 2. Juli 2026 stehen, während
das Spiel weiterlief. Die Oberfläche funktionierte weiter, die Empfehlungen
wurden still falsch. Genau deshalb liegt der Scraper hier im Repo.

### Installieren

WoW beenden, dann in den AddOns-Ordner klonen:

```bash
git clone https://github.com/Sparxx947/ClassCodex.git \
  "<WoW>/_retail_/Interface/AddOns/ClassCodex"
```

Der Ordner **muss** `ClassCodex` heißen — WoW erwartet die TOC-Datei unter
dem Ordnernamen. Später aktualisiert ein `git pull` in diesem Ordner.

### Daten auffrischen

Alles unter `Data/` ist erzeugt und wird **nicht von Hand bearbeitet**:

```bash
tools/refresh_all.sh
tools/refresh_all.sh --season midnight-season-3   # nach einem Saisonwechsel
```

Gebraucht wird nur Python 3.11+ aus dem Systembestand — keine virtuelle
Umgebung, kein npm, kein Browser. Ein Durchlauf dauert etwa 15 Minuten und
legt jede Seite in `tools/.cache/` ab, ein zweiter Lauf ist deshalb schnell.

### Blizzards Addon-Richtlinie

Geprüft gegen Blizzards [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534).

Das Original verstieß gegen Regel 5 („add-ons may not solicit
donations"): Es lieferte einen „Support on Patreon"-Knopf und einen
Reiter mit der Liste der Patreon-Unterstützer aus. Beides ist entfernt.
Aus dem Reiter sind Danksagungen geworden: der ursprüngliche Autor, das
Projekt, von dem Code stammt, und die vier Datenquellen — Anerkennung
ohne Spendenaufruf.

Die übrigen Regeln sind eingehalten: kostenlos, quelloffen und
unverschleiert; keine Chat- oder Addon-Nachrichten und kein dauerhafter
Handler pro Bild, also keine Last für den Realm; keine mitgelieferten
Blizzard-Grafiken oder -Klänge (eingebaute Symbole werden nur über ihren
Pfad referenziert); nichts Anstößiges. Die einzige Automatisierung ist
das Einspielen einer von dir gewählten Talentverteilung über die
öffentliche `C_Traits`-Schnittstelle.

### Bekannte Lücken

* `bnet-pvp-talents.lua` steht weiterhin auf dem Stand vom 02.07.2026. Die
  Daten kommen aus Blizzards API über die PvP-Ranglisten und brauchen
  Zugangsdaten sowie sehr viele Abfragen.
* Wowheads Statprioritäten stammen aus den `[build]`-Blöcken und decken das
  empfohlene Heldentalent ab. Die eigene Stat-Seite ist Fließtext und
  maschinell nicht auswertbar; Archons Statziele decken dafür jede
  Spezialisierung ab.
* Mythische Schlachtzugsdaten gibt es in dieser Saison noch nicht. Archon
  liefert Normal und Heroisch; Normal wird nur für die Bosse behalten, die
  es auf Heroisch noch nicht gibt — so steht kein Boss doppelt in der Liste.
