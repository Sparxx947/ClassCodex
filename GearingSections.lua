local _, ns = ...

-- Panel-side dispatcher for the gearing tabs (Enhancements / Trinkets /
-- Crafting / BiS Gear). Owns:
--   - the InitPanel handles for each Section module's section frame
--   - UpdateGearingSections — resolves data and delegates to each module's
--     RenderPanel, then enforces tab visibility
--   - LayoutGearingSections — positions the section frames in the panel's
--     scrollable content area
-- The shared helpers (item cache, format/quality lookups, BiS reverse
-- lookups, row icon/tooltip factories, PvP shape wrappers) live in
-- Shared/GearingUtils.lua so every Section module + the Compendium can
-- reuse them.

local L = ns.L
local ROW_HEIGHT = ns.ROW_HEIGHT
local SECTION_HEADER_HEIGHT = ns.SECTION_HEADER_HEIGHT
local PvP = ns.GearingPvP

-------------------------------------------------------------------------------
-- Init: build out each gearing Section's panel-side frames.
-------------------------------------------------------------------------------

-- Enhancements (Enchants + Gems + Consumables + source dropdown).
local _enhanceFrames = ns.Sections.Enhancements.InitPanel({
    parent = ns.contentFrame,
    refresh = function()
        ns:UpdateGearingSections()
        ns:LayoutPanel()
    end,
})
local enchantSection = _enhanceFrames.enchSection
local gemSection     = _enhanceFrames.gemSection
local consumSection  = _enhanceFrames.consumSection

local trinketSection = ns.Sections.Trinkets.InitPanel(ns.contentFrame)
local trinketCollapsed = false

-- Crafting now mirrors the Enhancements pattern: two top-level
-- collapsible sections (Crafts + Embellishments) plus a context
-- dropdown that sits above them.
local _craftingFrames = ns.Sections.Crafting.InitPanel({
    parent = ns.contentFrame,
    refresh = function()
        ns:UpdateGearingSections()
        ns:LayoutPanel()
    end,
})
local craftsSection = _craftingFrames.craftsSection
local embsSection   = _craftingFrames.embsSection

local bisSection = ns.Sections.Gear.InitPanel(ns.contentFrame)
local bisCollapsed = false

-------------------------------------------------------------------------------
-- Update
-------------------------------------------------------------------------------

local lastEnchantHeight = 0
local lastGemCount = 0
local lastConsumCount = 0
local lastTrinketCount = 0
local lastCraftsCount = 0
local lastEmbsCount = 0
local lastBisCount = 0

function ns:UpdateGearingSections()
    ns.Sections.Enhancements.HidePanelSourceDropdown()
    ns.Sections.Enhancements.RestorePanelCollapsedState(
        ClassCodexCharDB and ClassCodexCharDB.collapsed
    )

    local gearData = ns.GetSpecGearData()
    ns.RequestAllItems(gearData)

    -- Also request IV items so they're ready when user switches source.
    local playerClass = select(2, UnitClass("player"))
    local playerSpecKey = ns.GetSpecKey()
    local playerSpec = playerSpecKey and (playerSpecKey:match("-(.+)") or playerSpecKey)
    local ivSpecData = playerClass and playerSpec and ns:GetIcyVeinsSpecData(playerClass, playerSpec)
    if ivSpecData and ivSpecData.bisGear then
        for _, tab in ipairs(ivSpecData.bisGear) do
            for _, g in ipairs(tab.slots) do ns.RequestItemData(g.item.itemId) end
        end
    end

    -- Same for Archon gear so items are ready when the user switches source.
    local archonSpecData = playerClass and playerSpec and ns:GetArchonGearSpecData(playerClass, playerSpec)
    if archonSpecData and archonSpecData.bisGear then
        for _, tab in ipairs(archonSpecData.bisGear) do
            for _, g in ipairs(tab.slots) do ns.RequestItemData(g.item.itemId) end
        end
    end

    local enchHeight, gemCount, consumCount = ns.Sections.Enhancements.RenderPanel({
        wowheadEnchants = gearData and gearData.enchants,
        wowheadGems     = gearData and gearData.gems,
        consumables     = gearData and gearData.consumables,
        pvpEnchants     = PvP.enchants(),
        pvpGems         = PvP.gems(),
        showSourceDropdown = ns.getActiveTab and ns.getActiveTab() == "enhancements",
        specKey         = ns.GetSpecKey() or "",
        sourceLabels    = ns.ENH_SOURCE_LABELS,
        onChange        = function()
            ns:UpdateGearingSections()
            ns:LayoutPanel()
        end,
    })
    lastEnchantHeight = enchHeight
    lastGemCount = gemCount
    lastConsumCount = consumCount

    lastTrinketCount = ns.Sections.Trinkets.RenderPanel({
        trinkets = gearData and gearData.trinkets,
        onChange = function()
            ns:UpdateGearingSections()
            ns:LayoutPanel()
        end,
    })
    if lastTrinketCount == 0 then trinketSection:Hide() end

    local craftClassToken, craftSpec = ns.GetPlayerClassSpec()
    local craftResult = ns.Sections.Crafting.RenderPanel({
        class = craftClassToken,
        spec  = craftSpec,
    })
    lastCraftsCount = craftResult.crafts or 0
    lastEmbsCount   = craftResult.embs or 0

    local _classToken = select(2, UnitClass("player"))
    local _specKey = ns.GetSpecKey()
    local _spec = _specKey and (_specKey:match("-(.+)") or _specKey)
    local _ivSpec = _classToken and _spec and ns:GetIcyVeinsSpecData(_classToken, _spec)
    local _archonSpec = _classToken and _spec and ns:GetArchonGearSpecData(_classToken, _spec)
    lastBisCount = ns.Sections.Gear.RenderPanel({
        wowheadBis = gearData and gearData.bisGear,
        ivBis      = _ivSpec and _ivSpec.bisGear,
        archonBis  = _archonSpec and _archonSpec.bisGear,
        pvpBis     = PvP.bis(),
        onChange   = function()
            ns:UpdateGearingSections()
            ns:LayoutPanel()
        end,
    })

    -- Tab visibility: each gearing section shows on its tab.
    local tab = ns.getActiveTab()
    if tab ~= "enhancements" then
        enchantSection:Hide()
        gemSection:Hide()
        consumSection:Hide()
    end
    if tab ~= "crafting" then
        _craftingFrames.ctxDropdown:Hide()
        craftsSection:Hide()
        embsSection:Hide()
    end
    if tab ~= "trinkets" then trinketSection:Hide() end
    if tab ~= "bis" then bisSection:Hide() end
    if tab ~= "enhancements" and tab ~= "crafting"
        and tab ~= "trinkets" and tab ~= "bis" then return end

    -- Per-mode section visibility (right-click pin menu).
    if ClassCodexDB then
        local prefix = ns.isFloating() and "floatShow" or "dockShow"
        if not ClassCodexDB[prefix .. "Enchants"] then enchantSection:Hide() end
        if not ClassCodexDB[prefix .. "Gems"] then gemSection:Hide() end
        if not ClassCodexDB[prefix .. "Consumables"] then consumSection:Hide() end
        if not ClassCodexDB[prefix .. "Trinkets"] then trinketSection:Hide() end
        -- Crafts and Embellishments toggle independently (issue #618).
        -- Hide each section per its own toggle, but only hide the context
        -- dropdown when BOTH are off — a Crafts-only or Embellishments-
        -- only user still needs the Raid/M+/PvP picker above the cards.
        local showCrafts = ClassCodexDB[prefix .. "Crafts"] ~= false
        local showEmbs   = ClassCodexDB[prefix .. "Embellishments"] ~= false
        if not showCrafts then craftsSection:Hide() end
        if not showEmbs   then embsSection:Hide() end
        if not showCrafts and not showEmbs then
            _craftingFrames.ctxDropdown:Hide()
        end
        if not ClassCodexDB[prefix .. "BisGear"] then bisSection:Hide() end
    end
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

function ns:LayoutGearingSections(y)
    local function LayoutSection(section, collapsed, contentHeight, headerH)
        if not section:IsShown() then return y end
        local hdrH = headerH or SECTION_HEADER_HEIGHT
        section:ClearAllPoints()
        section:SetPoint("TOPLEFT", ns.contentFrame, "TOPLEFT", ns.CONTENT_INSET, y)
        section:SetPoint("RIGHT", ns.contentFrame, "RIGHT", -ns.CONTENT_INSET, 0)
        local sectionHeight = hdrH
        if not collapsed then sectionHeight = sectionHeight + contentHeight + 4 end
        section:SetHeight(sectionHeight)
        y = y - sectionHeight - 3
        return y
    end

    -- Enhancements source dropdown sits ABOVE the enchants section header.
    local enhFrames = ns.Sections.Enhancements.GetPanelFrames()
    if enhFrames.sourceDropdown:IsShown() then
        enhFrames.sourceDropdown:ClearAllPoints()
        enhFrames.sourceDropdown:SetPoint("TOPLEFT", ns.contentFrame, "TOPLEFT", ns.CONTENT_INSET, y)
        enhFrames.sourceDropdown:SetPoint("RIGHT", ns.contentFrame, "RIGHT", -ns.CONTENT_INSET, 0)
        y = y - 30
    end
    y = LayoutSection(enhFrames.enchSection, enhFrames.enchCollapsed, lastEnchantHeight)
    y = LayoutSection(enhFrames.gemSection, enhFrames.gemCollapsed, lastGemCount * ROW_HEIGHT)
    y = LayoutSection(enhFrames.consumSection, enhFrames.consumCollapsed, lastConsumCount * ROW_HEIGHT)

    local trinketContentHeight = lastTrinketCount * ROW_HEIGHT
    if ns.Sections.Trinkets.IsPanelCtxDropdownShown() then
        trinketContentHeight = trinketContentHeight + 30
    end
    y = LayoutSection(trinketSection, trinketCollapsed, trinketContentHeight)

    -- Crafting: dropdown sits above the two collapsible sections.
    local cFrames = ns.Sections.Crafting.GetPanelFrames()
    local craftCardH = ns.Sections.Crafting.GetPanelCardHeight()
    if cFrames.ctxDropdown:IsShown() then
        cFrames.ctxDropdown:ClearAllPoints()
        cFrames.ctxDropdown:SetPoint("TOPLEFT", ns.contentFrame, "TOPLEFT", ns.CONTENT_INSET, y)
        cFrames.ctxDropdown:SetPoint("RIGHT", ns.contentFrame, "RIGHT", -ns.CONTENT_INSET, 0)
        y = y - 30
    end
    y = LayoutSection(cFrames.craftsSection, cFrames.craftsCollapsed, lastCraftsCount * craftCardH)
    y = LayoutSection(cFrames.embsSection, cFrames.embsCollapsed, lastEmbsCount * craftCardH)

    local bisContentHeight = lastBisCount * ROW_HEIGHT
    if ns.Sections.Gear.IsPanelSourceDropdownShown() then bisContentHeight = bisContentHeight + 30 end
    if ns.Sections.Gear.IsPanelTabDropdownShown() then bisContentHeight = bisContentHeight + 30 end
    if ns.Sections.Gear.IsPanelFallbackShown() then bisContentHeight = bisContentHeight + 20 end
    y = LayoutSection(bisSection, bisCollapsed, bisContentHeight)

    return y
end

-------------------------------------------------------------------------------
-- Section Visibility Options (for pin right-click menu)
-------------------------------------------------------------------------------

ns.gearingFloatOptions = {
    { key = "floatShowEnchants", label = L["tab.enchants"] },
    { key = "floatShowGems", label = L["tab.gems"] },
    { key = "floatShowConsumables", label = L["tab.consumables"] },
    { key = "floatShowTrinkets", label = L["tab.trinkets"] },
    { key = "floatShowCrafts", label = L["crafting.section_crafts"] },
    { key = "floatShowEmbellishments", label = L["crafting.section_embellishments"] },
    { key = "floatShowBisGear", label = L["tab.bis_gear"] },
}

ns.gearingDockOptions = {
    { key = "dockShowEnchants", label = L["tab.enchants"] },
    { key = "dockShowGems", label = L["tab.gems"] },
    { key = "dockShowConsumables", label = L["tab.consumables"] },
    { key = "dockShowTrinkets", label = L["tab.trinkets"] },
    { key = "dockShowCrafts", label = L["crafting.section_crafts"] },
    { key = "dockShowEmbellishments", label = L["crafting.section_embellishments"] },
    { key = "dockShowBisGear", label = L["tab.bis_gear"] },
}
