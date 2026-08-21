local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

-- Talents section — Guide-tab preview only (the top builds for the active
-- hero, with copy + apply buttons). The standalone "Talents" side tab on
-- the panel (and the Talents tab in the Compendium) still renders inline
-- because the grouped-by-context / Archon-encounter layout uses its own
-- on-demand row + header pools with archon-section collapse state.
local Talents = {}
ns.Sections.Talents = Talents

local MAX_BUTTONS = 10
local BTN_HEIGHT = 22
local BTN_GAP    = 4
local ACTION_SIZE = 18
local ACTION_GAP  = 2

local function makeActionButton(parent, icon, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ACTION_SIZE, ACTION_SIZE)
    b:RegisterForClicks("LeftButtonUp")
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(icon)
    tex:SetDesaturated(true)
    tex:SetVertexColor(0.7, 0.7, 0.7)
    b.icon = tex
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetTexture(icon); hl:SetAlpha(0.3)
    b:SetScript("OnEnter", function(self)
        self.icon:SetDesaturated(false)
        self.icon:SetVertexColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tooltip, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.icon:SetDesaturated(true)
        self.icon:SetVertexColor(0.7, 0.7, 0.7)
        GameTooltip:Hide()
    end)
    return b
end
ns.CreateTalentActionButton = makeActionButton
ns.TALENT_BTN_HEIGHT = BTN_HEIGHT
ns.TALENT_BTN_GAP = BTN_GAP
ns.TALENT_ACTION_GAP = ACTION_GAP

-------------------------------------------------------------------------------
-- Panel surface (Guide-tab preview)
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent (contentFrame), opts.header (CreateSectionHeader) for collapse hook
function Talents.InitPanel(opts)
    panel.section = CreateFrame("Frame", nil, opts.parent)
    panel.header = opts.header(panel.section, L["section.talents"])
    panel.content = CreateFrame("Frame", nil, panel.section)
    panel.content:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, 0)
    panel.content:SetPoint("RIGHT", 0, 0)
    panel.content:SetHeight(100)

    panel.buttons = {}
    for i = 1, MAX_BUTTONS do
        local row = CreateFrame("Frame", nil, panel.content, "BackdropTemplate")
        row:SetHeight(BTN_HEIGHT)
        row:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        row:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
        row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

        local applyBtn = makeActionButton(row,
            "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "Apply talents")
        applyBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.applyBtn = applyBtn

        local copyBtn = makeActionButton(row,
            "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "Copy talent string")
        copyBtn:SetPoint("RIGHT", applyBtn, "LEFT", -ACTION_GAP, 0)
        row.copyBtn = copyBtn

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", 8, 0)
        text:SetPoint("RIGHT", copyBtn, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")
        text:SetTextColor(0.8, 0.8, 0.8)
        row.label = text

        row:SetScript("OnEnter", function(self)
            if not self.isActive then self:SetBackdropBorderColor(0.6, 0.6, 0.6, 1) end
            self.label:SetTextColor(1, 1, 1)
        end)
        row:SetScript("OnLeave", function(self)
            if not self.isActive then self:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8) end
            self.label:SetTextColor(self.isActive and 0.3 or 0.8, self.isActive and 1 or 0.8, self.isActive and 0.3 or 0.8)
        end)
        row:Hide()
        panel.buttons[i] = row
    end

    panel.fallback = CreateFrame("Frame", nil, panel.content)
    panel.fallback:SetHeight(20)
    panel.fallbackText = panel.fallback:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.fallbackText:SetPoint("LEFT", 0, 0); panel.fallbackText:SetPoint("RIGHT", 0, 0)
    panel.fallbackText:SetJustifyH("LEFT"); panel.fallbackText:SetTextColor(0.5, 0.5, 0.5)
    panel.fallback:Hide()

    return panel.section, panel.header, panel.content
end

function Talents.GetPanelButtons() return panel.buttons end
function Talents.GetPanelMax() return MAX_BUTTONS end

-- args = {
--   builds              -- array of build records (already filtered to hero)
--   hero                -- current hero talent name (used by labels)
--   activeTalentBits    -- bit signature for the active loadout
--   fallbackEmptyText   -- shown when specData has no talents at all
--   fallbackNoneText    -- shown when builds is empty but the spec has talents
--   onCopy(build)       -- click handler for the copy button (passes build)
--   onApply(self, build)
-- }
-- Returns content height for the layout pass.
function Talents.RenderPanel(args)
    for i = 1, MAX_BUTTONS do panel.buttons[i]:Hide() end
    panel.fallback:Hide()

    if args.fallbackEmptyText then
        panel.fallbackText:SetText(args.fallbackEmptyText)
        panel.fallback:ClearAllPoints()
        panel.fallback:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, 0)
        panel.fallback:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
        panel.fallback:Show()
        panel.section:Show()
        return ns.ROW_HEIGHT
    end

    local builds = args.builds or {}
    if #builds == 0 then
        if args.fallbackNoneText then
            panel.fallbackText:SetText(args.fallbackNoneText)
            panel.fallback:ClearAllPoints()
            panel.fallback:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, 0)
            panel.fallback:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
            panel.fallback:Show()
            panel.section:Show()
            return ns.ROW_HEIGHT
        end
        panel.section:Hide()
        return 0
    end

    local count = math.min(#builds, MAX_BUTTONS)
    for i = 1, count do
        local t = builds[i]
        local btn = panel.buttons[i]
        local label = ns.FormatBuildLabel and ns.FormatBuildLabel(t) or (t.label or "Build")
        local isActive = args.activeTalentBits
            and ns.ExtractTalentBits and ns.ExtractTalentBits(t.exportString) == args.activeTalentBits
        btn.isActive = isActive
        if isActive then
            btn:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
            btn.label:SetTextColor(0.3, 1, 0.3)
        else
            btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            btn.label:SetTextColor(0.8, 0.8, 0.8)
        end
        btn.label:SetText(label)
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -((i - 1) * (BTN_HEIGHT + BTN_GAP)))
        btn:SetPoint("RIGHT", panel.content, "RIGHT", 0, 0)
        if args.onCopy then
            btn.copyBtn:SetScript("OnClick", function() args.onCopy(t) end)
        end
        if args.onApply then
            btn.applyBtn:SetScript("OnClick", function(self) args.onApply(self, t) end)
        end
        btn:Show()
    end
    panel.section:Show()
    return count * (BTN_HEIGHT + BTN_GAP)
end
