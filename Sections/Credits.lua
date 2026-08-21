local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

local Credits = {}
ns.Sections.Credits = Credits

-- This panel replaced upstream's Supporters tab. Blizzard's UI Add-On
-- Development Policy, rule 5: "Add-ons may not include requests for
-- donations ... such requests should be limited to the add-on website or
-- distribution site and should not appear in the game." The old tab
-- listed Patreon backers underneath a Patreon button, which is exactly
-- that. It also hard-coded the real names of fifteen people who pledged
-- to the upstream project, not to this one.
--
-- The tab is kept rather than deleted, because credit for the work is
-- worth showing — it just names who wrote the addon and where its data
-- comes from instead of asking for money.

local CREDITS = {
    { name = "jfstn", role = L["credits.role.original"], color = { 0.98, 0.78, 0.18 } },
    { name = "Sparxx947", role = L["credits.role.continuation"], color = { 0.98, 0.78, 0.18 } },
    { name = "NumyAddon", role = L["credits.role.tlm"], color = { 0.85, 0.72, 0.55 } },
    { name = "Ace3 / WoWAce", role = L["credits.role.libs"], color = { 0.85, 0.72, 0.55 } },
    { name = "Wowhead", role = L["credits.role.data"], color = { 0.70, 0.78, 0.90 } },
    { name = "Icy Veins", role = L["credits.role.data"], color = { 0.70, 0.78, 0.90 } },
    { name = "Archon.gg", role = L["credits.role.data"], color = { 0.70, 0.78, 0.90 } },
    { name = "murlok.io", role = L["credits.role.data"], color = { 0.70, 0.78, 0.90 } },
}

-------------------------------------------------------------------------------
-- Panel surface (Compendium has no Credits tab)
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent + opts.contentWidth (for the description's word-wrap width)
function Credits.InitPanel(opts)
    panel.title = CreateFrame("Frame", nil, opts.parent)
    panel.title:SetHeight(ns.SECTION_HEADER_HEIGHT)
    local title = panel.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 2, 0)
    title:SetText(L["about.credits"])
    title:SetTextColor(1, 0.82, 0)
    panel.title:Hide()

    panel.content = CreateFrame("Frame", nil, opts.parent)
    panel.content:SetHeight(1)
    panel.content:Hide()

    local desc = panel.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 2, 0)
    desc:SetWidth(opts.contentWidth)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetTextColor(0.7, 0.7, 0.7)
    desc:SetText(L["about.free_message"])

    -- panel.lastChild = bottom-most rendered element, so LayoutPanel can size
    -- the content frame correctly.
    local prev = desc
    local first = true
    for _, entry in ipairs(CREDITS) do
        local row = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, first and -14 or -2)
        row:SetText(entry.name .. "  |cff808080" .. entry.role .. "|r")
        row:SetTextColor(entry.color[1], entry.color[2], entry.color[3])
        prev = row
        first = false
    end
    panel.lastChild = prev

    return panel.title, panel.content
end

-- y = current top offset, opts.parent, opts.inset. Returns the new y.
function Credits.LayoutPanel(y, opts)
    panel.title:Show()
    panel.title:ClearAllPoints()
    panel.title:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", opts.inset, y)
    panel.title:SetPoint("RIGHT", opts.parent, "RIGHT", -opts.inset, 0)
    y = y - ns.SECTION_HEADER_HEIGHT

    panel.content:Show()
    panel.content:ClearAllPoints()
    panel.content:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", opts.inset, y)
    panel.content:SetPoint("RIGHT", opts.parent, "RIGHT", -opts.inset, 0)
    local lastBottom = panel.lastChild and panel.lastChild:GetBottom()
    local contentTop = panel.content:GetTop()
    local contentH = (lastBottom and lastBottom > 0 and contentTop and contentTop > 0)
        and (contentTop - lastBottom)
        or 80
    panel.content:SetHeight(contentH)
    y = y - contentH - 16

    return y
end

function Credits.HidePanel()
    if panel.title then panel.title:Hide() end
    if panel.content then panel.content:Hide() end
end
