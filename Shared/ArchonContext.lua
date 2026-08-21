local _, ns = ...

-------------------------------------------------------------------------------
-- ArchonContext: Archon per-encounter build accessors + zone auto-detection.
--
-- The Archon scraper writes Data\{Class}\archon-talents.lua files keyed by
-- "zoneType:difficulty:encounter" (e.g. "mythic-plus:high-keys:skyreach",
-- "raid:mythic:imperator"). This module provides:
--
--   - ns.GetArchonSpecData(class, spec) — full per-spec record from the
--     ClassCodexArchonData global, or nil.
--   - ns.GroupArchonContexts(specData) — bucketed view: { mplusOverview,
--     mplusDungeons[], raidOverviewHeroic, raidOverviewMythic,
--     raidHeroicBosses[], raidMythicBosses[] }.
--   - ns.FindArchonBuild(class, spec, contextKey) — the single best build
--     stored for that context (the scraper picks the highest-popularity
--     main entry per page).
--   - ns.GetActiveArchonContext() — heuristic match from the player's
--     current zone / current pull to a contextKey, or nil if unknown.
--   - ns.RegisterArchonContextCallback(fn) — fires whenever the active
--     context changes so the talent pane / Compendium can refresh their
--     auto-pick.
--
-- Slug↔ID mapping is hand-curated below. Slugs change at season
-- transitions; updating one season's worth of dungeons + bosses is a
-- small recurring chore documented near the table itself.
-------------------------------------------------------------------------------

local ARCHON_DATA = _G.ClassCodexArchonData

-- Re-resolve at use time too — toc load order means the global may not
-- be present at this file's load (we are listed after the data files,
-- but be defensive in case that ever changes).
local function GetArchonGlobal()
    return ARCHON_DATA or _G.ClassCodexArchonData
end

-------------------------------------------------------------------------------
-- Slug → in-game lookups (auto-derived from scraped data)
--
-- The dungeon/boss list and their display names are NOT hand-maintained.
-- They are built at runtime from the scraped contexts in
-- ClassCodexArchonData — every context carries its encounter slug plus
-- the full in-game `encounterLabel` (the scraper pulls it from Archon's
-- seo.description). So when a season rotates dungeons or a new raid tier
-- ships, the next data refresh updates these lookups with zero code
-- changes here.
--
-- NAME_OVERRIDE is the only hand-edited surface, and only for the rare
-- case where Archon's spelling differs from Blizzard's in-game name
-- (which is what the name-match path compares against). ID_OVERRIDE lets
-- a non-enUS client pin numeric IDs; empty by default since name-match
-- covers enUS.
-------------------------------------------------------------------------------

-- Archon label -> in-game name, by encounter slug. Add an entry only when
-- the two disagree; everything else flows straight from encounterLabel.
local DUNGEON_NAME_OVERRIDE = {
    ["maisara-caverns"] = "Mai'sara Caverns", -- Archon renders "Maisara Caverns"
}
local BOSS_NAME_OVERRIDE = {}

-- Optional numeric-ID pins (instanceMapID / encounterID) for localized
-- clients where name-match can't work. Empty by default.
local DUNGEON_ID_OVERRIDE = {}
local BOSS_ID_OVERRIDE = {}

-- Reverse lookups, (re)built from ClassCodexArchonData.
local DUNGEON_BY_ID, DUNGEON_BY_NAME
local BOSS_BY_ID, BOSS_BY_NAME
-- slug -> in-game display name, for the non-localised label fallback.
local DUNGEON_DISPLAY, BOSS_DISPLAY
-- Difficulty slugs present in the data, per zone type. These are NOT
-- constants: Archon renamed the Mythic+ bracket from "high-keys"
-- (Midnight season 1) to "10" (season 2), and a fresh season publishes
-- Normal and Heroic raid data weeks before Mythic exists. Reading them
-- back out of the scraped contexts is what keeps zone detection working
-- across a season rollover without a code change.
local MPLUS_DIFFICULTY_COUNT, RAID_DIFFICULTY_SET
local MPLUS_DIFFICULTY

-- The in-game name we match the player's current zone against: the
-- spelling override when present, else the scraped encounterLabel.
local function DungeonName(slug, label)
    return DUNGEON_NAME_OVERRIDE[slug] or label
end
local function BossName(slug, label)
    return BOSS_NAME_OVERRIDE[slug] or label
end

-- True once we've built against a populated data global. Distinguishes
-- "built, legitimately empty" from "global wasn't ready yet" so the lazy
-- rebuild fires exactly once when the data appears — without depending on
-- both name tables being non-empty (a partial dataset, e.g. M+ contexts
-- but no raid yet, must still count as built).
local lookupsBuilt = false

local function BuildLookups()
    DUNGEON_BY_ID, DUNGEON_BY_NAME = {}, {}
    BOSS_BY_ID, BOSS_BY_NAME = {}, {}
    DUNGEON_DISPLAY, BOSS_DISPLAY = {}, {}
    MPLUS_DIFFICULTY_COUNT, RAID_DIFFICULTY_SET = {}, {}
    MPLUS_DIFFICULTY = nil

    local data = GetArchonGlobal()
    lookupsBuilt = data ~= nil
    if data then
        for _, classData in pairs(data) do
            for _, specData in pairs(classData) do
                local contexts = type(specData) == "table" and specData.contexts
                if contexts then
                    for _, ctx in pairs(contexts) do
                        local slug = ctx.encounter
                        if ctx.difficulty then
                            if ctx.zoneType == "mythic-plus" then
                                MPLUS_DIFFICULTY_COUNT[ctx.difficulty] =
                                    (MPLUS_DIFFICULTY_COUNT[ctx.difficulty] or 0) + 1
                            elseif ctx.zoneType == "raid" then
                                RAID_DIFFICULTY_SET[ctx.difficulty] = true
                            end
                        end
                        if slug and slug ~= "all-dungeons" and slug ~= "all-bosses" then
                            local label = ctx.encounterLabel
                            if ctx.zoneType == "mythic-plus" then
                                local name = DungeonName(slug, label)
                                if name and name ~= "" then
                                    DUNGEON_BY_NAME[name:lower()] = slug
                                    DUNGEON_DISPLAY[slug] = name
                                end
                            elseif ctx.zoneType == "raid" then
                                local name = BossName(slug, label)
                                if name and name ~= "" then
                                    BOSS_BY_NAME[name:lower()] = slug
                                    BOSS_DISPLAY[slug] = name
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- One Mythic+ bracket is published per season; pick the slug backing
    -- the most contexts, with the name as tie-breaker so the choice is
    -- stable rather than pairs()-order dependent.
    local bestCount = -1
    for slug, count in pairs(MPLUS_DIFFICULTY_COUNT) do
        if count > bestCount or (count == bestCount and slug < MPLUS_DIFFICULTY) then
            MPLUS_DIFFICULTY, bestCount = slug, count
        end
    end

    -- Layer on any hand-pinned numeric IDs.
    for id, slug in pairs(DUNGEON_ID_OVERRIDE) do DUNGEON_BY_ID[id] = slug end
    for id, slug in pairs(BOSS_ID_OVERRIDE) do BOSS_BY_ID[id] = slug end
end
BuildLookups()

-- Public helper: resolves the display label for a context. The scraper
-- stamps the full in-game name onto encounterLabel, so we trust it; the
-- slug-keyed *_DISPLAY tables (also derived from the data) serve as the
-- fallback for the auto-detect name-match path.
function ns.GetArchonEncounterLabel(ctx)
    if not ctx then return "" end
    if ctx.encounterLabel and ctx.encounterLabel ~= "" then
        return ctx.encounterLabel
    end
    local slug = ctx.encounter
    if slug and DUNGEON_DISPLAY[slug] then return DUNGEON_DISPLAY[slug] end
    if slug and BOSS_DISPLAY[slug] then return BOSS_DISPLAY[slug] end
    return ""
end

-------------------------------------------------------------------------------
-- Data accessors
-------------------------------------------------------------------------------

function ns.GetArchonSpecData(class, spec)
    local data = GetArchonGlobal()
    if not data then return nil end
    local cls = data[class]
    if not cls then return nil end
    return cls[spec]
end

-- Returns the single build entry stored for a context, or nil.
function ns.FindArchonBuild(class, spec, contextKey)
    local sd = ns.GetArchonSpecData(class, spec)
    if not sd or not sd.contexts then return nil end
    local ctx = sd.contexts[contextKey]
    if not ctx or not ctx.builds or #ctx.builds == 0 then return nil end
    return ctx.builds[1], ctx
end

-- Find an Archon build by exportString across every context for a spec.
-- Used for "currently-active" detection in the talent pane.
function ns.FindArchonBuildByExportString(class, spec, exportString)
    if not exportString then return nil end
    local sd = ns.GetArchonSpecData(class, spec)
    if not sd or not sd.contexts then return nil end
    for ctxKey, ctx in pairs(sd.contexts) do
        if ctx.builds then
            for _, b in ipairs(ctx.builds) do
                if b.exportString == exportString then
                    return b, ctx, ctxKey
                end
            end
        end
    end
    return nil
end

-- Bucket contexts by zone type + difficulty for menu rendering.
-- Returns a table with these keys (each entry has { contextKey, ctx }):
--   mplusOverview        -- single context (high-keys / all-dungeons), or nil
--   mplusDungeons        -- ordered list, alphabetical by encounterLabel
--   raidOverviewHeroic   -- single context, or nil
--   raidOverviewMythic   -- single context, or nil
--   raidHeroicBosses     -- ordered list, by encounter slug
--   raidMythicBosses     -- ordered list, by encounter slug
function ns.GroupArchonContexts(specData)
    local out = {
        mplusDungeons = {},
        raidHeroicBosses = {},
        raidMythicBosses = {},
    }
    if not specData or not specData.contexts then return out end

    -- Iterate in the scraper-provided discovery order when available.
    -- contextOrder mirrors Archon's encounter dropdown order (M+
    -- overview + dungeons; then raid overviews + bosses in pull order),
    -- so dropping the entries into their buckets in this order means
    -- we don't need a hand-curated season-by-season pull-order table.
    -- Falls back to pairs() when the field isn't there (older snapshots).
    local order = specData.contextOrder
    local seen = {}
    local function process(ctxKey)
        if seen[ctxKey] then return end
        seen[ctxKey] = true
        local ctx = specData.contexts[ctxKey]
        if not ctx then return end
        if ctx.zoneType == "mythic-plus" then
            if ctx.encounter == "all-dungeons" then
                out.mplusOverview = { contextKey = ctxKey, ctx = ctx }
            else
                out.mplusDungeons[#out.mplusDungeons + 1] = { contextKey = ctxKey, ctx = ctx }
            end
        elseif ctx.zoneType == "raid" then
            if ctx.encounter == "all-bosses" then
                if ctx.difficulty == "mythic" then
                    out.raidOverviewMythic = { contextKey = ctxKey, ctx = ctx }
                else
                    out.raidOverviewHeroic = { contextKey = ctxKey, ctx = ctx }
                end
            else
                local bucket = (ctx.difficulty == "mythic") and out.raidMythicBosses or out.raidHeroicBosses
                bucket[#bucket + 1] = { contextKey = ctxKey, ctx = ctx }
            end
        end
    end

    if type(order) == "table" then
        for _, ctxKey in ipairs(order) do process(ctxKey) end
    end
    -- Catch any contexts that the order list missed (e.g. an order
    -- list from a stale snapshot whose dataset has new entries).
    for ctxKey in pairs(specData.contexts) do process(ctxKey) end

    -- When contextOrder is missing entirely (legacy snapshots), fall back
    -- to a deterministic label sort. With a present contextOrder — which
    -- the scraper always emits now — the buckets are already in Archon's
    -- pull order, so we leave them alone.
    if type(order) ~= "table" then
        local function byLabel(a, b)
            return ns.GetArchonEncounterLabel(a.ctx) < ns.GetArchonEncounterLabel(b.ctx)
        end
        table.sort(out.mplusDungeons, byLabel)
        table.sort(out.raidHeroicBosses, byLabel)
        table.sort(out.raidMythicBosses, byLabel)
    end

    return out
end

-------------------------------------------------------------------------------
-- Zone / encounter detection
-------------------------------------------------------------------------------

local activeContextKey  -- cached "where is the player right now" key
local lastEncounterID   -- remembered between ENCOUNTER_START and ENCOUNTER_END
local lastEncounterName -- boss name from ENCOUNTER_START, for name-match
local lastDifficulty    -- "heroic" | "mythic" | nil
local callbacks = {}

-- The lookups are built at file load, but toc order means the data
-- global *might* not be populated yet. Rebuild lazily the first time we
-- need them after the data global appears.
local function EnsureLookups()
    if not lookupsBuilt and GetArchonGlobal() then
        BuildLookups()
    end
end

-- Raid difficulty IDs: 14 = Normal, 15 = Heroic, 16 = Mythic, 17 = LFR.
-- Each maps to an *ordered* preference list rather than one slug, because
-- which difficulties Archon has published depends on how far the season
-- has progressed. LFR has no sample of its own and borrows Normal's.
local DIFFICULTY_TO_ARCHON = {
    [14] = { "normal", "heroic", "mythic" },
    [15] = { "heroic", "mythic", "normal" },
    [16] = { "mythic", "heroic", "normal" },
    [17] = { "normal", "heroic", "mythic" },
}
local DIFFICULTY_FALLBACK = { "heroic", "mythic", "normal" }

-- First preference that the loaded dataset actually carries.
local function PickRaidDifficulty(difficultyID)
    local prefs = DIFFICULTY_TO_ARCHON[difficultyID] or DIFFICULTY_FALLBACK
    if RAID_DIFFICULTY_SET then
        for i = 1, #prefs do
            if RAID_DIFFICULTY_SET[prefs[i]] then return prefs[i] end
        end
    end
    return prefs[1]
end

local function ResolveDungeonSlug(instanceMapID, instanceName)
    EnsureLookups()
    if instanceMapID and DUNGEON_BY_ID[instanceMapID] then
        return DUNGEON_BY_ID[instanceMapID]
    end
    if instanceName and DUNGEON_BY_NAME[instanceName:lower()] then
        return DUNGEON_BY_NAME[instanceName:lower()]
    end
    return nil
end

local function ResolveBossSlug(encounterID, encounterName)
    EnsureLookups()
    if encounterID and BOSS_BY_ID[encounterID] then
        return BOSS_BY_ID[encounterID]
    end
    if encounterName and BOSS_BY_NAME[encounterName:lower()] then
        return BOSS_BY_NAME[encounterName:lower()]
    end
    return nil
end

local function ComputeActiveContext()
    local _, instanceType = IsInInstance()
    local instanceName, _, difficultyID, _, _, _, _, instanceMapID = GetInstanceInfo()

    if instanceType == "party" then
        EnsureLookups()
        local bracket = MPLUS_DIFFICULTY
        if not bracket then return nil end
        local slug = ResolveDungeonSlug(instanceMapID, instanceName)
        if slug then
            return "mythic-plus:" .. bracket .. ":" .. slug
        end
        return "mythic-plus:" .. bracket .. ":all-dungeons"
    end

    if instanceType == "raid" then
        EnsureLookups()
        local archonDiff = PickRaidDifficulty(difficultyID)

        -- Mid-pull: prefer the boss the player just engaged. Match on the
        -- encounter name (enUS) since Archon doesn't expose Blizzard
        -- encounterIDs; a numeric ID is used first when one is pinned.
        if lastEncounterID or lastEncounterName then
            local slug = ResolveBossSlug(lastEncounterID, lastEncounterName)
            if slug then
                return "raid:" .. archonDiff .. ":" .. slug
            end
        end
        -- Between pulls: fall back to the difficulty-appropriate overview.
        return "raid:" .. archonDiff .. ":all-bosses"
    end

    return nil
end

local function FireCallbacks()
    for i = 1, #callbacks do
        local ok, err = pcall(callbacks[i], activeContextKey)
        if not ok then
            -- Surface the error but don't break the chain — one bad
            -- listener shouldn't take the others down with it.
            geterrorhandler()(err)
        end
    end
end

local function RefreshContext()
    local newKey = ComputeActiveContext()
    if newKey == activeContextKey then return end
    activeContextKey = newKey
    FireCallbacks()
end

function ns.GetActiveArchonContext()
    if activeContextKey == nil then RefreshContext() end
    return activeContextKey
end

function ns.RegisterArchonContextCallback(fn)
    callbacks[#callbacks + 1] = fn
end

-------------------------------------------------------------------------------
-- Event wiring
-------------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
-- ENCOUNTER_START args: encounterID, encounterName, difficultyID, groupSize.
f:SetScript("OnEvent", function(_, event, encounterID, encounterName, difficultyID)
    if event == "ENCOUNTER_START" then
        lastEncounterID = encounterID
        lastEncounterName = encounterName
        lastDifficulty = DIFFICULTY_TO_ARCHON[difficultyID]
    elseif event == "ENCOUNTER_END" then
        -- Keep lastEncounterID so the post-pull state still surfaces the
        -- right boss in the picker (TTL-style by relying on next zone
        -- change or pull to overwrite). Reset only on zone change.
    end
    RefreshContext()
end)

-------------------------------------------------------------------------------
-- Source persistence — stored per-character × per-specID.
-- ClassCodexCharDB.archonSource[specID] = "wowhead" | "archon"
-- ClassCodexCharDB.archonContext[specID] = contextKey  (manual override)
-------------------------------------------------------------------------------

local function CurrentSpecID()
    if not GetSpecialization then return nil end
    local idx = GetSpecialization()
    if not idx then return nil end
    local id = GetSpecializationInfo and GetSpecializationInfo(idx)
    return id
end

function ns.GetPersistedTalentSource()
    if not ClassCodexCharDB then return nil end
    local specID = CurrentSpecID()
    if not specID or not ClassCodexCharDB.archonSource then return nil end
    return ClassCodexCharDB.archonSource[specID]
end

function ns.SetPersistedTalentSource(source)
    if not ClassCodexCharDB then return end
    local specID = CurrentSpecID()
    if not specID then return end
    ClassCodexCharDB.archonSource = ClassCodexCharDB.archonSource or {}
    ClassCodexCharDB.archonSource[specID] = source
end

function ns.GetPersistedArchonContext()
    if not ClassCodexCharDB then return nil end
    local specID = CurrentSpecID()
    if not specID or not ClassCodexCharDB.archonContext then return nil end
    return ClassCodexCharDB.archonContext[specID]
end

function ns.SetPersistedArchonContext(contextKey)
    if not ClassCodexCharDB then return end
    local specID = CurrentSpecID()
    if not specID then return end
    ClassCodexCharDB.archonContext = ClassCodexCharDB.archonContext or {}
    ClassCodexCharDB.archonContext[specID] = contextKey
end

-- Default-source resolver: "archon" if the player is in a known Archon
-- context (dungeon / raid), else "wowhead". Falls back to the persisted
-- per-spec choice if one is set.
function ns.GetEffectiveTalentSource()
    local persisted = ns.GetPersistedTalentSource()
    if persisted then return persisted end
    local activeKey = ns.GetActiveArchonContext()
    if activeKey then return "archon" end
    return "wowhead"
end
