local _, ns = ...

-------------------------------------------------------------------------------
-- PvPData: accessors for the two PvP data sources.
--
-- Bnet (per spec, per bracket — talent loadouts + honor talents):
--   Data/{Class}/bnet-pvp-talents.lua
--     -> ClassCodexBnetPvpTalents[CLASS][spec].brackets[bracketKey] = {
--          builds = { { exportString, heroTalent? }, ... }, -- already share-floor-filtered upstream
--          pvpTalentSets = { { talents = {id1,id2,id3} } } -- pre-sorted; first = canonical
--        }
--   Bracket display name lives in PVP_BRACKET_NAMES below. sampleSize,
--   share, and the lowConfidence convergence flag live in the scraper
--   JSON only; the share floor (≥15%) is applied at scrape time and the
--   addon just renders the surviving builds in order.
--
-- Murlok (per spec — stat priorities + BiS gear + enchants + gems + embellishments):
--   Data/{Class}/murlok-pvp.lua
--     -> ClassCodexMurlokPvp[CLASS][spec] = {
--          statPriority = { { key, rating }, ... },        -- order is the signal; rating stabilized ±1%
--          bisGear = { [slot] = { { itemId } } },          -- pickrate dropped (daily noise)
--          embellishments? = { { itemId, name } },
--          enchants? = { [slot] = { { itemId, name } } },              -- itemId = 0 for enchants (no item-side ID)
--          gems? = { [socket] = { { itemId, name } } },
--        }
--
-- Bracket display ordering (mirrors Murlok / Bnet bracket precedence):
--   pvp-shuffle, pvp-blitz, pvp-2v2, pvp-3v3, pvp-rbg
-------------------------------------------------------------------------------

ns.PVP_BRACKET_ORDER = {
    "pvp-shuffle",
    "pvp-blitz",
    "pvp-2v2",
    "pvp-3v3",
    "pvp-rbg",
}

ns.PVP_BRACKET_NAMES = {
    ["pvp-shuffle"] = "Solo Shuffle",
    ["pvp-blitz"] = "Battleground Blitz",
    ["pvp-2v2"] = "2v2 Arena",
    ["pvp-3v3"] = "3v3 Arena",
    ["pvp-rbg"] = "Rated Battlegrounds",
}

-------------------------------------------------------------------------------
-- Bnet — talent loadouts + honor talents per (spec, bracket)
-------------------------------------------------------------------------------

local function GetBnetSpec(classToken, specKey)
    if not classToken or not specKey then return nil end
    local root = _G.ClassCodexBnetPvpTalents
    if not root then return nil end
    local cls = root[classToken]
    if not cls then return nil end
    return cls[specKey]
end

-- Returns the bracket data for one (spec, bracket): { sampleSize, builds, pvpTalentSets?, lowConfidence? }
-- or nil if no data was scraped.
function ns.GetPvPBuilds(classToken, specKey, bracketKey)
    if not bracketKey then return nil end
    local spec = GetBnetSpec(classToken, specKey)
    if not spec or not spec.brackets then return nil end
    return spec.brackets[bracketKey]
end

-- Inclusion rule for surfacing multiple build variants in the UI.
-- The scraper filters the `builds` array to those clearing the 15%
-- share floor before emitting Lua, so this layer just walks the list in
-- order and caps it at PVP_MAX_VARIANTS. The cap exists for screen real
-- estate, not statistical meaningfulness — that gate already fired upstream.
local PVP_MAX_VARIANTS = 3

-- Returns the ordered list of build variants to surface for a bracket.
-- Each entry: { hero = heroName, build = buildTable, altIndex = number? }
--
-- altIndex is set when a hero appears more than once in the list (e.g.
-- two Aldrachi Reaver variants with different choice nodes) so the UI
-- can disambiguate them — value is 2 for the second occurrence, 3 for
-- the third, etc. Single-hero appearances leave altIndex nil.
function ns.GetPvPBuildVariants(bracketData)
    if not bracketData or not bracketData.builds or not bracketData.builds[1] then
        return {}
    end

    local count = math.min(PVP_MAX_VARIANTS, #bracketData.builds)
    if count == 1 then
        local top = bracketData.builds[1]
        return { { hero = top.heroTalent, build = top } }
    end

    -- Tag same-hero duplicates so the UI can label "(alt)" / "(alt 2)"
    -- and the user can tell two Aldrachi rows apart at a glance.
    local heroCounts, out = {}, {}
    for i = 1, count do
        local b = bracketData.builds[i]
        local heroKey = b.heroTalent or "_nohero"
        heroCounts[heroKey] = (heroCounts[heroKey] or 0) + 1
        local altIndex = nil
        if heroCounts[heroKey] > 1 then altIndex = heroCounts[heroKey] end
        out[#out + 1] = { hero = b.heroTalent, build = b, altIndex = altIndex }
    end
    return out
end

-- Returns a sorted array of bracketKey strings that have data for this spec,
-- in PVP_BRACKET_ORDER. Empty list = no PvP data for the spec.
function ns.GetPvPBracketsWithData(classToken, specKey)
    local spec = GetBnetSpec(classToken, specKey)
    if not spec or not spec.brackets then return {} end
    local result = {}
    for _, key in ipairs(ns.PVP_BRACKET_ORDER) do
        if spec.brackets[key] then
            result[#result + 1] = key
        end
    end
    return result
end

-- Returns the display name for a bracket key (or the key as fallback).
function ns.GetPvPBracketName(bracketKey)
    return ns.PVP_BRACKET_NAMES[bracketKey] or bracketKey
end

-------------------------------------------------------------------------------
-- Murlok — stats, gear, enchants, gems, embellishments per spec
-------------------------------------------------------------------------------

local function GetMurlokSpec(classToken, specKey)
    if not classToken or not specKey then return nil end
    local root = _G.ClassCodexMurlokPvp
    if not root then return nil end
    local cls = root[classToken]
    if not cls then return nil end
    return cls[specKey]
end

-- Returns the full Murlok per-spec record, or nil if no data.
-- The slim schema only carries statPriority / bisGear / embellishments
-- / enchants / gems — see the Murlok block comment at the top of the
-- file for the exact shape. Source-attribution metadata (sourceUrl,
-- sourceBracket, scrapedAt) was dropped from the Lua emit because
-- nothing on the addon side surfaces it.
function ns.GetPvPSpecMeta(classToken, specKey)
    return GetMurlokSpec(classToken, specKey)
end

-- Returns the stat priority array (ordered, first = most important):
--   { { key = "haste", rating }, ... }
function ns.GetPvPStats(classToken, specKey)
    local spec = GetMurlokSpec(classToken, specKey)
    if not spec then return nil end
    return spec.statPriority
end

-- Returns a snapshot in the same shape archon-stats.lua exposes:
--   { targets = { crit, haste, mastery, versatility } }
-- so the existing Stats side-tab renderer can plug in a "PvP" context
-- alongside Mythic+ / Raid without bespoke rendering branches. Murlok's
-- stat priority entries carry the empirical mid-pack rating per stat.
function ns.GetPvPStatTargets(classToken, specKey)
    local stats = ns.GetPvPStats(classToken, specKey)
    if not stats then return nil end
    local targets = {}
    for _, s in ipairs(stats) do
        if s.key and s.rating and s.rating > 0 then
            targets[s.key] = s.rating
        end
    end
    if not next(targets) then return nil end
    return { targets = targets }
end

-- Returns BiS gear keyed by slot label:
--   { ["Head"] = { { itemId, pickrate? } }, ... }
function ns.GetPvPGear(classToken, specKey)
    local spec = GetMurlokSpec(classToken, specKey)
    if not spec then return nil end
    return spec.bisGear
end

-- Returns the embellishment array (top recommended, capped):
--   { { itemId, name }, ... }
function ns.GetPvPEmbellishments(classToken, specKey)
    local spec = GetMurlokSpec(classToken, specKey)
    if not spec then return nil end
    return spec.embellishments
end

-- Returns enchants keyed by slot label:
--   { ["Head"] = { { itemId = 0, name } }, ... }
-- itemId is 0 for enchants (no Wowhead item-side identifier; addon uses name).
function ns.GetPvPEnchants(classToken, specKey)
    local spec = GetMurlokSpec(classToken, specKey)
    if not spec then return nil end
    return spec.enchants
end

-- Returns gems keyed by socket type:
--   { ["Prismatic"] = { { itemId, name } }, ... }
function ns.GetPvPGems(classToken, specKey)
    local spec = GetMurlokSpec(classToken, specKey)
    if not spec then return nil end
    return spec.gems
end

-------------------------------------------------------------------------------
-- Synthetic adapters — convert the per-slot Murlok shape into the table
-- shape each rendering surface (Compendium tabs, Loadout Dock, docked
-- character pane) already consumes for Wowhead/Icy Veins. Hoisted here
-- so Compendium.lua and GearingSections.lua call the same helpers and
-- the slot-order constants live in one place.
-------------------------------------------------------------------------------

local PVP_BIS_SLOT_ORDER = {
    "Head", "Neck", "Shoulders", "Back", "Chest", "Wrist",
    "Hands", "Waist", "Legs", "Feet", "Rings", "Trinkets",
    "Main Hand", "Off Hand",
}

local PVP_ENCHANT_SLOT_ORDER = {
    "Head", "Cloak", "Chest", "Wrist", "Hands", "Waist",
    "Legs", "Feet", "Rings", "Main Hand", "Off Hand",
}

-- Returns a single-tab BiS structure: `{ { label = "PvP", slots = {...} } }`,
-- where each slot is `{ slot, item = { itemId }, source = "" }`.
-- pickrate is no longer emitted to Lua (daily drift was the dominant
-- noise in PvP data PRs); the "source" column stays empty for PvP rows.
-- Returns nil when no Murlok BiS data exists for the spec.
function ns.BuildPvPBisTabs(classToken, specKey)
    local gear = ns.GetPvPGear(classToken, specKey)
    if not gear then return nil end
    local slots = {}
    for _, slotName in ipairs(PVP_BIS_SLOT_ORDER) do
        local items = gear[slotName]
        if items and items[1] then
            local top = items[1]
            slots[#slots + 1] = {
                slot = slotName,
                item = { itemId = top.itemId },
                source = "",
            }
        end
    end
    if #slots == 0 then return nil end
    return { { label = "PvP", slots = slots } }
end

-- Returns a list of `{ slot, best = {itemId, name}, alternate? = {itemId, name} }`.
function ns.BuildPvPEnchantsRows(classToken, specKey)
    local enchants = ns.GetPvPEnchants(classToken, specKey)
    if not enchants then return nil end
    local out = {}
    for _, slot in ipairs(PVP_ENCHANT_SLOT_ORDER) do
        local items = enchants[slot]
        if items and items[1] then
            local row = { slot = slot, best = { itemId = items[1].itemId, name = items[1].name } }
            if items[2] then
                row.alternate = { itemId = items[2].itemId, name = items[2].name }
            end
            out[#out + 1] = row
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Returns the docked-panel-shaped gem record `{ secondary = {...} }`.
-- Murlok publishes one gem per socket type; there's no primary/secondary
-- distinction in PvP, so primary stays nil and the renderer shows just
-- the secondary list.
function ns.BuildPvPGemsRecord(classToken, specKey)
    local gems = ns.GetPvPGems(classToken, specKey)
    if not gems or not next(gems) then return nil end
    local secondary = {}
    for _, items in pairs(gems) do
        if items and items[1] then
            secondary[#secondary + 1] = { itemId = items[1].itemId, name = items[1].name }
        end
    end
    if #secondary == 0 then return nil end
    return { secondary = secondary }
end

-------------------------------------------------------------------------------
-- Brand-icon source-dropdown labels. Texture-escape strings now come from
-- the central source registry (Shared/Sources.lua) so the texture path lives
-- in exactly one place; these aliases stay for existing callers.
-------------------------------------------------------------------------------

ns.PVP_SOURCE_ICON = ns.SourceIcon("murlok")
ns.WOWHEAD_SOURCE_ICON = ns.SourceIcon("wowhead")
ns.ICYVEINS_SOURCE_ICON = ns.SourceIcon("icyveins")
ns.ARCHON_SOURCE_ICON = ns.SourceIcon("archon")

ns.BIS_SOURCE_LABELS = {
    ["Wowhead"]   = ns.SourceLabelText("wowhead"),
    ["Icy Veins"] = ns.SourceLabelText("icyveins"),
    ["Archon"]    = ns.SourceLabelText("archon"),
    ["PvP"]       = ns.PVP_SOURCE_ICON .. "  Murlok (PvP)",
}

ns.ENH_SOURCE_LABELS = {
    ["Wowhead"] = ns.SourceLabelText("wowhead"),
    ["PvP"]     = ns.PVP_SOURCE_ICON .. "  Murlok (PvP)",
}

-------------------------------------------------------------------------------
-- Combined source-availability check used by source-dropdown population.
-- Returns true if EITHER Bnet talents OR Murlok stats/gear exist for the spec.
-------------------------------------------------------------------------------

function ns.HasPvPData(classToken, specKey)
    if GetBnetSpec(classToken, specKey) then return true end
    if GetMurlokSpec(classToken, specKey) then return true end
    return false
end

-------------------------------------------------------------------------------
-- Honor talent (PvP talent) info lookup — pulled out so the dock and
-- talent-pane tooltips share one resolution path.
--
-- GetPvpTalentInfoByID(talentID) is the canonical retail API; signature is
-- (talentID, name, icon, selected, available, spellID, unlocked, row, column, known, grantedByAura).
-- Wrapped in pcall because untested talent IDs can throw on some clients.
-- Returns nil when the API is missing or the lookup fails.
-------------------------------------------------------------------------------

function ns.GetHonorTalentInfo(talentId)
    if type(talentId) ~= "number" then return nil end
    if type(GetPvpTalentInfoByID) ~= "function" then return nil end
    local ok, _, name, icon = pcall(GetPvpTalentInfoByID, talentId)
    if not ok or not name then return nil end
    return { name = name, icon = icon }
end

-- Render an inline texture escape for an honor talent icon, sized to match
-- the hero-talent atlas glyph (12px) so they line up in dock labels. Returns
-- "" when the talent lookup fails so the caller can concatenate safely.
function ns.FormatHonorTalentIcon(talentId)
    local info = ns.GetHonorTalentInfo(talentId)
    if not info or not info.icon then return "" end
    return "|T" .. info.icon .. ":12:12:0:0|t"
end

-------------------------------------------------------------------------------
-- Honor talent (PvP talent) apply
--
-- The retail API has churned across patches — try the modern names first,
-- fall back through historical ones. SetPvpTalent/LearnPvpTalent are
-- protected: the call must be triggered by a hardware event (mouse click
-- or keypress) and the player must be in War Mode + a PvP-enabled zone
-- (arena/BG/world PvP). Failure is silent and non-fatal — class talents
-- already applied via the regular flow.
--
-- talentIds is an array of 3 PvP talent IDs in slot order (1-3).
-------------------------------------------------------------------------------

local function ResolveLearnFn()
    -- Retail TWW: C_SpecializationInfo.LearnPvpTalent / SetPvpTalent
    -- Both have signature (talentID, slotIndex). The legacy global form
    -- has an opposite argument order, so we deliberately don't fall
    -- through to it — better to fail loud on unsupported clients than
    -- silently apply talents to the wrong slot.
    if C_SpecializationInfo then
        if C_SpecializationInfo.LearnPvpTalent then
            return C_SpecializationInfo.LearnPvpTalent
        end
        if C_SpecializationInfo.SetPvpTalent then
            return C_SpecializationInfo.SetPvpTalent
        end
    end
    return nil
end

local function CanApplyPvpTalents()
    -- WoW Classic doesn't have C_PvP at all; bail early.
    if not C_PvP then return false end
    if C_PvP.IsWarModeActive and C_PvP.IsWarModeActive() then return true end
    -- IsInInstance() returns "pvp" for battlegrounds and "arena" for arenas.
    -- (`IsInBattleground` and `IsActiveBattlefieldArena` are NOT real WoW
    -- APIs; the instanceType check is the canonical way to detect both.)
    if IsInInstance then
        local _, instanceType = IsInInstance()
        if instanceType == "pvp" or instanceType == "arena" then return true end
    end
    return false
end

function ns.ApplyPvpHonorTalents(talentIds)
    if not talentIds or type(talentIds) ~= "table" or #talentIds == 0 then return false end
    local fn = ResolveLearnFn()
    if not fn then return false end -- API unavailable on this client (e.g. Classic) — silent
    if not CanApplyPvpTalents() then
        -- Use UIErrorsFrame (the red center-screen toast) instead of a
        -- chat print: the user just clicked an entry and expects feedback
        -- in their eye-line. Chat scroll is easy to miss, especially in
        -- the middle of switching loadouts.
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage(
                "Honor talents will apply once you enter War Mode or a PvP instance.",
                1, 0.82, 0)
        end
        return false
    end
    local applied = 0
    for slot, talentId in ipairs(talentIds) do
        if slot > 3 then break end
        local ok = pcall(fn, talentId, slot)
        if ok then applied = applied + 1 end
    end
    if applied > 0 then
        print(string.format("|cff00ccffClass Codex:|r Applied %d PvP talent%s.",
            applied, applied == 1 and "" or "s"))
    end
    return applied > 0
end

