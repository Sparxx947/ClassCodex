local addonName, ns = ...

local DATA = ClassCodexData
local GEAR_DATA = ClassCodexGearData
if not DATA then
    -- Ensure OpenCompendium exists even if data failed to load
    function ns:OpenCompendium()
        print("|cff00ccffClass Codex:|r " .. ns.L["chat.compendium_data_not_loaded"])
    end
    return
end

local L = ns.L

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local FRAME_WIDTH = 540
local FRAME_HEIGHT = 480
local INSET_PAD = 8
local ROW_HEIGHT = 22
local SECTION_HEADER_HEIGHT = 24
-- Initial pool sizes for the Talents section. Pools grow on demand
-- (EnsureTalentButton / EnsureTalentHeroHeader); these are just the
-- pre-allocations so the common Wowhead-only render hits no cold path.
-- Archon adds ~27 contexts × 2 hero talents per spec, so the dynamic
-- growth path is what makes the Talents tab cover all sources without
-- truncation.
local MAX_TALENT_BUTTONS = 16
local MAX_TALENT_HERO_HEADERS = 6
local TALENT_HERO_HEADER_HEIGHT = 22
local TALENT_BTN_HEIGHT = 22
local TALENT_BTN_GAP = 4

local RANK_COLORS = {
    { r = 0.64, g = 0.21, b = 0.93 },
    { r = 0.00, g = 0.44, b = 0.87 },
    { r = 0.12, g = 1.00, b = 0.00 },
    { r = 1.00, g = 1.00, b = 1.00 },
    { r = 0.62, g = 0.62, b = 0.62 },
}

local TIER_COLORS = {
    S = { r = 1.00, g = 0.50, b = 0.00 },
    A = { r = 0.64, g = 0.21, b = 0.93 },
    B = { r = 0.00, g = 0.44, b = 0.87 },
    C = { r = 0.12, g = 1.00, b = 0.00 },
    D = { r = 0.62, g = 0.62, b = 0.62 },
}

local TIER_ORDER = { S = 1, A = 2, B = 3, C = 4, D = 5 }

local CONTEXT_LABELS = {
    raid = L["context.raid"],
    dungeon = L["context.dungeon"],
    delves = L["context.delves"],
    crafting = L["context.crafting"],
}

local CONSUMABLE_ORDER = { "flask", "combatPotion", "food", "weaponBuff", "augmentRune" }
local CONSUMABLE_LABELS = {
    flask = L["consumable.flask"],
    combatPotion = L["consumable.combat_potion"],
    food = L["consumable.food"],
    weaponBuff = L["consumable.weapon_buff"],
    augmentRune = L["consumable.augment_rune"],
}

local SPEC_KEYS = {
    DEATHKNIGHT  = { "blood", "frost", "unholy" },
    DEMONHUNTER  = { "havoc", "vengeance", "devourer" },
    DRUID        = { "balance", "feral", "guardian", "restoration" },
    EVOKER       = { "devastation", "preservation", "augmentation" },
    HUNTER       = { "beast-mastery", "marksmanship", "survival" },
    MAGE         = { "arcane", "fire", "frost" },
    MONK         = { "brewmaster", "mistweaver", "windwalker" },
    PALADIN      = { "holy", "protection", "retribution" },
    PRIEST       = { "discipline", "holy", "shadow" },
    ROGUE        = { "assassination", "outlaw", "subtlety" },
    SHAMAN       = { "elemental", "enhancement", "restoration" },
    WARLOCK      = { "affliction", "demonology", "destruction" },
    WARRIOR      = { "arms", "fury", "protection" },
}

local CLASS_ORDER = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}

local CLASS_ID_MAP = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
    DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local selectedClass = nil
local selectedSpec = nil
local selectedHero = nil
local activeTab = "guide"
local currentStatContext = nil
local currentRotContext = nil
local lastTalentSpecKey = nil
local initialized = false
local SaveCompendiumState -- forward declaration

-------------------------------------------------------------------------------
-- UI table (single upvalue to stay under Lua's 60-upvalue limit)
-------------------------------------------------------------------------------

local UI = {}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function GetClassDisplayName(classToken)
    local info = C_CreatureInfo and C_CreatureInfo.GetClassInfo(CLASS_ID_MAP[classToken])
    return info and info.className or classToken:sub(1, 1) .. classToken:sub(2):lower()
end

local function GetSpecDisplayName(classToken, specKey)
    local classID = CLASS_ID_MAP[classToken]
    if not classID or not GetSpecializationInfoForClassID then return specKey end
    local keys = SPEC_KEYS[classToken]
    if keys then
        for i, key in ipairs(keys) do
            if key == specKey then
                local _, name = GetSpecializationInfoForClassID(classID, i)
                if name then return name end
                break
            end
        end
    end
    return specKey:gsub("^%l", string.upper):gsub("%-(%l)", function(c) return " " .. c:upper() end)
end

local function GetSpecIconTexture(classToken, specKey)
    local classID = CLASS_ID_MAP[classToken]
    if not classID or not GetSpecializationInfoForClassID then return nil end
    local keys = SPEC_KEYS[classToken]
    if keys then
        for i, key in ipairs(keys) do
            if key == specKey then
                local _, _, _, icon = GetSpecializationInfoForClassID(classID, i)
                return icon
            end
        end
    end
    return nil
end

local function HeroMatches(entryHero, heroTalent)
    if entryHero == heroTalent then return true end
    if heroTalent and entryHero:sub(1, #heroTalent) == heroTalent
        and entryHero:sub(#heroTalent + 1, #heroTalent + 1) == " " then
        return true
    end
    if entryHero and heroTalent:sub(1, #entryHero) == entryHero
        and heroTalent:sub(#entryHero + 1, #entryHero + 1) == " " then
        return true
    end
    return false
end

local function GetHeroTalentOptions(specData)
    local seen, options = {}, {}
    if specData.priorities then
        for _, p in ipairs(specData.priorities) do
            local name = p.heroTalent
            if name and name ~= "All" and not seen[name] then
                seen[name] = true
                options[#options + 1] = name
            end
        end
    end
    return options
end

local function FindMatch(entries, heroTalent, context)
    if not entries then return nil end
    for _, e in ipairs(entries) do
        if e.heroTalent == heroTalent and e.context == context then return e end
    end
    for _, e in ipairs(entries) do if e.heroTalent == heroTalent then return e end end
    for _, e in ipairs(entries) do
        if HeroMatches(e.heroTalent, heroTalent) and e.context == context then return e end
    end
    for _, e in ipairs(entries) do if HeroMatches(e.heroTalent, heroTalent) then return e end end
    for _, e in ipairs(entries) do
        if e.heroTalent == "All" and e.context == context then return e end
    end
    for _, e in ipairs(entries) do if e.heroTalent == "All" then return e end end
    return entries[1]
end

local function GetAllTalentBuildsForHero(specData, heroTalent)
    if not specData.talents then return {} end
    local builds = {}
    for _, t in ipairs(specData.talents) do
        if t.heroTalent == heroTalent or t.heroTalent == "All" or HeroMatches(t.heroTalent, heroTalent) then
            builds[#builds + 1] = t
        end
    end
    return builds
end

local function FindRotationByContext(rotations, heroTalent, rotContext)
    if not rotations then return nil end
    for _, r in ipairs(rotations) do
        if r.heroTalent == heroTalent and r.context == rotContext then return r end
    end
    for _, r in ipairs(rotations) do
        if HeroMatches(r.heroTalent, heroTalent) and r.context == rotContext then return r end
    end
    for _, r in ipairs(rotations) do
        if r.heroTalent == "All" and r.context == rotContext then return r end
    end
    for _, r in ipairs(rotations) do if r.context == rotContext then return r end end
    return nil
end

local function GetRotationContextOptions(specData, heroTalent)
    if not specData.rotation then return {} end
    local seen, options = {}, {}
    for _, r in ipairs(specData.rotation) do
        if r.heroTalent == heroTalent or r.heroTalent == "All" or HeroMatches(r.heroTalent, heroTalent) then
            if r.context and not seen[r.context] then
                seen[r.context] = true
                options[#options + 1] = r.context
            end
        end
    end
    if #options == 0 then
        for _, r in ipairs(specData.rotation) do
            if r.context and not seen[r.context] then
                seen[r.context] = true
                options[#options + 1] = r.context
            end
        end
    end
    return options
end

local function GetStatContextOptions(specData, heroTalent)
    if not specData.priorities then return {} end
    local seen, options = {}, {}
    local statsPerContext = {}
    for _, p in ipairs(specData.priorities) do
        if p.heroTalent == heroTalent or p.heroTalent == "All" or HeroMatches(p.heroTalent, heroTalent) then
            if not seen[p.context] then
                seen[p.context] = true
                options[#options + 1] = p.context
                local key = ""
                for _, tier in ipairs(p.stats) do
                    key = key .. table.concat(tier, "=") .. ">"
                end
                statsPerContext[p.context] = key
            end
        end
    end
    if #options <= 1 then return {} end
    local firstStats = statsPerContext[options[1]]
    for i = 2, #options do
        if statsPerContext[options[i]] ~= firstStats then
            return options
        end
    end
    return {}
end

local function FormatRotationStep(stepText)
    return stepText:gsub("{(%d+)}", function(id)
        local spellId = tonumber(id)
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellId)
        if info and info.name then return info.name end
        return "Unknown Spell"
    end)
end

local function StripConditionPrefix(stepText)
    stepText = stepText:gsub("^%?!?{%d+}:%s*", "")
    stepText = stepText:gsub("^%?%b():%s*", "")
    return stepText
end

local function GetStepSpellIcon(stepText)
    local stripped = StripConditionPrefix(stepText)
    local spellId = stripped:match("{(%d+)}")
    if spellId then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(spellId))
        if info and info.iconID then return info.iconID end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Section header + collapse helpers come from ClassCodex.lua via ns.
-- so the docked panel and Compendium share the exact same look.
local CreateSectionHeader = ns.CreateSectionHeader
local SetCollapsed = ns.SetCollapsed

-------------------------------------------------------------------------------
-- Item cache (request → cache → refresh on load)
-------------------------------------------------------------------------------

local itemCache = {}
local pendingItems = {}
local compendiumDirty = false

local function RequestItemData(itemId)
    if not itemId or itemId == 0 then return end
    if itemCache[itemId] or pendingItems[itemId] then return end
    pendingItems[itemId] = true
    C_Item.RequestLoadItemDataByID(itemId)
end

local function RequestAllGearItems(gearData)
    if not gearData then return end
    if gearData.enchants then
        for _, e in ipairs(gearData.enchants) do
            RequestItemData(e.best.itemId)
            if e.alternate then RequestItemData(e.alternate.itemId) end
        end
    end
    if gearData.gems then
        RequestItemData(gearData.gems.primary.itemId)
        if gearData.gems.secondary then
            for _, g in ipairs(gearData.gems.secondary) do RequestItemData(g.itemId) end
        end
    end
    if gearData.consumables then
        for _, key in ipairs(CONSUMABLE_ORDER) do
            if gearData.consumables[key] then RequestItemData(gearData.consumables[key].itemId) end
        end
    end
    if gearData.trinkets then
        for _, t in ipairs(gearData.trinkets) do RequestItemData(t.itemId) end
    end
    ns.Sections.Crafting.RequestItems(selectedClass, selectedSpec, RequestItemData)
    if gearData.bisGear then
        for _, tab in ipairs(gearData.bisGear) do
            for _, g in ipairs(tab.slots) do RequestItemData(g.item.itemId) end
        end
    end
    -- Also request IV items for the same class/spec
    if selectedClass and selectedSpec and ns.GetIcyVeinsSpecData then
        local ivData = ns:GetIcyVeinsSpecData(selectedClass, selectedSpec)
        if ivData and ivData.bisGear then
            for _, tab in ipairs(ivData.bisGear) do
                for _, g in ipairs(tab.slots) do RequestItemData(g.item.itemId) end
            end
        end
    end
    -- And Archon gear items for the same class/spec
    if selectedClass and selectedSpec and ns.GetArchonGearSpecData then
        local archonData = ns:GetArchonGearSpecData(selectedClass, selectedSpec)
        if archonData and archonData.bisGear then
            for _, tab in ipairs(archonData.bisGear) do
                for _, g in ipairs(tab.slots) do RequestItemData(g.item.itemId) end
            end
        end
    end
end

local itemEventFrame = CreateFrame("Frame")
itemEventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
itemEventFrame:SetScript("OnEvent", function(_, _, itemId, success)
    if success then
        pendingItems[itemId] = nil
        local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemId)
        if name then
            itemCache[itemId] = { name = name, quality = quality, icon = icon }
            if not compendiumDirty and UI.frame and UI.frame:IsShown() then
                compendiumDirty = true
                C_Timer.After(0.1, function()
                    compendiumDirty = false
                    if UI.frame and UI.frame:IsShown() then
                        ns:UpdateCompendium()
                    end
                end)
            end
        end
    end
end)


local function GetItemDisplayName(itemRef)
    if not itemRef then return "" end
    if itemRef.spellId then
        if C_Spell and C_Spell.GetSpellName then
            local name = C_Spell.GetSpellName(itemRef.spellId)
            if name then return name end
        end
    end
    if itemRef.itemId then
        local cached = itemCache[itemRef.itemId]
        if cached and cached.name then return cached.name end
        local name = GetItemInfo(itemRef.itemId)
        if name then return name end
    end
    return itemRef.name or ("Item " .. (itemRef.itemId or "?"))
end

local function GetItemQuality(itemId)
    if not itemId then return nil end
    local cached = itemCache[itemId]
    if cached and cached.quality then return cached.quality end
    local _, _, quality = GetItemInfo(itemId)
    return quality
end

-- FormatItem(itemRef [, name]) -> string
-- Convenience wrapper around ns.FormatItemLabel that pulls quality
-- from the cache. Pass an explicit name to override the resolved one
-- (e.g. when stripping a prefix from an enchant name).
local function FormatItem(itemRef, nameOverride)
    if not itemRef then return "" end
    local name = nameOverride or GetItemDisplayName(itemRef)
    return ns.FormatItemLabel(name, GetItemQuality(itemRef.itemId))
end

local ICON_SIZE = 16

local function GetItemIcon(itemId)
    if not itemId then return nil end
    local cached = itemCache[itemId]
    if cached and cached.icon then return cached.icon end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    return icon
end

local function GetSpellIcon(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        if info and info.iconID then return info.iconID end
    end
    return nil
end

local function CreateRowIcon(row)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", 2, 0)
    icon:Hide()
    row.icon = icon
    return icon
end

local function SetRowIcon(row, itemId, spellId)
    if not row.icon then return end
    local tex = GetSpellIcon(spellId) or GetItemIcon(itemId)
    if tex then
        row.icon:SetTexture(tex)
        row.icon:Show()
    else
        row.icon:Hide()
    end
end

local function StripEnchantPrefix(name)
    local stripped = name:match("^Enchant [^%-]+ %- (.+)$")
    return stripped or name
end

-------------------------------------------------------------------------------
-- Dropdown setup (forward declared, assigned in InitFrame)
-------------------------------------------------------------------------------

local SetupClassDropdown, SetupSpecDropdown, SetupHeroDropdown

-------------------------------------------------------------------------------
-- InitFrame — lazily creates all UI (ensures Blizzard templates are loaded)
-------------------------------------------------------------------------------

local function InitFrame()
    if initialized then return end
    initialized = true

    -- Main frame
    UI.frame = CreateFrame("Frame", "ClassCodexCompendium", UIParent, "ButtonFrameTemplate")
    UI.frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    -- HIGH strata matches the small codex panel (ClassCodex.lua) and stops
    -- other addons' HIGH-strata frames (cooldown managers like Ayije CDM,
    -- action bars, buff icons) from rendering through the Compendium
    -- background and over the scrolling rotation list. Tooltips stay on
    -- top because TOOLTIP strata is above HIGH.
    UI.frame:SetFrameStrata("HIGH")
    -- Restore saved position or center
    if ClassCodexDB and ClassCodexDB.compendiumX and ClassCodexDB.compendiumY then
        UI.frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ClassCodexDB.compendiumX, ClassCodexDB.compendiumY)
    else
        UI.frame:SetPoint("CENTER")
    end
    UI.frame:SetTitle("Class Codex Compendium")
    UI.frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Book_09")
    ButtonFrameTemplate_HideButtonBar(UI.frame)
    -- Blizzard's ButtonFrameTemplate anchors the NineSlice bottom corners
    -- with a -3px Y offset so they hang slightly below the frame edge,
    -- meant to overlap a tab strip flush against the frame. Our tabs sit
    -- 30px below, so the default anchors leave the corners floating as
    -- "ears" under the frame. Preserve Blizzard's X offset (which positions
    -- the corner art correctly) and pin Y at -4 so the corner art hugs
    -- the BottomEdge slice cleanly without leaving a sliver gap above it.
    -- The BottomEdge anchors between the two corners and re-appears once
    -- they're positioned.
    local function pinCornerToBottomEdge(corner)
        if not corner then return end
        local point, relTo, relPoint, x = corner:GetPoint(1)
        if not point then return end
        corner:ClearAllPoints()
        corner:SetPoint(point, relTo, relPoint, x, -4)
    end
    if UI.frame.NineSlice then
        pinCornerToBottomEdge(UI.frame.NineSlice.BottomLeftCorner)
        pinCornerToBottomEdge(UI.frame.NineSlice.BottomRightCorner)
    end
    UI.frame:EnableMouse(true)
    UI.frame:SetMovable(true)
    UI.frame:SetClampedToScreen(true)
    UI.frame:Hide()
    UI.frame:SetScript("OnHide", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
    tinsert(UISpecialFrames, "ClassCodexCompendium")

    -- Make title bar draggable
    UI.frame.TitleContainer:EnableMouse(true)
    UI.frame.TitleContainer:RegisterForDrag("LeftButton")
    UI.frame.TitleContainer:SetScript("OnDragStart", function() UI.frame:StartMoving() end)
    UI.frame.TitleContainer:SetScript("OnDragStop", function()
        UI.frame:StopMovingOrSizing()
        if ClassCodexDB then
            ClassCodexDB.compendiumX = UI.frame:GetLeft()
            ClassCodexDB.compendiumY = UI.frame:GetTop()
        end
    end)

    -- Tabs
    local TAB_DATA = {
        { key = "guide",        label = L["tab.guide"] },
        { key = "talents",      label = L["section.talents"] },
        { key = "bis",          label = L["tab.bis_gear"] },
        { key = "trinkets",     label = L["tab.trinkets"] },
        { key = "enhancements", label = L["tab.enhancements"] },
        { key = "crafting",     label = L["tab.crafting"] },
    }
    local tabs = {}
    for i, data in ipairs(TAB_DATA) do
        local tab = CreateFrame("Button", "ClassCodexCompendiumTab" .. i, UI.frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(data.label)
        tab.tabKey = data.key
        if i == 1 then
            tab:SetPoint("BOTTOMLEFT", UI.frame, "BOTTOMLEFT", 15, -30)
        else
            tab:SetPoint("LEFT", tabs[i - 1], "RIGHT", -14, 0)
        end
        tab:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
            activeTab = self.tabKey
            PanelTemplates_SetTab(UI.frame, self:GetID())
            SaveCompendiumState()
            ns:UpdateCompendium()
        end)
        tabs[i] = tab
    end
    UI.tabs = tabs
    UI.TAB_DATA = TAB_DATA
    PanelTemplates_SetNumTabs(UI.frame, #TAB_DATA)
    PanelTemplates_SetTab(UI.frame, 1)

    -- Scroll frame inside Inset
    local scrollFrame = CreateFrame("ScrollFrame", "ClassCodexCompendiumScroll", UI.frame.Inset, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", UI.frame.Inset, "TOPLEFT", 4, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", UI.frame.Inset, "BOTTOMRIGHT", -24, 4)

    UI.scrollChild = CreateFrame("Frame", nil, scrollFrame)
    UI.scrollChild:SetWidth(scrollFrame:GetWidth() or (FRAME_WIDTH - 40))
    UI.scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(UI.scrollChild)
    scrollFrame:SetScript("OnSizeChanged", function(_, w) UI.scrollChild:SetWidth(w) end)

    -- Dropdowns (attic area) — class / spec / hero left-to-right, anchored from
    -- the right. The hero dropdown stops SOURCE_SLOT short of the right edge,
    -- leaving room for the source tag (which is always right-aligned).
    local SOURCE_SLOT = 96
    UI.heroDropdown = CreateFrame("DropdownButton", "ClassCodexCompHeroDD", UI.frame, "WowStyle1DropdownTemplate")
    UI.heroDropdown:SetPoint("TOPRIGHT", UI.frame.Inset, "TOPRIGHT", -SOURCE_SLOT, 28)
    UI.heroDropdown:SetWidth(135)

    UI.specDropdown = CreateFrame("DropdownButton", "ClassCodexCompSpecDD", UI.frame, "WowStyle1DropdownTemplate")
    UI.specDropdown:SetPoint("RIGHT", UI.heroDropdown, "LEFT", -3, 0)
    UI.specDropdown:SetWidth(118)

    UI.classDropdown = CreateFrame("DropdownButton", "ClassCodexCompClassDD", UI.frame, "WowStyle1DropdownTemplate")
    UI.classDropdown:SetPoint("RIGHT", UI.specDropdown, "LEFT", -3, 0)
    UI.classDropdown:SetWidth(130)

    -- Copy popup (shared)
    -- Copy popup is a single shared widget exposed by ClassCodex.lua;
    -- the Compendium just hands strings to ns.ShowCopyPopup.

    ---------------------------------------------------------------------------
    -- Sections
    ---------------------------------------------------------------------------

    local function MakeItemRow(parent)
        local row = CreateFrame("Button", nil, parent)
        row:SetHeight(ROW_HEIGHT)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnEnter", function(self)
            if self.itemId then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if self.bonusIDs and #self.bonusIDs > 0 then
                    local bonusStr = #self.bonusIDs .. ":" .. table.concat(self.bonusIDs, ":")
                    local link = format("item:%d::::::::::::%s", self.itemId, bonusStr)
                    local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
                    if not ok then GameTooltip:SetItemByID(self.itemId) end
                else
                    GameTooltip:SetItemByID(self.itemId)
                end
                -- Crafts surface their embellishment as a tooltip line so a
                -- single row can carry both items without splitting the
                -- visual list.
                if self.embItemId then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine((L and L["gear.tooltip.embellishment"]) or "Embellishment:", 0.6, 0.6, 0.6)
                    local embName = self.embName
                    if not embName or embName == "" then
                        embName = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(self.embItemId))
                            or GetItemInfo(self.embItemId) or ("Item " .. self.embItemId)
                    end
                    GameTooltip:AddLine("  " .. embName, 1, 1, 1)
                end
                if self.sourceText then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddDoubleLine(SOURCE or "Source", self.sourceText, 0.5, 0.5, 0.5, 1, 0.82, 0)
                end
                GameTooltip:Show()
            elseif self.spellId then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self.spellId)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if not self.itemId then return end
            local _, link = C_Item.GetItemInfo(self.itemId)
            if not link then return end
            if IsModifiedClick("CHATLINK") then
                ChatEdit_InsertLink(link)
            elseif IsModifiedClick("DRESSUP") then
                DressUpItemLink(link)
            end
        end)
        return row
    end

    -- Guide: Stat Priority — extracted to Sections/Stats.lua.
    UI.statSection, UI.statHeader, UI.statContent =
        ns.Sections.Stats.InitCompendium({
            parent = UI.scrollChild,
            headerFactory = CreateSectionHeader,
        })
    UI.statCollapsed = false
    UI.statHeader:SetScript("OnClick", function()
        UI.statCollapsed = not UI.statCollapsed
        SetCollapsed(UI.statContent, UI.statHeader, UI.statCollapsed)
        ns:LayoutCompendium()
    end)

    -- Guide: Talents
    UI.talentSection = CreateFrame("Frame", nil, UI.scrollChild)
    UI.talentHeader = CreateSectionHeader(UI.talentSection, L["section.talents"], true)
    UI.talentContent = CreateFrame("Frame", nil, UI.talentSection)
    UI.talentContent:SetPoint("TOPLEFT", UI.talentHeader, "BOTTOMLEFT", 0, -2)
    UI.talentContent:SetPoint("RIGHT", 0, 0)
    UI.talentButtons = {}
    UI.talentCollapsed = false

    -- Lazy factory so the pool can grow past the initial allocation.
    -- Render functions call this with a 1-based index; existing buttons
    -- are reused, missing ones are created on demand. Hero badge support
    -- (used by the Archon view) hangs off btn.heroIcon.
    local function CreateTalentButton(i)
        if UI.talentButtons[i] then return UI.talentButtons[i] end
        local btn = CreateFrame("Button", nil, UI.talentContent, "BackdropTemplate")
        btn:SetHeight(TALENT_BTN_HEIGHT)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        local hero = btn:CreateTexture(nil, "ARTWORK")
        hero:SetSize(14, 14); hero:SetPoint("LEFT", 6, 0); hero:Hide()
        btn.heroIcon = hero
        local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", 8, 0); text:SetPoint("RIGHT", -8, 0)
        text:SetJustifyH("LEFT"); text:SetTextColor(0.8, 0.8, 0.8)
        btn.label = text
        local ci = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ci:SetPoint("RIGHT", -6, 0)
        ci:SetText("|TInterface\\Buttons\\UI-GuildButton-PublicNote-Up:12:12|t")
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(0.6, 0.6, 0.6, 1); self.label:SetTextColor(1, 1, 1)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Click to copy talent string", 1, 1, 1); GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8); self.label:SetTextColor(0.8, 0.8, 0.8); GameTooltip:Hide()
        end)
        btn:Hide()
        UI.talentButtons[i] = btn
        return btn
    end
    UI._ensureTalentButton = CreateTalentButton
    for i = 1, MAX_TALENT_BUTTONS do CreateTalentButton(i) end
    UI.talentFallback = UI.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    UI.talentFallback:SetTextColor(0.5, 0.5, 0.5); UI.talentFallback:Hide()
    UI.talentHeader:SetScript("OnClick", function()
        UI.talentCollapsed = not UI.talentCollapsed
        SetCollapsed(UI.talentContent, UI.talentHeader, UI.talentCollapsed)
        ns:LayoutCompendium()
    end)

    -- Hero/section group headers (Talents tab). Same lazy-grow pattern
    -- as talentButtons — Archon adds Mythic+/Raid Heroic/Raid Mythic
    -- headers on top of the hero headers.
    UI.talentHeroHeaders = {}
    local function CreateTalentHeroHeader(i)
        if UI.talentHeroHeaders[i] then return UI.talentHeroHeaders[i] end
        local hdr = CreateFrame("Frame", nil, UI.talentContent)
        hdr:SetHeight(TALENT_HERO_HEADER_HEIGHT)
        local text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("LEFT", 4, 0)
        text:SetTextColor(1, 0.82, 0)
        hdr.label = text
        hdr:Hide()
        UI.talentHeroHeaders[i] = hdr
        return hdr
    end
    UI._ensureTalentHeroHeader = CreateTalentHeroHeader
    for i = 1, MAX_TALENT_HERO_HEADERS do CreateTalentHeroHeader(i) end

    -- Source dropdown (Wowhead | Archon | PvP) — only shown by the
    -- Talents tab. Mirrors the docked panel and the addon's other
    -- dropdowns. Each option carries the brand icon via a |T...|t escape.
    local SOURCE_ICON_WOWHEAD  = "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12:0:0|t  Wowhead"
    local SOURCE_ICON_ARCHON   = "|TInterface\\AddOns\\ClassCodex\\Textures\\archon:12:12:0:0|t  Archon"
    local SOURCE_ICON_ICYVEINS = "|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:12:12:0:0|t  Icy Veins"
    local SOURCE_ICON_PVP      = "|TInterface\\AddOns\\ClassCodex\\Textures\\bnet:12:12:0:0|t  PvP"
    local function SourceLabel(source)
        if source == "archon" then return SOURCE_ICON_ARCHON end
        if source == "icyveins" then return SOURCE_ICON_ICYVEINS end
        if source == "pvp" then return SOURCE_ICON_PVP end
        return SOURCE_ICON_WOWHEAD
    end

    UI.talentSource = "wowhead" -- per-spec source within the Compendium
    UI.talentSourceDropdown = ns.CreateOptionDropdown("ClassCodexCompendiumTalentSourceDropdown", UI.talentContent, 140)
    UI.talentSourceDropdown:Hide()

    UI._refreshTalentSourceDropdown = function(archonAvailable, icyVeinsAvailable)
        -- PvP always appears so users discover the feature even on specs
        -- without scraped data — RenderPvPTalentList surfaces the
        -- "No PvP builds available." fallback when empty.
        local opts = { { label = SOURCE_ICON_WOWHEAD, value = "wowhead" } }
        if archonAvailable then
            opts[#opts + 1] = { label = SOURCE_ICON_ARCHON, value = "archon" }
        end
        if icyVeinsAvailable then
            opts[#opts + 1] = { label = SOURCE_ICON_ICYVEINS, value = "icyveins" }
        end
        opts[#opts + 1] = { label = SOURCE_ICON_PVP, value = "pvp" }
        -- Archon and Icy Veins can each vanish on a per-spec coverage gap.
        local current = UI.talentSource
        if current == "archon" and not archonAvailable then current = "wowhead" end
        if current == "icyveins" and not icyVeinsAvailable then current = "wowhead" end
        if current ~= UI.talentSource then UI.talentSource = current end
        UI.talentSourceDropdown:SetOptions(opts, UI.talentSource, function(picked)
            if UI.talentSource ~= picked then
                UI.talentSource = picked
                ns:UpdateCompendium()
            end
        end)
    end

    -- Guide: Rotation — extracted to Sections/Rotation.lua.
    UI.rotationSection, UI.rotationHeader, UI.rotationContent =
        ns.Sections.Rotation.InitCompendium({
            parent = UI.scrollChild,
            headerFactory = CreateSectionHeader,
            refresh = function() ns:LayoutCompendium() end,
        })
    UI.rotationCollapsed = false

    -- Enhancements (Enchants + Gems + Consumables) extracted to
    -- Sections/Enhancements.lua. Module owns row pools, sub-rows, source
    -- dropdown, PvP fallback, and collapse hooks.
    local _enhFrames = ns.Sections.Enhancements.InitCompendium({
        parent = UI.scrollChild,
        headerFactory = CreateSectionHeader,
        rowFactory = MakeItemRow,
        refresh = function() ns:LayoutCompendium() end,
        iconSize = ICON_SIZE,
    })
    UI.enchantSection, UI.enchantHeader, UI.enchantContent =
        _enhFrames.enchSection, _enhFrames.enchHeader, _enhFrames.enchContent
    UI.gemSection, UI.gemHeader, UI.gemContent =
        _enhFrames.gemSection, _enhFrames.gemHeader, _enhFrames.gemContent
    UI.consumSection, UI.consumHeader, UI.consumContent =
        _enhFrames.consumSection, _enhFrames.consumHeader, _enhFrames.consumContent
    UI.enhancementsSourceDropdown = _enhFrames.sourceDropdown

    -- Trinkets section — extracted to Sections/Trinkets.lua. The module owns
    -- the row pool, context dropdown, persisted-context state, and render
    -- code; we just keep handles to the returned frames for the layout pass.
    UI.trinketSection, UI.trinketHeader, UI.trinketContent =
        ns.Sections.Trinkets.InitCompendium({
            parent = UI.scrollChild,
            headerFactory = CreateSectionHeader,
            rowFactory = MakeItemRow,
        })
    UI.trinketCollapsed = false

    -- Crafting section — extracted to Sections/Crafting.lua. Frame pool,
    -- card factory, dropdown, fallback, and render code all live there;
    -- we keep handles to the returned frames so the Compendium layout pass
    -- can position the section relative to its siblings.
    UI.craftSection, UI.craftHeader, UI.craftContent =
        ns.Sections.Crafting.InitCompendium({
            parent = UI.scrollChild,
            headerFactory = CreateSectionHeader,
        })
    UI.craftCollapsed = false

    -- BiS Gear — extracted to Sections/Gear.lua. The module owns the row
    -- pool, source/tab dropdowns, PvP fallback, and render code.
    UI.bisSection, UI.bisHeader, UI.bisContent =
        ns.Sections.Gear.InitCompendium({
            parent = UI.scrollChild,
            headerFactory = CreateSectionHeader,
            rowFactory = MakeItemRow,
        })
    UI.bisCollapsed = false

    -- Source attribution is the last thing on the top row — always right-
    -- aligned to the inset edge, in the reserved SOURCE_SLOT (vertically lined
    -- up with the dropdowns). Set per render in UpdateCompendiumAttribution.
    UI.sourceTag = ns.CreateSourceTag(UI.frame, { noPrefix = true })
    -- Right edge lands at the inset edge (-4); anchoring to the hero dropdown
    -- keeps it vertically centered with the dropdown row.
    UI.sourceTag:SetPoint("RIGHT", UI.heroDropdown, "RIGHT", SOURCE_SLOT - 4, 0)

    -- Empty state
    UI.emptyText = UI.scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    UI.emptyText:SetPoint("CENTER", UI.scrollChild, "TOP", 0, -60)
    UI.emptyText:SetText(L["empty.select_class_spec"])
    UI.emptyText:SetTextColor(0.5, 0.5, 0.5)
end

-------------------------------------------------------------------------------
-- Dropdown setup functions
-------------------------------------------------------------------------------

local HERO_TALENT_ATLAS = ns.HERO_TALENT_ATLAS

SaveCompendiumState = function()
    if not ClassCodexDB then return end
    ClassCodexDB.compendiumClass = selectedClass
    ClassCodexDB.compendiumSpec = selectedSpec
    ClassCodexDB.compendiumHero = selectedHero
    ClassCodexDB.compendiumTab = activeTab
end

SetupClassDropdown = function()
    UI.classDropdown:SetupMenu(function(_, rootDescription)
        for _, classToken in ipairs(CLASS_ORDER) do
            local color = RAID_CLASS_COLORS[classToken]
            local label = color and color:WrapTextInColorCode(GetClassDisplayName(classToken)) or GetClassDisplayName(classToken)
            rootDescription:CreateRadio(label,
                function() return selectedClass == classToken end,
                function()
                    selectedClass = classToken
                    selectedSpec = SPEC_KEYS[classToken] and SPEC_KEYS[classToken][1] or nil
                    -- Auto-select first hero talent for new spec
                    if selectedSpec then
                        local specData = DATA[classToken] and DATA[classToken][selectedSpec]
                        if specData then
                            local opts = GetHeroTalentOptions(specData)
                            selectedHero = opts[1] or "All"
                        else
                            selectedHero = nil
                        end
                    else
                        selectedHero = nil
                    end
                    SaveCompendiumState()
                    SetupSpecDropdown()
                    SetupHeroDropdown()
                    UI.specDropdown:GenerateMenu()
                    UI.heroDropdown:GenerateMenu()
                    ns:UpdateCompendium()
                end,
                classToken)
        end
    end)
end

SetupSpecDropdown = function()
    UI.specDropdown:SetupMenu(function(_, rootDescription)
        if not selectedClass then return end
        local keys = SPEC_KEYS[selectedClass]
        if not keys then return end
        for _, specKey in ipairs(keys) do
            local label = GetSpecDisplayName(selectedClass, specKey)
            rootDescription:CreateRadio(label,
                function() return selectedSpec == specKey end,
                function()
                    selectedSpec = specKey
                    -- Auto-select first hero talent
                    local specData = DATA[selectedClass] and DATA[selectedClass][specKey]
                    if specData then
                        local opts = GetHeroTalentOptions(specData)
                        selectedHero = opts[1] or "All"
                    else
                        selectedHero = nil
                    end
                    SaveCompendiumState()
                    SetupHeroDropdown()
                    UI.heroDropdown:GenerateMenu()
                    ns:UpdateCompendium()
                end,
                specKey)
        end
    end)
end

SetupHeroDropdown = function()
    UI.heroDropdown:SetupMenu(function(_, rootDescription)
        if not selectedClass or not selectedSpec then return end
        local specData = DATA[selectedClass] and DATA[selectedClass][selectedSpec]
        if not specData then return end
        local options = GetHeroTalentOptions(specData)
        if #options == 0 then
            rootDescription:CreateTitle("No hero talents")
            return
        end
        for _, heroName in ipairs(options) do
            rootDescription:CreateRadio(heroName,
                function() return selectedHero == heroName end,
                function()
                    selectedHero = heroName
                    SaveCompendiumState()
                    ns:UpdateCompendium()
                end,
                heroName)
        end
    end)
end

-------------------------------------------------------------------------------
-- Update: populate content based on selections
-------------------------------------------------------------------------------

-- Set the footer source tag for the browsed spec — the source feeding the
-- active tab, tracking the Compendium's own talent/gear/enhancement selections.
local function UpdateCompendiumAttribution(class, spec)
    local tag = UI.sourceTag
    if not tag then return end
    if not class or not spec then tag:SetSource(nil); return end

    local U = ns.SourceUrls
    local key, url

    if activeTab == "guide" or activeTab == "trinkets" then
        key, url = "wowhead", U.wowheadGuide(class, spec)
    elseif activeTab == "talents" then
        local ts = UI.talentSource
        if ts == "archon" then key, url = "archon", U.archonOverview(class, spec) or ns.SOURCES.archon.homepage
        elseif ts == "icyveins" then key, url = "icyveins", U.icyVeinsTalents(class, spec)
        elseif ts == "pvp" then key, url = "bnet", ns.SOURCES.bnet.homepage
        else key, url = "wowhead", U.wowheadGuide(class, spec) end
    elseif activeTab == "bis" then
        key = ns.Sections.Gear.GetCompendiumSourceKey and ns.Sections.Gear.GetCompendiumSourceKey() or "wowhead"
        url = ns.BisUrlForKey(key, class, spec)
    elseif activeTab == "enhancements" then
        key = ns.Sections.Enhancements.GetCompendiumSourceKey and ns.Sections.Enhancements.GetCompendiumSourceKey() or "wowhead"
        url = (key == "murlok") and U.murlok(class, spec) or U.wowheadGuide(class, spec)
    elseif activeTab == "crafting" then
        local ctx = ns.Sections.Crafting.GetContextKey and ns.Sections.Crafting.GetContextKey()
        if ctx == "pvp" then key, url = "murlok", U.murlok(class, spec)
        else key, url = "archon", U.archonOverview(class, spec) or ns.SOURCES.archon.homepage end
    end

    tag:SetSource(key, url)
end

function ns:UpdateCompendium()
    -- Hide all sections first
    UI.statSection:Hide(); UI.talentSection:Hide(); UI.rotationSection:Hide()
    UI.enchantSection:Hide(); UI.gemSection:Hide(); UI.consumSection:Hide()
    UI.trinketSection:Hide(); UI.craftSection:Hide(); UI.bisSection:Hide()
    UI.emptyText:Hide(); UI.talentFallback:Hide()
    -- Rotation fallback now lives inside Sections/Rotation.lua and is reset
    -- at the start of each RenderCompendium call.
    -- Enhancements source dropdown lives outside enchantSection now,
    -- so hiding the section doesn't take it down. Hide it explicitly
    -- on every tab switch — the Enhancements tab's update path will
    -- re-show it when it's actually needed.
    if UI.enhancementsSourceDropdown then UI.enhancementsSourceDropdown:Hide() end

    if not selectedClass or not selectedSpec then
        UI.emptyText:Show()
        ns:LayoutCompendium()
        return
    end

    local specData = DATA[selectedClass] and DATA[selectedClass][selectedSpec]
    if not specData then
        UI.emptyText:SetText(L["empty.no_data"])
        UI.emptyText:Show()
        ns:LayoutCompendium()
        return
    end

    -- Auto-select first hero if none selected
    local heroOptions = GetHeroTalentOptions(specData)
    if not selectedHero or selectedHero == "" then
        selectedHero = heroOptions[1] or "All"
    end

    -- Update portrait
    local icon = GetSpecIconTexture(selectedClass, selectedSpec)
    if icon then UI.frame:SetPortraitToAsset(icon)
    else UI.frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Book_09") end

    -- Update title
    UI.frame:SetTitle("Class Codex Compendium · " .. GetSpecDisplayName(selectedClass, selectedSpec) .. " " .. GetClassDisplayName(selectedClass))

    -- Request item data for gearing tabs
    if activeTab ~= "guide" and activeTab ~= "talents" and GEAR_DATA then
        local gearData = GEAR_DATA[selectedClass] and GEAR_DATA[selectedClass][selectedSpec]
        RequestAllGearItems(gearData)
    end

    local heroTalent = selectedHero or "All"

    if activeTab == "guide" then
        self:UpdateCompendiumGuide(specData, heroTalent)
    elseif activeTab == "talents" then
        self:UpdateCompendiumAllTalents(specData, selectedClass, selectedSpec)
    elseif activeTab == "bis" then
        self:UpdateCompendiumBis()
    elseif activeTab == "trinkets" then
        self:UpdateCompendiumTrinkets()
    elseif activeTab == "enhancements" then
        self:UpdateCompendiumEnchants()
        self:UpdateCompendiumConsumables()
    elseif activeTab == "crafting" then
        self:UpdateCompendiumCrafts()
    end

    ns:LayoutCompendium()  -- also refreshes the source tag
end

-- Build a synthetic priority record from Murlok's per-spec PvP stat data
-- so the existing rendering loop (which expects priority.stats as an
-- array of stat-label tiers) works without source-specific branches.
local function BuildPvPPrioritySynthetic()
    if not selectedClass or not selectedSpec or not ns.GetPvPStats then return nil end
    local stats = ns.GetPvPStats(selectedClass, selectedSpec)
    if not stats or #stats == 0 then return nil end
    local labels = ns.STAT_LABELS or {}
    local tiers = {}
    for _, s in ipairs(stats) do
        local label = labels[s.key] or s.key
        tiers[#tiers + 1] = { label }
    end
    return { stats = tiers }
end

-- Stat-priority resolution stays here (uses Compendium-internal helpers);
-- Sections/Stats.lua renders the result on both surfaces.
local function RenderStatPrioritySection(specData, heroTalent)
    local statCtxOptions = GetStatContextOptions(specData, heroTalent)
    local pvpPriority = BuildPvPPrioritySynthetic()
    if #statCtxOptions == 0 then
        statCtxOptions = { "General", "PvP" }
    else
        statCtxOptions[#statCtxOptions + 1] = "PvP"
    end

    if not currentStatContext then currentStatContext = statCtxOptions[1] end
    local found = false
    for _, c in ipairs(statCtxOptions) do
        if c == currentStatContext then found = true; break end
    end
    if not found then currentStatContext = statCtxOptions[1] end

    local priority
    if currentStatContext == "PvP" then
        priority = pvpPriority
    else
        priority = FindMatch(specData.priorities, heroTalent, currentStatContext or "General")
    end

    ns.Sections.Stats.RenderCompendium({
        contextOptions   = statCtxOptions,
        currentContext   = currentStatContext,
        priorityStats    = priority and priority.stats or nil,
        showPvpFallback  = currentStatContext == "PvP" and not priority,
        labelForContext  = function(ctx)
            if ctx == "PvP" then
                return "|TInterface\\AddOns\\ClassCodex\\Textures\\murlok:12:12:0:0|t  " .. L["pvp.label"]
            end
            return L[ctx]
        end,
        onCtxChange      = function(picked)
            currentStatContext = picked
            ns:UpdateCompendium()
        end,
    })
end

function ns:UpdateCompendiumGuide(specData, heroTalent)
    RenderStatPrioritySection(specData, heroTalent)

    -- Talents — Guide view shows Wowhead-only context-filtered builds.
    -- The source dropdown is hidden here; the standalone Talents tab is
    -- the surface for browsing both sources.
    if UI.talentSourceDropdown then UI.talentSourceDropdown:Hide() end
    for _, b in ipairs(UI.talentButtons) do b:Hide() end
    for _, h in ipairs(UI.talentHeroHeaders) do h:Hide() end
    UI.talentFallback:Hide()
    local talentBuilds = GetAllTalentBuildsForHero(specData, heroTalent)
    if #talentBuilds > 0 then
        local count = #talentBuilds
        for i = 1, count do
            local t = talentBuilds[i]
            local btn = UI._ensureTalentButton(i)
            if btn.heroIcon then btn.heroIcon:Hide() end
            local label = t.context or L["talent.build"]
            if t.buildLabel and t.buildLabel ~= "" then label = label .. " — " .. t.buildLabel end
            btn.label:SetText(label)
            btn.label:ClearAllPoints()
            btn.label:SetPoint("LEFT", 8, 0); btn.label:SetPoint("RIGHT", -8, 0)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, -((i - 1) * (TALENT_BTN_HEIGHT + TALENT_BTN_GAP)))
            btn:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
            btn:SetScript("OnClick", function()
                ns.ShowCopyPopup(t.exportString, btn)
            end)
            btn:Show()
        end
        UI.talentContent:SetHeight(count * (TALENT_BTN_HEIGHT + TALENT_BTN_GAP))
        UI.talentSection:Show()
    elseif specData.talents and #specData.talents > 0 then
        UI.talentFallback:SetText(L["empty.no_builds_for"]:format(heroTalent))
        UI.talentFallback:Show()
        UI.talentContent:SetHeight(20)
        UI.talentSection:Show()
    end

    -- Rotation — Sections/Rotation.lua owns rendering. Context resolution
    -- stays here (uses Compendium-internal helpers + persisted state).
    local rotCtxOptions = GetRotationContextOptions(specData, heroTalent)
    local rotContext = rotCtxOptions[1] or "General"
    if currentRotContext then
        for _, c in ipairs(rotCtxOptions) do
            if c == currentRotContext then rotContext = currentRotContext; break end
        end
    end
    if #rotCtxOptions > 1 then currentRotContext = rotContext end
    local rotation = FindRotationByContext(specData.rotation, heroTalent, rotContext)
    ns.Sections.Rotation.RenderCompendium({
        contextOptions  = rotCtxOptions,
        currentContext  = currentRotContext or rotContext,
        rotation        = rotation,
        heroTalent      = heroTalent,
        hasAnyRotation  = specData.rotation and #specData.rotation > 0,
        textAreaWidth   = (FRAME_WIDTH - 80) - 42,
        labelForContext = function(ctx) return L[ctx] end,
        helpers = {
            shouldShow = function() return true end,
            strip      = StripConditionPrefix,
            getIcon    = GetStepSpellIcon,
            format     = FormatRotationStep,
        },
        onCtxChange     = function(picked)
            currentRotContext = picked
            ns:UpdateCompendium()
        end,
    })
end

-- Helper: bind a talent button to copy a given exportString on click.
local function BindCopyClick(btn, exportString) -- luacheck: no unused
    btn:SetScript("OnClick", function()
        ns.ShowCopyPopup(exportString, btn)
    end)
end


-- Wowhead view of the standalone Talents tab: groups builds by hero
-- talent, one row per (hero × context) combination. Returns the y-cursor
-- after layout so the caller can size talentContent.
local function RenderWowheadTalentList(specData, yPos)
    local talents = specData.talents
    if not talents or #talents == 0 then
        UI.talentFallback:SetText(L["loadout_dock.no_talent_builds"])
        UI.talentFallback:ClearAllPoints()
        UI.talentFallback:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 4, -(yPos + 4))
        UI.talentFallback:Show()
        return yPos + 20
    end

    local heroOrder, heroBuilds = ns.GroupBuildsByHero(talents)
    local hdrIdx, rowIdx = 0, 0
    for _, hero in ipairs(heroOrder) do
        hdrIdx = hdrIdx + 1
        local hdr = UI._ensureTalentHeroHeader(hdrIdx)
        hdr.label:SetText(ns.FormatHeroHeaderText(hero))
        hdr.label:SetTextColor(1, 0.82, 0)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, -yPos)
        hdr:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
        hdr:Show()
        yPos = yPos + TALENT_HERO_HEADER_HEIGHT

        for _, build in ipairs(heroBuilds[hero]) do
            rowIdx = rowIdx + 1
            local btn = UI._ensureTalentButton(rowIdx)
            if btn.heroIcon then btn.heroIcon:Hide() end
            btn.label:ClearAllPoints()
            btn.label:SetPoint("LEFT", 8, 0); btn.label:SetPoint("RIGHT", -8, 0)
            btn.label:SetText(ns.FormatBuildLabel(build))
            btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            btn.label:SetTextColor(0.8, 0.8, 0.8)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 8, -yPos)
            btn:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
            BindCopyClick(btn, build.exportString)
            btn:Show()
            yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
        end
        yPos = yPos + 4
    end
    return yPos
end

-- Archon view: rows are encounters (hero talent shown as a small icon
-- badge on the left). Sectioned: M+, Raid Heroic, Raid Mythic.
local function RenderArchonTalentList(class, spec, yPos)
    local archon = ns.GetArchonSpecData and ns.GetArchonSpecData(class, spec) or nil
    if not archon or not archon.contexts or not next(archon.contexts) then
        UI.talentFallback:SetText(L["loadout_dock.no_archon_builds"] or "No Archon builds available.")
        UI.talentFallback:ClearAllPoints()
        UI.talentFallback:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 4, -(yPos + 4))
        UI.talentFallback:Show()
        return yPos + 20
    end

    local groups = ns.GroupArchonContexts(archon)
    local hdrIdx, rowIdx = 0, 0

    local function emitSection(headerText, entries)
        if not entries or #entries == 0 then return end
        hdrIdx = hdrIdx + 1
        local hdr = UI._ensureTalentHeroHeader(hdrIdx)
        hdr.label:SetText(headerText)
        hdr.label:SetTextColor(1, 0.82, 0)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, -yPos)
        hdr:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
        hdr:Show()
        yPos = yPos + TALENT_HERO_HEADER_HEIGHT

        for _, entry in ipairs(entries) do
            local ctx = entry.ctx
            if ctx.builds and ctx.builds[1] then
                local build = ctx.builds[1]
                rowIdx = rowIdx + 1
                local btn = UI._ensureTalentButton(rowIdx)

                local heroAtlas = build.heroTalent and ns.HERO_TALENT_ATLAS
                    and ns.HERO_TALENT_ATLAS[build.heroTalent]
                if btn.heroIcon then
                    if heroAtlas then
                        btn.heroIcon:SetAtlas(heroAtlas)
                        btn.heroIcon:Show()
                    else
                        btn.heroIcon:Hide()
                    end
                end
                btn.label:ClearAllPoints()
                local labelLeftOffset = heroAtlas and 24 or 8
                btn.label:SetPoint("LEFT", labelLeftOffset, 0)
                btn.label:SetPoint("RIGHT", -8, 0)
                local fullLabel = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(ctx))
                    or ctx.encounterLabel or "Build"
                btn.label:SetText(fullLabel)
                local isActive = ns.BuildMatchesActive and ns.BuildMatchesActive(build)
                if isActive then
                    btn:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
                    btn.label:SetTextColor(0.3, 1, 0.3)
                else
                    btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
                    btn.label:SetTextColor(0.8, 0.8, 0.8)
                end

                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 8, -yPos)
                btn:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
                BindCopyClick(btn, build.exportString)
                btn:Show()
                yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
            end
        end
        yPos = yPos + 4
    end

    -- Order: M+, Raid Heroic, Raid Mythic. Overview entry first inside each.
    local mplus = {}
    if groups.mplusOverview then mplus[#mplus + 1] = groups.mplusOverview end
    for _, e in ipairs(groups.mplusDungeons) do mplus[#mplus + 1] = e end
    emitSection("Mythic+", mplus)

    local heroic = {}
    if groups.raidOverviewHeroic then heroic[#heroic + 1] = groups.raidOverviewHeroic end
    for _, e in ipairs(groups.raidHeroicBosses) do heroic[#heroic + 1] = e end
    emitSection("Raid — Heroic", heroic)

    local mythic = {}
    if groups.raidOverviewMythic then mythic[#mythic + 1] = groups.raidOverviewMythic end
    for _, e in ipairs(groups.raidMythicBosses) do mythic[#mythic + 1] = e end
    emitSection("Raid — Mythic", mythic)

    return yPos
end

-- PvP view: rows are brackets, top class talent loadout per bracket.
-- One section header ("PvP"); one row per available bracket. Honor
-- talents are stored on the build but not rendered as separate rows
-- here — Apply takes care of them via ns.ApplyPvpHonorTalents.
local function RenderPvPTalentList(class, spec, yPos)
    if not ns.GetPvPBracketsWithData then
        UI.talentFallback:SetText(L["pvp.no_builds"] or "No PvP builds available.")
        UI.talentFallback:ClearAllPoints()
        UI.talentFallback:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 4, -(yPos + 4))
        UI.talentFallback:Show()
        return yPos + 20
    end
    local brackets = ns.GetPvPBracketsWithData(class, spec)
    if not brackets or #brackets == 0 then
        UI.talentFallback:SetText(L["pvp.no_builds"] or "No PvP builds available.")
        UI.talentFallback:ClearAllPoints()
        UI.talentFallback:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 4, -(yPos + 4))
        UI.talentFallback:Show()
        return yPos + 20
    end

    local hdrIdx, rowIdx = 0, 0
    hdrIdx = hdrIdx + 1
    local hdr = UI._ensureTalentHeroHeader(hdrIdx)
    hdr.label:SetText("PvP")
    hdr.label:SetTextColor(1, 0.82, 0)
    hdr:ClearAllPoints()
    hdr:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, -yPos)
    hdr:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
    hdr:Show()
    yPos = yPos + TALENT_HERO_HEADER_HEIGHT

    for _, bracketKey in ipairs(brackets) do
        local data = ns.GetPvPBuilds(class, spec, bracketKey)
        if data and data.builds and data.builds[1] then
            local bracketName = (ns.GetPvPBracketName and ns.GetPvPBracketName(bracketKey)) or bracketKey
            local variants = ns.GetPvPBuildVariants and ns.GetPvPBuildVariants(data)
                or { { hero = data.builds[1].heroTalent, build = data.builds[1] } }
            local multiVariant = #variants > 1

            for _, v in ipairs(variants) do
                local build = v.build
                rowIdx = rowIdx + 1
                local btn = UI._ensureTalentButton(rowIdx)
                -- Hero atlas icon only when surfacing multiple variants
                -- so single-bracket rows keep their existing chrome.
                local heroAtlas = multiVariant and v.hero and ns.HERO_TALENT_ATLAS
                    and ns.HERO_TALENT_ATLAS[v.hero]
                if btn.heroIcon then
                    if heroAtlas then
                        btn.heroIcon:SetAtlas(heroAtlas)
                        btn.heroIcon:Show()
                    else
                        btn.heroIcon:Hide()
                    end
                end
                btn.label:ClearAllPoints()
                local labelLeftOffset = heroAtlas and 24 or 8
                btn.label:SetPoint("LEFT", labelLeftOffset, 0)
                btn.label:SetPoint("RIGHT", -8, 0)
                local label
                if multiVariant then
                    label = bracketName .. " — " .. (v.hero or "—")
                    if v.altIndex then
                        local suffix = v.altIndex == 2
                            and (L["loadout.alt"] or "alt")
                            or string.format(L["loadout.alt_n"] or "alt %d", v.altIndex - 1)
                        label = label .. " |cff9a9a9a(" .. suffix .. ")|r"
                    end
                else
                    label = bracketName
                end
                btn.label:SetText(label)
                local isActive = ns.BuildMatchesActive and ns.BuildMatchesActive({ exportString = build.exportString })
                if isActive then
                    btn:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
                    btn.label:SetTextColor(0.3, 1, 0.3)
                else
                    btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
                    btn.label:SetTextColor(0.8, 0.8, 0.8)
                end
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 8, -yPos)
                btn:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
                BindCopyClick(btn, build.exportString)
                btn:Show()
                yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
            end
        end
    end
    yPos = yPos + 4

    return yPos
end

-- Icy Veins view: context-labeled builds (not hero-grouped). Buckets by
-- context; a context with 2+ builds gets a header, a lone build is a bare
-- row. Leveling builds bucket last under their own header/row.
local IV_COMPENDIUM_CONTEXT_ORDER = { "Raid", "Mythic+", "Delves", "General", "Leveling" }

local function RenderIcyVeinsTalentList(class, spec, yPos)
    local ivt = ns.GetIcyVeinsTalentSpecData and ns:GetIcyVeinsTalentSpecData(class, spec) or nil
    local builds = ivt and ivt.talents
    if not builds or #builds == 0 then
        UI.talentFallback:SetText(L["loadout_dock.no_icyveins_builds"] or "No Icy Veins talent builds available.")
        UI.talentFallback:ClearAllPoints()
        UI.talentFallback:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 4, -(yPos + 4))
        UI.talentFallback:Show()
        return yPos + 20
    end

    local buckets = {}
    for _, b in ipairs(builds) do
        local key = b.leveling and "Leveling" or (b.context or "General")
        buckets[key] = buckets[key] or {}
        buckets[key][#buckets[key] + 1] = b
    end

    local hdrIdx, rowIdx = 0, 0
    local function emitRow(build)
        rowIdx = rowIdx + 1
        local btn = UI._ensureTalentButton(rowIdx)
        if btn.heroIcon then btn.heroIcon:Hide() end
        btn.label:ClearAllPoints()
        btn.label:SetPoint("LEFT", 8, 0); btn.label:SetPoint("RIGHT", -8, 0)
        btn.label:SetText(build.buildLabel or build.context or "Build")
        btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        btn.label:SetTextColor(0.8, 0.8, 0.8)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 8, -yPos)
        btn:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
        BindCopyClick(btn, build.exportString)
        btn:Show()
        yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
    end

    local seen = {}
    local function emitBucket(key)
        local group = buckets[key]
        if not group or #group == 0 or seen[key] then return end
        seen[key] = true
        if #group >= 2 then
            hdrIdx = hdrIdx + 1
            local hdr = UI._ensureTalentHeroHeader(hdrIdx)
            hdr.label:SetText(key == "Leveling" and (L["talents.leveling"] or "Leveling") or key)
            hdr.label:SetTextColor(1, 0.82, 0)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, -yPos)
            hdr:SetPoint("RIGHT", UI.talentContent, "RIGHT", 0, 0)
            hdr:Show()
            yPos = yPos + TALENT_HERO_HEADER_HEIGHT
        end
        for _, build in ipairs(group) do emitRow(build) end
        yPos = yPos + 4
    end

    for _, key in ipairs(IV_COMPENDIUM_CONTEXT_ORDER) do emitBucket(key) end
    for key in pairs(buckets) do emitBucket(key) end
    return yPos
end

function ns:UpdateCompendiumAllTalents(specData, classFile, specKey)
    for _, b in ipairs(UI.talentButtons) do b:Hide() end
    for _, h in ipairs(UI.talentHeroHeaders) do h:Hide() end
    UI.talentFallback:Hide()

    -- Reset source on spec change so users land on Wowhead by default
    -- when browsing a new spec, matching the BiS / Enhancements tabs.
    local talentSpecKey = (classFile or "") .. "-" .. (specKey or "")
    if talentSpecKey ~= lastTalentSpecKey then
        UI.talentSource = "wowhead"
        lastTalentSpecKey = talentSpecKey
    end

    -- Source dropdown is the first row of talentContent. Archon may not
    -- cover every spec, so its option drops out when missing. PvP always
    -- shows so users can discover the feature; RenderPvPTalentList
    -- handles the "no data" copy inline.
    local archonAvailable = classFile and specKey
        and ns.GetArchonSpecData and ns.GetArchonSpecData(classFile, specKey) ~= nil
    local icyVeinsAvailable = classFile and specKey
        and ns.GetIcyVeinsTalentSpecData and ns:GetIcyVeinsTalentSpecData(classFile, specKey) ~= nil
    if not archonAvailable and UI.talentSource == "archon" then
        UI.talentSource = "wowhead"
    end
    if not icyVeinsAvailable and UI.talentSource == "icyveins" then
        UI.talentSource = "wowhead"
    end
    if UI._refreshTalentSourceDropdown then
        UI._refreshTalentSourceDropdown(archonAvailable, icyVeinsAvailable)
    end

    UI.talentSourceDropdown:ClearAllPoints()
    UI.talentSourceDropdown:SetPoint("TOPLEFT", UI.talentContent, "TOPLEFT", 0, 0)
    UI.talentSourceDropdown:SetPoint("TOPRIGHT", UI.talentContent, "TOPRIGHT", 0, 0)
    UI.talentSourceDropdown:Show()

    local yPos = 32 -- leave room for the dropdown row (DROPDOWN_HEIGHT 26 + 6 gap)
    if UI.talentSource == "archon" and archonAvailable then
        yPos = RenderArchonTalentList(classFile, specKey, yPos)
    elseif UI.talentSource == "icyveins" and icyVeinsAvailable then
        yPos = RenderIcyVeinsTalentList(classFile, specKey, yPos)
    elseif UI.talentSource == "pvp" then
        -- RenderPvPTalentList itself handles the no-data case and
        -- writes the talentFallback ("No PvP builds available."), so
        -- we route through it regardless of whether PvP data exists.
        yPos = RenderPvPTalentList(classFile, specKey, yPos)
    else
        yPos = RenderWowheadTalentList(specData, yPos)
    end

    UI.talentContent:SetHeight(yPos)
    UI.talentSection:Show()
end

-- Compendium enchant/gem renderers consume the slim PvP shape via
-- ns.BuildPvPEnchantsRows / ns.BuildPvPGemsRecord (PvPData.lua) — the
-- same builders the docked panel uses, so slot ordering and field
-- mapping stay in one place.
local function BuildPvPEnchantsSynthetic()
    if not ns.BuildPvPEnchantsRows then return nil end
    return ns.BuildPvPEnchantsRows(selectedClass, selectedSpec)
end

local function BuildPvPGemsSynthetic()
    if not ns.BuildPvPGemsRecord then return nil end
    return ns.BuildPvPGemsRecord(selectedClass, selectedSpec)
end

function ns:UpdateCompendiumEnchants()
    if not GEAR_DATA then return end
    local gearData = GEAR_DATA[selectedClass] and GEAR_DATA[selectedClass][selectedSpec]
    ns.Sections.Enhancements.RenderCompendiumEnchantsGems({
        wowheadEnchants = gearData and gearData.enchants,
        wowheadGems     = gearData and gearData.gems,
        pvpEnchants     = BuildPvPEnchantsSynthetic(),
        pvpGems         = BuildPvPGemsSynthetic(),
        specKey         = (selectedClass or "") .. "-" .. (selectedSpec or ""),
        sourceLabels    = ns.ENH_SOURCE_LABELS,
        getDisplayName  = GetItemDisplayName,
        refresh         = function()
            ns:UpdateCompendiumEnchants()
            ns:LayoutCompendium()
        end,
    })
end

function ns:UpdateCompendiumConsumables()
    if not GEAR_DATA then return end
    local gearData = GEAR_DATA[selectedClass] and GEAR_DATA[selectedClass][selectedSpec]
    ns.Sections.Enhancements.RenderCompendiumConsumables({
        consumables = gearData and gearData.consumables,
    })
end

function ns:UpdateCompendiumTrinkets()
    if not GEAR_DATA then return end
    local gearData = GEAR_DATA[selectedClass] and GEAR_DATA[selectedClass][selectedSpec]
    ns.Sections.Trinkets.RenderCompendium({
        trinkets = gearData and gearData.trinkets,
        refresh  = function() ns:UpdateCompendium() end,
    })
end

-- Crafting tab — delegated entirely to Sections/Crafting.lua. The Section
-- module owns the frame pool, context dropdown, and render code.
function ns:UpdateCompendiumCrafts()
    ns.Sections.Crafting.RenderCompendium({
        class   = selectedClass,
        spec    = selectedSpec,
        refresh = function() ns:UpdateCompendium() end,
    })
end

local function BuildPvPBisSyntheticTabs()
    if not ns.BuildPvPBisTabs then return nil end
    return ns.BuildPvPBisTabs(selectedClass, selectedSpec)
end

function ns:UpdateCompendiumBis()
    local wowheadBis = GEAR_DATA and GEAR_DATA[selectedClass] and GEAR_DATA[selectedClass][selectedSpec]
        and GEAR_DATA[selectedClass][selectedSpec].bisGear
    local ivSpecData = ns.GetIcyVeinsSpecData and ns:GetIcyVeinsSpecData(selectedClass, selectedSpec)
    local archonSpecData = ns.GetArchonGearSpecData and ns:GetArchonGearSpecData(selectedClass, selectedSpec)
    ns.Sections.Gear.RenderCompendium({
        wowheadBis = wowheadBis,
        ivBis      = ivSpecData and ivSpecData.bisGear,
        archonBis  = archonSpecData and archonSpecData.bisGear,
        pvpBis     = BuildPvPBisSyntheticTabs(),
        specKey    = (selectedClass or "") .. "-" .. (selectedSpec or ""),
        refresh    = function() ns:UpdateCompendium(); ns:LayoutCompendium() end,
    })
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

function ns:LayoutCompendium()
    -- Refresh the source tag on every layout pass so it tracks dropdown changes
    -- whose refresh callback only re-lays-out (e.g. the Enhancements / gear /
    -- crafting source/context pickers), not just the full UpdateCompendium path.
    UpdateCompendiumAttribution(selectedClass, selectedSpec)

    local y = 0

    local function LayoutSection(section, collapsed, content, contentHeight)
        if not section:IsShown() then return y end
        section:ClearAllPoints()
        section:SetPoint("TOPLEFT", UI.scrollChild, "TOPLEFT", INSET_PAD, y)
        section:SetPoint("RIGHT", UI.scrollChild, "RIGHT", -INSET_PAD, 0)
        local h = SECTION_HEADER_HEIGHT
        if not collapsed then h = h + contentHeight + 4 end
        section:SetHeight(h)
        y = y - h - 4
        return y
    end

    if UI.emptyText:IsShown() then
        UI.scrollChild:SetHeight(120)
        return
    end

    if activeTab == "guide" then
        LayoutSection(
            UI.statSection, UI.statCollapsed, UI.statContent,
            ns.Sections.Stats.GetCompendiumContentHeight()
        )
        local talentH = 0
        -- Iterate the actual pool (which can grow past MAX_TALENT_BUTTONS
        -- via _ensureTalentButton). The Wowhead-only Guide path doesn't
        -- usually need extra rows, but this stays consistent with the
        -- Talents-tab path below and protects against silent clipping.
        for i = 1, #UI.talentButtons do if UI.talentButtons[i]:IsShown() then talentH = talentH + TALENT_BTN_HEIGHT + TALENT_BTN_GAP end end
        if UI.talentFallback:IsShown() then talentH = 20 end
        LayoutSection(UI.talentSection, UI.talentCollapsed, UI.talentContent, talentH)
        LayoutSection(
            UI.rotationSection, UI.rotationCollapsed, UI.rotationContent,
            ns.Sections.Rotation.GetCompendiumContentHeight()
        )
    elseif activeTab == "talents" then
        local talentH = 0
        if UI.talentSourceDropdown and UI.talentSourceDropdown:IsShown() then talentH = talentH + 32 end
        -- Iterate by actual pool length — the Archon view grows the
        -- pool well past the initial MAX_* allocation.
        for i = 1, #UI.talentHeroHeaders do if UI.talentHeroHeaders[i]:IsShown() then talentH = talentH + TALENT_HERO_HEADER_HEIGHT + 4 end end
        for i = 1, #UI.talentButtons do if UI.talentButtons[i]:IsShown() then talentH = talentH + TALENT_BTN_HEIGHT + TALENT_BTN_GAP end end
        if UI.talentFallback:IsShown() then talentH = 20 end
        LayoutSection(UI.talentSection, UI.talentCollapsed, UI.talentContent, talentH)
    elseif activeTab == "bis" then
        LayoutSection(
            UI.bisSection, UI.bisCollapsed, UI.bisContent,
            ns.Sections.Gear.GetCompendiumContentHeight()
        )
    elseif activeTab == "trinkets" then
        LayoutSection(
            UI.trinketSection, UI.trinketCollapsed, UI.trinketContent,
            ns.Sections.Trinkets.GetCompendiumContentHeight()
        )
    elseif activeTab == "enhancements" then
        local enhFrames = ns.Sections.Enhancements.GetCompendiumFrames()
        -- Source dropdown sits ABOVE the enchants section.
        if enhFrames.sourceDropdown and enhFrames.sourceDropdown:IsShown() then
            enhFrames.sourceDropdown:ClearAllPoints()
            enhFrames.sourceDropdown:SetPoint("TOPLEFT", UI.scrollChild, "TOPLEFT", INSET_PAD, y)
            enhFrames.sourceDropdown:SetPoint("RIGHT", UI.scrollChild, "RIGHT", -INSET_PAD, 0)
            y = y - 30
        end
        LayoutSection(enhFrames.enchSection, enhFrames.enchCollapsed, enhFrames.enchContent,
            ns.Sections.Enhancements.GetCompendiumEnchantHeight())
        LayoutSection(enhFrames.gemSection, enhFrames.gemCollapsed, enhFrames.gemContent,
            ns.Sections.Enhancements.GetCompendiumGemHeight())
        LayoutSection(enhFrames.consumSection, enhFrames.consumCollapsed, enhFrames.consumContent,
            ns.Sections.Enhancements.GetCompendiumConsumHeight())
    elseif activeTab == "crafting" then
        -- Crafting content height comes from the Section module — frame
        -- pool sizes + dropdown offset live there.
        LayoutSection(
            UI.craftSection, UI.craftCollapsed, UI.craftContent,
            ns.Sections.Crafting.GetCompendiumContentHeight()
        )
    end

    UI.scrollChild:SetHeight(math.abs(y) + 20)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function ns:OpenCompendium()
    InitFrame()

    if UI.frame:IsShown() then
        UI.frame:Hide()
        return
    end

    -- Restore saved state or default to player's class/spec
    if not selectedClass then
        if ClassCodexDB and ClassCodexDB.compendiumClass and ClassCodexDB.compendiumSpec then
            selectedClass = ClassCodexDB.compendiumClass
            selectedSpec = ClassCodexDB.compendiumSpec
            selectedHero = ClassCodexDB.compendiumHero
        else
            local _, classToken = UnitClass("player")
            selectedClass = classToken
            local specIndex = GetSpecialization()
            if specIndex and SPEC_KEYS[classToken] then
                selectedSpec = SPEC_KEYS[classToken][specIndex]
            else
                selectedSpec = SPEC_KEYS[classToken] and SPEC_KEYS[classToken][1]
            end
        end
        -- Auto-select first hero if none saved
        if not selectedHero and selectedSpec then
            local specData = DATA[selectedClass] and DATA[selectedClass][selectedSpec]
            if specData then
                local opts = GetHeroTalentOptions(specData)
                selectedHero = opts[1] or "All"
            end
        end
    end

    -- Restore saved tab
    if ClassCodexDB and ClassCodexDB.compendiumTab then
        activeTab = ClassCodexDB.compendiumTab
        for i, data in ipairs(UI.TAB_DATA) do
            if data.key == activeTab then
                PanelTemplates_SetTab(UI.frame, i)
                break
            end
        end
    end

    SetupClassDropdown()
    SetupSpecDropdown()
    SetupHeroDropdown()

    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    UI.frame:Show()
    ns:UpdateCompendium()
end
