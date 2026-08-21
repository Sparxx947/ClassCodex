local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

-- Stat Priority section — the ranked list of secondary stats per context.
-- Renders on the Guide tab on both surfaces (the panel's "Stats" side tab
-- shows the live stat-target bars, which are a separate inline section).
--
-- Spec-data resolution (FindMatch / GetStatContextOptions / pvpPriority
-- synthesis) stays with the surface owner so this module doesn't fork the
-- existing helpers. Callers pass the resolved values into Render*.
local Stats = {}
ns.Sections.Stats = Stats

local MAX_ROWS = 10
local DEFAULT_RANK_COLORS = {
    [1] = { r = 1.00, g = 0.50, b = 0.00 },
    [2] = { r = 0.64, g = 0.21, b = 0.93 },
    [3] = { r = 0.00, g = 0.44, b = 0.87 },
    [4] = { r = 0.12, g = 1.00, b = 0.00 },
    [5] = { r = 0.62, g = 0.62, b = 0.62 },
}

local function PickRankColor(i, override)
    return (override and override[i]) or DEFAULT_RANK_COLORS[i] or DEFAULT_RANK_COLORS[5]
end

-------------------------------------------------------------------------------
-- Panel surface
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent (contentFrame), opts.header (function(parent,label) -> header
-- frame; collapsible). The caller hooks the header OnClick separately so the
-- panel can drive its own collapsed-state persistence.
function Stats.InitPanel(opts)
    panel.section = CreateFrame("Frame", nil, opts.parent)
    panel.header = opts.header(panel.section, L["section.stat_priority"])
    panel.content = CreateFrame("Frame", nil, panel.section)
    panel.content:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, 0)
    panel.content:SetPoint("RIGHT", 0, 0)
    panel.content:SetHeight(200)

    panel.ctxDropdown = ns.CreateOptionDropdown("ClassCodexStatCtxDropdown", panel.content)
    panel.ctxDropdown:SetPoint("TOPLEFT", 0, 0)
    panel.ctxDropdown:SetPoint("TOPRIGHT", 0, 0)
    panel.ctxDropdown:Hide()

    panel.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, panel.content)
        row:SetHeight(20)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ns.ROW_HEIGHT)
        row:SetPoint("RIGHT", 0, 0)
        local rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rank:SetPoint("LEFT", 0, 0)
        rank:SetWidth(20)
        rank:SetJustifyH("CENTER")
        row.rank = rank
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        name:SetPoint("LEFT", rank, "RIGHT", 6, 0)
        name:SetPoint("RIGHT", 0, 0)
        name:SetJustifyH("LEFT")
        row.statName = name
        panel.rows[i] = row
    end

    return panel.section, panel.header, panel.content
end

-- args = {
--   contextOptions = { ctxLabel, ... } -- empty array hides the dropdown
--   currentContext = string | nil      -- which option is active
--   priorityStats  = { { "stat", ... }, ... } | nil  -- nil hides the section
--   rankColors     = optional override for tier colours
--   onCtxChange    = function(picked) end -- caller saves + re-renders
-- }
-- Returns the rendered row count for the layout pass.
function Stats.RenderPanel(args)
    local options = args.contextOptions or {}
    local showCtx = #options > 0

    if showCtx then
        panel.ctxDropdown:Show()
        panel.ctxDropdown:SetOptions(options, args.currentContext, function(picked)
            if args.onCtxChange then args.onCtxChange(picked) end
        end)
    else
        panel.ctxDropdown:Hide()
    end

    for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
    local priority = args.priorityStats
    if not priority then
        panel.section:Hide()
        return 0
    end

    local yOffset = showCtx and -30 or 0
    local count = math.min(#priority, MAX_ROWS)
    for i = 1, count do
        local row = panel.rows[i]
        local color = PickRankColor(i, args.rankColors)
        row.rank:SetTextColor(color.r or 0.6, color.g or 0.6, color.b or 0.6)
        row.rank:SetText(i .. ".")
        row.statName:SetTextColor(
            #priority[i] > 1 and 0.8 or 1,
            #priority[i] > 1 and 0.8 or 1,
            #priority[i] > 1 and 0.6 or 1
        )
        row.statName:SetText(table.concat(priority[i], " / "))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yOffset - (i - 1) * ns.ROW_HEIGHT)
        row:SetPoint("RIGHT", 0, 0)
        row:Show()
    end
    panel.section:Show()
    return count
end

-- Layout helper for the panel — returns the section's content height
-- (rows + optional 30px dropdown).
function Stats.GetPanelContentHeight(visibleRowCount)
    local h = (visibleRowCount or 0) * ns.ROW_HEIGHT
    if panel.ctxDropdown and panel.ctxDropdown:IsShown() then
        h = h + 30
    end
    return h
end

-------------------------------------------------------------------------------
-- Compendium surface
-------------------------------------------------------------------------------

local comp = {}

-- opts.parent (scrollChild), opts.headerFactory (collapsible), opts.refresh
-- (callback the dropdown invokes when ctx changes).
function Stats.InitCompendium(opts)
    comp.section = CreateFrame("Frame", nil, opts.parent)
    comp.header = opts.headerFactory(comp.section, L["section.stat_priority"], true)
    comp.content = CreateFrame("Frame", nil, comp.section)
    comp.content:SetPoint("TOPLEFT", comp.header, "BOTTOMLEFT", 0, -2)
    comp.content:SetPoint("RIGHT", 0, 0)

    comp.ctxDropdown = CreateFrame(
        "DropdownButton", "ClassCodexCompStatCtxDD",
        comp.content, "WowStyle1DropdownTemplate"
    )
    comp.ctxDropdown:SetPoint("TOPLEFT", 0, 0)
    comp.ctxDropdown:SetPoint("TOPRIGHT", 0, 0)
    comp.ctxDropdown:SetHeight(24)
    comp.ctxDropdown:Hide()

    comp.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, comp.content)
        row:SetHeight(20)
        local rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rank:SetPoint("LEFT", 0, 0); rank:SetWidth(20); rank:SetJustifyH("CENTER")
        row.rank = rank
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        name:SetPoint("LEFT", rank, "RIGHT", 6, 0); name:SetPoint("RIGHT", 0, 0)
        name:SetJustifyH("LEFT")
        row.statName = name
        comp.rows[i] = row
    end

    comp.pvpFallback = comp.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    comp.pvpFallback:SetTextColor(0.5, 0.5, 0.5)
    comp.pvpFallback:Hide()

    return comp.section, comp.header, comp.content
end

-- args = {
--   contextOptions     = { ctxKey, ... }
--   currentContext     = string
--   priorityStats      = { { "stat" }, ... } | nil
--   showPvpFallback    = boolean       -- shown when ctx=PvP but no data
--   labelForContext    = function(ctx) -> string (icon-prefixed labels)
--   onCtxChange        = function(picked)
--   rankColors         = optional
-- }
function Stats.RenderCompendium(args)
    local options = args.contextOptions or {}
    local showCtx = #options > 0

    if showCtx then
        comp.ctxDropdown:SetupMenu(function(_, rootDescription)
            for _, ctx in ipairs(options) do
                rootDescription:CreateRadio(
                    args.labelForContext and args.labelForContext(ctx) or ctx,
                    function() return args.currentContext == ctx end,
                    function()
                        if args.onCtxChange then args.onCtxChange(ctx) end
                    end,
                    ctx)
            end
        end)
        comp.ctxDropdown:Show()
    else
        comp.ctxDropdown:Hide()
    end

    comp.pvpFallback:Hide()
    for i = 1, MAX_ROWS do comp.rows[i]:Hide() end

    local priority = args.priorityStats
    if priority then
        local yOffset = showCtx and -30 or 0
        local count = math.min(#priority, MAX_ROWS)
        for i = 1, count do
            local row = comp.rows[i]
            local color = PickRankColor(i, args.rankColors)
            row.rank:SetTextColor(color.r or 0.6, color.g or 0.6, color.b or 0.6)
            row.rank:SetText(i .. ".")
            row.statName:SetTextColor(1, 1, 1)
            row.statName:SetText(table.concat(priority[i], " / "))
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 0, yOffset - (i - 1) * ns.ROW_HEIGHT)
            row:SetPoint("RIGHT", comp.content, "RIGHT", 0, 0)
            row:Show()
        end
        comp.content:SetHeight(math.abs(yOffset) + count * ns.ROW_HEIGHT)
        comp.section:Show()
    elseif args.showPvpFallback then
        local yOffset = showCtx and -30 or 0
        comp.pvpFallback:SetText(L["pvp.no_stat_priority"]
            or "No PvP stat priority for this spec yet.")
        comp.pvpFallback:ClearAllPoints()
        comp.pvpFallback:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 4, yOffset - 4)
        comp.pvpFallback:Show()
        comp.content:SetHeight(math.abs(yOffset) + 20)
        comp.section:Show()
    end
end

function Stats.GetCompendiumContentHeight()
    local h = 0
    if comp.ctxDropdown:IsShown() then h = h + 30 end
    for i = 1, MAX_ROWS do
        if comp.rows[i]:IsShown() then h = h + ns.ROW_HEIGHT end
    end
    if comp.pvpFallback:IsShown() then h = h + 20 end
    return h
end
