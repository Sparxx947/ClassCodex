local _, ns = ...

-------------------------------------------------------------------------------
-- LoadoutDock: tiny floating widget that shows the player's currently active
-- talent loadout name and, on click, pops a menu of every other build they
-- could switch to — Blizzard saved loadouts plus Class Codex recommendations.
--
-- Lives independently from the character-frame docked panel and the
-- Compendium. Hidden by default; opt-in via Settings > Class Codex >
-- "Show Loadout Dock". Position persists per-character. Drag the label to
-- move it (when unlocked); right-click for lock / hide / settings.
-------------------------------------------------------------------------------

local DOCK_DEFAULT_WIDTH = 200
local DOCK_MIN_WIDTH = 120
local DOCK_MAX_WIDTH = 400
local DOCK_HEIGHT = 22
local ICON_SIZE = 14 -- shared between spec and hero icons so they line up
local PAD = 6
local ICON_GAP = 4
local LABEL_GAP = 6

local dock = nil

local function GetCharDB()
    return ClassCodexCharDB
end

-- Resolve the active Blizzard talent loadout's display name. Prefers the
-- spec's last-selected SAVED loadout over the live "active" config —
-- when no saved loadout is loaded, GetActiveConfigID returns a scratch
-- buffer that Blizzard auto-names with the spec name ("Devourer",
-- "Frost", etc.), which is not a useful loadout label.
local function configName(id)
    if not id or not C_Traits or not C_Traits.GetConfigInfo then return nil end
    local info = C_Traits.GetConfigInfo(id)
    if info and info.name and info.name ~= "" then return info.name end
    return nil
end

local function GetActiveLoadoutName()
    if not C_ClassTalents then return nil end
    local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
    if specID and C_ClassTalents.GetLastSelectedSavedConfigID then
        local savedID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        local name = configName(savedID)
        if name then return name end
    end
    local active = C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    return configName(active)
end

-- Find the Wowhead-sourced Class Codex build whose talent bits match the
-- player's current in-game talents.
local function MatchCodexBuild(specData)
    if not specData or not specData.talents or not ns.GetActiveTalentSignature then return nil end
    local activeBits = ns.GetActiveTalentSignature()
    if not activeBits then return nil end
    for _, build in ipairs(specData.talents) do
        if build.exportString and ns.ExtractTalentBits then
            local buildBits = ns.ExtractTalentBits(build.exportString)
            if buildBits == activeBits then return build end
        end
    end
    return nil
end

-- Find the Archon-sourced build whose talent bits match the player's
-- current in-game talents. Returns (build, ctx) or nil.
local function MatchArchonBuild(classToken, specKey)
    if not classToken or not specKey then return nil end
    if not ns.GetArchonSpecData or not ns.GetActiveTalentSignature or not ns.ExtractTalentBits then return nil end
    local sd = ns.GetArchonSpecData(classToken, specKey)
    if not sd or not sd.contexts then return nil end
    local activeBits = ns.GetActiveTalentSignature()
    if not activeBits then return nil end
    for _, ctx in pairs(sd.contexts) do
        if ctx.builds then
            for _, build in ipairs(ctx.builds) do
                if build.exportString then
                    local buildBits = ns.ExtractTalentBits(build.exportString)
                    if buildBits == activeBits then return build, ctx end
                end
            end
        end
    end
    return nil
end

-- Lay out icons + label per alignment. Uses absolute x-offsets for icons
-- so the spec/hero pair shifts with the alignment setting; the label
-- keeps a dual LEFT+RIGHT anchor (so it always has a non-zero render
-- width regardless of GetStringWidth timing) and JustifyH does the
-- final positioning of the text within that span.
local function LayoutDockContent()
    if not dock then return end
    local alignment = (ClassCodexDB and ClassCodexDB.dockLoadoutAlignment) or "LEFT"
    local frameW = dock:GetWidth() or DOCK_DEFAULT_WIDTH

    local hasSpec = dock.specIcon:IsShown()
    local hasHero = dock.heroIcon:IsShown()
    local iconCount = (hasSpec and 1 or 0) + (hasHero and 1 or 0)
    local iconsW = iconCount * ICON_SIZE + math.max(0, iconCount - 1) * ICON_GAP
    local labelW = (dock.label:GetStringWidth() or 0)
    local groupW = iconsW + (iconCount > 0 and labelW > 0 and LABEL_GAP or 0) + labelW

    -- Icons-only offset: shifts the spec/hero pair as a sub-group,
    -- while the label below stretches across the remaining width and
    -- JustifyH decides where its text sits.
    local iconOffset
    if alignment == "CENTER" then
        iconOffset = math.max(PAD, math.floor((frameW - groupW) / 2))
    elseif alignment == "RIGHT" then
        iconOffset = math.max(PAD, frameW - groupW - PAD)
    else
        iconOffset = PAD
    end

    dock.specIcon:ClearAllPoints()
    dock.heroIcon:ClearAllPoints()
    dock.label:ClearAllPoints()

    local cursor = iconOffset
    if hasSpec then
        dock.specIcon:SetPoint("LEFT", cursor, 0)
        cursor = cursor + ICON_SIZE + (hasHero and ICON_GAP or 0)
    end
    if hasHero then
        dock.heroIcon:SetPoint("LEFT", cursor, 0)
        cursor = cursor + ICON_SIZE
    end

    -- Label: dual-anchored so it always renders even when GetStringWidth
    -- hasn't propagated yet. JustifyH inside drives the visual alignment.
    local labelLeft = (iconCount > 0) and (cursor + LABEL_GAP) or PAD
    dock.label:SetPoint("LEFT", labelLeft, 0)
    dock.label:SetPoint("RIGHT", -PAD, 0)

    if alignment == "CENTER" then
        dock.label:SetJustifyH("CENTER")
    elseif alignment == "RIGHT" then
        dock.label:SetJustifyH("RIGHT")
    else
        dock.label:SetJustifyH("LEFT")
    end
end

local function RefreshLabel()
    if not dock then return end
    local db = ClassCodexDB or {}
    local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

    -- Spec icon
    local showSpec = db.dockLoadoutShowSpecIcon ~= false
    if showSpec then
        local specIndex = GetSpecialization and GetSpecialization()
        if specIndex then
            local _, _, _, iconTex = GetSpecializationInfo(specIndex)
            if iconTex then
                dock.specIcon:SetTexture(iconTex)
                dock.specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                dock.specIcon:Show()
            else
                dock.specIcon:Hide()
            end
        else
            dock.specIcon:Hide()
        end
    else
        dock.specIcon:Hide()
    end

    -- Hero icon
    local showHero = db.dockLoadoutShowHeroIcon ~= false
    local heroName = ns.GetActiveHeroTalentName and ns.GetActiveHeroTalentName()
    local heroAtlas = heroName and ns.HERO_TALENT_ATLAS and ns.HERO_TALENT_ATLAS[heroName]
    if showHero and heroAtlas then
        dock.heroIcon:SetAtlas(heroAtlas)
        dock.heroIcon:Show()
    else
        dock.heroIcon:Hide()
    end

    -- Resolve label text and set it BEFORE measuring or laying out.
    local labelText
    local active = GetActiveLoadoutName()
    if active and active ~= "" then
        labelText = active
    else
        local specData = ns.GetSpecData and ns.GetSpecData()
        local wowheadMatch = MatchCodexBuild(specData)
        if wowheadMatch and ns.FormatBuildLabel then
            labelText = ns.FormatBuildLabel(wowheadMatch)
        else
            local classToken, specSlug
            if ns.GetClassAndSpec then classToken, specSlug = ns.GetClassAndSpec() end
            local archonBuild, archonCtx = MatchArchonBuild(classToken, specSlug)
            if archonBuild and archonCtx then
                labelText = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(archonCtx)) or "Archon"
            end
        end
    end
    if not labelText then labelText = "|cff808080" .. L["loadout_dock.custom_build"] .. "|r" end
    dock.label:SetText(labelText)

    -- Auto-width before layout so the dock is the right size when we
    -- compute alignment offset.
    if ClassCodexDB and ClassCodexDB.dockLoadoutAutoWidth then
        ns.ApplyLoadoutDockWidth()
    end

    -- Lay out immediately AND on the next frame. The deferred pass
    -- handles the case where SetText hasn't been processed yet so
    -- GetStringWidth returns 0 on the immediate call.
    LayoutDockContent()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if dock and dock:IsShown() then
                if ClassCodexDB and ClassCodexDB.dockLoadoutAutoWidth then
                    ns.ApplyLoadoutDockWidth()
                end
                LayoutDockContent()
            end
        end)
    end
end

-- Build the loadout-switch menu (left-click).
local function BuildLoadoutMenu(_, root)
    local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
    local specID = PlayerUtil and PlayerUtil.GetCurrentSpecID and PlayerUtil.GetCurrentSpecID()
    local specData = ns.GetSpecData and ns.GetSpecData()
    local activeBits = ns.GetActiveTalentSignature and ns.GetActiveTalentSignature()
    local activeID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID() or nil
    local activeExport = activeID and C_Traits and C_Traits.GenerateImportString and C_Traits.GenerateImportString(activeID) or nil
    -- Per-spec memory of the last build applied via the dock. Survives
    -- the round-trip drift between Archon's published exportString and
    -- the one Blizzard's stage/commit emits, which can defeat both the
    -- bit and full-string comparisons below. Validated against the bits
    -- that were active right after the apply settled — if the player
    -- has since manually changed talents, current bits diverge from the
    -- captured snapshot and the memo is invalidated (stale memo cleared
    -- so it doesn't keep falsely highlighting an entry).
    local perSpec = (ns.GetPerSpecState and ns.GetPerSpecState()) or nil
    local lastAppliedExport = perSpec and perSpec.lastAppliedBuildExport or nil
    local lastAppliedBits = perSpec and perSpec.lastAppliedBuildBits or nil
    if lastAppliedExport and lastAppliedBits and activeBits and lastAppliedBits ~= activeBits then
        if perSpec then
            perSpec.lastAppliedBuildExport = nil
            perSpec.lastAppliedBuildBits = nil
        end
        lastAppliedExport = nil
        lastAppliedBits = nil
    end

    local function activeMatches(exportString)
        if not exportString then return false end
        if lastAppliedExport and lastAppliedBits and activeBits
           and lastAppliedBits == activeBits and lastAppliedExport == exportString then
            return true
        end
        if activeExport and activeExport == exportString then return true end
        if activeBits and ns.ExtractTalentBits then
            local b = ns.ExtractTalentBits(exportString)
            if b and b == activeBits then return true end
        end
        return false
    end

    local function rememberApplied(exportString)
        local p = ns.GetPerSpecState and ns.GetPerSpecState()
        if p and exportString then p.pendingApplyBuildExport = exportString end
    end

    local db = ClassCodexDB or {}

    -- Section 1: Blizzard saved loadouts for the current spec.
    local hasBlizzard = false
    if db.dockLoadoutShowSaved ~= false and specID and C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID then
        local configs = C_ClassTalents.GetConfigIDsBySpecID(specID)
        if configs and #configs > 0 then
            root:CreateTitle(L["loadout_dock.saved_loadouts"])
            for _, configID in ipairs(configs) do
                local info = C_Traits and C_Traits.GetConfigInfo and C_Traits.GetConfigInfo(configID)
                local name = info and info.name or ("Loadout " .. configID)
                if configID == activeID then
                    name = "|cff00cc00" .. name .. "|r"
                end
                root:CreateButton(name, function()
                    if InCombatLockdown() then
                        UIErrorsFrame:AddMessage(L["loadout_dock.cannot_switch_combat"], 1, 0.3, 0.3)
                        return
                    end
                    C_ClassTalents.LoadConfig(configID, true)
                    -- Refresh fires on TRAIT_CONFIG_UPDATED.
                end)
            end
            hasBlizzard = true
        end
    end

    -- Section 2: Class Codex - Wowhead recommended builds, grouped by hero
    -- talent so a long list doesn't dominate the menu.
    local hasWowhead = false
    if db.dockLoadoutShowWowhead ~= false and specData and specData.talents and #specData.talents > 0 and ns.GroupBuildsByHero then
        if hasBlizzard then root:CreateDivider() end
        root:CreateTitle("|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:14:14:0:0|t  " .. L["settings.value.wowhead"])
        local heroOrder, heroBuilds = ns.GroupBuildsByHero(specData.talents)
        for _, hero in ipairs(heroOrder) do
            local heroLabel = (ns.FormatHeroHeaderText and ns.FormatHeroHeaderText(hero)) or hero
            -- Tag the hero submenu when any of its builds is the
            -- recommended pick — surfaces the (Best) marker even before
            -- the user expands the submenu.
            for _, b in ipairs(heroBuilds[hero]) do
                if b.recommended then
                    heroLabel = heroLabel .. " |cff00cc00★|r"
                    break
                end
            end
            local heroSubmenu = root:CreateButton(heroLabel)
            -- Recommended builds first so the (Best) entry is always at
            -- the top of the hero submenu. Stable sort: keep original
            -- order within each group.
            local sortedBuilds = {}
            for i, b in ipairs(heroBuilds[hero]) do
                sortedBuilds[i] = { build = b, ord = i }
            end
            table.sort(sortedBuilds, function(a, b)
                local ra = a.build.recommended and 0 or 1
                local rb = b.build.recommended and 0 or 1
                if ra ~= rb then return ra < rb end
                return a.ord < b.ord
            end)
            for _, entry in ipairs(sortedBuilds) do
                local build = entry.build
                local label = ns.FormatBuildLabel and ns.FormatBuildLabel(build) or build.context or "Build"
                if activeMatches(build.exportString) then
                    label = "|cff00cc00" .. label .. "|r"
                end
                heroSubmenu:CreateButton(label, function()
                    if InCombatLockdown() then
                        UIErrorsFrame:AddMessage(L["loadout_dock.cannot_switch_combat"], 1, 0.3, 0.3)
                        return
                    end
                    local rawLabel = build.context or "Build"
                    if build.buildLabel and build.buildLabel ~= "" then
                        rawLabel = rawLabel .. " — " .. build.buildLabel
                    end
                    local loadoutLabel = (hero and hero ~= "All") and (hero .. " " .. rawLabel) or rawLabel
                    rememberApplied(build.exportString)
                    if ns.ApplyTalentExportString then
                        ns.ApplyTalentExportString(build.exportString, loadoutLabel)
                    end
                end)
            end
        end
        hasWowhead = true
    end

    -- Section 3: Class Codex - Archon (per-encounter recommendations).
    -- Archon's data table is keyed by the spec slug (e.g. "frost"), which
    -- is the SECOND return of GetClassAndSpec. Falls back to direct
    -- _G.ClassCodexArchonData lookup if the namespace helper is missing.
    local classToken, specSlug
    if ns.GetClassAndSpec then classToken, specSlug = ns.GetClassAndSpec() end
    local archonSpecData
    if db.dockLoadoutShowArchon ~= false and classToken and specSlug then
        if ns.GetArchonSpecData then
            archonSpecData = ns.GetArchonSpecData(classToken, specSlug)
        end
        if not archonSpecData and _G.ClassCodexArchonData and _G.ClassCodexArchonData[classToken] then
            archonSpecData = _G.ClassCodexArchonData[classToken][specSlug]
        end
    end
    local hasArchon = false
    -- Diagnostic surface: when the Archon lookup fails, render a visible
    -- breadcrumb in the menu instead of silently dropping the section so
    -- it's obvious whether the data, the helper, or the lookup itself is
    -- the issue.
    local archonReason
    if not classToken then archonReason = "no class detected"
    elseif not specSlug then archonReason = "no spec slug detected"
    elseif not _G.ClassCodexArchonData then archonReason = "ClassCodexArchonData global missing"
    elseif not _G.ClassCodexArchonData[classToken] then archonReason = "no archon data for class " .. classToken
    elseif not _G.ClassCodexArchonData[classToken][specSlug] then archonReason = "no archon data for " .. classToken .. "/" .. specSlug
    elseif not archonSpecData then archonReason = "spec data resolution returned nil"
    elseif not archonSpecData.contexts then archonReason = "spec data has no contexts table"
    elseif not ns.GroupArchonContexts then archonReason = "GroupArchonContexts helper missing"
    end
    if archonReason then
        if hasBlizzard or (specData and specData.talents and #specData.talents > 0) then
            root:CreateDivider()
        end
        root:CreateTitle("|TInterface\\AddOns\\ClassCodex\\Textures\\archon:14:14:0:0|t  " .. L["settings.value.archon"])
        root:CreateButton("|cff999999" .. archonReason .. "|r", function() end)
    end
    if archonSpecData and archonSpecData.contexts and ns.GroupArchonContexts then
        local groups = ns.GroupArchonContexts(archonSpecData)

        local function archonLabel(entry, override)
            local ctx = entry.ctx
            local base = override or (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(ctx)) or entry.contextKey
            local build = ctx.builds and ctx.builds[1]
            if build and build.heroTalent and ns.HERO_TALENT_ATLAS then
                local atlas = ns.HERO_TALENT_ATLAS[build.heroTalent]
                if atlas then
                    base = "|A:" .. atlas .. ":12:12|a " .. base
                end
            end
            if build and activeMatches(build.exportString) then
                base = "|cff00cc00" .. base .. "|r"
            end
            return base, build
        end

        local function archonApply(parent, entry, override)
            local label, build = archonLabel(entry, override)
            if not build then return end
            parent:CreateButton(label, function()
                if InCombatLockdown() then
                    UIErrorsFrame:AddMessage(L["loadout_dock.cannot_switch_combat"], 1, 0.3, 0.3)
                    return
                end
                local clean = label:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A:[^|]+|a", ""):gsub("^%s+", "")
                rememberApplied(build.exportString)
                if ns.ApplyTalentExportString then
                    ns.ApplyTalentExportString(build.exportString, clean)
                end
            end)
        end

        local hasAny = groups.mplusOverview or groups.raidOverviewMythic or groups.raidOverviewHeroic
            or #groups.mplusDungeons > 0 or #groups.raidMythicBosses > 0 or #groups.raidHeroicBosses > 0
        if hasAny then
            if hasBlizzard or hasWowhead then root:CreateDivider() end
            root:CreateTitle("|TInterface\\AddOns\\ClassCodex\\Textures\\archon:14:14:0:0|t  " .. L["settings.value.archon"])

            -- M+ Dungeons submenu — overview ("All Dungeons") sits as the
            -- first entry inside the submenu rather than as a separate
            -- top-level item, so the menu surface stays compact.
            if groups.mplusOverview or #groups.mplusDungeons > 0 then
                local sub = root:CreateButton(L["context.mplus_dungeons"])
                if groups.mplusOverview then archonApply(sub, groups.mplusOverview) end
                for _, e in ipairs(groups.mplusDungeons) do archonApply(sub, e) end
            end
            -- Heroic before Mythic — most players gear up through Heroic
            -- first, so the more-likely-to-be-clicked submenu sits closer
            -- to the M+ Dungeons entry above.
            if groups.raidOverviewHeroic or #groups.raidHeroicBosses > 0 then
                local sub = root:CreateButton(L["context.raid_heroic"])
                if groups.raidOverviewHeroic then archonApply(sub, groups.raidOverviewHeroic) end
                for _, e in ipairs(groups.raidHeroicBosses) do archonApply(sub, e) end
            end
            if groups.raidOverviewMythic or #groups.raidMythicBosses > 0 then
                local sub = root:CreateButton(L["context.raid_mythic"])
                if groups.raidOverviewMythic then archonApply(sub, groups.raidOverviewMythic) end
                for _, e in ipairs(groups.raidMythicBosses) do archonApply(sub, e) end
            end
            hasArchon = true
        end
    end

    -- Section 3.5: Class Codex - Icy Veins talent builds. IV builds are
    -- context-labeled (not hero-grouped), and there are only a handful per
    -- spec, so they render as a flat list under the source title rather
    -- than nested submenus. Leveling builds are included inline.
    local hasIcyVeins = false
    if db.dockLoadoutShowIcyVeins ~= false and classToken and specSlug and ns.GetIcyVeinsTalentSpecData then
        local ivSpecData = ns:GetIcyVeinsTalentSpecData(classToken, specSlug)
        if ivSpecData and ivSpecData.talents and #ivSpecData.talents > 0 then
            if hasBlizzard or hasWowhead or hasArchon then root:CreateDivider() end
            root:CreateTitle("|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:14:14:0:0|t  " .. (L["settings.value.icyveins"] or "Icy Veins"))
            for _, build in ipairs(ivSpecData.talents) do
                local capturedExport = build.exportString
                local capturedLabel = build.buildLabel or build.context or "Build"
                local label = capturedLabel
                if activeMatches(capturedExport) then
                    label = "|cff00cc00" .. label .. "|r"
                end
                root:CreateButton(label, function()
                    if InCombatLockdown() then
                        UIErrorsFrame:AddMessage(L["loadout_dock.cannot_switch_combat"], 1, 0.3, 0.3)
                        return
                    end
                    rememberApplied(capturedExport)
                    if ns.ApplyTalentExportString then
                        ns.ApplyTalentExportString(capturedExport, "Icy Veins " .. capturedLabel)
                    end
                end)
            end
            hasIcyVeins = true
        end
    end

    -- Section 4: Class Codex - PvP (per-bracket recommendations from
    -- Bnet talent_loadout_code + Murlok). Mirrors Archon's submenu
    -- pattern (M+ Dungeons / Raid Heroic / Raid Mythic above): an
    -- "Arena" submenu groups Solo Shuffle / 2v2 / 3v3, and a
    -- "Battleground" submenu groups Blitz / RBG. Clicking a bracket
    -- applies the top class talent build for that bracket and, when in
    -- a PvP zone, also applies the top honor talent set.
    local hasPvp = false
    if classToken and specSlug and ns.GetPvPBracketsWithData then
        local pvpBrackets = ns.GetPvPBracketsWithData(classToken, specSlug)
        if pvpBrackets and #pvpBrackets > 0 then
            local ARENA_GROUP = { "pvp-shuffle", "pvp-2v2", "pvp-3v3" }
            local BG_GROUP    = { "pvp-blitz", "pvp-rbg" }
            local available = {}
            for _, k in ipairs(pvpBrackets) do available[k] = true end

            -- `parent` is whichever menu node we're attaching to (root
            -- for fallback flat rendering, an Arena/BG submenu otherwise).
            -- Emits one apply-able entry for a specific (bracket, hero,
            -- build) triple. Used both for the canonical single-build
            -- flow and per-hero in a multi-hero bracket submenu.
            local function emitBuildButton(parent, bracketData, build, bracketKey, label)
                local capturedBuild = build
                local capturedKey = bracketKey
                local capturedHonor = (bracketData.pvpTalentSets
                    and bracketData.pvpTalentSets[1]
                    and bracketData.pvpTalentSets[1].talents) or nil
                -- Append honor talent icon strip so the bracket entry shows
                -- *what* will be applied, not just the bracket name. The
                -- talents themselves still get applied lazily on click,
                -- gated by War Mode / instance — see ApplyPvpHonorTalents.
                if capturedHonor and ns.FormatHonorTalentIcon then
                    local icons = ""
                    for _, talentId in ipairs(capturedHonor) do
                        icons = icons .. ns.FormatHonorTalentIcon(talentId)
                    end
                    if icons ~= "" then label = label .. "  " .. icons end
                end
                if activeMatches(build.exportString) then
                    label = "|cff00cc00" .. label .. "|r"
                end
                local capturedHero = build.heroTalent
                local entry = parent:CreateButton(label, function()
                    if InCombatLockdown() then
                        UIErrorsFrame:AddMessage(L["loadout_dock.cannot_switch_combat"], 1, 0.3, 0.3)
                        return
                    end
                    local loadoutLabel = "PvP — " ..
                        ((ns.GetPvPBracketName and ns.GetPvPBracketName(capturedKey)) or capturedKey)
                    rememberApplied(capturedBuild.exportString)
                    if ns.ApplyTalentExportString then
                        ns.ApplyTalentExportString(capturedBuild.exportString, loadoutLabel)
                    end
                    if capturedHonor and ns.ApplyPvpHonorTalents then
                        ns.ApplyPvpHonorTalents(capturedHonor)
                    end
                end)
                -- Attach a hover tooltip listing the hero talent + the three
                -- honor talents. SetTooltip is the modern MenuUtil hook; if a
                -- client predates it, the call is no-op and the label icons
                -- still convey the picks at a glance.
                if entry and entry.SetTooltip then
                    entry:SetTooltip(function(tooltip)
                        local bracketName = (ns.GetPvPBracketName and ns.GetPvPBracketName(capturedKey)) or capturedKey
                        tooltip:AddLine("PvP — " .. bracketName, 1, 0.82, 0)
                        if capturedHero then
                            local atlas = ns.HERO_TALENT_ATLAS and ns.HERO_TALENT_ATLAS[capturedHero]
                            local prefix = atlas and ("|A:" .. atlas .. ":14:14|a ") or ""
                            tooltip:AddLine(prefix .. capturedHero, 1, 1, 1)
                        end
                        if capturedHonor and #capturedHonor > 0 then
                            tooltip:AddLine(" ")
                            tooltip:AddLine(L["pvp.honor_talents"] or "Honor Talents", 1, 0.82, 0)
                            for _, talentId in ipairs(capturedHonor) do
                                local info = ns.GetHonorTalentInfo and ns.GetHonorTalentInfo(talentId)
                                local name = (info and info.name) or ("#" .. tostring(talentId))
                                local icon = info and info.icon and ("|T" .. info.icon .. ":14:14:0:0|t ") or ""
                                tooltip:AddLine(icon .. name, 1, 1, 1)
                            end
                            tooltip:AddLine(" ")
                            tooltip:AddLine(
                                L["pvp.honor_talents_apply"]
                                    or "Honor talents apply in War Mode or PvP instances.",
                                0.7, 0.7, 0.7)
                        end
                    end)
                end
            end

            -- Render one bracket entry. Single button when the meta has
            -- a clear winner; collapsing submenu listing top-N variants
            -- when multiple builds clear the share floor (Solo Shuffle
            -- and similar — may be different heroes OR same hero with
            -- different choice-node picks). Honor talents stay at the
            -- bracket level — same set applies regardless of variant.
            local function emitBracket(parent, bracketKey)
                local bracketData = ns.GetPvPBuilds(classToken, specSlug, bracketKey)
                if not bracketData or not bracketData.builds or not bracketData.builds[1] then return end
                local bracketName = (ns.GetPvPBracketName and ns.GetPvPBracketName(bracketKey)) or bracketKey
                local variants = ns.GetPvPBuildVariants and ns.GetPvPBuildVariants(bracketData)
                    or { { hero = bracketData.builds[1].heroTalent, build = bracketData.builds[1] } }

                if #variants <= 1 then
                    -- Stable single-build flow. Hero atlas prefix mirrors
                    -- the Archon submenu pattern.
                    local label = bracketName
                    local top = variants[1].build
                    if top.heroTalent and ns.HERO_TALENT_ATLAS then
                        local atlas = ns.HERO_TALENT_ATLAS[top.heroTalent]
                        if atlas then label = "|A:" .. atlas .. ":12:12|a " .. label end
                    end
                    emitBuildButton(parent, bracketData, top, bracketKey, label)
                    return
                end

                -- Multi-variant: bracket becomes a submenu, one entry
                -- per qualifying build. Labels are hero icon + hero name;
                -- same-hero duplicates get "(alt)" / "(alt 2)" suffixes
                -- so two visually-identical rows are distinguishable.
                local bracketNode = parent:CreateButton(bracketName)
                for _, v in ipairs(variants) do
                    local label = v.hero or "—"
                    if v.hero and ns.HERO_TALENT_ATLAS then
                        local atlas = ns.HERO_TALENT_ATLAS[v.hero]
                        if atlas then label = "|A:" .. atlas .. ":12:12|a " .. label end
                    end
                    if v.altIndex then
                        local suffix = v.altIndex == 2
                            and (L["loadout.alt"] or "alt")
                            or string.format(L["loadout.alt_n"] or "alt %d", v.altIndex - 1)
                        label = label .. " |cff9a9a9a(" .. suffix .. ")|r"
                    end
                    emitBuildButton(bracketNode, bracketData, v.build, bracketKey, label)
                end
            end

            local function groupHasAny(group)
                for _, k in ipairs(group) do if available[k] then return true end end
                return false
            end
            local arenaHas = groupHasAny(ARENA_GROUP)
            local bgHas = groupHasAny(BG_GROUP)

            if hasBlizzard or hasWowhead or hasArchon or hasIcyVeins then root:CreateDivider() end
            root:CreateTitle("|TInterface\\AddOns\\ClassCodex\\Textures\\bnet:14:14:0:0|t  " .. (L["pvp.label"] or "PvP"))

            if not arenaHas and not bgHas then
                -- Defensive fallback: all brackets fall outside the
                -- known groups (e.g. a new bracket key the scraper
                -- adds). Render them flat at the top level instead of
                -- silently swallowing them.
                for _, bracketKey in ipairs(pvpBrackets) do emitBracket(root, bracketKey) end
            else
                if arenaHas then
                    local arenaSub = root:CreateButton(L["pvp.arena"] or "Arena")
                    for _, k in ipairs(ARENA_GROUP) do
                        if available[k] then emitBracket(arenaSub, k) end
                    end
                end
                if bgHas then
                    local bgSub = root:CreateButton(L["pvp.battleground"] or "Battleground")
                    for _, k in ipairs(BG_GROUP) do
                        if available[k] then emitBracket(bgSub, k) end
                    end
                end
            end
            hasPvp = true
        end
    end

    if not hasBlizzard and not hasArchon and not hasIcyVeins and not hasPvp and (not specData or not specData.talents or #specData.talents == 0) then
        root:CreateTitle(L["loadout_dock.no_loadouts"])
    end
end

-- Right-click menu: position lock + open settings. Lock state is
-- account-wide (ClassCodexDB.dockLoadoutLocked) so it stays consistent
-- across alts.
local function BuildOptionsMenu(_, root)
    local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
    local locked = ClassCodexDB and ClassCodexDB.dockLoadoutLocked
    root:CreateTitle(L["settings.header.loadout_dock"])
    local lockLabel = locked and L["loadout_dock.unlock_position"] or L["loadout_dock.lock_position"]
    root:CreateButton(lockLabel, function()
        if not ClassCodexDB then return end
        ClassCodexDB.dockLoadoutLocked = not ClassCodexDB.dockLoadoutLocked
    end)
    root:CreateButton(L["compendium.open_settings"], function()
        if ns.OpenSettings then ns.OpenSettings() end
    end)
end

local function CreateDock()
    local f = CreateFrame("Button", "ClassCodexLoadoutDock", UIParent, "BackdropTemplate")
    local savedWidth = (ClassCodexDB and ClassCodexDB.dockLoadoutWidth) or DOCK_DEFAULT_WIDTH
    f:SetSize(math.max(DOCK_MIN_WIDTH, math.min(DOCK_MAX_WIDTH, savedWidth)), DOCK_HEIGHT)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:RegisterForDrag("LeftButton")

    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)

    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    -- Spec icon (active spec's iconTexture from GetSpecializationInfo).
    local specIcon = f:CreateTexture(nil, "ARTWORK")
    specIcon:SetSize(ICON_SIZE, ICON_SIZE)
    specIcon:SetPoint("LEFT", 6, 0)
    f.specIcon = specIcon

    -- Hero talent icon (atlas from ns.HERO_TALENT_ATLAS keyed by hero name).
    local heroIcon = f:CreateTexture(nil, "ARTWORK")
    heroIcon:SetSize(ICON_SIZE, ICON_SIZE)
    heroIcon:SetPoint("LEFT", specIcon, "RIGHT", 4, 0)
    f.heroIcon = heroIcon

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    -- Anchor set in RefreshLabel based on which icons are visible.
    f.label = label

    f:SetScript("OnDragStart", function(self)
        if ClassCodexDB and ClassCodexDB.dockLoadoutLocked then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not ClassCodexDB then return end
        local point, _, relativePoint, x, y = self:GetPoint()
        ClassCodexDB.dockLoadoutPosition = {
            point = point,
            relativePoint = relativePoint,
            x = x,
            y = y,
        }
    end)

    f:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            MenuUtil.CreateContextMenu(self, BuildOptionsMenu)
        else
            MenuUtil.CreateContextMenu(self, BuildLoadoutMenu)
        end
    end)

    f:SetScript("OnEnter", function(self)
        local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")

        -- Full loadout name as the title — the dock label itself can
        -- truncate on long names with SetWordWrap(false).
        local fullName = GetActiveLoadoutName()
        if fullName and fullName ~= "" then
            GameTooltip:AddLine(fullName, 1, 0.82, 0)
        else
            GameTooltip:AddLine("Class Codex", 1, 0.82, 0)
        end

        -- If the active build matches a Codex recommendation, surface
        -- which one (and from which source) so power users see at a
        -- glance whether they're on the recommended Mythic+ or Raid.
        local specData = ns.GetSpecData and ns.GetSpecData()
        local wowheadMatch = MatchCodexBuild(specData)
        if wowheadMatch and ns.FormatBuildLabel then
            GameTooltip:AddLine("|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12:0:0|t  " ..
                ns.FormatBuildLabel(wowheadMatch), 0.6, 0.85, 0.6)
        else
            local classToken, specSlug
            if ns.GetClassAndSpec then classToken, specSlug = ns.GetClassAndSpec() end
            local archonBuild, archonCtx = MatchArchonBuild(classToken, specSlug)
            if archonBuild and archonCtx then
                local archonLabel = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(archonCtx)) or "Archon"
                GameTooltip:AddLine("|TInterface\\AddOns\\ClassCodex\\Textures\\archon:12:12:0:0|t  " ..
                    archonLabel, 0.6, 0.85, 0.6)
            end
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["loadout_dock.click_to_switch"], 1, 1, 1)
        GameTooltip:AddLine(L["loadout_dock.right_click_options"], 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Initial position: account-wide saved value or sensible default
    -- (top-centre, just below the default minimap area).
    local saved = ClassCodexDB and ClassCodexDB.dockLoadoutPosition
    f:ClearAllPoints()
    if saved and saved.point and saved.x and saved.y then
        f:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x, saved.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    end

    return f
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Apply the user's background opacity setting (defaults to 0.95 if unset).
function ns.ApplyLoadoutDockOpacity()
    if not dock then return end
    local pct = (ClassCodexDB and ClassCodexDB.dockLoadoutOpacity) or 95
    local alpha = math.max(0, math.min(100, pct)) / 100
    dock:SetBackdropColor(0.08, 0.08, 0.08, alpha)
end

-- Toggle the dock border on/off based on settings. dockLoadoutShowBorder
-- nil/true → visible at 0.7 alpha; false → fully transparent border.
function ns.ApplyLoadoutDockBorder()
    if not dock then return end
    if ClassCodexDB and ClassCodexDB.dockLoadoutShowBorder == false then
        dock:SetBackdropBorderColor(0, 0, 0, 0)
    else
        dock:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.7)
    end
end

-- Compute the natural width the content needs (icons + gaps + label
-- rendered text + padding). Used by auto-fit width and by the alignment
-- offset calculation.
local function computeContentWidth()
    if not dock then return 0 end
    local hasSpec = dock.specIcon:IsShown()
    local hasHero = dock.heroIcon:IsShown()
    local iconCount = (hasSpec and 1 or 0) + (hasHero and 1 or 0)
    local iconsW = iconCount * ICON_SIZE + math.max(0, iconCount - 1) * ICON_GAP
    local labelW = dock.label:GetStringWidth() or 0
    return iconsW + (iconCount > 0 and labelW > 0 and LABEL_GAP or 0) + labelW
end

function ns.ApplyLoadoutDockWidth()
    if not dock then return end
    if ClassCodexDB and ClassCodexDB.dockLoadoutAutoWidth then
        local content = computeContentWidth()
        local w = math.max(DOCK_MIN_WIDTH, math.min(DOCK_MAX_WIDTH, math.ceil(content + PAD * 2)))
        dock:SetWidth(w)
    else
        local w = (ClassCodexDB and ClassCodexDB.dockLoadoutWidth) or DOCK_DEFAULT_WIDTH
        dock:SetWidth(math.max(DOCK_MIN_WIDTH, math.min(DOCK_MAX_WIDTH, w)))
    end
end

-- Native frame scale: grows or shrinks the widget proportionally so
-- font, icons, height, and padding all stay in their designed ratio.
-- The setting stores a percentage (50-200), divide by 100 for SetScale.
function ns.ApplyLoadoutDockScale()
    if not dock then return end
    local pct = (ClassCodexDB and ClassCodexDB.dockLoadoutScale) or 100
    local scale = math.max(0.5, math.min(2.0, pct / 100))
    dock:SetScale(scale)
    -- The label's measured width can shift after a SetScale because
    -- the font's render reflows; without a re-measure, the previously
    -- computed auto-fit width may now be too narrow and the label
    -- truncates to "...". Mirror RefreshLabel's immediate+deferred
    -- pattern so the deferred pass picks up the post-scale width.
    if dock:IsShown() then
        ns.ApplyLoadoutDockWidth()
        LayoutDockContent()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if dock and dock:IsShown() then
                    ns.ApplyLoadoutDockWidth()
                    LayoutDockContent()
                end
            end)
        end
    end
end

function ns.ShowLoadoutDock()
    if not dock then dock = CreateDock() end
    dock:Show()
    ns.ApplyLoadoutDockOpacity()
    ns.ApplyLoadoutDockBorder()
    ns.ApplyLoadoutDockWidth()
    ns.ApplyLoadoutDockScale()
    RefreshLabel()
    -- The talent API is occasionally not populated immediately after
    -- PLAYER_LOGIN — an extra refresh half a second later catches the
    -- common "loadout name shows blank on first display" case.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function()
            if dock and dock:IsShown() then RefreshLabel() end
        end)
    end
end

function ns.HideLoadoutDock()
    if dock then dock:Hide() end
end

function ns.RefreshLoadoutDock()
    if dock and dock:IsShown() then RefreshLabel() end
end

-- Apply visibility based on settings + combat state. Called from settings
-- callbacks and combat events.
function ns.UpdateLoadoutDockVisibility()
    local db = ClassCodexDB
    if not db then return end
    if not db.dockLoadoutEnabled then
        ns.HideLoadoutDock()
        return
    end
    if db.dockLoadoutHideInCombat and InCombatLockdown() then
        ns.HideLoadoutDock()
        return
    end
    ns.ShowLoadoutDock()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        ns.UpdateLoadoutDockVisibility()
        if dock and dock:IsShown() then RefreshLabel() end
    elseif event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Promote a pending apply (set when the user clicked a build
        -- in the dock menu) to a confirmed one, capturing the player's
        -- bits as they actually settled — that snapshot is what the
        -- next menu render uses to validate the memo.
        local perSpec = ns.GetPerSpecState and ns.GetPerSpecState()
        if perSpec and perSpec.pendingApplyBuildExport then
            local bits = ns.GetActiveTalentSignature and ns.GetActiveTalentSignature()
            if bits then
                perSpec.lastAppliedBuildExport = perSpec.pendingApplyBuildExport
                perSpec.lastAppliedBuildBits = bits
                perSpec.pendingApplyBuildExport = nil
            end
        end
        ns.RefreshLoadoutDock()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        ns.UpdateLoadoutDockVisibility()
    end
end)
