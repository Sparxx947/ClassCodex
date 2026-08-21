local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

-- Rotation section — context dropdown + ordered step list (numbered, with
-- spell-id icon and conditional visibility). Renders on the Guide tab on
-- both surfaces. Spec-data resolution (FindRotationByContext /
-- GetRotationContextOptions / step-condition helpers) stays with the
-- surface owner; the caller passes the resolved rotation in.
local Rotation = {}
ns.Sections.Rotation = Rotation

local MAX_STEPS = 20

local function makeStepHelpers(opts)
    return {
        shouldShow = opts.shouldShow or function() return true end,
        strip      = opts.strip      or function(s) return s end,
        getIcon    = opts.getIcon    or function() return "Interface\\Icons\\INV_Misc_QuestionMark" end,
        format     = opts.format     or function(s) return s end,
    }
end

local function makeStepRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ns.ROW_HEIGHT)
    local rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rank:SetPoint("TOPLEFT", 0, 0)
    rank:SetWidth(18); rank:SetJustifyH("RIGHT")
    rank:SetTextColor(0.5, 0.5, 0.5)
    row.rank = rank
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16); icon:SetPoint("TOPLEFT", rank, "TOPRIGHT", 4, 0)
    row.icon = icon
    local stepText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    stepText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
    stepText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    stepText:SetJustifyH("LEFT"); stepText:SetJustifyV("TOP")
    stepText:SetWordWrap(true); stepText:SetNonSpaceWrap(true)
    row.stepText = stepText
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.spellId then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellId)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-------------------------------------------------------------------------------
-- Panel surface
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent (contentFrame), opts.header (CreateSectionHeader) for collapse hook
function Rotation.InitPanel(opts)
    panel.section = CreateFrame("Frame", nil, opts.parent)
    panel.header = opts.header(panel.section, L["section.rotation"])
    panel.content = CreateFrame("Frame", nil, panel.section)
    panel.content:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, 0)
    panel.content:SetPoint("RIGHT", 0, 0)
    panel.content:SetHeight(400)

    panel.ctxDropdown = ns.CreateOptionDropdown("ClassCodexRotCtxDropdown", panel.content)
    panel.ctxDropdown:SetPoint("TOPLEFT", 0, 0)
    panel.ctxDropdown:SetPoint("TOPRIGHT", 0, 0)

    panel.rows = {}
    for i = 1, MAX_STEPS do panel.rows[i] = makeStepRow(panel.content) end

    panel.fallback = CreateFrame("Frame", nil, panel.content)
    panel.fallback:SetHeight(20)
    panel.fallbackText = panel.fallback:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.fallbackText:SetPoint("LEFT", 0, 0); panel.fallbackText:SetPoint("RIGHT", 0, 0)
    panel.fallbackText:SetJustifyH("LEFT"); panel.fallbackText:SetTextColor(0.5, 0.5, 0.5)
    panel.fallback:Hide()

    return panel.section, panel.header, panel.content
end

function Rotation.IsPanelCtxDropdownShown() return panel.ctxDropdown:IsShown() end

-- args = {
--   contextOptions, currentContext, rotation (resolved {steps=...} or nil),
--   heroTalent, hasAnyRotation (bool, for fallback), textAreaWidth,
--   helpers = { shouldShow, strip, getIcon, format },
--   onCtxChange,
-- }
-- Returns content height for the layout pass.
function Rotation.RenderPanel(args)
    local options = args.contextOptions or {}
    local showCtx = #options > 1
    if showCtx then
        panel.ctxDropdown:Show()
        panel.ctxDropdown:SetOptions(options, args.currentContext, function(picked)
            if args.onCtxChange then args.onCtxChange(picked) end
        end)
    else
        panel.ctxDropdown:Hide()
    end

    for i = 1, MAX_STEPS do panel.rows[i]:Hide() end
    panel.fallback:Hide()

    local h = makeStepHelpers(args.helpers or {})
    local rotation = args.rotation
    local hero = args.heroTalent
    local textW = args.textAreaWidth or 200

    if rotation then
        local yOffset = showCtx and -30 or 0
        local visibleStep = 0
        local currentY = yOffset
        for _, step in ipairs(rotation.steps) do
            if h.shouldShow(step, hero) then
                visibleStep = visibleStep + 1
                if visibleStep > MAX_STEPS then break end
                local row = panel.rows[visibleStep]
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, currentY)
                row:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
                row.rank:SetText(visibleStep .. ".")
                row.icon:SetTexture(h.getIcon(step))
                local cleanStep = h.strip(step)
                row.stepText:SetText(h.format(cleanStep))
                row.spellId = tonumber(cleanStep:match("{(%d+)}"))
                row.stepText:SetWidth(textW)
                local textHeight = row.stepText:GetStringHeight() or 12
                local rowH = math.max(ns.ROW_HEIGHT, textHeight + 6)
                row:SetHeight(rowH)
                row:Show()
                currentY = currentY - rowH
            end
        end
        panel.section:Show()
        return math.abs(currentY - yOffset)
    elseif args.hasAnyRotation then
        local yOffset = showCtx and -30 or 0
        panel.fallbackText:SetText(L["empty.no_rotation_for_details"]:format(hero or ""))
        panel.fallback:ClearAllPoints()
        panel.fallback:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, yOffset)
        panel.fallback:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
        panel.fallback:Show()
        panel.section:Show()
        return ns.ROW_HEIGHT
    else
        panel.section:Hide()
        return 0
    end
end

-------------------------------------------------------------------------------
-- Compendium surface
-------------------------------------------------------------------------------

local comp = {}

function Rotation.InitCompendium(opts)
    comp.section = CreateFrame("Frame", nil, opts.parent)
    comp.header = opts.headerFactory(comp.section, L["section.rotation"], true)
    comp.content = CreateFrame("Frame", nil, comp.section)
    comp.content:SetPoint("TOPLEFT", comp.header, "BOTTOMLEFT", 0, -2)
    comp.content:SetPoint("RIGHT", 0, 0)

    comp.ctxDropdown = CreateFrame(
        "DropdownButton", "ClassCodexCompRotCtxDD",
        comp.content, "WowStyle1DropdownTemplate"
    )
    comp.ctxDropdown:SetPoint("TOPLEFT", 0, 0)
    comp.ctxDropdown:SetPoint("TOPRIGHT", 0, 0)
    comp.ctxDropdown:SetHeight(24); comp.ctxDropdown:Hide()

    comp.rows = {}
    for i = 1, MAX_STEPS do comp.rows[i] = makeStepRow(comp.content) end

    comp.fallback = comp.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    comp.fallback:SetTextColor(0.5, 0.5, 0.5); comp.fallback:Hide()

    comp.header:SetScript("OnClick", function()
        comp.collapsed = not comp.collapsed
        ns.SetCollapsed(comp.content, comp.header, comp.collapsed)
        if opts.refresh then opts.refresh() end
    end)

    return comp.section, comp.header, comp.content
end


function Rotation.RenderCompendium(args)
    local options = args.contextOptions or {}
    local showCtx = #options > 1
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

    for i = 1, MAX_STEPS do comp.rows[i]:Hide() end
    comp.fallback:Hide()

    local h = makeStepHelpers(args.helpers or {})
    local rotation = args.rotation
    local hero = args.heroTalent
    local textW = args.textAreaWidth or 400

    if rotation then
        local yOffset = showCtx and -30 or 0
        local visibleStep = 0
        local currentY = yOffset
        for _, step in ipairs(rotation.steps) do
            if h.shouldShow(step, hero) then
                visibleStep = visibleStep + 1
                if visibleStep > MAX_STEPS then break end
                local row = comp.rows[visibleStep]
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 0, currentY)
                row:SetPoint("RIGHT", comp.content, "RIGHT", 0, 0)
                row.rank:SetText(visibleStep .. ".")
                row.icon:SetTexture(h.getIcon(step))
                local cleanStep = h.strip(step)
                row.stepText:SetText(h.format(cleanStep))
                row.spellId = tonumber(cleanStep:match("{(%d+)}"))
                row.stepText:SetWidth(textW)
                local textHeight = row.stepText:GetStringHeight() or 12
                local rowH = math.max(ns.ROW_HEIGHT, textHeight + 6)
                row:SetHeight(rowH)
                row:Show()
                currentY = currentY - rowH
            end
        end
        comp.content:SetHeight(math.abs(currentY))
        comp.section:Show()
    elseif args.hasAnyRotation then
        local yOffset = showCtx and -30 or 0
        comp.fallback:SetText(L["empty.no_rotation_for_details"]:format(hero or ""))
        comp.fallback:ClearAllPoints()
        comp.fallback:SetPoint("TOPLEFT", comp.content, "TOPLEFT", 0, yOffset)
        comp.fallback:SetPoint("RIGHT", comp.content, "RIGHT", 0, 0)
        comp.fallback:Show()
        comp.content:SetHeight(math.abs(yOffset) + 20)
        comp.section:Show()
    end
end

function Rotation.GetCompendiumContentHeight()
    local h = 0
    if comp.ctxDropdown:IsShown() then h = h + 30 end
    for i = 1, MAX_STEPS do
        if comp.rows[i]:IsShown() then h = h + comp.rows[i]:GetHeight() end
    end
    if comp.fallback:IsShown() then h = h + 20 end
    return h
end
