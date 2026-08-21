local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

-- Live stat-target bars rendered on the panel's "Stats" side tab. Pairs the
-- empirical secondary-stat targets from Archon (M+ / Raid / PvP) with the
-- player's current ratings, showing a Blizzard StatusBar filled toward the
-- target plus a tinted delta arrow (green/blue/red).
local StatTargets = {}
ns.Sections.StatTargets = StatTargets

local ROW_HEIGHT = 40
local ROW_GAP    = 5
local BAR_HEIGHT = 16
local MAX_ROWS   = 4
local BAR_MAX_RATIO = 1.3

local DISPLAY_ORDER = { "mastery", "haste", "crit", "versatility" }

local STATUS_ICONS = {
    above = { texture = "Interface\\BUTTONS\\Arrow-Up-Up",       r = 0.40, g = 0.70, b = 1.00, texCoord = { 0, 1, 0, 1 } },
    at    = { texture = "Interface\\BUTTONS\\UI-CheckBox-Check", r = 0.40, g = 1.00, b = 0.45, texCoord = { 0, 1, 0, 1 } },
    below = { texture = "Interface\\BUTTONS\\Arrow-Up-Up",       r = 1.00, g = 0.40, b = 0.40, texCoord = { 0, 1, 1, 0 } },
}
local BAR_COLORS = {
    above = { 0.35, 0.65, 1.00 },
    at    = { 0.40, 1.00, 0.45 },
    below = { 0.95, 0.40, 0.40 },
}

local panel = {}
panel.currentCtx = nil

local function MakeBar(row)
    local barFrame = CreateFrame("Frame", nil, row)
    barFrame:SetPoint("BOTTOMLEFT", 4, 3)
    barFrame:SetPoint("BOTTOMRIGHT", -2, 3)
    barFrame:SetHeight(BAR_HEIGHT)

    local function colorEdge(layer, r, g, b, a)
        local t = barFrame:CreateTexture(nil, layer)
        t:SetColorTexture(r, g, b, a or 1)
        return t
    end
    -- Outer 1px black ring
    local oTop  = colorEdge("BORDER", 0, 0, 0); oTop:SetPoint("TOPLEFT"); oTop:SetPoint("TOPRIGHT"); oTop:SetHeight(1)
    local oBot  = colorEdge("BORDER", 0, 0, 0); oBot:SetPoint("BOTTOMLEFT"); oBot:SetPoint("BOTTOMRIGHT"); oBot:SetHeight(1)
    local oL    = colorEdge("BORDER", 0, 0, 0); oL:SetPoint("TOPLEFT"); oL:SetPoint("BOTTOMLEFT"); oL:SetWidth(1)
    local oR    = colorEdge("BORDER", 0, 0, 0); oR:SetPoint("TOPRIGHT"); oR:SetPoint("BOTTOMRIGHT"); oR:SetWidth(1)
    -- Inner WoW-tan bevel
    local iTop  = colorEdge("BORDER", 0.62, 0.51, 0.27); iTop:SetPoint("TOPLEFT", 1, -1); iTop:SetPoint("TOPRIGHT", -1, -1); iTop:SetHeight(1)
    local iBot  = colorEdge("BORDER", 0.62, 0.51, 0.27); iBot:SetPoint("BOTTOMLEFT", 1, 1); iBot:SetPoint("BOTTOMRIGHT", -1, 1); iBot:SetHeight(1)
    local iL    = colorEdge("BORDER", 0.62, 0.51, 0.27); iL:SetPoint("TOPLEFT", 1, -1); iL:SetPoint("BOTTOMLEFT", 1, 1); iL:SetWidth(1)
    local iR    = colorEdge("BORDER", 0.62, 0.51, 0.27); iR:SetPoint("TOPRIGHT", -1, -1); iR:SetPoint("BOTTOMRIGHT", -1, 1); iR:SetWidth(1)

    -- Dark recessed plate
    local barBg = barFrame:CreateTexture(nil, "BACKGROUND")
    barBg:SetPoint("TOPLEFT", 2, -2); barBg:SetPoint("BOTTOMRIGHT", -2, 2)
    barBg:SetColorTexture(0.05, 0.05, 0.05, 1)
    -- 1px inner top shadow
    local innerShadow = barFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
    innerShadow:SetColorTexture(0, 0, 0, 0.55)
    innerShadow:SetPoint("TOPLEFT", 2, -2); innerShadow:SetPoint("TOPRIGHT", -2, -2)
    innerShadow:SetHeight(1)

    -- Fill
    local fill = barFrame:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 2, -2); fill:SetPoint("BOTTOMLEFT", 2, 2)
    fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    fill:SetVertexColor(0.85, 0.45, 0.45, 1)
    fill:SetWidth(0)

    -- Gloss
    local glossHeight = math.max(2, math.floor((BAR_HEIGHT - 4) * 0.4))
    local gloss = barFrame:CreateTexture(nil, "OVERLAY")
    gloss:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    gloss:SetVertexColor(1, 1, 1, 0.16)
    gloss:SetBlendMode("ADD")
    gloss:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
    gloss:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
    gloss:SetHeight(glossHeight)

    -- Target tick
    local tick = barFrame:CreateTexture(nil, "OVERLAY")
    tick:SetColorTexture(0.95, 0.86, 0.55, 0.95)
    tick:SetWidth(2)
    barFrame.tick = tick

    barFrame:SetScript("OnSizeChanged", function(self, w)
        local p = self.progress or 0
        local inner = math.max(0, w - 4)
        self.fill:SetWidth(math.max(p > 0 and 2 or 0, math.min(p * inner, inner)))
        if self.tick then
            local tickX = 2 + math.floor((1 / BAR_MAX_RATIO) * inner + 0.5)
            self.tick:ClearAllPoints()
            self.tick:SetPoint("TOP", self, "TOPLEFT", tickX, -2)
            self.tick:SetPoint("BOTTOM", self, "BOTTOMLEFT", tickX, 2)
        end
    end)
    barFrame.fill = fill
    return barFrame
end

-- opts.parent (contentFrame)
function StatTargets.InitPanel(opts)
    panel.section = CreateFrame("Frame", nil, opts.parent)
    panel.content = CreateFrame("Frame", nil, panel.section)
    panel.content:SetPoint("TOPLEFT", 0, 0)
    panel.content:SetPoint("RIGHT", 0, 0)
    panel.content:SetHeight(140)

    panel.ctxDropdown = ns.CreateOptionDropdown("ClassCodexStatTargetCtxDropdown", panel.content)
    panel.ctxDropdown:SetPoint("TOPLEFT", 0, 0)
    panel.ctxDropdown:SetPoint("TOPRIGHT", 0, 0)

    panel.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, panel.content)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", 0, 0); row:SetPoint("RIGHT", 0, 0)

        local statusIcon = row:CreateTexture(nil, "ARTWORK")
        statusIcon:SetSize(14, 14); statusIcon:SetPoint("TOPRIGHT", -2, -2)
        row.statusIcon = statusIcon

        local rating = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rating:SetPoint("RIGHT", statusIcon, "LEFT", -4, 0)
        rating:SetJustifyH("RIGHT")
        row.rating = rating

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        name:SetPoint("TOPLEFT", 4, -2)
        name:SetPoint("RIGHT", rating, "LEFT", -4, 0)
        name:SetJustifyH("LEFT")
        row.statName = name

        row.bar = MakeBar(row)
        panel.rows[i] = row
    end

    panel.pvpFallback = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.pvpFallback:SetTextColor(0.5, 0.5, 0.5); panel.pvpFallback:SetJustifyH("LEFT"); panel.pvpFallback:SetWordWrap(true)
    panel.pvpFallback:Hide()

    panel.combatFallback = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.combatFallback:SetTextColor(0.5, 0.5, 0.5); panel.combatFallback:SetJustifyH("LEFT"); panel.combatFallback:SetWordWrap(true)
    panel.combatFallback:Hide()

    return panel.section
end

function StatTargets.GetPanelContent() return panel.content end

-- Active stat-targets context ("Mythic+" / "Raid" / "PvP"). Used by attribution
-- to credit Archon (PvE) vs Murlok (PvP).
function StatTargets.GetActiveContext() return panel.currentCtx end

-- Layout-pass height (rows + optional 28px dropdown + bottom margin).
function StatTargets.GetPanelHeight()
    local h = 0
    if panel.ctxDropdown:IsShown() then h = h + 28 end
    local n = 0
    for i = 1, MAX_ROWS do
        if panel.rows[i]:IsShown() then n = n + 1 end
    end
    if n > 0 then
        h = h + n * ROW_HEIGHT + (n - 1) * ROW_GAP + 4
    elseif panel.pvpFallback:IsShown() or panel.combatFallback:IsShown() then
        h = h + 24
    end
    return h
end

-- args = { classToken, specKey, refresh }
-- Returns the rendered row count.
function StatTargets.RenderPanel(args)
    panel.combatFallback:Hide()
    local classToken = args.classToken
    local specKey = args.specKey
    if not classToken or not specKey then
        for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
        return 0
    end

    -- Build context list. M+/Raid only when Archon has data; PvP always
    -- surfaced for discoverability.
    local availableContexts = {}
    for _, ctx in ipairs({ "Mythic+", "Raid" }) do
        if ns.GetStatTargets(classToken, specKey, ctx) then
            availableContexts[#availableContexts + 1] = ctx
        end
    end
    local pvpTargets = ns.GetPvPStatTargets and ns.GetPvPStatTargets(classToken, specKey) or nil
    availableContexts[#availableContexts + 1] = "PvP"

    if #availableContexts == 1 and not pvpTargets then
        panel.ctxDropdown:Hide()
        panel.pvpFallback:Hide()
        for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
        return 0
    end

    local function resolveCtx(ctx)
        if ctx == "PvP" then return pvpTargets end
        return ns.GetStatTargets(classToken, specKey, ctx)
    end

    local hasNonPvpCtx = false
    for _, ctx in ipairs(availableContexts) do
        if ctx ~= "PvP" then hasNonPvpCtx = true; break end
    end
    if not panel.currentCtx
        or (panel.currentCtx ~= "PvP" and not resolveCtx(panel.currentCtx)) then
        panel.currentCtx = hasNonPvpCtx and availableContexts[1] or "PvP"
    end

    if #availableContexts > 1 then
        panel.ctxDropdown:Show()
        panel.ctxDropdown:SetOptions(availableContexts, panel.currentCtx, function(selected)
            panel.currentCtx = selected
            if args.refresh then args.refresh() end
        end)
    else
        panel.ctxDropdown:Hide()
    end

    if panel.currentCtx == "PvP" and not pvpTargets then
        for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
        local yOffset = (#availableContexts > 1) and -28 or -4
        panel.pvpFallback:SetText(L["pvp.no_stat_targets"]
            or "No PvP stat targets for this spec yet.")
        panel.pvpFallback:ClearAllPoints()
        panel.pvpFallback:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, yOffset)
        panel.pvpFallback:SetPoint("RIGHT", panel.content, "RIGHT", -4, 0)
        panel.pvpFallback:Show()
        return 1
    end
    panel.pvpFallback:Hide()

    local snapshot = resolveCtx(panel.currentCtx)
    if not snapshot or not snapshot.targets then
        for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
        return 0
    end

    if InCombatLockdown() then
        for i = 1, MAX_ROWS do panel.rows[i]:Hide() end
        local yOffset = (#availableContexts > 1) and -28 or -4
        panel.combatFallback:SetText(
            L["stat_targets.combat_warning"]
            or "Stat targets can't be computed in combat — values update after combat ends.")
        panel.combatFallback:ClearAllPoints()
        panel.combatFallback:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 4, yOffset)
        panel.combatFallback:SetPoint("RIGHT", panel.content, "RIGHT", -4, 0)
        panel.combatFallback:Show()
        return 1
    end


    local yOffset = (#availableContexts > 1) and -28 or -4
    local visibleCount = 0

    for _, statKey in ipairs(DISPLAY_ORDER) do
        local target = snapshot.targets[statKey]
        if target and target > 0 then
            visibleCount = visibleCount + 1
            local row = panel.rows[visibleCount]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, yOffset)
            row:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", 0, yOffset)
            row:Show()
            yOffset = yOffset - ROW_HEIGHT - ROW_GAP

            local current = ns.GetPlayerStatRating(statKey)
            local livePct = ns.GetPlayerStatPercent(statKey)
            row.statName:SetText(ns.STAT_LABELS[statKey] or statKey)

            local kind = ns.ClassifyStatDelta(current, target) or "below"
            local status = STATUS_ICONS[kind]
            row.statusIcon:SetTexture(status.texture)
            row.statusIcon:SetTexCoord(status.texCoord[1], status.texCoord[2], status.texCoord[3], status.texCoord[4])
            row.statusIcon:SetVertexColor(status.r, status.g, status.b)

            row.rating:SetText(string.format("%.1f%%  |cff9a9a9a%d / %d|r", livePct, current, target))

            local marginal = ns.GetMarginalDR and ns.GetMarginalDR(livePct) or 1
            if marginal >= 1 then
                row.rating:SetTextColor(0.85, 0.85, 0.85)
            elseif marginal >= 0.8 then
                row.rating:SetTextColor(1, 0.85, 0.4)
            elseif marginal >= 0.6 then
                row.rating:SetTextColor(1, 0.65, 0.1)
            else
                row.rating:SetTextColor(1, 0.4, 0.2)
            end

            row:EnableMouse(true)
            row.statKey = statKey
            row.snapshot = snapshot
            if not row._statTooltipBound then
                row:SetScript("OnEnter", function(self)
                    if not self.statKey then return end
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if ns.AppendStatExtrasToTooltip then
                        ns.AppendStatExtrasToTooltip(GameTooltip, self.statKey, self.snapshot, { includeTitle = true })
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row._statTooltipBound = true
            end

            local rawRatio = current / target
            local progress = math.min(rawRatio, BAR_MAX_RATIO) / BAR_MAX_RATIO
            row.bar.progress = progress
            local barW = row.bar:GetWidth()
            local inner = math.max(0, barW - 4)
            row.bar.fill:SetWidth(math.max(progress > 0 and 2 or 0, math.min(progress * inner, inner)))

            if row.bar.tick then
                local tickX = 2 + math.floor((1 / BAR_MAX_RATIO) * inner + 0.5)
                row.bar.tick:ClearAllPoints()
                row.bar.tick:SetPoint("TOP", row.bar, "TOPLEFT", tickX, -2)
                row.bar.tick:SetPoint("BOTTOM", row.bar, "BOTTOMLEFT", tickX, 2)
            end

            local barColor = BAR_COLORS[kind]
            row.bar.fill:SetVertexColor(barColor[1], barColor[2], barColor[3], 1)
        end
    end

    for i = visibleCount + 1, MAX_ROWS do panel.rows[i]:Hide() end
    return visibleCount
end
