local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

local Crafting = {}
ns.Sections.Crafting = Crafting

-------------------------------------------------------------------------------
-- Shared constants + helpers
-------------------------------------------------------------------------------

-- Slot icon sizing: ICON_SIZE wrapped by a Quickslot2 bevel sized at
-- the KL-style 1.8125× ratio (the Blizzard texture renders cleanly at
-- this ratio; tighter ratios distort the bevel art). The card is sized
-- to the ICON, not the slot — the bevel is allowed to extend outside
-- the card on all sides so rows can pack tightly without the bevel
-- bloating the row stride.
local ICON_SIZE     = 32
local SLOT_FRAME    = math.floor(ICON_SIZE * 1.8125 + 0.5) -- ≈ 58
local SLOT_OVERHANG = math.floor((SLOT_FRAME - ICON_SIZE) / 2) -- bevel bleed past the icon
local CARD_HEIGHT   = 40                                       -- slightly tighter row stride than the slot height — bevels overlap more between rows
local HEADER_HEIGHT = ns.SECTION_HEADER_HEIGHT or 24 -- matches docked-mode CreateSectionHeader chrome
local CONTENT_INSET = 2                                        -- horizontal indent for sub-headers / dropdown / fallback
-- Icon offset from the card's left edge. Slot bevel is centered on the
-- icon, so its visible left edge sits at (CARD_INSET_X - SLOT_OVERHANG).
-- At SLOT_OVERHANG (≈13) the bevel left edge is exactly flush with the
-- card boundary; smaller values let the bevel bleed left into the
-- parent margin. We pin the icon a couple px past flush so the move
-- reads visibly and the bevel doesn't get clipped by the parent.
local CARD_INSET_X  = CONTENT_INSET + 2 -- icon left edge sits 2 px right of the sub-header text
local TEXT_GAP_X    = 5                 -- gap from icon's right edge to the item name (skips the bevel bleed)
-- Vertical buffer around sub-headers. Three separate values now:
--   • HEADER_PAD_FIRST  pad above the FIRST sub-header in the section
--     (no prior card slot to absorb, so just a hair off the section
--     title)
--   • HEADER_PAD_BEFORE pad above a subsequent sub-header — needs to
--     match the slot bleed so the prior section's last card doesn't
--     bevel-overlap the next header
--   • HEADER_PAD_AFTER  pad below every sub-header. Allowed to be a
--     touch less than SLOT_OVERHANG — the bevel slightly overlapping
--     the header's bottom pixels is fine visually and tightens the
--     vertical rhythm.
local SLOT_BLEED       = math.max(0, math.floor((SLOT_FRAME - CARD_HEIGHT) / 2))
local HEADER_PAD_FIRST = 0
local HEADER_PAD_AFTER  = math.max(0, SLOT_BLEED - 4)
local HEADER_PAD_BEFORE = HEADER_PAD_AFTER -- mirror so the pad above and below a sub-header match visually
local MAX_CARDS     = 15  -- comfortably fits 8 crafts + 5 embellishments + 2 headers
local MAX_CRAFT_CARDS = 8
local MAX_EMB_CARDS   = 7

local CONTEXTS = {
    { key = "raid",       label = function() return L["context.raid"] end },
    { key = "mythicPlus", label = function() return L["context.mythic_plus"] end },
    { key = "pvp",        label = function() return L["pvp.label"] end },
}

local function GetPerSpecCtx()
    if ns.GetPerSpecState then
        local ps = ns.GetPerSpecState()
        if ps and ps.craftingContext then return ps.craftingContext end
    end
    return "raid"
end

local function SetPerSpecCtx(ctx)
    if ns.GetPerSpecState then
        local ps = ns.GetPerSpecState()
        if ps then ps.craftingContext = ctx end
    end
end

-- Active crafting context ("raid" / "mythicPlus" / "pvp"). Used by attribution
-- to credit Archon (PvE) vs Murlok (PvP) for the crafts/embellishments lists.
function Crafting.GetContextKey()
    return GetPerSpecCtx()
end

-- "Top picks only" filter — when enabled, the Crafting tab drops
-- trailing non-highlighted entries so only items flagged BiS
-- (bis = true) or popular (popular = true) show up. Reduces card
-- count to the meta-relevant picks for first-time-look clarity.
-- Default ON; toggled via the gear menu on the tab header AND the
-- main settings panel (Settings.lua → "Crafting" section).
local function IsTopPicksOnly()
    if ClassCodexDB and ClassCodexDB.craftingTopPicksOnly ~= nil then
        return ClassCodexDB.craftingTopPicksOnly == true
    end
    return true
end

-- If filtering would empty the section we keep the original list — a
-- context with no BiS/popular markers (rare; mostly PvP healers with
-- thin Murlok samples) should still show its rows rather than render
-- as an empty Crafting tab.
local function FilterTopPicks(entries)
    if not entries or #entries == 0 then return entries end
    if not IsTopPicksOnly() then return entries end
    local filtered = {}
    for _, e in ipairs(entries) do
        if e.bis == true or e.popular == true then
            filtered[#filtered + 1] = e
        end
    end
    if #filtered == 0 then return entries end
    return filtered
end

-------------------------------------------------------------------------------
-- Embellishment-applied detection
-------------------------------------------------------------------------------
-- Strategy: bonus_id intersection.
--
-- Every crafted item carries a list of bonus_ids encoded into its item
-- link (rank, sockets, missive, spec stamp, and — when an embellishment
-- is applied — the embellishment's effect bonus_id). We parse the
-- bonus_ids straight out of each equipped item's link, union them into
-- a set, and intersect against the bonusIDs array we ship for each
-- embellishment in Data/<Class>/crafting.lua. If the embellishment's
-- bonus_ids are a (non-trivial) subset of the equipped union, the
-- embellishment is applied somewhere on the player.
--
-- Caveat: where two embellishments happen to share identical SimC
-- bonusIDs in our data (same rank/missive/spec stamp combo), both will
-- light up. Distinguishing them cleanly needs a per-embellishment
-- effect_bonus_id map (~20 entries per season, sourced from
-- Wowhead/SimC) — tracked as a follow-up.
--
-- State (pure event-driven, no TTL):
--   embBonusIds[itemId]  → numeric set parsed from the embellishment
--                          item's link bonusIDs (cached when non-empty)
--   equippedBonusIds     → union of every bonus_id across equipped
--                          slots. Rebuilt only after
--                          PLAYER_EQUIPMENT_CHANGED / BAG_UPDATE_DELAYED.

local embBonusIds = {}  -- itemId -> set of bonus_ids from our crafting data
local equippedBonusIds  -- nil = needs rebuild; table = union of equipped bonus_ids

-- Older clients lack the modern item-link layout; keep a tooltip text
-- scanner as a last-resort fallback so detection degrades to "owned in
-- bags / equipped slot itself" if link parsing returns nothing.
local craftScanner = ns.CreateTooltipScanner("ClassCodexCraftScanTip")

local function InvalidateEquippedState()
    equippedBonusIds = nil
    equippedSpellIds = nil
    craftScanner:InvalidateInventoryCache()
end

local stateFrame = CreateFrame("Frame")
stateFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED") -- carrier swapped → bonus_ids change
stateFrame:RegisterEvent("BAG_UPDATE_DELAYED")       -- new craft landed in bags
stateFrame:SetScript("OnEvent", InvalidateEquippedState)

-- Bonus_ids that EVERY craft carries (rank, "crafted by player", etc.)
-- — useless for distinguishing embellishments and excluded from the
-- match set so they don't dilute the signal. Per-spec stamp bonuses
-- (8790..8795 range, observed in current Midnight data) also go here
-- because they encode which spec was active at craft time, not which
-- embellishment.
local BORING_BONUS_IDS = {
    [8960]  = true, -- crafted-by-player flag
    [12066] = true, -- rank 5 quality
    [12214] = true, -- crafted-stat allocation tick
    [8790]  = true, [8791] = true, [8792] = true,
    [8793]  = true, [8794] = true, [8795] = true, -- spec stamps
}

-- Parse the bonus_id field from an item link. Field layout (1-indexed,
-- positional — empty values still count):
--   1: itemID
--   2..12: enchant, gem1..4, suffix, unique, linkLevel, spec,
--          modifiersMask, itemContext
--   13: numBonusIDs
--   14..(13+N): the bonus_ids themselves
--
-- IMPORTANT: gmatch("[^:]+") skips empty fields, which silently
-- mis-indexes the numBonusIDs slot for every well-formed link (most
-- equipped items leave enchant/gem fields empty). We instead pad the
-- payload with a trailing ":" and capture "[^:]*" which preserves
-- empty fields.
local function ExtractBonusIdsFromLink(link, into)
    if not link then return end
    local payload = link:match("item:([^|]+)")
    if not payload then return end
    local fields = {}
    for field in (payload .. ":"):gmatch("([^:]*):") do
        fields[#fields + 1] = field
    end
    local numBonus = tonumber(fields[13]) or 0
    if numBonus <= 0 then return end
    for i = 1, numBonus do
        local id = tonumber(fields[13 + i])
        if id and id > 0 and not BORING_BONUS_IDS[id] then
            into[id] = true
        end
    end
end

-- Convert an entry's bonusIDs array (from Data/<Class>/crafting.lua)
-- into a set, dropping the boring bonuses so the match operates on
-- meaningful IDs only.
local function MaterializeEmbBonusIds(entry)
    local cached = embBonusIds[entry.itemId]
    if cached then return cached end
    if not entry.bonusIDs then return nil end
    local set = {}
    local count = 0
    for _, id in ipairs(entry.bonusIDs) do
        if not BORING_BONUS_IDS[id] then
            set[id] = true
            count = count + 1
        end
    end
    if count == 0 then return nil end
    embBonusIds[entry.itemId] = set
    return set
end

-- Build the union of bonus_ids across every equipped slot. Computed
-- once after each PLAYER_EQUIPMENT_CHANGED / BAG_UPDATE_DELAYED; every
-- subsequent render returns the cached table.
local function GetEquippedBonusIds()
    if equippedBonusIds then return equippedBonusIds end
    local ids = {}
    for slot = 1, 18 do
        if slot ~= 4 then
            local link = GetInventoryItemLink("player", slot)
            ExtractBonusIdsFromLink(link, ids)
        end
    end
    equippedBonusIds = ids
    return ids
end

local function IsEmbellishmentAppliedByText(itemId)
    local link = ("item:%d"):format(itemId)
    local equipped = craftScanner:InventoryLineSet()
    for text in craftScanner:LinesForLink(link) do
        if #text >= 25 and text:find(":", 1, true) and equipped[text] then
            return true
        end
    end
    return false
end

-- Equipped-slot effect-spell IDs. GetItemSpell on a carrier returns
-- the spell ID of its primary equip effect — when an embellishment is
-- applied, that IS the embellishment's effect spell. Compared against
-- the scraped ClassCodexEmbellishmentEffects.bySpellId map this gives
-- deterministic per-embellishment detection without bonus-id
-- ambiguity. Rebuilt on the same equipping / bag events as the
-- bonus-id state.
local equippedSpellIds  -- nil = needs rebuild; set of spellID -> true

local function GetEquippedEffectSpellIds()
    if equippedSpellIds then return equippedSpellIds end
    local ids = {}
    for slot = 1, 18 do
        if slot ~= 4 then
            local link = GetInventoryItemLink("player", slot)
            if link then
                local _, spellId = GetItemSpell(link)
                if spellId then ids[spellId] = true end
            end
        end
    end
    equippedSpellIds = ids
    return ids
end

-- Detection priority:
--   1. SimC bonus-id (authoritative): if the equipped carrier's item
--      link carries this embellishment's bonus_id, it's applied. No
--      false positives across embellishment fingerprints.
--   2. SimC spell-id (backup): GetItemSpell on the equipped carrier
--      returns the embellishment's effect spell when bonus-id parsing
--      doesn't catch it (some clients reorder bonus payloads).
--   3. Embellishment's own SimC bonusIDs from crafting.lua subset
--      match — works for embellishments we couldn't resolve via the
--      Wowhead+SimC scrape, falls back gracefully.
--   4. Tooltip text intersection — last-resort, locale-stable enough.
local function IsEmbellishmentApplied(entry)
    if not entry or not entry.itemId then return false end
    local effects = _G.ClassCodexEmbellishmentEffects
    local effectEntry = effects and effects.byItemId and effects.byItemId[entry.itemId]

    if effectEntry then
        -- Path 1: bonus_id match.
        if effectEntry.bonusId then
            local equipped = GetEquippedBonusIds()
            if equipped and equipped[effectEntry.bonusId] then return true end
        end
        -- Path 2: spell_id match via GetItemSpell.
        if effectEntry.spellIds then
            local equippedSpells = GetEquippedEffectSpellIds()
            for _, spellId in ipairs(effectEntry.spellIds) do
                if equippedSpells[spellId] then return true end
            end
        end
        -- Both authoritative paths checked and missed — not applied.
        -- (Don't fall through to the fuzzy paths when we have a clean
        -- bonus_id; the carrier just doesn't have this embellishment.)
        if effectEntry.bonusId then return false end
    end

    -- Path 3: embellishments not yet in the scraped map — best-effort
    -- subset match against the SimC build stack in crafting.lua. Will
    -- false-positive across embellishments that share the same stack
    -- in our data, but the user sees a check on _some_ embellishment
    -- rather than nothing.
    local needed = MaterializeEmbBonusIds(entry)
    local equipped = GetEquippedBonusIds()
    if needed and equipped and next(equipped) then
        for id in pairs(needed) do
            if not equipped[id] then return false end
        end
        return true
    end
    return IsEmbellishmentAppliedByText(entry.itemId)
end

-- Does the player have this item across bags, bank, warbank, reagent
-- bank, equipped, or — for embellishments — applied to an equipped
-- carrier item? Closes #610. We take the full entry so the
-- embellishment path can access bonusIDs without a second lookup.
local function IsItemOwned(entry, isEmbellishment)
    local itemId = entry.itemId
    if not itemId or itemId == 0 then return false end
    local count = GetItemCount(itemId, true, false, true, true) or 0
    if count > 0 then return true end
    if IsEquippedItem and IsEquippedItem(itemId) then return true end
    if isEmbellishment and IsEmbellishmentApplied(entry) then return true end
    return false
end

-- Vertical stack layout for top-left source-attribution markers.
-- `bis` (Wowhead) stays anchored at the corner. The active popular
-- mark (Archon for PvE, Murlok for PvP) sits at the corner when alone
-- and shifts DOWN by POPULAR_DY when bis is also present, so the pair
-- reads bis-then-popular top-to-bottom with markers touching but not
-- overlapping. Markers are 13px and top-left uses dy=+1, so -13 places
-- the second marker directly below the first.
local POPULAR_DY = -13

local function PaintCardIcon(icon, entry, isEmbellishment, ctx)
    icon:SetItem(entry.itemId)
    local hasPopular = entry.popular == true
    local hasBiS     = entry.bis == true
    local isPvp      = ctx == "pvp"
    -- Mutually exclusive at the same corner — pick by context so the
    -- icon attributes the popularity signal to its actual source.
    local popularDY = (hasBiS and hasPopular) and POPULAR_DY or 0
    icon:SetMarkerOffset("popular_archon", 0, popularDY)
    icon:SetMarkerOffset("popular_murlok", 0, popularDY)
    icon:ToggleMarker("popular_archon", hasPopular and not isPvp)
    icon:ToggleMarker("popular_murlok", hasPopular and isPvp)
    icon:ToggleMarker("bis", hasBiS)
    icon:ToggleMarker("owned", IsItemOwned(entry, isEmbellishment))
    icon:Show()
end

local function MakeIcon(parent)
    return ns.CreateSlotIcon(parent, { size = ICON_SIZE, slotSize = SLOT_FRAME })
end

-- Inline-tooltip escape sequences for the two card markers. WoW
-- renders |Tpath:w:h|t (texture) and |A:atlas:w:h|a (atlas) inside
-- tooltip strings, so we can drop the actual visuals next to the
-- explanation lines instead of describing them in words. Atlas first
-- with a texture fallback so older clients without common-icon-
-- checkmark still see something.
-- IMPORTANT: defined ABOVE MakeCard so the card's OnEnter closure
-- resolves it lexically (Lua locals are scoped from declaration
-- onward; declaring this below MakeCard makes the OnEnter look it up
-- as a global → nil → "attempt to concatenate" error).
local BIS_INLINE_ICON            = "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12|t"
local POPULAR_ARCHON_INLINE_ICON = "|TInterface\\AddOns\\ClassCodex\\Textures\\archon:12:12|t"
local POPULAR_MURLOK_INLINE_ICON = "|TInterface\\AddOns\\ClassCodex\\Textures\\murlok:12:12|t"
local function ownedInlineIcon()
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-icon-checkmark") then
        return "|A:common-icon-checkmark:14:14|a"
    end
    return "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t"
end

-- Right-click context menu. Two actions:
--   1. Track materials — adds the recipe to the objective tracker on
--      the right side of the screen. Uses the recipe spell ID scraped
--      from Wowhead and embedded on each entry by the generator
--      (parse-wowhead-craft-recipes + generate-crafting-lua). Falls
--      back to C_TradeSkillUI.GetRecipesForItem only when the entry
--      doesn't carry a recipeId — but the scraped data covers every
--      entry currently, so the fallback is mostly dead code.
--   2. Copy Wowhead link — always available; puts
--      https://wowhead.com/item=N in a copy popup. Useful for
--      commission/shopping flows when the player doesn't have the
--      recipe themselves.
--
-- Same MenuUtil pattern as LoadoutDock uses.
local function OpenCraftMenu(card)
    local itemId = card.itemId
    if not itemId then return end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end

    -- Prefer the scraped recipe ID — works without the profession
    -- window open. Runtime lookup is the fallback only.
    local recipeId = card.recipeId
    if not recipeId and C_TradeSkillUI and C_TradeSkillUI.GetRecipesForItem then
        local recipeIds = C_TradeSkillUI.GetRecipesForItem(itemId)
        if recipeIds and #recipeIds > 0 then recipeId = recipeIds[1] end
    end

    MenuUtil.CreateContextMenu(card, function(_, root)
        root:CreateTitle(card.itemText and card.itemText:GetText() or L["tab.crafting"])
        if recipeId then
            root:CreateButton(L["crafting.menu.track_materials"], function()
                if C_TradeSkillUI and C_TradeSkillUI.SetRecipeTracked then
                    C_TradeSkillUI.SetRecipeTracked(recipeId, true, false)
                end
            end)
        end
        root:CreateButton(L["crafting.menu.wowhead"], function()
            if ns.ShowCopyPopup then
                ns.ShowCopyPopup("https://www.wowhead.com/item=" .. itemId, card)
            end
        end)
    end)
end

local function MakeCard(parent)
    local card = CreateFrame("Button", nil, parent)
    card:SetHeight(CARD_HEIGHT)
    -- Right-click uses ButtonDown (not Up) because MenuUtil's outside-
    -- click dismiss handler can mis-classify the same Up event that
    -- opens the menu, causing the "click twice to open" bug. Firing on
    -- Down opens the menu before any Up arrives.
    card:RegisterForClicks("LeftButtonUp", "RightButtonDown")
    card.icon = MakeIcon(card)
    -- Inset by SLOT_OVERHANG so the chunky bevel doesn't bleed past the
    -- card's left edge. Vertical anchor is centred so the bevel stays
    -- inside the card top/bottom too (CARD_HEIGHT > SLOT_FRAME).
    card.icon:SetPoint("LEFT", card, "LEFT", CARD_INSET_X, 0)
    local name = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(true)
    name:SetMaxLines(2)
    card.itemText = name
    card:SetScript("OnEnter", function(self)
        if not self.itemId then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- Prefetch item metadata so first-hover renders correctly for
        -- items the player has never seen (SetHyperlink silently shows
        -- a blank tooltip until the item is cached).
        C_Item.RequestLoadItemDataByID(self.itemId)
        -- If we have bonus IDs (a missive pick from Archon), render via
        -- SetHyperlink so the tooltip shows the item with the missive's
        -- stat bonus applied. SetItemByID drops bonus IDs and shows the
        -- base item. Use the 0-padded canonical link format (item link
        -- fields: enchant, gem1-4, suffix, unique, linkLevel, spec,
        -- modifiers, context, numBonusIDs) — Blizzard's parser silently
        -- rejects links with empty fields on some codepaths.
        local rendered = false
        if self.bonusIDs and #self.bonusIDs > 0 then
            local bonusStr = table.concat(self.bonusIDs, ":")
            -- Field layout (Blizzard item-link spec, fields 2..13):
            -- enchant, gem1, gem2, gem3, gem4, suffix, unique, linkLevel,
            -- specialization, modifiersMask, itemContext, numBonusIDs.
            -- 11 zeros between itemID (field 1) and numBonusIDs (field 13).
            local link = format(
                "item:%d:0:0:0:0:0:0:0:0:0:0:0:%d:%s",
                self.itemId, #self.bonusIDs, bonusStr
            )
            rendered = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
        end
        if not rendered then GameTooltip:SetItemByID(self.itemId) end
        if self.isBiS or self.isPopular then
            GameTooltip:AddLine(" ")
            if self.isBiS then
                GameTooltip:AddLine(BIS_INLINE_ICON .. "  " .. L["crafting.tooltip.bis"], 1, 0.82, 0, true)
            end
            if self.isPopular then
                -- One line per source so each attribution reads as a
                -- distinct line — Archon for PvE, Murlok for PvP — and
                -- the user can scan them independently.
                GameTooltip:AddLine(
                    POPULAR_ARCHON_INLINE_ICON .. "  " .. L["crafting.tooltip.popular_archon"],
                    1, 1, 1, true
                )
                GameTooltip:AddLine(
                    POPULAR_MURLOK_INLINE_ICON .. "  " .. L["crafting.tooltip.popular_murlok"],
                    1, 1, 1, true
                )
            end
        end
        if self.embItemId then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine((L and L["gear.tooltip.embellishment"]) or "Embellishment:", 0.6, 0.6, 0.6)
            local embName = self.embName or ("Item " .. self.embItemId)
            GameTooltip:AddLine("  " .. embName, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["crafting.tooltip.menu_hint"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    card:SetScript("OnLeave", function() GameTooltip:Hide() end)
    card:SetScript("OnClick", function(self, button)
        if not self.itemId then return end
        if button == "RightButton" then
            OpenCraftMenu(self)
            return
        end
        -- Left click: chat link / dressup. C_Item.GetItemInfo can return nil
        -- when the item isn't cached locally (common for crafted gear the
        -- player has never seen — was causing first-click misses). Prefetch
        -- + fall back to a hand-rolled link string so the action lands on
        -- the first try.
        local _, link = C_Item.GetItemInfo(self.itemId)
        if not link then
            C_Item.RequestLoadItemDataByID(self.itemId)
            link = format("item:%d", self.itemId)
        end
        if IsModifiedClick("CHATLINK") then ChatEdit_InsertLink(link)
        elseif IsModifiedClick("DRESSUP") then DressUpItemLink(link) end
    end)
    card:Hide()
    return card
end

-- Per-section collapse state, persisted in ClassCodexCharDB.collapsed.crafting.
-- The default (expanded) is stored as nil so the table doesn't bloat.
local function GetSectionCollapsed(key)
    if not ClassCodexCharDB or not ClassCodexCharDB.collapsed then return false end
    local t = ClassCodexCharDB.collapsed.crafting
    return t and t[key] == true
end

local function SetSectionCollapsed(key, collapsed)
    if not ClassCodexCharDB then return end
    ClassCodexCharDB.collapsed = ClassCodexCharDB.collapsed or {}
    ClassCodexCharDB.collapsed.crafting = ClassCodexCharDB.collapsed.crafting or {}
    ClassCodexCharDB.collapsed.crafting[key] = collapsed and true or nil
end

-- Compendium header row — reuses ns.CreateSectionHeader so the
-- backdrop + hover chrome + right-aligned arrow match the docked
-- panel's CreateCollapsibleSection style. The Compendium does its
-- own y-accumulator layout, so we keep the header as a standalone
-- frame and re-anchor it manually inside RenderCompendium.
local function MakeHeaderRow(parent)
    local row = ns.CreateSectionHeader(parent, "", true)
    row:Hide()
    return row
end

local function PaintHeaderArrow(row, collapsed)
    if not row.arrow then return end
    row.arrow:SetTexture(collapsed
        and "Interface\\Buttons\\UI-PlusButton-Up"
        or "Interface\\Buttons\\UI-MinusButton-Up")
end

-- Cards are dense enough that the Wowhead "W" mark (BiS), flame
-- (popular), and green check (owned) aren't self-explanatory to a
-- first-time user. The help icon on the section header carries the
-- explanation — and inlines the actual marker textures so users see
-- exactly what they're looking for.
local function AttachHelpIcon(titleFrame, insetOverride)
    return ns.CreateHelpIcon(titleFrame, {
        title = L["tab.crafting"],
        intro = L["crafting.help.intro"],
        highlight = L["crafting.help.menu"],
        -- Yellow heads-up above the icon legend: crafts have no equip
        -- cap but embellishments do (2 per character). Beginners often
        -- assume the highest-popularity entries in BOTH sections are
        -- "must-have" — surface the rule before the icons explain
        -- ranking so the constraint is the first thing read.
        warning = L["crafting.help.embellishment_limit"],
        lines = {
            BIS_INLINE_ICON .. "  " .. L["crafting.help.star"],
            POPULAR_ARCHON_INLINE_ICON .. "  " .. L["crafting.help.popular_archon"],
            POPULAR_MURLOK_INLINE_ICON .. "  " .. L["crafting.help.popular_murlok"],
            ownedInlineIcon() .. "  " .. L["crafting.help.check"],
        },
        inset = insetOverride,
    })
end

-- Public: lets ClassCodex.lua mount a "?" info button on the shared
-- tab-title row, matching the Guide/Stats tab info-icon pattern.
-- Inset 18 leaves a 2 px gap between the help icon and the gear icon
-- (gear is 12 px at inset 4, so 18 - 12 - 4 = 2).
function Crafting.AttachInfoButton(parent)
    return AttachHelpIcon(parent, 18)
end

-- Public: gear icon to the right of the help button. Opens a context
-- menu with per-tab toggles (currently just the "top picks only"
-- filter). The same toggle is mirrored in the main settings panel —
-- both write to the same SavedVar so they stay in sync.
function Crafting.AttachOptionsButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(12, 12)
    btn:SetPoint("RIGHT", parent, "RIGHT", -4, 0)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\AddOns\\ClassCodex\\Textures\\gear")
    tex:SetVertexColor(0.7, 0.7, 0.7, 0.9)  -- idle, matches HelpIcon

    btn:SetScript("OnEnter", function(self)
        tex:SetVertexColor(1, 1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["crafting.menu.options_tooltip"], 1, 0.82, 0)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        tex:SetVertexColor(0.7, 0.7, 0.7, 0.9)
        GameTooltip:Hide()
    end)

    btn:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle(L["tab.crafting"])
            root:CreateCheckbox(
                L["crafting.menu.top_picks_only"],
                function() return IsTopPicksOnly() end,
                function()
                    if not ClassCodexDB then return end
                    ClassCodexDB.craftingTopPicksOnly = not IsTopPicksOnly()
                    if ns.UpdatePanel then ns:UpdatePanel() end
                    if ns.UpdateCompendium then ns:UpdateCompendium() end
                    return MenuResponse.Refresh
                end
            )
        end)
    end)
    return btn
end

-- Single-card renderer used for both crafts and embellishments. Crafts +
-- embellishments share the { itemId, name, bis? } shape — there are no
-- longer pair cards (embellishments are popularity-ranked singles
-- aggregated from Archon's pair data; see generate-crafting-lua.ts).
-- isEmbellishment toggles the "applied to equipped carrier" detection
-- so we don't tooltip-scan equipment for plain craft items.
local function ApplyCard(card, entry, isEmbellishment, ctx)
    card.itemId = entry.itemId
    card.embItemId = nil
    card.embName = nil
    card.bonusIDs = entry.bonusIDs  -- per-craft missive stack, nil-safe
    card.recipeId = entry.recipeId  -- scraped Wowhead recipe spell ID
    card.altItemId = nil
    card.isBiS = entry.bis == true       -- surfaced in the hover tooltip
    card.isPopular = entry.popular == true -- surfaced in the hover tooltip
    -- Popularity attribution by context: PvE → Archon, PvP → Murlok.
    -- Drives both the corner marker (popular_archon vs popular_murlok)
    -- and the tooltip line (inline icon + locale string).
    card.popularSource = (ctx == "pvp") and "murlok" or "archon"
    PaintCardIcon(card.icon, entry, isEmbellishment, ctx)
    -- BiS is communicated via the Wowhead "W" mark on the icon
    -- (top-left). The redundant gold [BiS] text suffix was removed
    -- per feedback.
    -- Use ns.FormatItem so the label matches the rest of the addon's
    -- "[Item Name]" idiom + quality-colour convention (Shared/ItemLabel
    -- + Shared/GearingUtils). Falls back to a plain "Item NNN" string
    -- when the item's quality hasn't been cached yet — it'll re-format
    -- on the next render once GetItemInfo populates.
    local label = ns.FormatItem({ itemId = entry.itemId }, entry.name)
    if not label or label == "" then
        label = entry.name or ("Item " .. (entry.itemId or 0))
    end
    card.itemText:SetText(label)
    card.itemText:ClearAllPoints()
    -- Anchor text to the slot's right edge (slot extends SLOT_OVERHANG
    -- past the icon, so we'd otherwise sit text underneath the bevel).
    card.itemText:SetPoint("LEFT", card.icon.slot, "RIGHT", TEXT_GAP_X, 0)
    card.itemText:SetPoint("RIGHT", card, "RIGHT", -4, 0)
end

local function LookupData(class, spec, ctxKey)
    local data = _G.ClassCodexCraftingData
        and _G.ClassCodexCraftingData[class]
        and _G.ClassCodexCraftingData[class][spec]
    return data and data[ctxKey] or nil
end

-- RequestAllItems helper — pre-fetches GetItemInfo for everything the
-- current spec's crafting data might display, across all three contexts.
-- Called once by surface owners during their UpdatePanel/UpdateCompendium so
-- icons + tooltips are warm by the time the section renders.
function Crafting.RequestItems(class, spec, requestItem)
    if not class or not spec or not requestItem then return end
    local entry = _G.ClassCodexCraftingData and _G.ClassCodexCraftingData[class] and _G.ClassCodexCraftingData[class][spec]
    if not entry then return end
    for _, ctxName in ipairs({ "raid", "mythicPlus", "pvp" }) do
        local section = entry[ctxName]
        if section then
            if section.crafts then
                for _, c in ipairs(section.crafts) do requestItem(c.itemId) end
            end
            if section.embellishments then
                for _, e in ipairs(section.embellishments) do
                    if e.itemId then requestItem(e.itemId) end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Panel surface (docked/floating main panel)
-------------------------------------------------------------------------------

local panel = {}

local function BuildCtxOptions()
    local opts = {}
    for _, c in ipairs(CONTEXTS) do
        opts[#opts + 1] = { label = c.label(), value = c.key }
    end
    return opts
end

-- opts: { parent = ns.contentFrame, refresh = function() ns:UpdatePanel() end }
-- Returns a table of frames for the layout pass — mirrors the
-- Sections/Enhancements pattern:
--   { ctxDropdown, craftsSection, embsSection }
function Crafting.InitPanel(opts)
    opts = opts or {}
    local parent = opts.parent or ns.contentFrame
    local refresh = opts.refresh

    -- Context dropdown — sits above both sections, mirrors compendium.
    panel.ctxDropdown = ns.CreateOptionDropdown("ClassCodexPanelCraftingCtxDD", parent)
    panel.ctxDropdown:Hide()

    -- Crafts section — top-level collapsible block (heavy chrome).
    -- Help "?" icon lives on the shared tab-title row above (see
    -- ClassCodex.lua: Crafting.AttachInfoButton), so the section
    -- header is just label + collapse arrow.
    panel.craftsSection, panel.craftsHeader, panel.craftsContent =
        ns.CreateCollapsibleSection(parent, {
            label = L["crafting.section_crafts"],
            stateKey = "crafting.crafts",
            refresh = refresh,
        })
    panel.craftsSection:Hide()

    -- Embellishments section — second collapsible block.
    panel.embsSection, panel.embsHeader, panel.embsContent =
        ns.CreateCollapsibleSection(parent, {
            label = L["crafting.section_embellishments"],
            stateKey = "crafting.embellishments",
            refresh = refresh,
        })
    panel.embsSection:Hide()

    -- Per-section card pools, anchored to their respective content frames.
    panel.craftCards = {}
    panel.embCards = {}
    for i = 1, MAX_CRAFT_CARDS do panel.craftCards[i] = MakeCard(panel.craftsContent) end
    for i = 1, MAX_EMB_CARDS  do panel.embCards[i]   = MakeCard(panel.embsContent)   end

    return {
        ctxDropdown   = panel.ctxDropdown,
        craftsSection = panel.craftsSection,
        embsSection   = panel.embsSection,
    }
end

-- args = { class, spec }
-- Populates each section's content frame. Returns { crafts, embs }
-- shown counts so the layout pass can size each section.
function Crafting.RenderPanel(args)
    for _, c in ipairs(panel.craftCards) do c:Hide() end
    for _, c in ipairs(panel.embCards)   do c:Hide() end

    local activeCtx = GetPerSpecCtx()
    local ctxData = LookupData(args.class, args.spec, activeCtx)
    local crafts = FilterTopPicks((ctxData and ctxData.crafts) or {})
    local embellishments = FilterTopPicks((ctxData and ctxData.embellishments) or {})

    if #crafts == 0 and #embellishments == 0 then
        panel.ctxDropdown:Hide()
        panel.craftsSection:Hide()
        panel.embsSection:Hide()
        return { crafts = 0, embs = 0 }
    end

    -- Context dropdown
    panel.ctxDropdown:Show()
    panel.ctxDropdown:SetOptions(BuildCtxOptions(), activeCtx, function(picked)
        SetPerSpecCtx(picked)
        if ns.UpdatePanel then ns:UpdatePanel() end
    end)

    -- Crafts section
    local craftsShown = 0
    if #crafts > 0 then
        panel.craftsSection:Show()
        for i, c in ipairs(crafts) do
            if i > MAX_CRAFT_CARDS then break end
            local card = panel.craftCards[i]
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", panel.craftsContent, "TOPLEFT", CARD_INSET_X, -(i - 1) * CARD_HEIGHT)
            card:SetPoint("RIGHT", panel.craftsContent, "RIGHT", 0, 0)
            ApplyCard(card, c, false, activeCtx)
            card:Show()
            craftsShown = i
        end
    else
        panel.craftsSection:Hide()
    end

    -- Embellishments section
    local embsShown = 0
    if #embellishments > 0 then
        panel.embsSection:Show()
        for i, e in ipairs(embellishments) do
            if i > MAX_EMB_CARDS then break end
            local card = panel.embCards[i]
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", panel.embsContent, "TOPLEFT", CARD_INSET_X, -(i - 1) * CARD_HEIGHT)
            card:SetPoint("RIGHT", panel.embsContent, "RIGHT", 0, 0)
            ApplyCard(card, e, true, activeCtx)
            card:Show()
            embsShown = i
        end
    else
        panel.embsSection:Hide()
    end

    return { crafts = craftsShown, embs = embsShown }
end

-- Used by ns:LayoutGearingSections.
function Crafting.GetPanelFrames()
    return {
        ctxDropdown      = panel.ctxDropdown,
        craftsSection    = panel.craftsSection,
        craftsCollapsed  = panel.craftsSection.IsCollapsed and panel.craftsSection.IsCollapsed() or false,
        embsSection      = panel.embsSection,
        embsCollapsed    = panel.embsSection.IsCollapsed and panel.embsSection.IsCollapsed() or false,
    }
end

function Crafting.GetPanelCardHeight() return CARD_HEIGHT end

-------------------------------------------------------------------------------
-- Compendium surface (standalone window)
-------------------------------------------------------------------------------

local comp = {}

-- opts: { parent = scrollChild, headerFactory = CreateSectionHeader }
-- Returns section, header, content so the Compendium layout pass can
-- reference them (kept symmetrical with the other Compendium tabs).
--
-- Header is a plain Frame + FontString — NOT opts.headerFactory. The
-- docked panel's title row is borderless and inset-free, so reusing
-- CreateSectionHeader here would visually fork the two surfaces
-- (Compendium Crafting would carry the tooltip-bevel chrome that the
-- panel doesn't). The sub-section headers (Crafts / Embellishments)
-- below still use the bevel — only the tab-title row is plain.
function Crafting.InitCompendium(opts)
    comp.section = CreateFrame("Frame", nil, opts.parent)

    comp.header = CreateFrame("Frame", nil, comp.section)
    comp.header:SetHeight(HEADER_HEIGHT)
    comp.header:SetPoint("TOPLEFT", 0, 0)
    comp.header:SetPoint("TOPRIGHT", 0, 0)
    local headerText = comp.header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerText:SetPoint("LEFT", 2, 0)
    headerText:SetText(L["tab.crafting"])
    headerText:SetTextColor(1, 0.82, 0)

    -- Match the docked panel exactly: gear at the rightmost slot
    -- (inset 4, 12 px) with the help icon shifted left (inset 18, 16 px)
    -- so the two surfaces read identically.
    AttachHelpIcon(comp.header, 18)
    Crafting.AttachOptionsButton(comp.header)
    comp.content = CreateFrame("Frame", nil, comp.section)
    comp.content:SetPoint("TOPLEFT", comp.header, "BOTTOMLEFT", 0, -2)
    comp.content:SetPoint("RIGHT", 0, 0)

    comp.ctxDropdown = CreateFrame(
        "DropdownButton", "ClassCodexCompCraftingCtxDD",
        comp.content, "WowStyle1DropdownTemplate"
    )
    comp.ctxDropdown:SetPoint("TOPLEFT", CONTENT_INSET, 0)
    comp.ctxDropdown:SetPoint("TOPRIGHT", -CONTENT_INSET, 0)
    comp.ctxDropdown:SetHeight(24)
    comp.ctxDropdown:Hide()

    comp.fallback = comp.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    comp.fallback:SetTextColor(0.5, 0.5, 0.5)
    comp.fallback:Hide()

    comp.cards = {}
    comp.headerRows = {}
    for i = 1, MAX_CARDS do comp.cards[i] = MakeCard(comp.content) end
    for i = 1, 4 do comp.headerRows[i] = MakeHeaderRow(comp.content) end

    return comp.section, comp.header, comp.content
end

-- args = { class, spec, refresh }
-- `refresh` is a callback the dropdown invokes after the user changes
-- the per-spec context — the Compendium owns the master refresh.
function Crafting.RenderCompendium(args)
    for i = 1, MAX_CARDS do comp.cards[i]:Hide() end
    for i = 1, #comp.headerRows do comp.headerRows[i]:Hide() end
    comp.fallback:Hide()

    -- Always wire the dropdown so users can pick a different context
    -- even when the current context has no data.
    local ctxKey = GetPerSpecCtx()
    comp.ctxDropdown:SetupMenu(function(_, rootDescription)
        for _, c in ipairs(CONTEXTS) do
            rootDescription:CreateRadio(
                c.label(),
                function() return ctxKey == c.key end,
                function()
                    SetPerSpecCtx(c.key)
                    if args.refresh then args.refresh() end
                end,
                c.key
            )
        end
    end)
    comp.ctxDropdown:Show()

    local y = -30  -- dropdown
    local cardIdx, hdrIdx = 0, 0
    local seenHeader = false

    local refresh = args and args.refresh

    local function addCollapsibleHeader(label, key)
        y = y - (seenHeader and HEADER_PAD_BEFORE or HEADER_PAD_FIRST)
        seenHeader = true
        hdrIdx = hdrIdx + 1
        local hdr = comp.headerRows[hdrIdx]
        if not hdr then return false end
        local collapsed = GetSectionCollapsed(key)
        hdr.label:SetText(label)
        PaintHeaderArrow(hdr, collapsed)
        hdr:SetScript("OnClick", function()
            SetSectionCollapsed(key, not GetSectionCollapsed(key))
            if refresh then refresh() end
        end)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 0, y)
        hdr:SetPoint("RIGHT", comp.content, "RIGHT", 0, 0)
        hdr:Show()
        y = y - HEADER_HEIGHT - HEADER_PAD_AFTER
        return not collapsed
    end

    local function placeCard(card)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 0, y)
        card:SetPoint("RIGHT", comp.content, "RIGHT", 0, 0)
        y = y - CARD_HEIGHT
    end

    local ctxData = LookupData(args.class, args.spec, ctxKey)
    local crafts = FilterTopPicks((ctxData and ctxData.crafts) or {})
    local embellishments = FilterTopPicks((ctxData and ctxData.embellishments) or {})

    if #crafts == 0 and #embellishments == 0 then
        comp.fallback:ClearAllPoints()
        comp.fallback:SetPoint("TOPLEFT", comp.content, "TOPLEFT", CONTENT_INSET, y)
        comp.fallback:SetPoint("RIGHT", comp.content, "RIGHT", -CONTENT_INSET, 0)
        comp.fallback:SetText(L["crafting.no_data"])
        comp.fallback:Show()
        comp.content:SetHeight(math.abs(y) + HEADER_HEIGHT)
        comp.section:Show()
        return
    end

    if #crafts > 0 then
        local expanded = addCollapsibleHeader(L["crafting.section_crafts"], "crafts")
        if expanded then
            for _, c in ipairs(crafts) do
                cardIdx = cardIdx + 1
                if cardIdx > MAX_CARDS then break end
                local card = comp.cards[cardIdx]
                ApplyCard(card, c, false, ctxKey)
                placeCard(card)
                card:Show()
            end
        end
    end
    if #embellishments > 0 and cardIdx < MAX_CARDS then
        local expanded = addCollapsibleHeader(L["crafting.section_embellishments"], "embellishments")
        if expanded then
            for _, e in ipairs(embellishments) do
                cardIdx = cardIdx + 1
                if cardIdx > MAX_CARDS then break end
                local card = comp.cards[cardIdx]
                ApplyCard(card, e, true, ctxKey)
                placeCard(card)
                card:Show()
            end
        end
    end

    -- Trim the trailing slot bleed off the section height for the same
    -- reason as the panel side — see RenderPanel return comment.
    comp.content:SetHeight(math.max(0, math.abs(y) - SLOT_BLEED))
    comp.section:Show()
end

-- For the Compendium's LayoutCompendium pass — returns the rendered content
-- height (in pixels) so the surface owner can stack the section.
function Crafting.GetCompendiumContentHeight()
    local h = 30  -- dropdown
    for i = 1, MAX_CARDS do
        if comp.cards[i]:IsShown() then h = h + CARD_HEIGHT end
    end
    for i = 1, #comp.headerRows do
        if comp.headerRows[i]:IsShown() then h = h + HEADER_HEIGHT end
    end
    if comp.fallback:IsShown() then h = h + HEADER_HEIGHT end
    return h
end
