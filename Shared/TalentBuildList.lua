local _, ns = ...

-------------------------------------------------------------------------------
-- TalentBuildList: shared helpers for rendering grouped talent builds.
--
-- Pure functions used by every place that renders talent builds:
--   - Main panel Talents tab (ClassCodex.lua: ns:UpdateAllTalents)
--   - Compendium talents section (Compendium.lua: ns:UpdateCompendiumAllTalents)
--   - Talent-pane frame (TalentPaneFrame.lua)
--
-- Each caller owns its own widget pool and action wiring; this file owns the
-- grouping, formatting, and active-build detection so all three stay in sync.
-------------------------------------------------------------------------------

-- GroupBuildsByHero(talents) -> heroOrder, heroBuilds
-- Groups a list of talent builds by their heroTalent field, preserving the
-- original order of both heroes and builds within each hero.
function ns.GroupBuildsByHero(talents)
    local heroOrder, heroBuilds = {}, {}
    if not talents then return heroOrder, heroBuilds end
    for _, t in ipairs(talents) do
        local hero = t.heroTalent
        if not heroBuilds[hero] then
            heroBuilds[hero] = {}
            heroOrder[#heroOrder + 1] = hero
        end
        heroBuilds[hero][#heroBuilds[hero] + 1] = t
    end
    return heroOrder, heroBuilds
end

-- FormatHeroHeaderText(hero) -> string
-- Returns the display text for a hero talent group header. Includes the
-- hero's atlas icon if available, and localizes "All" -> "General".
function ns.FormatHeroHeaderText(hero)
    local L = ns.L
    local displayHero = (hero == "All" and L and L["settings.header.general"]) or (hero == "All" and "General") or hero
    local atlas = ns.HERO_TALENT_ATLAS and ns.HERO_TALENT_ATLAS[hero]
    if atlas then
        return "|A:" .. atlas .. ":14:14|a " .. displayHero
    end
    return displayHero
end

-- FormatBuildLabel(build) -> string
-- Returns the display text for a build row: "Context -- BuildLabel (Best)".
function ns.FormatBuildLabel(build)
    local label = build.context or "Build"
    if build.buildLabel and build.buildLabel ~= "" then
        label = label .. " — " .. build.buildLabel
    end
    if build.recommended then
        label = label .. " |cff00cc00(Best)|r"
    end
    return label
end

-- ExtractTalentBits(exportString) -> string or nil
-- Decodes just the per-node bits from a Blizzard talent export string,
-- skipping the 152-bit header (8 version + 16 spec + 128 tree hash).
-- Used for comparing two builds for equality without depending on the
-- tree hash (which can differ even for identical node selections).
function ns.ExtractTalentBits(exportString)
    if not exportString or not ExportUtil or not ExportUtil.MakeImportDataStream then
        return nil
    end
    local ok, stream = pcall(ExportUtil.MakeImportDataStream, exportString)
    if not ok or not stream then return nil end
    -- Skip 152-bit header: 19 reads of 8 bits
    for _ = 1, 19 do pcall(stream.ExtractValue, stream, 8) end
    local bits = {}
    for _ = 1, 500 do
        local bok, val = pcall(stream.ExtractValue, stream, 1)
        if not bok then break end
        bits[#bits + 1] = val
    end
    return table.concat(bits)
end

-- GetActiveTalentSignature() -> string or nil
-- Returns a signature for the currently-active talent build, suitable for
-- equality comparison against a build's exportString via ExtractTalentBits.
-- In inspect mode (ns._talentPaneInspect set by TalentPaneDropdown) we
-- read the configID from the talent frame itself rather than hardcoding
-- INSPECT_TRAIT_CONFIG_ID — Blizzard uses VIEW_TRAIT_CONFIG_ID for
-- inspect-by-string, INSPECT_TRAIT_CONFIG_ID for inspect-by-unit.
function ns.GetActiveTalentSignature()
    if not C_Traits or not C_Traits.GenerateImportString then return nil end
    local configID
    if ns._talentPaneInspect then
        local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
        if tf and tf.GetConfigID then
            local ok, id = pcall(tf.GetConfigID, tf)
            if ok then configID = id end
        end
        if not configID then
            configID = (Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID) or -1
        end
    else
        if not C_ClassTalents or not C_ClassTalents.GetActiveConfigID then return nil end
        configID = C_ClassTalents.GetActiveConfigID()
    end
    if not configID then return nil end
    local str = C_Traits.GenerateImportString(configID)
    if not str then return nil end
    return ns.ExtractTalentBits(str)
end
