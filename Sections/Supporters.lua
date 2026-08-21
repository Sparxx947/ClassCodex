local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

local Supporters = {}
ns.Sections.Supporters = Supporters

-- Hand-curated until the Patreon API integration lands. Names land here in
-- the order they pledged. Tier order matches display order — Champions
-- render above Supporters.
local CHAMPIONS = {
    "Tantify",
    "Bull Horn",
    "Insecurity",
    "Lisa",
    "HelloImDrew",
}
local SUPPORTER_LIST = {
    "Bxnane",
    "Rod",
    "Alida Bell",
    "Furkan Yünkül",
    "Mudrc",
    "Fabian Goertz",
    "Volkan Yamanlar",
    "Joe Zollo",
    "Zalyniela",
    "Kim",
}

-------------------------------------------------------------------------------
-- Panel surface (Compendium has no Supporters tab)
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent + opts.contentWidth (for the description's word-wrap width)
function Supporters.InitPanel(opts)
    panel.title = CreateFrame("Frame", nil, opts.parent)
    panel.title:SetHeight(ns.SECTION_HEADER_HEIGHT)
    local title = panel.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 2, 0)
    title:SetText(L["about.supporters"])
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
    if #CHAMPIONS == 0 and #SUPPORTER_LIST == 0 then
        local empty = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
        empty:SetTextColor(0.5, 0.5, 0.5)
        empty:SetText(L["about.be_first_supporter"])
        panel.lastChild = empty
    else
        local heart = "|TInterface\\Icons\\Spell_Holy_PrayerOfHealing:14:14:0:0|t"
        local prev = desc
        local firstName = true

        -- Tier is conveyed by colour alone — Champions (gold) above
        -- Supporters (coral) — with no header rows separating the groups
        -- so a short list doesn't feel padded.
        local function renderTier(names, color)
            for _, name in ipairs(names) do
                local row = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, firstName and -14 or -2)
                row:SetText(heart .. "  " .. name)
                row:SetTextColor(color[1], color[2], color[3])
                prev = row
                firstName = false
            end
        end
        renderTier(CHAMPIONS, { 0.98, 0.78, 0.18 })
        renderTier(SUPPORTER_LIST, { 0.98, 0.65, 0.50 })
        panel.lastChild = prev
    end

    return panel.title, panel.content
end

-- The Patreon button is created by ClassCodex.lua's CreateAboutButton (shared
-- with the About tab); we just need a handle so the layout pass can position
-- it below the supporter list.
function Supporters.SetPatreonButton(btn)
    panel.patreonBtn = btn
end

-- y = current top offset, opts.parent, opts.inset.
-- Returns the new y (below the patreon button).
function Supporters.LayoutPanel(y, opts)
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

    if panel.patreonBtn then
        panel.patreonBtn:ClearAllPoints()
        panel.patreonBtn:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", opts.inset, y)
        panel.patreonBtn:SetPoint("RIGHT", opts.parent, "RIGHT", -opts.inset, 0)
        panel.patreonBtn:Show()
        y = y - 28
    end
    return y
end

function Supporters.HidePanel()
    if panel.title then panel.title:Hide() end
    if panel.content then panel.content:Hide() end
    if panel.patreonBtn then panel.patreonBtn:Hide() end
end
