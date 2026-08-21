local _, ns = ...

-------------------------------------------------------------------------------
-- ItemLabel: shared formatter for quality-coloured bracket labels.
--
-- Pure function used wherever an item name is rendered in the addon
-- (BiS, trinkets, enchants, gems, consumables, crafts) so all those
-- surfaces match Redshift's "[Item Name]" idiom and stay in sync.
--
-- Callers resolve the item's name and quality however they like
-- (typically via their existing GetItemInfo + cache plumbing) and
-- hand both in. The formatter wraps the name in brackets and tints
-- the whole thing with the quality colour. SetTextColor on the
-- caller's font string is no longer needed — the colour lives in
-- the returned string via the WoW |c...|r escape.
-------------------------------------------------------------------------------

-- ns.FormatItemLabel(name, quality) -> string
-- name    : item name (already resolved by the caller; may be nil/empty)
-- quality : Blizzard quality enum (0–7) or nil. nil renders unbracketed
--           with no colour so the fallback "Item 12345" placeholder
--           doesn't look like a poor-quality grey item.
function ns.FormatItemLabel(name, quality)
    if not name or name == "" then return "" end
    if quality == nil then return name end
    local ok, r, g, b = pcall(GetItemQualityColor, quality)
    if not ok or not r then return "[" .. name .. "]" end
    local hex = string.format(
        "|cff%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5)
    )
    return hex .. "[" .. name .. "]|r"
end
