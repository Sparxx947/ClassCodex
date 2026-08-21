local _, ns = ...

-------------------------------------------------------------------------------
-- TalentPaneDropdown: a build picker on the talent frame.
--
-- Visible affordance: a small Class Codex icon at the bottom-left of the
-- Talents tab, above Blizzard's Apply/Undo/Reset action bar. Clicking
-- the icon expands a row of controls to its right with a slide+fade
-- animation: an inline build dropdown, a close (X) icon, an Export
-- icon, and an Apply icon.
--
-- Interaction model:
--   - Click icon          -> toggles panel open/closed. Selected build
--                            is remembered across collapse; glow on the
--                            talent tree shows only while the panel is
--                            open.
--   - Click build dropdown-> menu of builds (grouped by hero) opens.
--   - Hover a build       -> diff overlays appear on the talent tree.
--   - Click a build       -> menu closes, dropdown shows the build,
--                            Export + Apply icons fade in.
--   - Click Export        -> popup with the previewed build's export
--                            string.
--   - Click Apply         -> applies the build, collapses the panel.
--   - Right-click a build -> popup with that build's export string.
-------------------------------------------------------------------------------

if not C_ClassTalents or not C_Traits then return end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local ICON_SIZE = 30
local ACTION_ICON_SIZE = 20
local SOURCE_DROPDOWN_WIDTH = 116
local SCOPE_DROPDOWN_WIDTH = 124
local BUILD_DROPDOWN_WIDTH = 220
local ICON_GAP = 6
local CONTAINER_PADDING_X = 8
local CONTAINER_PADDING_Y = 6
local REVEAL_DURATION = 0.18

local GLOW_INSET = 3 -- tight halo, just past the button edge
local GLOW_ALPHA = 0.45
local GLOW_ATLAS = "bags-glow-orange" -- naturally rounded, confirmed renders
local GLOW_COLOR_ADD    = { 0.20, 1.00, 0.35 } -- green
local GLOW_COLOR_REMOVE = { 1.00, 0.30, 0.30 } -- red
local GLOW_COLOR_CHANGE = { 1.00, 0.75, 0.20 } -- amber

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local container
local iconBtn
local sourceDropdown -- WowStyle1Dropdown for picking the data source (Wowhead | Archon)
local scopeDropdown  -- WowStyle1Dropdown for picking the Archon scope (Mythic+ / Raid Heroic / Raid Mythic). Hidden when source = Wowhead.
local buildDropdown  -- WowStyle1Dropdown for picking the build within the selected source/scope
local applyBtn
local copyBtn
local panelExpanded = false -- sticky reveal toggle (click icon to expand)
-- copyBox / copyEdit live in ClassCodex.lua now (ns.ShowCopyPopup);
-- this file just calls into the shared widget.
local previewedBuild           -- the build whose diff is currently glowing
local buildMapCache = {}       -- exportString -> { [nodeID] = entry } or false
local activeMapCache           -- nil means needs refresh
local touchedGlowButtons = {}  -- Blizzard talent buttons we added glow to
local setupDone = false

-- Source state — defaults via ns.GetEffectiveTalentSource() (auto-detect
-- aware), overridable per-character × per-spec via the source dropdown.
local selectedSource           -- "wowhead" | "archon" | "pvp"
local selectedArchonScope      -- "mplus" | "raidHeroic" | "raidMythic"
local selectedPvpBracket       -- "pvp-shuffle" | "pvp-blitz" | "pvp-2v2" | "pvp-3v3" | "pvp-rbg"

-- WoW retail's Lua 5.1 doesn't support \xHH escapes; the previous
-- "★" auto-row prefix (encoded as \xE2\x98\x85) leaked through as
-- mojibake. We now use a yellow color highlight on the label instead
-- of a glyph, and decimal escapes (\226\128\148 = U+2014 em dash) for
-- any non-ASCII characters elsewhere.
-- Raid difficulty labels come from Blizzard's own global strings so they
-- always match the player's client language. \226\128\148 = U+2014 em dash.
local SCOPE_LABELS = {
    mplus      = (ns.L and ns.L["context.mythic_plus"]) or "Mythic+",
    raidHeroic = ((RAID and PLAYER_DIFFICULTY2) and (RAID .. " \226\128\148 " .. PLAYER_DIFFICULTY2)) or "Raid \226\128\148 Heroic",
    raidMythic = ((RAID and PLAYER_DIFFICULTY6) and (RAID .. " \226\128\148 " .. PLAYER_DIFFICULTY6)) or "Raid \226\128\148 Mythic",
}

-------------------------------------------------------------------------------
-- Inspect-mode override
--
-- When PlayerSpellsFrame is showing another player's talents (because
-- the user clicked an inspect target), we want the build picker to load
-- builds for THAT class/spec, not the local player's. The inspect view
-- has a magic configID (VIEW_TRAIT_CONFIG_ID) that the diff functions
-- read instead of the player's active configID, so glow + active-build
-- detection still light up against the inspected target's tree state.
-- Apply is disabled — there is no API to apply talents to another
-- player's loadout.
-------------------------------------------------------------------------------

-- The talent frame uses INSPECT_TRAIT_CONFIG_ID (not VIEW_TRAIT_CONFIG_ID)
-- when showing an inspected target — see Blizzard_ClassTalentsFrame.lua,
-- ClassTalentsFrameMixin:LoadInspectFromString / SetInspectUnit. The diff
-- helpers route through this when an inspect override is active.
local INSPECT_CONFIG_ID = (Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID) or -1

-- inspectOverride is { classFile, specName, specID, level } or nil.
local inspectOverride = nil

local function ResolveInspectOverride()
    -- Canonical inspect signal: PlayerSpellsFrame:IsInspecting() returns
    -- true when either an inspect unit or an inspect string is set.
    if not PlayerSpellsFrame or not PlayerSpellsFrame.IsInspecting then return nil end
    local ok, isInspecting = pcall(PlayerSpellsFrame.IsInspecting, PlayerSpellsFrame)
    if not ok or not isInspecting then return nil end

    local infoFn = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoByID)
        or _G.GetSpecializationInfoByID
    if not infoFn then return nil end

    -- Path A: unit-based inspect (Blizzard's own InspectFrame → View Talents).
    -- Resolve class/spec live from the inspected unit.
    local unit = PlayerSpellsFrame.GetInspectUnit and PlayerSpellsFrame:GetInspectUnit() or nil
    if unit and UnitExists and UnitExists(unit) then
        local _, classFile = UnitClass(unit)
        local specID = GetInspectSpecialization and GetInspectSpecialization(unit) or 0
        if classFile and specID and specID ~= 0 then
            local _, specDisplayName = infoFn(specID)
            if specDisplayName and specDisplayName ~= "" then
                return {
                    classFile = classFile,
                    specName = specDisplayName:lower():gsub("%s+", "-"),
                    specID = specID,
                    level = (UnitLevel and UnitLevel(unit)) or 80,
                }
            end
        end
    end

    -- Path B: inspect-string mode (our menu entry's GenerateInspectImportString
    -- flow, or a pasted talent-build link). PlayerSpellsFrame:GetInspectString
    -- returns (string, classID, specID) — enough to resolve class/spec for
    -- CC's build list. Level isn't carried by the string here so default to 80.
    if PlayerSpellsFrame.GetInspectString then
        local _, classID, specID = PlayerSpellsFrame:GetInspectString()
        if classID and specID then
            local classInfo = C_CreatureInfo and C_CreatureInfo.GetClassInfo(classID)
            local classFile = classInfo and classInfo.classFile
            if classFile then
                local _, specDisplayName = infoFn(specID)
                if specDisplayName and specDisplayName ~= "" then
                    return {
                        classFile = classFile,
                        specName = specDisplayName:lower():gsub("%s+", "-"),
                        specID = specID,
                        level = 80,
                    }
                end
            end
        end
    end

    return nil
end

local function RefreshInspectOverride()
    -- If the talent frame is still in inspect mode but we couldn't
    -- resolve a new override (e.g. GetInspectSpecialization returned 0
    -- during a transient between-events state, or the unit briefly
    -- failed UnitExists), keep the previous override. Otherwise the
    -- dropdowns flicker to the local player's data and back, which
    -- looks like a reset.
    local resolved = ResolveInspectOverride()
    if not resolved and inspectOverride then
        local stillInspecting = PlayerSpellsFrame
            and PlayerSpellsFrame.IsInspecting
            and PlayerSpellsFrame:IsInspecting()
        if stillInspecting then
            return -- keep previous override
        end
    end
    inspectOverride = resolved
    ns._talentPaneInspect = inspectOverride
end

-------------------------------------------------------------------------------
-- Diff computation
-------------------------------------------------------------------------------

local function ClearGlow()
    for i = 1, #touchedGlowButtons do
        local btn = touchedGlowButtons[i]
        if btn and btn._ccGlow then btn._ccGlow:Hide() end
        touchedGlowButtons[i] = nil
    end
end

local function InvalidateActiveMap()
    activeMapCache = nil
    -- Build maps depend on the configID's tree state too (ConvertToEntryInfo
    -- reads node info via the configID). When the active config changes —
    -- player applies talents, inspect data finally loads, etc. — empty/
    -- failed build parses cached as `false` would otherwise stick. Wipe
    -- the build cache too so the next access re-parses against fresh
    -- node data.
    if buildMapCache then wipe(buildMapCache) end
end

-- Returns the configID we should diff *against*. In inspect mode the
-- talent frame itself owns the right value — Blizzard switches between
-- INSPECT_TRAIT_CONFIG_ID (inspect-by-unit) and VIEW_TRAIT_CONFIG_ID
-- (inspect-by-import-string) depending on context, so reading the
-- frame's current configID is more robust than guessing the constant.
local function GetActiveConfigID()
    if inspectOverride then
        local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
        if tf and tf.GetConfigID then
            local ok, id = pcall(tf.GetConfigID, tf)
            if ok and id then return id end
        end
        return INSPECT_CONFIG_ID
    end
    return C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
end

local function GetActiveMap()
    if activeMapCache then return activeMapCache end
    local configID = GetActiveConfigID()
    if not configID then return nil end
    local info = C_Traits.GetConfigInfo(configID)
    if not info or not info.treeIDs or not info.treeIDs[1] then return nil end
    local treeNodes = C_Traits.GetTreeNodes(info.treeIDs[1])
    if not treeNodes then return nil end
    local map = {}
    for _, nodeID in ipairs(treeNodes) do
        local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
        if nodeInfo and nodeInfo.ranksPurchased and nodeInfo.ranksPurchased > 0 then
            local entryID = nodeInfo.activeEntry and nodeInfo.activeEntry.entryID or nil
            map[nodeID] = {
                ranksPurchased = nodeInfo.ranksPurchased,
                selectionEntryID = entryID,
            }
        end
    end
    activeMapCache = map
    return map
end

local function GetBuildMap(exportString)
    local cached = buildMapCache[exportString]
    if cached ~= nil then return cached or nil end
    local map = ns.ParseLoadoutNodes and ns.ParseLoadoutNodes(exportString) or nil
    -- Don't cache empty / failed parses — common during inspect data
    -- loading where ConvertToEntryInfo can't resolve nodes yet. Caching
    -- the empty result would freeze the menu in a degenerate state until
    -- the buildMapCache is wiped externally.
    if map and next(map) then
        buildMapCache[exportString] = map
    else
        buildMapCache[exportString] = false
    end
    return (map and next(map)) and map or nil
end

local function ComputeDiff(buildMap, activeMap)
    local adds, removes, changes = {}, {}, {}
    if not buildMap or not activeMap then return adds, removes, changes end
    for nodeID, buildEntry in pairs(buildMap) do
        local activeEntry = activeMap[nodeID]
        if not activeEntry then
            adds[#adds + 1] = nodeID
        elseif buildEntry.selectionEntryID ~= activeEntry.selectionEntryID
            or buildEntry.ranksPurchased ~= activeEntry.ranksPurchased then
            changes[#changes + 1] = nodeID
        end
    end
    for nodeID in pairs(activeMap) do
        if not buildMap[nodeID] then
            removes[#removes + 1] = nodeID
        end
    end
    return adds, removes, changes
end

-- Returns the iterable of PvP talent slot frames from the modern talent
-- pane, or nil if the frame structure has shifted. Slots carry both the
-- currently-selected talent (`.selectedTalentID`) and a `.PvPTalentSlot`
-- subframe in some layouts — we accept either at the call site.
local function GetPvpSlotFrames()
    local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not tf then return nil end
    local tray = tf.PvPTalentSlotTray or tf.PvpTalentSlotTray
    if not tray then return nil end
    local slots = tray.Slots
    if type(slots) == "table" and slots[1] then return slots end
    -- Fallback: tray may expose slots as direct children Slot1..Slot3.
    local out = {}
    for i = 1, 3 do
        local s = tray["Slot" .. i] or tray["slot" .. i]
        if s then out[#out + 1] = s end
    end
    if #out > 0 then return out end
    return nil
end

-- Overlay the same diff-glow texture used for class talents on PvP slot
-- frames whose currently-selected talent matches one of `talentIds`.
-- Silently no-ops if the PvP frame layout differs from what we expect —
-- the slots-by-name fallback is what's documented for retail 11.x, but
-- Blizzard renames these between patches and we'd rather skip the glow
-- than throw.
local function ApplyGlowToPvpSlot(slotFrame, color)
    if not slotFrame or not slotFrame.CreateTexture then return end
    if not slotFrame._ccGlow then
        local glow = slotFrame:CreateTexture(nil, "OVERLAY", nil, 7)
        glow:SetAtlas(GLOW_ATLAS)
        glow:SetBlendMode("BLEND")
        local size = math.max(slotFrame:GetWidth() or 0, slotFrame:GetHeight() or 0)
        if size <= 0 then size = 38 end
        size = size + GLOW_INSET * 2
        glow:SetSize(size, size)
        glow:SetPoint("CENTER", slotFrame, "CENTER")
        slotFrame._ccGlow = glow
    end
    slotFrame._ccGlow:SetVertexColor(color[1], color[2], color[3], GLOW_ALPHA)
    slotFrame._ccGlow:Show()
    touchedGlowButtons[#touchedGlowButtons + 1] = slotFrame
end

local function GlowHonorTalents(talentIds)
    if not talentIds or #talentIds == 0 then return end
    local slots = GetPvpSlotFrames()
    if not slots then return end
    local wanted = {}
    for _, id in ipairs(talentIds) do wanted[id] = true end
    for _, slot in ipairs(slots) do
        local current = slot.selectedTalentID or slot.talentID
            or (slot.GetSelectedTalent and slot:GetSelectedTalent())
            or (slot.PvPTalentSlot and slot.PvPTalentSlot.selectedTalentID)
        if current and not wanted[current] then
            -- Slot currently holds a non-recommended talent → glow it to
            -- prompt the user to swap. ADD color signals "set this".
            ApplyGlowToPvpSlot(slot, GLOW_COLOR_ADD)
        end
    end
end

local function ApplyGlowToButton(nodeID, color)
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talentsFrame or not talentsFrame.GetTalentButtonByNodeID then return end
    local btn = talentsFrame:GetTalentButtonByNodeID(nodeID)
    if not btn then return end
    if not btn._ccGlow then
        -- Single soft radial glow using bags-glow-orange (confirmed
        -- renders on retail). Sized very large so the soft falloff
        -- has room to render smoothly (small sizes make the radial
        -- gradient look square at the texture edges). OVERLAY
        -- sublevel 7 so it draws above the button's own decorations.
        local glow = btn:CreateTexture(nil, "OVERLAY", nil, 7)
        glow:SetAtlas(GLOW_ATLAS)
        glow:SetBlendMode("BLEND")
        local size = math.max(btn:GetWidth() or 0, btn:GetHeight() or 0)
        if size <= 0 then size = 38 end
        size = size + GLOW_INSET * 2
        glow:SetSize(size, size)
        glow:SetPoint("CENTER", btn, "CENTER")
        btn._ccGlow = glow
    end
    btn._ccGlow:SetVertexColor(color[1], color[2], color[3], GLOW_ALPHA)
    btn._ccGlow:Show()
    touchedGlowButtons[#touchedGlowButtons + 1] = btn
end

-------------------------------------------------------------------------------
-- Reveal animation: container slides open to the right when a build is
-- previewed, action icons fade in. Sliding back when preview clears.
-------------------------------------------------------------------------------

local function GetIdleWidth()
    return CONTAINER_PADDING_X * 2 + ICON_SIZE
end

local function GetMediumWidth()
    -- Panel expanded but no build picked yet: icon + source + (scope?) + build.
    local w = CONTAINER_PADDING_X * 2 + ICON_SIZE
        + ICON_GAP + SOURCE_DROPDOWN_WIDTH
        + ICON_GAP + BUILD_DROPDOWN_WIDTH
    if selectedSource == "archon" then
        w = w + ICON_GAP + SCOPE_DROPDOWN_WIDTH
    end
    return w
end

local function GetExpandedWidth()
    -- Build picked: + Export + Apply icons.
    return GetMediumWidth() + (ICON_GAP + ACTION_ICON_SIZE) * 2
end

local function GetTargetWidth()
    -- Container width is driven by panelExpanded only. If a build is
    -- remembered (previewedBuild ~= nil) but the panel is closed, we
    -- still collapse to idle width — the build is "remembered" via
    -- the previewedBuild state and shows up again on next expand.
    if not panelExpanded then return GetIdleWidth() end
    if previewedBuild then return GetExpandedWidth() end
    return GetMediumWidth()
end

-- Scope dropdown is only visible when source = archon. The other two
-- dropdowns track panelExpanded; scope is gated additionally by source.
local function UpdateScopeDropdownVisibility()
    if not scopeDropdown then return end
    if selectedSource == "archon" and panelExpanded then
        scopeDropdown:Show()
        scopeDropdown:SetAlpha(1)
    else
        scopeDropdown:Hide()
        scopeDropdown:SetAlpha(0)
    end
end

local function ShowDropdown()
    if sourceDropdown then sourceDropdown:Show() end
    if buildDropdown then buildDropdown:Show() end
    UpdateScopeDropdownVisibility()
end

local function HideDropdown()
    if sourceDropdown then sourceDropdown:Hide() end
    if buildDropdown then buildDropdown:Hide() end
    if scopeDropdown then scopeDropdown:Hide(); scopeDropdown:SetAlpha(0) end
end

local function ShowActionIcons()
    if applyBtn then applyBtn:Show() end
    if copyBtn then copyBtn:Show() end
end

local function HideActionIcons()
    if applyBtn then applyBtn:Hide() end
    if copyBtn then copyBtn:Hide() end
end

local function CloseBuildMenu()
    -- Close the build dropdown's currently-open menu if any. We
    -- deliberately avoid Menu.GetManager():CloseMenus() — that closes
    -- every menu in the UI (including Blizzard's UnitPopup right-click
    -- menus on portraits, raid frames, chat names, etc.) because in
    -- modern retail the UnitPopup system shares the MenuManager
    -- singleton. UpdateVisibility runs on INSPECT_READY and a few other
    -- frequently-fired hooks, so a global CloseMenus from here was
    -- silently dismissing the player's open right-click menu a few
    -- seconds after they opened it.
    if buildDropdown and buildDropdown.CloseMenu then
        pcall(buildDropdown.CloseMenu, buildDropdown)
    end
end

-- Visibility states (panelExpanded gates everything, previewedBuild
-- gates the action icons within the expanded panel):
--   panel closed              -> only CC icon (build may still be
--                                remembered in previewedBuild)
--   panel open, no build      -> CC icon + dropdown
--   panel open, build picked  -> CC icon + dropdown + Reset/Copy/Apply
local function GetTargetAlphas()
    local dropdownTarget = panelExpanded and 1 or 0
    -- Apply isn't legal in inspect mode (the API can't load talents
    -- onto another player), so the action icons stay hidden. Export
    -- still works via right-click on a build row.
    local canShowActions = panelExpanded and previewedBuild and not inspectOverride
    local actionTarget = canShowActions and 1 or 0
    return dropdownTarget, actionTarget
end

local function UpdateRevealAnimation()
    if not container then return end

    local targetWidth = GetTargetWidth()
    local dropdownTarget, actionTarget = GetTargetAlphas()

    if dropdownTarget > 0 then ShowDropdown() end
    if actionTarget > 0 then ShowActionIcons() end

    local startWidth = container:GetWidth()
    local startDropdownAlpha = buildDropdown and buildDropdown:GetAlpha() or 0
    local startActionAlpha = applyBtn and applyBtn:GetAlpha() or 0

    local atTarget = math.abs(startWidth - targetWidth) < 0.5
        and math.abs(startDropdownAlpha - dropdownTarget) < 0.01
        and math.abs(startActionAlpha - actionTarget) < 0.01

    -- Scope follows the same alpha as the other dropdowns when source =
    -- archon, else snaps to 0 and stays hidden.
    local scopeTarget = (selectedSource == "archon") and dropdownTarget or 0

    if atTarget then
        container:SetWidth(targetWidth)
        if sourceDropdown then sourceDropdown:SetAlpha(dropdownTarget) end
        if buildDropdown then buildDropdown:SetAlpha(dropdownTarget) end
        if applyBtn then applyBtn:SetAlpha(actionTarget) end
        if copyBtn then copyBtn:SetAlpha(actionTarget) end
        UpdateScopeDropdownVisibility()
        if dropdownTarget == 0 then HideDropdown() end
        if actionTarget == 0 then HideActionIcons() end
        container:SetScript("OnUpdate", nil)
        return
    end

    local elapsed = 0
    container:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local t = math.min(elapsed / REVEAL_DURATION, 1.0)
        local eased = 1 - (1 - t) * (1 - t)
        self:SetWidth(startWidth + (targetWidth - startWidth) * eased)

        local dAlpha = startDropdownAlpha + (dropdownTarget - startDropdownAlpha) * eased
        local aAlpha = startActionAlpha + (actionTarget - startActionAlpha) * eased
        if sourceDropdown then sourceDropdown:SetAlpha(dAlpha) end
        if buildDropdown then buildDropdown:SetAlpha(dAlpha) end
        if scopeDropdown and selectedSource == "archon" then
            scopeDropdown:Show(); scopeDropdown:SetAlpha(dAlpha)
        end
        if applyBtn then applyBtn:SetAlpha(aAlpha) end
        if copyBtn then copyBtn:SetAlpha(aAlpha) end

        if t >= 1 then
            self:SetScript("OnUpdate", nil)
            if dropdownTarget == 0 then HideDropdown() end
            if actionTarget == 0 then HideActionIcons() end
        end
    end)
end

-- Collapse the panel from any state. Used by the X (Reset) button so
-- it works whether or not a build was previewed: SetPreview(nil) alone
-- early-returns when preview was already nil, skipping the animation.
local function CollapsePanel()
    CloseBuildMenu()
    panelExpanded = false
    previewedBuild = nil
    ClearGlow()
    UpdateRevealAnimation()
end

local function ApplyGlowForBuild(build)
    if not build then return end
    local buildMap = GetBuildMap(build.exportString)
    local activeMap = GetActiveMap()
    if buildMap and activeMap then
        local adds, removes, changes = ComputeDiff(buildMap, activeMap)
        for _, n in ipairs(adds)    do ApplyGlowToButton(n, GLOW_COLOR_ADD)    end
        for _, n in ipairs(removes) do ApplyGlowToButton(n, GLOW_COLOR_REMOVE) end
        for _, n in ipairs(changes) do ApplyGlowToButton(n, GLOW_COLOR_CHANGE) end
    end
    -- PvP builds carry honor talents in `_pvpHonorTalents`; glow the
    -- corresponding slot frames so the user can see which honor talents
    -- to swap to. Class-talent glow above already covers the export
    -- string; this is the PvP-tab equivalent.
    if build._pvpHonorTalents then
        GlowHonorTalents(build._pvpHonorTalents)
    end
end

-- Compare a build to the player's currently-applied loadout via parsed
-- node maps rather than raw export bits. Bit-comparison via
-- ExtractTalentBits worked for Wowhead exports but mis-classified
-- Archon's exports — same node allocations, but the export tooling
-- can pad / order bits differently around choice nodes and partial
-- ranks. Map-based comparison ignores those representation
-- differences and only checks "is the same talent state allocated".
local function BuildMatchesActive(build)
    if not build or not build.exportString then return false end
    local buildMap = GetBuildMap(build.exportString)
    local activeMap = GetActiveMap()
    if not buildMap or not activeMap then return false end
    -- Empty maps mean the parser couldn't resolve nodes (common during
    -- inspect data loading — C_Traits.GetNodeInfo returns 0-rank entries
    -- before the server data lands). ComputeDiff over two empty tables
    -- returns no differences, which would false-positive every row in
    -- the menu. Treat empty as "unknown" instead of "equal".
    if next(buildMap) == nil or next(activeMap) == nil then return false end
    local adds, removes, changes = ComputeDiff(buildMap, activeMap)
    return #adds == 0 and #removes == 0 and #changes == 0
end

-- Exposed so other surfaces (docked panel Talents tab, Compendium)
-- can use the same map-based equality without each importing the
-- GetBuildMap / GetActiveMap / ComputeDiff plumbing. Shares this
-- file's caches, which are invalidated by the same TRAIT_CONFIG_*
-- and inspect events that drive the talent pane itself.
ns.BuildMatchesActive = BuildMatchesActive

local function IsActiveBuild(build)
    return BuildMatchesActive(build)
end

-- Resolve the active class token + spec key in the same form used as
-- keys throughout Data\{Class}\* (e.g. "HUNTER", "beast-mastery"). In
-- inspect mode we return the inspected target's class/spec so all
-- downstream lookups (Wowhead specData, Archon contexts, hero atlas)
-- resolve to the target's data set.
local function CurrentClassSpec()
    if inspectOverride then
        return inspectOverride.classFile, inspectOverride.specName
    end
    if not ns.GetSpecData then return nil, nil end
    local _, classToken, specKey = ns.GetSpecData()
    return classToken, specKey
end

-- Wowhead spec data resolution: in inspect mode we look up directly
-- in the global rather than going through ns.GetSpecData (which keys
-- off the local player). Returns the same shape as ns.GetSpecData.
local function GetEffectiveSpecData()
    if inspectOverride then
        local DATA = _G.ClassCodexData
        if not DATA then return nil end
        local cls = DATA[inspectOverride.classFile]
        if not cls then return nil end
        return cls[inspectOverride.specName]
    end
    return ns.GetSpecData and ns.GetSpecData() or nil
end

-- Scan Wowhead first, then Archon. Returns the first build whose
-- talent-bit signature matches the player's currently-applied loadout.
local function FindActiveBuild()
    -- Use map-based equality (BuildMatchesActive) rather than raw bit
    -- comparison so this works for both Wowhead and Archon exports —
    -- the two sources can produce differently-padded export strings
    -- for the same talent state.
    if not GetActiveMap() then return nil end

    local specData = GetEffectiveSpecData()
    if specData and specData.talents then
        for _, build in ipairs(specData.talents) do
            if BuildMatchesActive(build) then
                return build
            end
        end
    end

    local classFile, specName = CurrentClassSpec()
    if classFile and specName and ns.GetArchonSpecData then
        local archon = ns.GetArchonSpecData(classFile, specName)
        if archon and archon.contexts then
            for _, ctx in pairs(archon.contexts) do
                if ctx.builds then
                    for _, build in ipairs(ctx.builds) do
                        if BuildMatchesActive(build) then
                            return build
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function SetPreview(build)
    if previewedBuild == build then return end
    previewedBuild = build
    ClearGlow()
    -- Only apply glow when the panel is actually open. The build is
    -- still remembered while collapsed; glow returns when re-opened.
    if build and panelExpanded then
        ApplyGlowForBuild(build)
    end
    UpdateRevealAnimation()
end

-------------------------------------------------------------------------------
-- Copy popup
-------------------------------------------------------------------------------

local function ShowCopyPopup(exportString)
    if ns.ShowCopyPopup then ns.ShowCopyPopup(exportString) end
end

-------------------------------------------------------------------------------
-- Apply
-------------------------------------------------------------------------------

local function BuildLoadoutLabel(build)
    local hero = build.heroTalent or "All"
    local label = build.context or "Build"
    if hero ~= "All" then label = hero .. " " .. label end
    if build.buildLabel and build.buildLabel ~= "" then
        label = label .. " " .. build.buildLabel
    end
    return label
end

local function OnApplyClicked()
    if not previewedBuild then return end
    -- Apply is illegal in inspect mode (the API has no way to apply
    -- talents to another player). Defensive guard — the button is
    -- hidden by GetTargetAlphas in inspect mode, but the script could
    -- still be invoked programmatically.
    if inspectOverride then return end
    -- No-op if this is already the applied build.
    if IsActiveBuild(previewedBuild) then return end
    -- Hide the diff glow up front. While the apply runs, the staged
    -- talent state shifts node-by-node so the diff would be
    -- meaningless mid-flight. The event handler suppresses re-renders
    -- during apply (ns._talentApplyInProgress); after commit fires,
    -- the glow re-computes against the new active state (which now
    -- matches the build, so the glow ends up empty anyway).
    ClearGlow()
    local build = previewedBuild
    local ok, err = ns.ApplyTalentExportString(build.exportString, BuildLoadoutLabel(build))
    if not ok then
        print("|cff00ccffClass Codex:|r " .. (err or "Failed to apply talents"))
        return
    end
    -- For PvP builds, also apply honor talents (3 PvP talent slots).
    -- These have a separate API and only succeed in War Mode + arena/BG.
    -- Failure here is non-fatal: class talents already applied successfully.
    if build._pvpHonorTalents and ns.ApplyPvpHonorTalents then
        ns.ApplyPvpHonorTalents(build._pvpHonorTalents)
    end
    -- Successful apply: keep the panel open and the build remembered.
end

-------------------------------------------------------------------------------
-- Dropdown menu population
-------------------------------------------------------------------------------

local function HookItemBehavior(initializer, build)
    initializer:AddInitializer(function(button)
        button:HookScript("OnEnter", function()
            SetPreview(build)
        end)
        if build then
            -- Right-click: copy export string. Note: the menu will close on
            -- mouse up regardless; the popup appears on top after close.
            if button.RegisterForClicks then
                pcall(button.RegisterForClicks, button, "LeftButtonUp", "RightButtonUp")
            end
            button:HookScript("OnMouseUp", function(_, mouseBtn)
                if mouseBtn == "RightButton" then
                    ShowCopyPopup(build.exportString)
                end
            end)
        end
    end)
end

-- Builds an Archon-flavoured "build" record matching the shape that
-- SetPreview / ApplyTalentExportString expect. Adds context/hero/buildLabel
-- fields derived from the Archon metadata so existing helpers (gold-border
-- "active" check, Apply loadout naming, etc.) work without source-specific
-- branches downstream.
local function ArchonBuildRecord(ctx, build)
    local hero = build.heroTalent or "All"
    local context = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(ctx))
        or ctx.encounterLabel or "Build"
    local difficultyLabel = ctx.difficultyLabel
    local buildLabel = nil
    if difficultyLabel and difficultyLabel ~= "" and ctx.zoneType == "raid" then
        buildLabel = difficultyLabel
    end
    return {
        heroTalent = hero,
        context = context,
        buildLabel = buildLabel,
        exportString = build.exportString,
        recommended = false,
        _archonSource = true,
        _archonContextKey = nil, -- filled in by caller
    }
end

-- Format a PvP-flavoured "build" record matching the shape SetPreview /
-- ApplyTalentExportString expect. Carries `_pvpHonorTalents` so the apply
-- flow can call SetPvpTalent / LearnPvpTalent for each of the 3 slots
-- after the class talent loadout applies.
--
-- heroTalent now comes from the scraper (Blizzard's selected_hero_talent_tree
-- field on the leaderboard loadout), so menu rendering can show the hero
-- icon. Falls back to "All" for older Lua data files that predate the
-- per-build heroTalent emit.
local function PvpBuildRecord(bracketKey, bracketData, bracketBuild)
    local honor = nil
    if bracketData.pvpTalentSets and bracketData.pvpTalentSets[1]
        and bracketData.pvpTalentSets[1].talents then
        honor = bracketData.pvpTalentSets[1].talents
    end
    return {
        heroTalent = bracketBuild.heroTalent or "All",
        context = ns.GetPvPBracketName and ns.GetPvPBracketName(bracketKey) or bracketKey,
        buildLabel = "PvP",
        exportString = bracketBuild.exportString,
        recommended = false,
        _pvpSource = true,
        _pvpBracketKey = bracketKey,
        _pvpHonorTalents = honor,
    }
end

local function DefaultPvpBracketForSpec(classFile, specName)
    if not classFile or not specName or not ns.GetPvPBracketsWithData then return nil end
    local available = ns.GetPvPBracketsWithData(classFile, specName)
    if not available or #available == 0 then return nil end
    -- Prefer the currently-selected bracket if it's still available
    if selectedPvpBracket then
        for _, key in ipairs(available) do
            if key == selectedPvpBracket then return selectedPvpBracket end
        end
    end
    return available[1]
end

-- Apply the top build for the current/default PvP bracket as the preview.
-- No-op when no PvP data exists for the spec.
local function SeedPvpDefaultPreview()
    local classFile, specName = CurrentClassSpec()
    if not classFile or not specName or not ns.GetPvPBuilds then return end
    local bracket = DefaultPvpBracketForSpec(classFile, specName)
    if not bracket then return end
    local data = ns.GetPvPBuilds(classFile, specName, bracket)
    if not data or not data.builds or not data.builds[1] then return end
    selectedPvpBracket = bracket
    SetPreview(PvpBuildRecord(bracket, data, data.builds[1]))
end

local function PopulatePvpMenu(rootDescription)
    local classFile, specName = CurrentClassSpec()
    if not classFile or not specName or not ns.GetPvPBracketsWithData then
        rootDescription:CreateTitle((ns.L and ns.L["pvp.no_builds"]) or "No PvP builds available.")
        return
    end
    local brackets = ns.GetPvPBracketsWithData(classFile, specName)
    if not brackets or #brackets == 0 then
        rootDescription:CreateTitle((ns.L and ns.L["pvp.no_builds"]) or "No PvP builds available.")
        return
    end

    for _, bracketKey in ipairs(brackets) do
        local bracketData = ns.GetPvPBuilds(classFile, specName, bracketKey)
        if bracketData and bracketData.builds and bracketData.builds[1] then
            local topBuild = bracketData.builds[1]
            local label = ns.GetPvPBracketName and ns.GetPvPBracketName(bracketKey) or bracketKey
            local capturedKey = bracketKey
            local capturedRecord = PvpBuildRecord(bracketKey, bracketData, topBuild)
            local isActive = BuildMatchesActive({ exportString = topBuild.exportString })
            if isActive then
                label = label .. " |cff66ff66(active)|r"
            end
            local item = rootDescription:CreateRadio(
                label,
                function()
                    if previewedBuild and previewedBuild._pvpBracketKey == capturedKey then return true end
                    if previewedBuild == nil and isActive then return true end
                    return false
                end,
                function()
                    selectedPvpBracket = capturedKey
                    if previewedBuild and previewedBuild._pvpBracketKey == capturedKey then
                        SetPreview(nil)
                    else
                        SetPreview(capturedRecord)
                    end
                end
            )
            HookItemBehavior(item, capturedRecord)
        end
    end
end

local function PopulateWowheadMenu(rootDescription)
    local specData = GetEffectiveSpecData()
    if not specData or not specData.talents or #specData.talents == 0 then
        rootDescription:CreateTitle((ns.L and ns.L["loadout_dock.no_talent_builds"]) or "No talent builds available.")
        return
    end

    local heroOrder, heroBuilds = ns.GroupBuildsByHero(specData.talents)

    for _, hero in ipairs(heroOrder) do
        rootDescription:CreateTitle(ns.FormatHeroHeaderText(hero))
        for _, build in ipairs(heroBuilds[hero]) do
            local label = ns.FormatBuildLabel(build)
            local isActive = BuildMatchesActive(build)
            if isActive then
                label = label .. " |cff66ff66(active)|r"
            end
            local capturedBuild = build
            local capturedActive = isActive
            local item = rootDescription:CreateRadio(
                label,
                function()
                    -- Show the active build's row as selected when the
                    -- user hasn't picked anything yet, so the closed
                    -- dropdown displays "...(active)" instead of the
                    -- placeholder.
                    if previewedBuild == capturedBuild then return true end
                    if previewedBuild == nil and capturedActive then return true end
                    return false
                end,
                function()
                    if previewedBuild == capturedBuild then
                        SetPreview(nil)
                    else
                        SetPreview(capturedBuild)
                    end
                end
            )
            HookItemBehavior(item, capturedBuild)
        end
    end
end

local function FormatArchonRow(ctx, build, isActive, isAuto)
    local heroAtlas = build.heroTalent and ns.HERO_TALENT_ATLAS and ns.HERO_TALENT_ATLAS[build.heroTalent]
    local heroBadge = heroAtlas and ("|A:" .. heroAtlas .. ":12:12|a ") or ""
    local label = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(ctx))
        or ctx.encounterLabel or "Build"
    local body = heroBadge .. label
    -- Yellow highlight on the auto-detected row instead of a Unicode
    -- glyph (Lua 5.1's literal-byte handling makes glyph prefixes
    -- unreliable in WoW retail).
    if isAuto then body = "|cffffd100" .. body .. "|r" end
    if isActive then
        body = body .. " |cff66ff66(active)|r"
    end
    return body
end

-- Translate a contextKey into a scope token used by the scope dropdown.
-- "mythic-plus:high-keys:..."  -> "mplus"
-- "raid:heroic:..."            -> "raidHeroic"
-- "raid:mythic:..."            -> "raidMythic"
local function ScopeForContextKey(contextKey)
    if not contextKey then return nil end
    if contextKey:find("^mythic%-plus:") then return "mplus" end
    if contextKey:find("^raid:mythic:") then return "raidMythic" end
    if contextKey:find("^raid:heroic:") then return "raidHeroic" end
    return nil
end

-- Pick a sensible scope when none is set yet: prefer the auto-detected
-- context's scope, else the first scope that has any data.
local function ResolveDefaultScope(groups)
    local autoKey = ns.GetActiveArchonContext and ns.GetActiveArchonContext() or nil
    local autoScope = ScopeForContextKey(autoKey)
    if autoScope then return autoScope end
    if groups.mplusOverview or #groups.mplusDungeons > 0 then return "mplus" end
    if groups.raidOverviewHeroic or #groups.raidHeroicBosses > 0 then return "raidHeroic" end
    if groups.raidOverviewMythic or #groups.raidMythicBosses > 0 then return "raidMythic" end
    return "mplus"
end

-- Default Archon entry for a given scope: the overview row (All
-- Dungeons / All Bosses) when present, else the first encounter.
-- Used to seed previewedBuild whenever Archon mode opens without a
-- specific user pick — so the build dropdown lands on a sensible
-- starting state instead of "Pick an encounter".
local function DefaultArchonEntryForScope(groups, scope)
    if scope == "mplus" then
        return groups.mplusOverview or groups.mplusDungeons[1]
    elseif scope == "raidHeroic" then
        return groups.raidOverviewHeroic or groups.raidHeroicBosses[1]
    elseif scope == "raidMythic" then
        return groups.raidOverviewMythic or groups.raidMythicBosses[1]
    end
    return nil
end

-- Apply the default Archon build for the current scope/spec to the
-- preview. No-op when no Archon data exists. Used when entering Archon
-- mode (or switching scope) without a specific user pick.
local function SeedArchonDefaultPreview()
    local classFile, specName = CurrentClassSpec()
    if not classFile or not specName or not ns.GetArchonSpecData then return end
    local specData = ns.GetArchonSpecData(classFile, specName)
    if not specData or not specData.contexts then return end
    local groups = ns.GroupArchonContexts(specData)
    if not selectedArchonScope then
        selectedArchonScope = ResolveDefaultScope(groups)
    end
    local entry = DefaultArchonEntryForScope(groups, selectedArchonScope)
    if not entry or not entry.ctx or not entry.ctx.builds or not entry.ctx.builds[1] then
        return
    end
    local build = ArchonBuildRecord(entry.ctx, entry.ctx.builds[1])
    build._archonContextKey = entry.contextKey
    SetPreview(build)
end

local function PopulateArchonMenu(rootDescription)
    local classFile, specName = CurrentClassSpec()
    local specData = classFile and specName and ns.GetArchonSpecData
        and ns.GetArchonSpecData(classFile, specName) or nil
    if not specData or not specData.contexts or not next(specData.contexts) then
        rootDescription:CreateTitle((ns.L and ns.L["loadout_dock.no_archon_builds"]) or "No Archon builds available.")
        return
    end

    local groups = ns.GroupArchonContexts(specData)
    if not selectedArchonScope then selectedArchonScope = ResolveDefaultScope(groups) end

    local autoKey = ns.GetActiveArchonContext and ns.GetActiveArchonContext() or nil

    -- The current scope's overview is what we fall back to when there's
    -- no preview and no active match — guarantees the closed dropdown
    -- shows "All Dungeons" / "All Bosses" instead of the placeholder.
    local defaultEntry = DefaultArchonEntryForScope(groups, selectedArchonScope)
    local defaultKey = defaultEntry and defaultEntry.contextKey or nil

    -- Also need to know whether *any* row will report active when the
    -- user has nothing previewed — if yes, the active row wins over
    -- the overview default.
    local anyActiveKey = nil
    do
        local function checkBucket(b)
            if not b then return end
            for _, e in ipairs(b) do
                if e.ctx and e.ctx.builds and e.ctx.builds[1]
                    and BuildMatchesActive({ exportString = e.ctx.builds[1].exportString }) then
                    anyActiveKey = e.contextKey
                    return
                end
            end
        end
        if groups.mplusOverview and groups.mplusOverview.ctx.builds and groups.mplusOverview.ctx.builds[1]
            and BuildMatchesActive({ exportString = groups.mplusOverview.ctx.builds[1].exportString }) then
            anyActiveKey = groups.mplusOverview.contextKey
        end
        if not anyActiveKey then checkBucket(groups.mplusDungeons) end
        if not anyActiveKey and groups.raidOverviewHeroic and groups.raidOverviewHeroic.ctx.builds
            and groups.raidOverviewHeroic.ctx.builds[1]
            and BuildMatchesActive({ exportString = groups.raidOverviewHeroic.ctx.builds[1].exportString }) then
            anyActiveKey = groups.raidOverviewHeroic.contextKey
        end
        if not anyActiveKey then checkBucket(groups.raidHeroicBosses) end
        if not anyActiveKey and groups.raidOverviewMythic and groups.raidOverviewMythic.ctx.builds
            and groups.raidOverviewMythic.ctx.builds[1]
            and BuildMatchesActive({ exportString = groups.raidOverviewMythic.ctx.builds[1].exportString }) then
            anyActiveKey = groups.raidOverviewMythic.contextKey
        end
        if not anyActiveKey then checkBucket(groups.raidMythicBosses) end
    end

    local function addContextRow(entry)
        local ctx = entry.ctx
        if not ctx.builds or not ctx.builds[1] then return end
        local build = ArchonBuildRecord(ctx, ctx.builds[1])
        build._archonContextKey = entry.contextKey
        local isAuto = autoKey == entry.contextKey
        -- Map-based comparison so Archon's exports are recognised as
        -- active after Apply (raw-bit comparison gave false negatives).
        local capturedActive = BuildMatchesActive(build)
        local capturedKey = entry.contextKey
        local capturedIsDefault = (defaultKey == capturedKey)
        local label = FormatArchonRow(ctx, ctx.builds[1], capturedActive, isAuto)
        local item = rootDescription:CreateRadio(
            label,
            function()
                if previewedBuild and previewedBuild._archonContextKey == entry.contextKey then
                    return true
                end
                -- Surface the active build as the closed-state label
                -- when no preview is set.
                if previewedBuild == nil and capturedActive then return true end
                -- Overview fallback: if nothing is previewed AND no
                -- row matches the player's active build, show the
                -- scope's overview (All Dungeons / All Bosses) as the
                -- default selection so the closed dropdown never
                -- displays the empty placeholder.
                if previewedBuild == nil and not anyActiveKey and capturedIsDefault then
                    return true
                end
                return false
            end,
            function()
                if previewedBuild and previewedBuild._archonContextKey == entry.contextKey then
                    SetPreview(nil)
                else
                    SetPreview(build)
                    if ns.SetPersistedArchonContext then
                        ns.SetPersistedArchonContext(entry.contextKey)
                    end
                end
            end
        )
        HookItemBehavior(item, build)
    end

    -- Render only the selected scope. The scope dropdown sits between
    -- source and build, so the build menu just lists encounters within
    -- the chosen bucket — keeping the menu short and focused.
    if selectedArchonScope == "mplus" then
        if groups.mplusOverview then addContextRow(groups.mplusOverview) end
        for _, entry in ipairs(groups.mplusDungeons) do addContextRow(entry) end
    elseif selectedArchonScope == "raidHeroic" then
        if groups.raidOverviewHeroic then addContextRow(groups.raidOverviewHeroic) end
        for _, entry in ipairs(groups.raidHeroicBosses) do addContextRow(entry) end
    elseif selectedArchonScope == "raidMythic" then
        if groups.raidOverviewMythic then addContextRow(groups.raidOverviewMythic) end
        for _, entry in ipairs(groups.raidMythicBosses) do addContextRow(entry) end
    end
end

local function PopulateScopeMenu(_, rootDescription)
    local function makeRadio(label, value)
        rootDescription:CreateRadio(
            label,
            function() return selectedArchonScope == value end,
            function()
                if selectedArchonScope == value then return end
                selectedArchonScope = value
                if scopeDropdown then
                    if scopeDropdown.SetDefaultText then
                        scopeDropdown:SetDefaultText(SCOPE_LABELS[value] or label)
                    end
                    if scopeDropdown.GenerateMenu then scopeDropdown:GenerateMenu() end
                end
                -- Seed the new scope's overview FIRST so the build
                -- dropdown's regenerated radios see the new
                -- previewedBuild via IsSelected. Otherwise the closed
                -- label keeps showing the old scope's pick until the
                -- user clicks the dropdown.
                SeedArchonDefaultPreview()
                if buildDropdown and buildDropdown.GenerateMenu then
                    buildDropdown:GenerateMenu()
                end
            end
        )
    end
    makeRadio(SCOPE_LABELS.mplus, "mplus")
    makeRadio(SCOPE_LABELS.raidHeroic, "raidHeroic")
    makeRadio(SCOPE_LABELS.raidMythic, "raidMythic")
end

-- Icy Veins "build" record matching the shape SetPreview /
-- ApplyTalentExportString expect. IV builds aren't hero-grouped, so
-- heroTalent is "All"; context/buildLabel come straight from the scrape.
local function IcyVeinsBuildRecord(build)
    return {
        heroTalent = "All",
        context = build.context or "Build",
        buildLabel = build.buildLabel,
        exportString = build.exportString,
        recommended = false,
        _ivSource = true,
    }
end

local function SeedIcyVeinsDefaultPreview()
    local classFile, specName = CurrentClassSpec()
    if not classFile or not specName or not ns.GetIcyVeinsTalentSpecData then return end
    local ivData = ns:GetIcyVeinsTalentSpecData(classFile, specName)
    if not ivData or not ivData.talents or not ivData.talents[1] then return end
    SetPreview(IcyVeinsBuildRecord(ivData.talents[1]))
end

local function PopulateIcyVeinsMenu(rootDescription)
    local classFile, specName = CurrentClassSpec()
    local ivData = (classFile and specName and ns.GetIcyVeinsTalentSpecData)
        and ns:GetIcyVeinsTalentSpecData(classFile, specName) or nil
    if not ivData or not ivData.talents or #ivData.talents == 0 then
        rootDescription:CreateTitle((ns.L and ns.L["loadout_dock.no_icyveins_builds"]) or "No Icy Veins talent builds available.")
        return
    end

    for _, build in ipairs(ivData.talents) do
        local label = build.buildLabel or build.context or "Build"
        local isActive = BuildMatchesActive({ exportString = build.exportString })
        if isActive then label = label .. " |cff66ff66(active)|r" end
        local capturedRecord = IcyVeinsBuildRecord(build)
        local capturedExport = build.exportString
        local capturedActive = isActive
        local item = rootDescription:CreateRadio(
            label,
            function()
                if previewedBuild and previewedBuild.exportString == capturedExport then return true end
                if previewedBuild == nil and capturedActive then return true end
                return false
            end,
            function()
                if previewedBuild and previewedBuild.exportString == capturedExport then
                    SetPreview(nil)
                else
                    SetPreview(capturedRecord)
                end
            end
        )
        HookItemBehavior(item, capturedRecord)
    end
end

local function PopulateMenu(_, rootDescription)
    if selectedSource == "archon" then
        PopulateArchonMenu(rootDescription)
    elseif selectedSource == "icyveins" then
        PopulateIcyVeinsMenu(rootDescription)
    elseif selectedSource == "pvp" then
        PopulatePvpMenu(rootDescription)
    else
        PopulateWowheadMenu(rootDescription)
    end
end

-- Per-source UI strings. `label` is shown in the open dropdown menu
-- (with brand icon prefix), `closed` is the short label rendered when
-- the menu is closed, `placeholder` is the build dropdown's placeholder
-- text when no build has been picked yet.
local SOURCE_INFO = {
    wowhead = {
        label = "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:14:14:0:0|t Wowhead",
        closed = "Wowhead",
        placeholder = (ns.L and ns.L["loadout_dock.pick_a_build"]) or "Pick a build",
    },
    archon = {
        label = "|TInterface\\AddOns\\ClassCodex\\Textures\\archon:14:14:0:0|t Archon",
        closed = "Archon",
        placeholder = (ns.L and ns.L["talent_pane.placeholder.encounter"]) or "Pick an encounter",
    },
    icyveins = {
        label = "|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:14:14:0:0|t Icy Veins",
        closed = "Icy Veins",
        placeholder = (ns.L and ns.L["loadout_dock.pick_a_build"]) or "Pick a build",
    },
    pvp = {
        label = "|TInterface\\AddOns\\ClassCodex\\Textures\\bnet:14:14:0:0|t PvP",
        closed = "PvP",
        placeholder = (ns.L and ns.L["talent_pane.placeholder.bracket"]) or "Pick a bracket",
    },
}

local function PopulateSourceMenu(_, rootDescription)
    local function makeRadio(label, value)
        rootDescription:CreateRadio(
            label,
            function() return selectedSource == value end,
            function()
                if selectedSource == value then return end
                selectedSource = value
                SetPreview(nil)
                if ns.SetPersistedTalentSource then
                    ns.SetPersistedTalentSource(value)
                end
                if sourceDropdown then
                    if sourceDropdown.SetDefaultText then
                        local info = SOURCE_INFO[value]
                        sourceDropdown:SetDefaultText((info and info.closed) or label)
                    end
                    if sourceDropdown.GenerateMenu then sourceDropdown:GenerateMenu() end
                end
                if ns._ccRelayoutTalentBuildDropdown then ns._ccRelayoutTalentBuildDropdown() end
                if buildDropdown and buildDropdown.SetDefaultText then
                    local info = SOURCE_INFO[value]
                    buildDropdown:SetDefaultText((info and info.placeholder) or "Pick a build")
                end
                UpdateScopeDropdownVisibility()
                if container then container:SetWidth(GetTargetWidth()) end
                -- Switching INTO Archon or PvP: seed a sensible default
                -- BEFORE regenerating the build menu so the closed
                -- dropdown shows the seeded build, not the placeholder.
                if value == "archon" then SeedArchonDefaultPreview() end
                if value == "icyveins" then SeedIcyVeinsDefaultPreview() end
                if value == "pvp" then SeedPvpDefaultPreview() end
                if buildDropdown and buildDropdown.GenerateMenu then
                    buildDropdown:GenerateMenu()
                end
            end
        )
    end
    makeRadio(SOURCE_INFO.wowhead.label, "wowhead")
    makeRadio(SOURCE_INFO.archon.label, "archon")
    -- Icy Veins always appears too; PopulateIcyVeinsMenu surfaces the
    -- "No Icy Veins talent builds available." copy on uncovered specs.
    makeRadio(SOURCE_INFO.icyveins.label, "icyveins")
    -- PvP source always appears so users discover the feature; if a spec
    -- has no Bnet/Murlok data, PopulatePvpMenu surfaces the "No PvP
    -- builds available." copy instead of bracket rows.
    makeRadio(SOURCE_INFO.pvp.label, "pvp")
end

-------------------------------------------------------------------------------
-- Anchoring + frame creation
-------------------------------------------------------------------------------

local function PersistPanelState()
    if not ClassCodexCharDB then return end
    ClassCodexCharDB.talentPaneOpen = panelExpanded or nil
    ClassCodexCharDB.talentPaneBuild = (previewedBuild and previewedBuild.exportString) or nil
end

local function OnIconClicked()
    -- Toggle the panel open/closed. On first open with no remembered
    -- build, pre-select whichever build matches the player's currently-
    -- applied talents (if any) so the dropdown lands on something
    -- sensible. Build is remembered across collapse; glow only renders
    -- while the panel is open. State is persisted to char SavedVars
    -- so re-opening the talent frame restores the same panel state.
    panelExpanded = not panelExpanded
    if not panelExpanded then
        CloseBuildMenu()
        ClearGlow()
    else
        if not previewedBuild then
            previewedBuild = FindActiveBuild()
        end
        if previewedBuild then
            ApplyGlowForBuild(previewedBuild)
        end
    end
    PersistPanelState()
    UpdateRevealAnimation()
end

local function EnsureContainer()
    if iconBtn then return end
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talentsFrame then return end

    -- A small bordered container wraps the row of icons (CC, Reset,
    -- Export, Apply) so they read as one cohesive widget. Anchored at
    -- the top-right edge of the talent pane, above the divider line.
    container = CreateFrame("Frame", "ClassCodexTalentIconContainer", talentsFrame)
    container:SetHeight(ICON_SIZE + CONTAINER_PADDING_Y * 2)
    container:SetWidth(CONTAINER_PADDING_X * 2 + ICON_SIZE) -- starts at icon-only width
    container:SetFrameStrata("HIGH")
    -- Bottom-left of the talent pane, anchored directly to TalentsFrame's
    -- BOTTOMLEFT. Vertical: clear the action bar, then lift ~3/4 of our
    -- own height plus an additional 1/3 of the icon size for breathing
    -- room. Horizontal: tight against the left edge.
    local containerHeight = ICON_SIZE + CONTAINER_PADDING_Y * 2
    local liftAbove = math.floor(containerHeight * 0.75 + 0.5)
    local extraLift = math.floor(ICON_SIZE / 3 + 0.5)
    container:SetPoint("BOTTOMLEFT", talentsFrame, "BOTTOMLEFT", 8, 40 + liftAbove + extraLift + 6)

    -- Modern rounded Blizzard panel via 9-sliced atlas. Toast-Background
    -- is the small notification panel atlas — clean rounded corners,
    -- subtle inner shading, scales properly at small sizes.
    local bg = container:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetAtlas("Toast-Background", true)

    iconBtn = CreateFrame("Button", "ClassCodexTalentIcon", container)
    iconBtn:SetSize(ICON_SIZE, ICON_SIZE)
    iconBtn:SetPoint("LEFT", container, "LEFT", CONTAINER_PADDING_X, 0)
    iconBtn:RegisterForClicks("LeftButtonUp")

    local icon = iconBtn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\AddOns\\ClassCodex\\icon")
    if not icon:GetTexture() then
        icon:SetAtlas("mechagon-projects")
        icon:SetDesaturated(true)
        icon:SetVertexColor(0.85, 0.85, 0.85)
    end
    iconBtn.icon = icon

    local hl = iconBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.18)

    iconBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Class Codex", 1, 1, 1)
        GameTooltip:AddLine((ns.L and ns.L["loadout_dock.pick_a_build"]) or "Pick a build", 0.7, 0.7, 0.7)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffd100Beta Feature|r", 1, 0.82, 0)
        GameTooltip:AddLine("If any issues please report on the Class Codex Discord.", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:SetScript("OnClick", OnIconClicked)

    -- Source dropdown — picks the data source (Wowhead | Archon).
    -- Default resolves via ns.GetEffectiveTalentSource() (auto-detect on
    -- first open, persisted choice on subsequent opens).
    selectedSource = (ns.GetEffectiveTalentSource and ns.GetEffectiveTalentSource()) or "wowhead"
    sourceDropdown = CreateFrame("DropdownButton", "ClassCodexTalentSourceDropdown", container, "WowStyle1DropdownTemplate")
    sourceDropdown:SetSize(SOURCE_DROPDOWN_WIDTH, ICON_SIZE)
    sourceDropdown:SetPoint("LEFT", iconBtn, "RIGHT", ICON_GAP, 0)
    if sourceDropdown.SetDefaultText then
        local info = SOURCE_INFO[selectedSource] or SOURCE_INFO.wowhead
        sourceDropdown:SetDefaultText(info.closed)
    end
    if sourceDropdown.SetupMenu then
        sourceDropdown:SetupMenu(PopulateSourceMenu)
    end
    sourceDropdown:Hide()
    sourceDropdown:SetAlpha(0)

    -- Scope dropdown — only visible when source = archon. Filters the
    -- build dropdown to a single bucket: M+ / Raid Heroic / Raid Mythic.
    -- Default scope tracks the auto-detected zone, falls back to the
    -- first scope that has data.
    scopeDropdown = CreateFrame("DropdownButton", "ClassCodexTalentScopeDropdown", container, "WowStyle1DropdownTemplate")
    scopeDropdown:SetSize(SCOPE_DROPDOWN_WIDTH, ICON_SIZE)
    scopeDropdown:SetPoint("LEFT", sourceDropdown, "RIGHT", ICON_GAP, 0)
    if scopeDropdown.SetupMenu then
        scopeDropdown:SetupMenu(PopulateScopeMenu)
    end
    -- Initial label tracks the auto-detected scope when known.
    do
        local autoScope = ScopeForContextKey(ns.GetActiveArchonContext and ns.GetActiveArchonContext() or nil)
        selectedArchonScope = autoScope or selectedArchonScope or "mplus"
        if scopeDropdown.SetDefaultText then
            scopeDropdown:SetDefaultText(SCOPE_LABELS[selectedArchonScope] or SCOPE_LABELS.mplus)
        end
    end
    scopeDropdown:Hide()
    scopeDropdown:SetAlpha(0)

    -- Build dropdown — content depends on selected source + scope. Anchor
    -- behaviour:
    --   source = wowhead: anchor to source dropdown (scope hidden).
    --   source = archon : anchor to scope dropdown (sits between).
    -- We update the anchor whenever the source changes so the row stays
    -- visually contiguous.
    buildDropdown = CreateFrame("DropdownButton", "ClassCodexTalentBuildDropdown", container, "WowStyle1DropdownTemplate")
    buildDropdown:SetSize(BUILD_DROPDOWN_WIDTH, ICON_SIZE)
    -- (Anchor is set in RelayoutBuildDropdown below.)
    if buildDropdown.SetDefaultText then
        local info = SOURCE_INFO[selectedSource] or SOURCE_INFO.wowhead
        buildDropdown:SetDefaultText(info.placeholder)
    end
    if buildDropdown.SetupMenu then
        buildDropdown:SetupMenu(PopulateMenu)
    end
    buildDropdown:Hide()
    buildDropdown:SetAlpha(0)

    local function RelayoutBuildDropdown()
        buildDropdown:ClearAllPoints()
        if selectedSource == "archon" then
            buildDropdown:SetPoint("LEFT", scopeDropdown, "RIGHT", ICON_GAP, 0)
        else
            buildDropdown:SetPoint("LEFT", sourceDropdown, "RIGHT", ICON_GAP, 0)
        end
    end
    RelayoutBuildDropdown()
    -- Expose so PopulateSourceMenu can call it on source change.
    ns._ccRelayoutTalentBuildDropdown = RelayoutBuildDropdown

    -- Apply icon — green checkmark, only visible when a build is previewed.
    local function OnActionEnter(self)
        if self.iconTex then
            self.iconTex:SetDesaturated(false)
            self.iconTex:SetVertexColor(1, 1, 1)
        end
        if self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end
    end
    local function OnActionLeave(self)
        if self.iconTex then
            self.iconTex:SetDesaturated(true)
            self.iconTex:SetVertexColor(0.85, 0.85, 0.85)
        end
        GameTooltip:Hide()
    end
    local function MakeActionIcon(name, parent, texture, tooltip, onClick)
        local b = CreateFrame("Button", name, parent)
        b:SetSize(ACTION_ICON_SIZE, ACTION_ICON_SIZE)
        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(texture)
        tex:SetDesaturated(true)
        tex:SetVertexColor(0.85, 0.85, 0.85)
        b.iconTex = tex
        b.tooltipText = tooltip
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.18)
        b:SetScript("OnEnter", OnActionEnter)
        b:SetScript("OnLeave", OnActionLeave)
        b:SetScript("OnClick", onClick)
        b:Hide()
        b:SetAlpha(0) -- start invisible so the reveal animation has somewhere to lerp to
        return b
    end

    -- Order after the inline dropdown: Export -> Apply.
    -- The CC icon click handles open/close (replacing what an X would
    -- have done), so each control here has a distinct purpose.
    copyBtn = MakeActionIcon(
        "ClassCodexTalentExportButton", container,
        "Interface\\Buttons\\UI-GuildButton-PublicNote-Up",
        "Export build string",
        function()
            if previewedBuild then ShowCopyPopup(previewedBuild.exportString) end
        end
    )
    copyBtn:SetPoint("LEFT", buildDropdown, "RIGHT", ICON_GAP, 0)

    applyBtn = MakeActionIcon(
        "ClassCodexTalentApplyButton", container,
        "Interface\\Buttons\\UI-CheckBox-Check",
        "Apply previewed build",
        OnApplyClicked
    )
    applyBtn:SetPoint("LEFT", copyBtn, "RIGHT", ICON_GAP, 0)
    -- Dynamic tooltip — reads previewedBuild state at hover time.
    applyBtn:SetScript("OnEnter", function(self)
        if self.iconTex then
            self.iconTex:SetDesaturated(false)
            self.iconTex:SetVertexColor(1, 1, 1)
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if previewedBuild and IsActiveBuild(previewedBuild) then
            GameTooltip:AddLine("This is the applied build", 0.7, 0.85, 0.5)
        else
            GameTooltip:AddLine("Apply previewed build", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
end

-------------------------------------------------------------------------------
-- Visibility (tab tracking)
-------------------------------------------------------------------------------

local function IsTalentsTabActive()
    if not PlayerSpellsFrame or not PlayerSpellsFrame.IsFrameTabActive then return false end
    local util = _G.PlayerSpellsUtil
    if not util or not util.FrameTabs or not util.FrameTabs.ClassTalents then return false end
    local ok, active = pcall(PlayerSpellsFrame.IsFrameTabActive, PlayerSpellsFrame, util.FrameTabs.ClassTalents)
    return ok and active
end

local function FindBuildByExportString(exportString)
    if not exportString then return nil end
    local specData = GetEffectiveSpecData()
    if specData and specData.talents then
        for _, build in ipairs(specData.talents) do
            if build.exportString == exportString then return build end
        end
    end
    local classFile, specName = CurrentClassSpec()
    if classFile and specName and ns.FindArchonBuildByExportString then
        local b = ns.FindArchonBuildByExportString(classFile, specName, exportString)
        if b then return b end
    end
    return nil
end

local function RestorePanelState()
    if not ClassCodexCharDB then return end
    if ClassCodexCharDB.talentPaneOpen then
        panelExpanded = true
        if not previewedBuild and ClassCodexCharDB.talentPaneBuild then
            previewedBuild = FindBuildByExportString(ClassCodexCharDB.talentPaneBuild)
        end
        if not previewedBuild then
            previewedBuild = FindActiveBuild()
        end
        if previewedBuild then
            ApplyGlowForBuild(previewedBuild)
        end
    end
end

local function IsTalentPaneEnabled()
    -- Gate the integration on a Settings checkbox stored in
    -- ClassCodexDB.talentPaneEnabled. nil means default (enabled).
    if ClassCodexDB == nil then return true end
    if ClassCodexDB.talentPaneEnabled == nil then return true end
    return ClassCodexDB.talentPaneEnabled and true or false
end

local function UpdateVisibility()
    if not container then return end
    if PlayerSpellsFrame and PlayerSpellsFrame:IsShown() and IsTalentsTabActive() and IsTalentPaneEnabled() then
        -- Re-evaluate inspect mode every time the frame becomes visible.
        -- Blizzard reuses the same TalentsFrame; we mirror that by
        -- detecting the inspect signal on each show.
        local prev = inspectOverride
        RefreshInspectOverride()
        if prev ~= inspectOverride then
            -- Spec/class changed (or inspect entered/exited): drop any
            -- preview from the previous context, invalidate the active-
            -- tree cache (configID + treeID both change), drop the
            -- build-parse cache (a build's parse depends on tree +
            -- configID), and rebuild the dropdowns.
            previewedBuild = nil
            ClearGlow()
            InvalidateActiveMap()
            wipe(buildMapCache)
            -- Re-resolve effective source for the new spec.
            selectedSource = (ns.GetEffectiveTalentSource and ns.GetEffectiveTalentSource()) or "wowhead"
            selectedArchonScope = nil
            selectedPvpBracket = nil
            if sourceDropdown then
                if sourceDropdown.SetDefaultText then
                    local _info = SOURCE_INFO[selectedSource]
                    sourceDropdown:SetDefaultText((_info and _info.closed) or "Wowhead")
                end
                if sourceDropdown.GenerateMenu then sourceDropdown:GenerateMenu() end
            end
            if ns._ccRelayoutTalentBuildDropdown then ns._ccRelayoutTalentBuildDropdown() end
            if buildDropdown and buildDropdown.SetDefaultText then
                local info = SOURCE_INFO[selectedSource]
                buildDropdown:SetDefaultText((info and info.placeholder) or SOURCE_INFO.wowhead.placeholder)
            end
            -- Seed the Archon overview as the default preview when no
            -- explicit pick exists yet, so the closed dropdown shows
            -- "All Dungeons" / "All Bosses" instead of the placeholder.
            if selectedSource == "archon" then SeedArchonDefaultPreview() end
            if buildDropdown and buildDropdown.GenerateMenu then buildDropdown:GenerateMenu() end
        end
        container:Show()
        -- Restore the saved open/closed state on first show.
        RestorePanelState()
        -- After RestorePanelState may have left previewedBuild nil
        -- (no saved build, or saved build couldn't be resolved), make
        -- sure Archon mode lands on its overview default rather than
        -- the empty placeholder.
        if selectedSource == "archon" and not previewedBuild then
            SeedArchonDefaultPreview()
            if buildDropdown and buildDropdown.GenerateMenu then buildDropdown:GenerateMenu() end
        end
        UpdateRevealAnimation()
    else
        CloseBuildMenu()
        container:Hide()
        ClearGlow()
        previewedBuild = nil
        panelExpanded = false
        if applyBtn then applyBtn:Hide(); applyBtn:SetAlpha(0) end
        if copyBtn then copyBtn:Hide(); copyBtn:SetAlpha(0) end
        if sourceDropdown then sourceDropdown:Hide(); sourceDropdown:SetAlpha(0) end
        if scopeDropdown then scopeDropdown:Hide(); scopeDropdown:SetAlpha(0) end
        if buildDropdown then buildDropdown:Hide(); buildDropdown:SetAlpha(0) end
        container:SetWidth(GetIdleWidth())
    end
end

-------------------------------------------------------------------------------
-- Setup (after Blizzard_PlayerSpells is loaded)
-------------------------------------------------------------------------------

local function Setup()
    if setupDone then return end
    if not IsTalentPaneEnabled() then return end
    if not PlayerSpellsFrame or not PlayerSpellsFrame.TalentsFrame then return end
    setupDone = true

    EnsureContainer()
    if not container then setupDone = false; return end

    PlayerSpellsFrame:HookScript("OnShow", UpdateVisibility)
    PlayerSpellsFrame:HookScript("OnHide", UpdateVisibility)

    -- Hook the inspect state setter directly. INSPECT_READY fires before
    -- Blizzard calls SetInspecting, so listening only on the event would
    -- check IsInspecting() too early; by the time this hook runs the
    -- frame's inspect state and configID are already updated.
    --
    -- Debounce to next frame: Blizzard sometimes calls SetInspecting(nil)
    -- followed immediately by SetInspecting(unit) within the same frame
    -- (e.g. during a target spec change or tab refresh). Running
    -- UpdateVisibility synchronously on each call would briefly clear
    -- the override on the first call, causing a visible reset to the
    -- local player's data before the second call restored it. Coalescing
    -- both calls into a single deferred refresh skips the flicker.
    if PlayerSpellsFrame.SetInspecting then
        local pending = false
        local function deferredUpdate()
            pending = false
            UpdateVisibility()
        end
        pcall(hooksecurefunc, PlayerSpellsFrame, "SetInspecting", function()
            if pending then return end
            pending = true
            if C_Timer and C_Timer.After then
                C_Timer.After(0, deferredUpdate)
            else
                deferredUpdate()
            end
        end)
    end

    if _G.EventRegistry and EventRegistry.RegisterCallback then
        pcall(EventRegistry.RegisterCallback, EventRegistry, "PlayerSpellsFrame.TabSet", UpdateVisibility, container)
    end

    -- Cache invalidation on talent / config changes; refresh preview if any.
    -- TRAIT_TREE_CURRENCY_INFO_UPDATED fires on every staged
    -- allocation/refund (per click), so the diff updates live as the
    -- user matches the previewed build — highlights drop off matching
    -- nodes immediately. TRAIT_CONFIG_UPDATED only fires on commit.
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("TRAIT_TREE_CURRENCY_INFO_UPDATED")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("INSPECT_READY")
    -- Exposed so ImportExport.lua can explicitly trigger a refresh
    -- after a talent apply commit completes (the apply-in-progress
    -- flag suppresses the event-driven path so it doesn't fire
    -- mid-cast, and this gives a clean post-cast hook).
    ns._refreshTalentDiff = function()
        InvalidateActiveMap()
        local current = previewedBuild
        previewedBuild = nil
        SetPreview(current)
        if buildDropdown and buildDropdown.GenerateMenu then
            buildDropdown:GenerateMenu()
        end
    end

    -- Debounce trait-state events. PurchaseRank fires a flurry of
    -- TRAIT_TREE_CURRENCY_INFO_UPDATED during any bulk apply (our own
    -- + every other talent-loadout addon's), and re-running
    -- InvalidateActiveMap → GetActiveMap (60 GetNodeInfo calls) →
    -- ComputeDiff → ApplyGlow on every single one freezes the client.
    -- The generation counter cancels in-flight refreshes when a newer
    -- event arrives, so a 60-event burst collapses to a single trailing
    -- refresh. Our own apply still fast-paths via _talentApplyInProgress
    -- and the explicit _refreshTalentDiff post-cast.
    -- Cache invalidation already happened in the event handler; here
    -- we only do the user-visible refresh (re-paint glow against
    -- whatever is now in the active map, regenerate the build menu).
    local refreshGen = 0
    local function ScheduleTraitRefresh()
        refreshGen = refreshGen + 1
        local thisGen = refreshGen
        C_Timer.After(0.15, function()
            if thisGen ~= refreshGen then return end
            local current = previewedBuild
            previewedBuild = nil  -- force SetPreview to re-render
            SetPreview(current)
            if buildDropdown and buildDropdown.GenerateMenu then
                buildDropdown:GenerateMenu()
            end
        end)
    end

    eventFrame:SetScript("OnEvent", function(_, event)
        if ns._talentApplyInProgress then return end

        if event == "INSPECT_READY" then
            -- Re-resolve the inspect target now that talents are loaded
            -- on the inspected unit. UpdateVisibility handles the full
            -- spec-changed flow.
            InvalidateActiveMap()
            UpdateVisibility()
            return
        end
        if event == "PLAYER_SPECIALIZATION_CHANGED" then
            -- New spec = different builds; drop the preview immediately.
            InvalidateActiveMap()
            SetPreview(nil)
            return
        end

        -- TRAIT_CONFIG_UPDATED / TRAIT_TREE_CURRENCY_INFO_UPDATED —
        -- bursty. The cache invalidation itself is cheap (just clears a
        -- few locals), so always run it so the next time the user
        -- expands the icon they read fresh state. The expensive part
        -- is the diff + glow re-paint inside ScheduleTraitRefresh —
        -- skip that when the picker isn't expanded, since there's
        -- nothing visible to update.
        InvalidateActiveMap()
        if not panelExpanded then return end
        ScheduleTraitRefresh()
    end)

    -- React to zone/encounter transitions: re-evaluate effective source
    -- (auto-detect → archon when entering an instance), align the scope
    -- dropdown with the new zone, and refresh the build dropdown so the
    -- highlighted auto row tracks the current zone.
    if ns.RegisterArchonContextCallback then
        ns.RegisterArchonContextCallback(function(contextKey)
            -- Auto-flip the source only if the user hasn't pinned one
            -- for this spec yet.
            if ns.GetPersistedTalentSource and not ns.GetPersistedTalentSource() then
                local effective = ns.GetEffectiveTalentSource and ns.GetEffectiveTalentSource() or "wowhead"
                if effective ~= selectedSource then
                    selectedSource = effective
                    if sourceDropdown and sourceDropdown.SetDefaultText then
                        local _info = SOURCE_INFO[selectedSource]
                        sourceDropdown:SetDefaultText((_info and _info.closed) or "Wowhead")
                    end
                    if sourceDropdown and sourceDropdown.GenerateMenu then
                        sourceDropdown:GenerateMenu()
                    end
                    if ns._ccRelayoutTalentBuildDropdown then ns._ccRelayoutTalentBuildDropdown() end
                    if buildDropdown and buildDropdown.SetDefaultText then
                        local info = SOURCE_INFO[selectedSource]
                        buildDropdown:SetDefaultText((info and info.placeholder) or SOURCE_INFO.wowhead.placeholder)
                    end
                    UpdateScopeDropdownVisibility()
                    if container then container:SetWidth(GetTargetWidth()) end
                end
            end
            -- Always re-align the scope to the new zone when an auto
            -- context exists (cheap; user can override at any time).
            local newScope = ScopeForContextKey(contextKey)
            if newScope and newScope ~= selectedArchonScope then
                selectedArchonScope = newScope
                if scopeDropdown then
                    if scopeDropdown.SetDefaultText then
                        scopeDropdown:SetDefaultText(SCOPE_LABELS[newScope] or "Mythic+")
                    end
                    if scopeDropdown.GenerateMenu then scopeDropdown:GenerateMenu() end
                end
            end
            -- If we're in Archon mode but nothing is previewed yet,
            -- seed the new scope's overview as the default so the
            -- build dropdown shows "All Dungeons" / "All Bosses"
            -- instead of the placeholder.
            if selectedSource == "archon" and not previewedBuild then
                SeedArchonDefaultPreview()
            end
            if buildDropdown and buildDropdown.GenerateMenu then
                buildDropdown:GenerateMenu()
            end
        end)
    end

    UpdateVisibility()
end

local function IsPlayerSpellsLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells")
    elseif _G.IsAddOnLoaded then
        return IsAddOnLoaded("Blizzard_PlayerSpells")
    end
    return false
end

-- Toggle handler for the Settings checkbox. Called when the user
-- Diagnostic — printed by /cc inspectdump. Surfaces every link in the
-- inspect → diff → glow chain so we can see exactly where the path
-- breaks when the highlight doesn't appear.
function ns.DumpInspectState()
    local function p(...) print("|cff00ccffCC inspect:|r", ...) end
    p("--- start ---")
    p("inspectOverride:", inspectOverride and (inspectOverride.classFile .. "/" .. inspectOverride.specName) or "nil")
    p("ns._talentPaneInspect:", ns._talentPaneInspect and "set" or "nil")

    if PlayerSpellsFrame then
        local isInspecting = PlayerSpellsFrame.IsInspecting and PlayerSpellsFrame:IsInspecting() or false
        p("PlayerSpellsFrame:IsInspecting:", tostring(isInspecting))
        local unit = PlayerSpellsFrame.GetInspectUnit and PlayerSpellsFrame:GetInspectUnit() or nil
        p("GetInspectUnit:", tostring(unit), unit and ("exists=" .. tostring(UnitExists(unit))) or "")
        if unit and UnitExists(unit) then
            p("  UnitClass:", select(2, UnitClass(unit)))
            p("  GetInspectSpecialization:", tostring(GetInspectSpecialization(unit)))
        end
    end

    local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if tf and tf.GetConfigID then
        local ok, id = pcall(tf.GetConfigID, tf)
        p("TalentsFrame:GetConfigID:", ok and tostring(id) or "ERR")
    else
        p("TalentsFrame:GetConfigID: method missing")
    end
    p("INSPECT_CONFIG_ID constant:", tostring(INSPECT_CONFIG_ID))
    p("VIEW_TRAIT_CONFIG_ID:", tostring(Constants and Constants.TraitConsts and Constants.TraitConsts.VIEW_TRAIT_CONFIG_ID))

    local cid = GetActiveConfigID()
    p("GetActiveConfigID returns:", tostring(cid))
    if cid then
        local info = C_Traits.GetConfigInfo(cid)
        p("  GetConfigInfo:", info and "ok" or "nil")
        if info then
            p("  treeIDs:", info.treeIDs and table.concat(info.treeIDs, ",") or "nil")
            if info.treeIDs and info.treeIDs[1] then
                local nodes = C_Traits.GetTreeNodes(info.treeIDs[1])
                p("  GetTreeNodes count:", nodes and #nodes or 0)
                local purchased = 0
                if nodes then
                    for _, n in ipairs(nodes) do
                        local ni = C_Traits.GetNodeInfo(cid, n)
                        if ni and ni.ranksPurchased and ni.ranksPurchased > 0 then
                            purchased = purchased + 1
                        end
                    end
                end
                p("  nodes with ranksPurchased>0:", purchased)
            end
        end
    end

    p("panelExpanded:", tostring(panelExpanded))
    p("previewedBuild:", previewedBuild and ((previewedBuild._archonContextKey or "") .. " " .. (previewedBuild.heroTalent or "")) or "nil")
    if previewedBuild then
        local bm = GetBuildMap(previewedBuild.exportString)
        p("  buildMap:", bm and "ok" or "nil")
        if bm then
            local count = 0
            for _ in pairs(bm) do count = count + 1 end
            p("  buildMap node count:", count)
        end
    end

    local am = GetActiveMap()
    p("activeMap:", am and "ok" or "nil")
    if am then
        local count = 0
        for _ in pairs(am) do count = count + 1 end
        p("  activeMap node count:", count)
    end

    if previewedBuild and tf and tf.GetTalentButtonByNodeID then
        local bm = GetBuildMap(previewedBuild.exportString)
        if bm and am then
            local adds, removes, changes = ComputeDiff(bm, am)
            p("diff: adds=" .. #adds, "removes=" .. #removes, "changes=" .. #changes)
            local sample = adds[1] or changes[1] or removes[1]
            if sample then
                local btn = tf:GetTalentButtonByNodeID(sample)
                p("  GetTalentButtonByNodeID(" .. sample .. "):", btn and "got button" or "nil")
            end
        end
    end
    p("--- end ---")
end

-- enables/disables the talent pane integration. UpdateVisibility
-- now reads the setting on its own, so all we need to do here is
-- (a) run Setup if enabling and it never ran, and (b) trigger a
-- re-evaluation of visibility immediately. We also explicitly hide
-- every child widget on disable so nothing remains on screen even
-- if the container's anchor / strata is somehow off.
function ns.SetTalentPaneEnabled(enabled)
    if enabled then
        if not setupDone and IsPlayerSpellsLoaded() then
            Setup()
        end
    else
        if container then
            CloseBuildMenu()
            ClearGlow()
            previewedBuild = nil
            panelExpanded = false
            if iconBtn then iconBtn:Hide() end
            if sourceDropdown then sourceDropdown:Hide(); sourceDropdown:SetAlpha(0) end
            if scopeDropdown then scopeDropdown:Hide(); scopeDropdown:SetAlpha(0) end
            if buildDropdown then buildDropdown:Hide(); buildDropdown:SetAlpha(0) end
            if applyBtn then applyBtn:Hide(); applyBtn:SetAlpha(0) end
            if copyBtn then copyBtn:Hide(); copyBtn:SetAlpha(0) end
            container:Hide()
        end
    end
    -- Re-run visibility logic to settle into the right state right now,
    -- regardless of whether the talent frame is open or not.
    if container then UpdateVisibility() end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_PlayerSpells" then
            Setup()
            if setupDone then self:UnregisterEvent("ADDON_LOADED") end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if IsPlayerSpellsLoaded() then Setup() end
        if setupDone then self:UnregisterEvent("PLAYER_ENTERING_WORLD") end
    end
end)
