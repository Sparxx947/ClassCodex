local _, ns = ...

-------------------------------------------------------------------------------
-- TooltipScanner: hidden GameTooltip primitive for reading text out of
-- item links / equipped slots without showing UI to the user.
--
-- The pattern is the same one every addon hand-rolls (a CreateFrame
-- "GameTooltip" anchored to WorldFrame with ANCHOR_NONE, then
-- SetHyperlink + walk ClassCodexXxxScanTipTextLeft<N>:GetText()):
-- centralising it keeps the scanner names + caching consistent.
--
-- Usage:
--   local scanner = ns.CreateTooltipScanner("ClassCodexCraftScanTip")
--   -- one-off line scan for an item link:
--   for text in scanner:LinesForLink(itemLink) do ... end
--   -- bulk equipped-gear scan, cached for opts.cacheSeconds:
--   local set = scanner:InventoryLineSet({ cacheSeconds = 1.0 })
--   if set["Arcanoweave Lining"] then ... end
--
-- Callers layer their match logic on top — the scanner only reads text.
-------------------------------------------------------------------------------

local DEFAULT_MIN_SLOT     = 1
local DEFAULT_MAX_SLOT     = 18 -- head..ranged; 19 = tabard, rarely useful
local DEFAULT_SKIP_SLOTS   = { [4] = true } -- shirt slot, never carries gear data
local DEFAULT_CACHE_SECS   = 1.0

local ScannerAPI = {}

function ScannerAPI:Tip()
    if self._tip then return self._tip end
    local tip = CreateFrame("GameTooltip", self._name, nil, "GameTooltipTemplate")
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    self._tip = tip
    return tip
end

-- Iterate over text lines of an item link's tooltip. Returns an
-- iterator suitable for `for text in scanner:LinesForLink(link) do`.
function ScannerAPI:LinesForLink(link)
    local tip = self:Tip()
    tip:ClearLines()
    local ok = pcall(tip.SetHyperlink, tip, link)
    if not ok then return function() return nil end end
    local i, n = 0, tip:NumLines()
    local prefix = self._name .. "TextLeft"
    return function()
        while i < n do
            i = i + 1
            local fs = _G[prefix .. i]
            if fs then
                local text = fs:GetText()
                if text and text ~= "" then return text end
            end
        end
        return nil
    end
end

-- Walk equipped slots and return a set of every text line found in any
-- equipped item's tooltip. Use the set's keys for substring matching
-- (e.g. embellishment names baked into a carrier item).
--
-- opts (all optional):
--   cacheSeconds   reuse the previous scan if it's newer than this
--                  (defaults to 1.0 — long enough to cover a render
--                  pass that paints many cards, short enough that a
--                  gear-swap shows up before the next pass)
--   minSlot/maxSlot  inventory slot range (defaults 1..18)
--   skipSlots      table keyed by slot id, value truthy = skip
--                  (defaults to { [4] = true } — shirt)
function ScannerAPI:InventoryLineSet(opts)
    opts = opts or {}
    local cacheSecs = opts.cacheSeconds or DEFAULT_CACHE_SECS
    local now = GetTime()
    if self._invCache and (now - self._invCacheAt) < cacheSecs then
        return self._invCache
    end
    local minSlot = opts.minSlot or DEFAULT_MIN_SLOT
    local maxSlot = opts.maxSlot or DEFAULT_MAX_SLOT
    local skip    = opts.skipSlots or DEFAULT_SKIP_SLOTS

    local lines = {}
    for slot = minSlot, maxSlot do
        if not skip[slot] then
            local link = GetInventoryItemLink("player", slot)
            if link then
                for text in self:LinesForLink(link) do lines[text] = true end
            end
        end
    end
    self._invCache = lines
    self._invCacheAt = now
    return lines
end

-- Force the inventory cache to refresh on the next call. Useful if the
-- caller knows gear just changed (e.g. PLAYER_EQUIPMENT_CHANGED).
function ScannerAPI:InvalidateInventoryCache()
    self._invCache = nil
    self._invCacheAt = 0
end

-- ns.CreateTooltipScanner(name) -> scanner
-- name is the global frame name; pick something unique per consumer
-- so multiple scanners can coexist (the line lookup walks the global
-- TextLeft<N> font strings by name).
function ns.CreateTooltipScanner(name)
    local scanner = { _name = name }
    for k, v in pairs(ScannerAPI) do scanner[k] = v end
    return scanner
end
