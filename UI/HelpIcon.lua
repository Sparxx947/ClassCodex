local _, ns = ...

-------------------------------------------------------------------------------
-- HelpIcon: small "i" button anchored inside a section title with a
-- consistent on-hover tooltip layout. Tooltip shape:
--
--   ┌──────────────────────────┐
--   │ <title>                  │  gold (1, 0.82, 0)
--   │                          │
--   │ <intro line>             │  white (1, 1, 1)
--   │                          │  blank separator (when highlight)
--   │ <highlight line>         │  white (1, 1, 1)  -- optional
--   │                          │  blank separator
--   │ <line 1>                 │  muted grey (0.85, 0.85, 0.85)
--   │ <line 2>                 │
--   └──────────────────────────┘
--
-- Callers pass the localised text; this module owns the texture,
-- anchoring, hover hooks, and the tooltip layout so every section's
-- help icon reads identically. Adding a help icon to a new section is
-- one call:
--
--   ns.CreateHelpIcon(headerFrame, {
--       title = L["tab.crafting"],
--       intro = L["crafting.help.intro"],
--       lines = { L["crafting.help.star"], L["crafting.help.check"] },
--   })
-------------------------------------------------------------------------------

local TEX_FILE        = "Interface\\Common\\help-i"
local TITLE_COLOR     = { 1, 0.82, 0 }
local INTRO_COLOR     = { 1, 1, 1 }
local WARNING_COLOR   = { 1, 0.65, 0.15 }    -- Blizzard's "yellow" warning hue
local BODY_COLOR      = { 0.85, 0.85, 0.85 }
local IDLE_COLOR      = { 0.7, 0.7, 0.7, 0.9 }
local HOVER_COLOR     = { 1, 1, 1, 1 }
local DEFAULT_SIZE    = 16
local DEFAULT_INSET   = 4
local DEFAULT_ANCHOR  = "ANCHOR_LEFT"

-- ns.CreateHelpIcon(parent, opts) -> Button
-- opts (all optional except `title`):
--   title          tooltip header (required, no default)
--   intro          single intro line shown below the title in white
--   highlight      optional white line shown between intro and lines,
--                  separated from both by a blank — for surfacing an
--                  interaction hint that should sit above the legend
--   warning        optional yellow line shown between highlight and
--                  lines — for surfacing a constraint the player needs
--                  to know before reading the legend (e.g. embellishment
--                  cap on the Crafting tab)
--   lines          array of body lines shown in muted grey
--   size           icon edge length (default 16)
--   inset          anchor offset from parent's right edge (default 4)
--   tooltipAnchor  GameTooltip:SetOwner anchor (default "ANCHOR_LEFT")
function ns.CreateHelpIcon(parent, opts)
    opts = opts or {}
    local size = opts.size or DEFAULT_SIZE
    local inset = opts.inset or DEFAULT_INSET
    local anchor = opts.tooltipAnchor or DEFAULT_ANCHOR

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    btn:SetPoint("RIGHT", parent, "RIGHT", -inset, 0)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(TEX_FILE)
    tex:SetVertexColor(IDLE_COLOR[1], IDLE_COLOR[2], IDLE_COLOR[3], IDLE_COLOR[4])

    btn:SetScript("OnEnter", function(self)
        tex:SetVertexColor(HOVER_COLOR[1], HOVER_COLOR[2], HOVER_COLOR[3], HOVER_COLOR[4])
        GameTooltip:SetOwner(self, anchor)
        if opts.title then
            GameTooltip:SetText(opts.title, TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
        end
        if opts.intro then
            GameTooltip:AddLine(opts.intro, INTRO_COLOR[1], INTRO_COLOR[2], INTRO_COLOR[3], true)
        end
        if opts.highlight then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(opts.highlight, INTRO_COLOR[1], INTRO_COLOR[2], INTRO_COLOR[3], true)
        end
        if opts.warning then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(opts.warning, WARNING_COLOR[1], WARNING_COLOR[2], WARNING_COLOR[3], true)
        end
        if opts.lines and #opts.lines > 0 then
            GameTooltip:AddLine(" ")
            for _, line in ipairs(opts.lines) do
                GameTooltip:AddLine(line, BODY_COLOR[1], BODY_COLOR[2], BODY_COLOR[3], true)
            end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        tex:SetVertexColor(IDLE_COLOR[1], IDLE_COLOR[2], IDLE_COLOR[3], IDLE_COLOR[4])
        GameTooltip:Hide()
    end)
    return btn
end
