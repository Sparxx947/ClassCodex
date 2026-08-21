# Third-party components

This addon is distributed under the MIT licence (see [LICENSE](LICENSE)),
© 2026 jfstn. It also contains or derives from the work listed below.

Where a file states its own licence, that statement is quoted. Where a
file states none — which is common for WoW libraries embedded from
WoWAce — that is said plainly rather than guessed at, with a pointer to
the upstream project so the licence can be read at the source.

## Derived code

### TalentLoadoutManager — NumyAddon, MIT

`Shared/ReduceTaint.lua` is adapted from it, and `Shared/ImportExport.lua`
follows its approach to applying and exporting talent loadouts. Both
files say so in their own headers.

https://github.com/NumyAddon/TalentLoadoutManager

MIT requires that its copyright notice travel with any substantial
portion of the work. This file is that notice; the licence text is the
same MIT terms reproduced in `LICENSE`.

`UnitMenuIntegration.lua` additionally cites TalentTreeTweaks
(`modules/exportInspectedBuild.lua`, also NumyAddon) for the way it polls
`C_Traits.GenerateInspectImportString` after `INSPECT_READY`. That is a
technique rather than copied code, but it is worth crediting.

## Embedded libraries (`Libs/`)

Loaded through `Libs/embeds.xml`, not from the TOC.

| Library | Author / project | Licence as stated in the file |
|---|---|---|
| LibStub | Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel, joshborke | "LibStub is hereby placed in the Public Domain" |
| CallbackHandler-1.0 | Ace3 (WoWAce) | none stated in the file — see the [Ace3 project](https://www.wowace.com/projects/ace3) |
| LibDataBroker-1.1 | tekkub | none stated in the file — see [tekkub/libdatabroker-1-1](https://github.com/tekkub/libdatabroker-1-1) |
| LibDBIcon-1.0 | WoWAce | none stated in the file — see the [LibDBIcon-1.0 project](https://www.wowace.com/projects/libdbicon-1-0) |

## Guide data

The contents of `Data/` are scraped from, and belong to, their
publishers. The addon links back to the source page for every value it
shows, and the tools that produce the files record which site each field
came from (see [docs/data-sources.md](docs/data-sources.md)).

* [Wowhead](https://www.wowhead.com)
* [Icy Veins](https://www.icy-veins.com)
* [Archon.gg](https://www.archon.gg)
* [murlok.io](https://murlok.io)

## Game assets

No Blizzard art, audio or other game assets are redistributed. The addon
references built-in icons by path (`Interface\Icons\…`), which the client
resolves locally. The textures in `Textures/` and `assets/` are the
upstream project's own.

World of Warcraft and Blizzard Entertainment are trademarks of Blizzard
Entertainment, Inc. This addon is not affiliated with or endorsed by
Blizzard Entertainment.
