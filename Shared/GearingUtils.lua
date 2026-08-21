local _, ns = ...

-- Shared gearing helpers — item cache, format/quality lookups, BiS reverse
-- lookups (used by tooltip integration), row icon + tooltip factories, and
-- the PvP shape-conversion wrappers. Consumed by every Sections/* module
-- that renders gear data and by GearingSections.lua's dispatcher.
--
-- Pure utility layer: this file creates no widgets and registers no event
-- handlers other than ITEM_DATA_LOAD_RESULT for cache invalidation.

local GEAR_DATA = ClassCodexGearData
local L = ns.L

local IV_DATA = ClassCodexIcyVeinsData or {}
local IVT_DATA = ClassCodexIcyVeinsTalentData or {}
local ARCHON_GEAR_DATA = ClassCodexArchonGearData or {}

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

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

-- Enhance Shaman has 10 enchant slots (MH + OH weapon enchants, Helm,
-- Shoulders, Bracers, Chest, Belt, Legs, Boots, Ring). Cap at 12 to
-- match Compendium.lua's MAX_ENCHANT_ROWS so neither surface drops rows.
local MAX_ENCHANT_ROWS = 12
local MAX_GEM_ROWS = 4
local MAX_CONSUMABLE_ROWS = 6

-------------------------------------------------------------------------------
-- Item Cache
-------------------------------------------------------------------------------

local itemCache = {}
local pendingItems = {}
local gearingDirty = false

local function RequestItemData(itemId)
    if not itemId or itemId == 0 then return end
    if itemCache[itemId] or pendingItems[itemId] then return end
    pendingItems[itemId] = true
    C_Item.RequestLoadItemDataByID(itemId)
end

local function GetItemName(itemRef)
    if not itemRef then return "" end
    -- Spell-based entries (e.g. DK runeforges): resolve via C_Spell
    if itemRef.spellId then
        if C_Spell and C_Spell.GetSpellName then
            local name = C_Spell.GetSpellName(itemRef.spellId)
            if name then return name end
        elseif GetSpellInfo then
            local name = GetSpellInfo(itemRef.spellId)
            if name then return name end
        end
    end
    local cached = itemCache[itemRef.itemId]
    if cached and cached.name then return cached.name end
    if itemRef.name and itemRef.name ~= "" then return itemRef.name end
    if itemRef.spellId then return "Spell " .. itemRef.spellId end
    return "Item " .. itemRef.itemId
end

local function GetItemQuality(itemId)
    local cached = itemCache[itemId]
    return cached and cached.quality or nil
end

-- FormatItem(itemRef [, name]) -> string
-- Convenience wrapper around ns.FormatItemLabel that pulls the
-- quality from the cache for callers that don't already have it.
-- Pass an explicit name override (e.g. after StripEnchantPrefix)
-- when the displayed text differs from the resolved item name.
local function FormatItem(itemRef, nameOverride)
    if not itemRef then return "" end
    local name = nameOverride or GetItemName(itemRef)
    return ns.FormatItemLabel(name, GetItemQuality(itemRef.itemId))
end

local itemEventFrame = CreateFrame("Frame")
itemEventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
itemEventFrame:SetScript("OnEvent", function(_, _, itemId, success)
    if success then
        pendingItems[itemId] = nil
        local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemId)
        if name then
            itemCache[itemId] = { name = name, quality = quality, icon = icon }
            if not gearingDirty then
                gearingDirty = true
                C_Timer.After(0.1, function()
                    gearingDirty = false
                    if ns.panel and ns.panel:IsShown() then
                        ns:UpdateGearingSections()
                        ns:LayoutPanel()
                    end
                end)
            end
        end
    end
end)

local function RequestAllItems(gearData)
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
    -- Crafting item prefetch — defer to the Section module so this stays
    -- in sync with whatever shape Sections/Crafting.lua expects.
    local craftClassToken, craftSpec = ns.GetPlayerClassSpec()
    ns.Sections.Crafting.RequestItems(craftClassToken, craftSpec, RequestItemData)
    if gearData.bisGear then
        for _, tab in ipairs(gearData.bisGear) do
            for _, g in ipairs(tab.slots) do RequestItemData(g.item.itemId) end
        end
    end
end

-------------------------------------------------------------------------------
-- Gear Data Lookup
-------------------------------------------------------------------------------

local function GetSpecGearData()
    if not GEAR_DATA then return nil end
    local classToken, specKey = ns.GetClassAndSpec()
    if not classToken or not specKey then return nil end
    local classData = GEAR_DATA[classToken]
    if not classData then return nil end
    return classData[specKey]
end

-- Resolve the (classToken, spec-without-class-prefix) pair the docked
-- panel uses for PvP data lookups via PvPData.lua. The docked surface
-- always reflects the player's current spec.
local function GetPlayerClassSpec()
    local classToken = select(2, UnitClass("player"))
    local specKey = ns.GetSpecKey()
    if not classToken or not specKey then return nil, nil end
    local spec = specKey:match("-(.+)") or specKey
    return classToken, spec
end

-- PvP shape conversion lives in Shared/PvPData.lua so the Compendium and
-- the docked panel consume the same builders. Bundled into one table to
-- minimise upvalue pressure on UpdateGearingSections (Lua's 60-upvalue
-- limit was tripping after these helpers were added).
local PvP = {
    bis = function()
        if not ns.BuildPvPBisTabs then return nil end
        local classToken, spec = GetPlayerClassSpec()
        return ns.BuildPvPBisTabs(classToken, spec)
    end,
    enchants = function()
        if not ns.BuildPvPEnchantsRows then return nil end
        local classToken, spec = GetPlayerClassSpec()
        return ns.BuildPvPEnchantsRows(classToken, spec)
    end,
    gems = function()
        if not ns.BuildPvPGemsRecord then return nil end
        local classToken, spec = GetPlayerClassSpec()
        return ns.BuildPvPGemsRecord(classToken, spec)
    end,
}

-- Expose trinket tier lookup for tooltip integration
function ns:GetTrinketTier(itemId)
    local gearData = GetSpecGearData()
    if not gearData or not gearData.trinkets then return nil, nil, nil end
    for _, t in ipairs(gearData.trinkets) do
        if t.itemId == itemId then
            local color = TIER_COLORS[t.tier]
            return t.tier, color, t.source
        end
    end
    return nil, nil, nil
end

-- Locale-aware class/spec name resolution for tooltip BiS labels.
-- Class names come from Blizzard's LOCALIZED_CLASS_NAMES_MALE. Spec names are
-- resolved via GetSpecializationInfoForClassID using a local (classToken,
-- specKey) → (classID, specIndex) mapping that mirrors the data file keys.
-- Final fallback is a capitalized data key.
local SPEC_KEYS_BY_CLASS = {
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

local CLASS_ID_BY_TOKEN = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
    DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

local localizedClassNameCache = {}
local localizedSpecNameCache = {}

local function GetLocalizedClassName(classToken)
    local cached = localizedClassNameCache[classToken]
    if cached ~= nil then return cached end
    local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classToken]) or classToken
    localizedClassNameCache[classToken] = name
    return name
end

local function GetLocalizedSpecName(classToken, specKey)
    local cacheKey = classToken .. "|" .. specKey
    local cached = localizedSpecNameCache[cacheKey]
    if cached ~= nil then return cached end

    local result
    local classID = CLASS_ID_BY_TOKEN[classToken]
    local keys = SPEC_KEYS_BY_CLASS[classToken]
    local specIndex
    if keys then
        for i, k in ipairs(keys) do
            if k == specKey then specIndex = i; break end
        end
    end
    if classID and specIndex and GetSpecializationInfoForClassID then
        local _, name = GetSpecializationInfoForClassID(classID, specIndex)
        if name and name ~= "" then result = name end
    end
    if not result then
        result = specKey:sub(1, 1):upper() .. specKey:sub(2)
    end
    localizedSpecNameCache[cacheKey] = result
    return result
end

local CLASS_SPEC_COUNT = {}
local wowheadBisLookup = {}
local icyVeinsBisLookup = {}
local trinketLookup = {}
local trinketSourceLookup = {}
-- itemId -> bonusIDs, harvested from every source that carries them (Wowhead /
-- Icy Veins BiS slots + trinkets). Archon's gear pages don't publish bonus IDs,
-- so the Archon source borrows them here to render the correct item level.
local bonusIdLookup = {}
-- context ("raid" / "dungeon") -> the upgrade-track bonusIDs typical of that
-- content, taken from the first trinket we see in that context. Used as the
-- fallback for Archon items we can't resolve exactly, so a raid pick still
-- shows a mythic-raid item level rather than its base.
local contextBonusDefault = {}

function ns:GetTrinketSource(itemId)
    return trinketSourceLookup[itemId]
end

function ns:GetItemBonusIDs(itemId)
    return bonusIdLookup[itemId]
end

function ns:GetContextBonusDefault(context)
    return context and contextBonusDefault[context]
end

local function BuildBisLookup()
    if not GEAR_DATA then return end
    for classToken, specs in pairs(GEAR_DATA) do
        local count = 0
        for _ in pairs(specs) do count = count + 1 end
        CLASS_SPEC_COUNT[classToken] = count
    end

    for classToken, specs in pairs(GEAR_DATA) do
        local className = GetLocalizedClassName(classToken)
        for specKey, specData in pairs(specs) do
            local label = GetLocalizedSpecName(classToken, specKey) .. " " .. className

            local trinketIds = {}
            if specData.trinkets then
                for _, t in ipairs(specData.trinkets) do
                    trinketIds[t.itemId] = true
                end
            end

            if specData.bisGear then
                for _, tab in ipairs(specData.bisGear) do
                    for _, entry in ipairs(tab.slots) do
                        local id = entry.item.itemId
                        if entry.item.bonusIDs and not bonusIdLookup[id] then
                            bonusIdLookup[id] = entry.item.bonusIDs
                        end
                    end
                    if tab.label == "Overall" then
                        for _, entry in ipairs(tab.slots) do
                            local id = entry.item.itemId
                            local slotLower = entry.slot and entry.slot:lower() or ""
                            if not slotLower:find("trinket") and not trinketIds[id] then
                                if not wowheadBisLookup[id] then wowheadBisLookup[id] = {} end
                                wowheadBisLookup[id][#wowheadBisLookup[id] + 1] = { label = label, class = classToken, spec = specKey }
                            end
                        end
                    end
                end
            end

            if specData.trinkets then
                for _, t in ipairs(specData.trinkets) do
                    local id = t.itemId
                    if not trinketLookup[id] then trinketLookup[id] = {} end
                    trinketLookup[id][#trinketLookup[id] + 1] = { label = label, class = classToken, spec = specKey, tier = t.tier }
                    if t.source and not trinketSourceLookup[id] then
                        trinketSourceLookup[id] = t.source
                    end
                    if t.bonusIDs then
                        if not bonusIdLookup[id] then bonusIdLookup[id] = t.bonusIDs end
                        for _, ctx in ipairs(t.contexts or {}) do
                            if not contextBonusDefault[ctx] then contextBonusDefault[ctx] = t.bonusIDs end
                        end
                    end
                end
            end
        end
    end

    -- Icy Veins BiS lookup (all tabs — items differ between M+ / Raid / Overall).
    for classToken, specs in pairs(IV_DATA) do
        local className = GetLocalizedClassName(classToken)
        if not CLASS_SPEC_COUNT[classToken] then
            local count = 0
            for _ in pairs(specs) do count = count + 1 end
            CLASS_SPEC_COUNT[classToken] = count
        end
        for specKey, specData in pairs(specs) do
            local label = GetLocalizedSpecName(classToken, specKey) .. " " .. className
            if specData.bisGear then
                for _, tab in ipairs(specData.bisGear) do
                    for _, entry in ipairs(tab.slots) do
                        local id = entry.item.itemId
                        if entry.item.bonusIDs and not bonusIdLookup[id] then
                            bonusIdLookup[id] = entry.item.bonusIDs
                        end
                        if not icyVeinsBisLookup[id] then icyVeinsBisLookup[id] = {} end
                        local found = false
                        for _, existing in ipairs(icyVeinsBisLookup[id]) do
                            if existing.label == label then
                                existing.tabs[#existing.tabs + 1] = tab.label
                                found = true
                                break
                            end
                        end
                        if not found then
                            icyVeinsBisLookup[id][#icyVeinsBisLookup[id] + 1] = {
                                label = label, class = classToken, spec = specKey,
                                tabs = { tab.label },
                            }
                        end
                    end
                end
            end
        end
    end
end

BuildBisLookup()

-- Consolidate entries: if all specs of a class share the same entry, show
-- just the class name.
local function ConsolidateByClass(entries)
    local byClass = {}
    local classOrder = {}
    for _, entry in ipairs(entries) do
        if not byClass[entry.class] then
            byClass[entry.class] = {}
            classOrder[#classOrder + 1] = entry.class
        end
        byClass[entry.class][#byClass[entry.class] + 1] = entry
    end

    local result = {}
    for _, classToken in ipairs(classOrder) do
        local classEntries = byClass[classToken]
        local totalSpecs = CLASS_SPEC_COUNT[classToken] or 0
        local className = GetLocalizedClassName(classToken)
        local sameTier = true
        if #classEntries > 1 then
            for i = 2, #classEntries do
                if classEntries[i].tier ~= classEntries[1].tier then sameTier = false; break end
            end
        end
        if #classEntries >= totalSpecs and totalSpecs > 0 and sameTier then
            result[#result + 1] = { label = className, class = classToken, tier = classEntries[1].tier, consolidated = true }
        else
            for _, e in ipairs(classEntries) do
                e.consolidated = false
                result[#result + 1] = e
            end
        end
    end
    return result
end

function ns:GetWowheadBisSpecs(itemId)
    local raw = wowheadBisLookup[itemId]
    if not raw then return nil end
    return ConsolidateByClass(raw)
end

function ns:GetIcyVeinsBisSpecs(itemId)
    local raw = icyVeinsBisLookup[itemId]
    if not raw then return nil end
    return ConsolidateByClass(raw)
end

function ns:GetIcyVeinsData()
    return IV_DATA
end

function ns:GetIcyVeinsSpecData(classToken, specKey)
    if not classToken or not specKey then return nil end
    local classData = IV_DATA[classToken]
    if not classData then return nil end
    return classData[specKey]
end

function ns:GetArchonGearSpecData(classToken, specKey)
    if not classToken or not specKey then return nil end
    local classData = ARCHON_GEAR_DATA[classToken]
    if not classData then return nil end
    return classData[specKey]
end

-- Archon's Gear Overview lists items in slot order but never names the slot,
-- so we recover a display label from each item's equip location. English
-- labels keep it consistent with the Wowhead / Icy Veins sources, whose slot
-- strings are also raw English from their guides.
local EQUIPLOC_SLOT = {
    INVTYPE_HEAD = "Head",
    INVTYPE_NECK = "Neck",
    INVTYPE_SHOULDER = "Shoulders",
    INVTYPE_CLOAK = "Cloak",
    INVTYPE_CHEST = "Chest",
    INVTYPE_ROBE = "Chest",
    INVTYPE_WRIST = "Wrist",
    INVTYPE_HAND = "Gloves",
    INVTYPE_WAIST = "Belt",
    INVTYPE_LEGS = "Legs",
    INVTYPE_FEET = "Feet",
    INVTYPE_FINGER = "Ring",
    INVTYPE_TRINKET = "Trinket",
    INVTYPE_WEAPON = "Weapon",
    INVTYPE_2HWEAPON = "Weapon",
    INVTYPE_WEAPONMAINHAND = "Main Hand",
    INVTYPE_WEAPONOFFHAND = "Off Hand",
    INVTYPE_HOLDABLE = "Off Hand",
    INVTYPE_SHIELD = "Off Hand",
    INVTYPE_RANGED = "Weapon",
    INVTYPE_RANGEDRIGHT = "Weapon",
}

function ns.GearSlotName(itemId)
    if not itemId then return "" end
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(itemId)
    return (equipLoc and EQUIPLOC_SLOT[equipLoc]) or ""
end

function ns:GetIcyVeinsTalentSpecData(classToken, specKey)
    if not classToken or not specKey then return nil end
    local classData = IVT_DATA[classToken]
    if not classData then return nil end
    return classData[specKey]
end

function ns:GetTrinketSpecs(itemId)
    local raw = trinketLookup[itemId]
    if not raw then return nil end
    return ConsolidateByClass(raw)
end

-------------------------------------------------------------------------------
-- Item Icon Helper
-------------------------------------------------------------------------------

local ICON_SIZE = 16

local function GetItemIcon(itemId)
    local cached = itemCache[itemId]
    if cached and cached.icon then return cached.icon end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    return icon
end

local function CreateRowIcon(row)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", 2, 0)
    icon:Hide()
    row.icon = icon
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

-- GetItemCount sees bags + bank + reagent bank + warbank (with the 5th
-- arg) but NOT equipment slots, so we need the IsEquippedItem
-- short-circuit. Returns false when the user has opted out via the
-- "Highlight Owned Gear" setting.
local function IsItemOwned(itemId)
    if not itemId then return false end
    if ClassCodexDB and ClassCodexDB.highlightOwnedGear == false then return false end
    if IsEquippedItem and IsEquippedItem(itemId) then return true end
    return (GetItemCount(itemId, true, false, true, true) or 0) > 0
end

-------------------------------------------------------------------------------
-- Item Tooltip Helper
-------------------------------------------------------------------------------

local function GetItemLink(itemId)
    local _, link = C_Item.GetItemInfo(itemId)
    return link
end

local function HandleItemClick(self)
    if not self.itemId then return end
    local link = GetItemLink(self.itemId)
    if not link then return end
    if IsModifiedClick("CHATLINK") then
        ChatEdit_InsertLink(link)
    elseif IsModifiedClick("DRESSUP") then
        DressUpItemLink(link)
    end
end

local function SetupItemTooltip(row)
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", HandleItemClick)
    row:SetScript("OnEnter", function(self)
        if self.spellId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellId)
            GameTooltip:Show()
        elseif self.itemId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.bonusIDs and #self.bonusIDs > 0 then
                local bonusStr = #self.bonusIDs .. ":" .. table.concat(self.bonusIDs, ":")
                local link = format("item:%d::::::::::::%s", self.itemId, bonusStr)
                local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
                if not ok then GameTooltip:SetItemByID(self.itemId) end
            else
                GameTooltip:SetItemByID(self.itemId)
            end
            if self.altItemId then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine((L and L["gear.tooltip.alternative"]) or "Alternative:", 0.6, 0.6, 0.6)
                local altRef = { itemId = self.altItemId, name = self.altName or "" }
                GameTooltip:AddLine("  " .. FormatItem(altRef))
            end
            if self.embItemId then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine((L and L["gear.tooltip.embellishment"]) or "Embellishment:", 0.6, 0.6, 0.6)
                local embRef = { itemId = self.embItemId, name = self.embName or "" }
                GameTooltip:AddLine("  " .. FormatItem(embRef))
            end
            if self.sourceText then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine(SOURCE or "Source", self.sourceText, 0.5, 0.5, 0.5, 1, 0.82, 0)
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-------------------------------------------------------------------------------
-- Export everything Sections/* and the panel dispatcher need on `ns`.
-------------------------------------------------------------------------------
ns.FormatItem = FormatItem
ns.IsItemOwned = IsItemOwned
ns.CreateRowIcon = CreateRowIcon
ns.SetRowIcon = SetRowIcon
ns.GetSpellIcon = GetSpellIcon
ns.SetupItemTooltip = SetupItemTooltip
ns.GetItemIcon = GetItemIcon
ns.GetItemName = GetItemName
ns.HandleItemClick = HandleItemClick
ns.RequestItemData = RequestItemData
ns.RequestAllItems = RequestAllItems
ns.GetSpecGearData = GetSpecGearData
ns.GetPlayerClassSpec = GetPlayerClassSpec
ns.GearingPvP = PvP
ns.TIER_COLORS = TIER_COLORS
ns.TIER_ORDER = TIER_ORDER
ns.CONTEXT_LABELS = CONTEXT_LABELS
ns.CONSUMABLE_ORDER = CONSUMABLE_ORDER
ns.CONSUMABLE_LABELS = CONSUMABLE_LABELS
ns.ICON_SIZE_GEAR = ICON_SIZE

-- Right-aligned source/drop column: grow to fit its text (up to `cap`) but never
-- so wide that the name column to its left drops below `nameMin`. On a wide pane
-- the full source shows; on a narrow one it caps and ellipsizes as before.
-- `leftCols` = width consumed left of the name (slot/tier + icon + gaps + pad).
function ns.SizeSourceColumn(fs, rowWidth, leftCols, nameMin, cap)
    local content = math.ceil(fs:GetStringWidth()) + 2
    local maxByName = (rowWidth and rowWidth > 0)
        and math.max(20, rowWidth - leftCols - nameMin)
        or content
    fs:SetWidth(math.max(1, math.min(content, maxByName, cap or 300)))
end
ns.MAX_ENCHANT_ROWS = MAX_ENCHANT_ROWS
ns.MAX_GEM_ROWS = MAX_GEM_ROWS
ns.MAX_CONSUMABLE_ROWS = MAX_CONSUMABLE_ROWS
