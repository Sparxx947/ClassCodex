local _, ns = ...
ns.Sections = ns.Sections or {}

local L = ns.L

local About = {}
ns.Sections.About = About

-------------------------------------------------------------------------------
-- Button factory for the About tab
-------------------------------------------------------------------------------

local function CreateAboutButton(parent, label, bgR, bgG, bgB, borderR, borderG, borderB)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetHeight(24)
    btn:Hide()
    btn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(bgR or 0.15, bgG or 0.15, bgB or 0.15, 0.9)
    btn:SetBackdropBorderColor(borderR or 0.4, borderG or 0.4, borderB or 0.4, 0.8)
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER", 0, 0)
    text:SetText(label)
    text:SetTextColor(0.8, 0.8, 0.8)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor((borderR or 0.4) + 0.2, (borderG or 0.4) + 0.2, (borderB or 0.4) + 0.2, 1)
        text:SetTextColor(1, 1, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(borderR or 0.4, borderG or 0.4, borderB or 0.4, 0.8)
        text:SetTextColor(0.8, 0.8, 0.8)
    end)
    return btn
end

local function SetCopyOnClick(btn, url)
    btn:SetScript("OnClick", function()
        local resolved = type(url) == "function" and url() or url
        if ns.ShowCopyPopup then ns.ShowCopyPopup(resolved, btn) end
    end)
end

-- Exposed for any future callers that need the same backdrop button style.
About.CreateButton = CreateAboutButton
About.SetCopyOnClick = SetCopyOnClick

-------------------------------------------------------------------------------
-- Panel surface (Compendium has no About tab)
-------------------------------------------------------------------------------

local panel = {}

-- opts.parent (contentFrame), opts.contentWidth (text wrap width),
-- opts.version (addon version string).
function About.InitPanel(opts)
    panel.parent = opts.parent

    -- Title row
    panel.title = CreateFrame("Frame", nil, opts.parent)
    panel.title:SetHeight(ns.SECTION_HEADER_HEIGHT)
    local titleText = panel.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("LEFT", 2, 0)
    titleText:SetText(L["about.title"]:format(opts.version or "?"))
    titleText:SetTextColor(1, 0.82, 0)
    panel.title:Hide()

    -- Content (description + slash hint)
    panel.content = CreateFrame("Frame", nil, opts.parent)
    panel.content:SetHeight(1)
    panel.content:Hide()

    local desc = panel.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 2, 0)
    desc:SetWidth(opts.contentWidth)
    desc:SetJustifyH("LEFT"); desc:SetWordWrap(true); desc:SetNonSpaceWrap(true)
    desc:SetText(L["about.description"])

    local slash = panel.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slash:SetPoint("LEFT", desc, "LEFT", 0, 0)
    slash:SetPoint("TOP", desc, "BOTTOM", 0, -10)
    slash:SetWidth(opts.contentWidth)
    slash:SetJustifyH("LEFT")
    slash:SetTextColor(0.5, 0.5, 0.5)
    slash:SetText(L["about.help_hint"])
    panel.slashHint = slash
    panel.lastChild = slash

    local function classSpec()
        local classToken = select(2, UnitClass("player"))
        local specKey = ns.GetSpecKey and ns.GetSpecKey() or nil
        local spec = specKey and (specKey:match("-(.+)") or specKey)
        return classToken, spec
    end

    -- Generic branded card — shared by the Addon, Data Sources and Community
    -- grids. o = { texture, color = {r,g,b}, title, role, onClick, emphasize,
    --   copy + urlFn (link cards) | hint (action cards) }.
    local function CreateCard(o)
        local card = CreateFrame("Button", nil, opts.parent, "BackdropTemplate")
        card:SetHeight(38)
        card:Hide()
        card:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        card:SetBackdropColor(0.12, 0.12, 0.12, 0.9)

        local c = o.color or { 0.5, 0.5, 0.55 }
        -- Emphasized cards keep a faint accent-tinted border at rest
        -- so they stand out a touch; everything else uses neutral grey.
        local restR, restG, restB, restA = 0.35, 0.35, 0.35, 0.8
        if o.emphasize then restR, restG, restB, restA = c[1], c[2], c[3], 0.55 end
        card:SetBackdropBorderColor(restR, restG, restB, restA)
        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", 3, -3)
        accent:SetPoint("BOTTOMLEFT", 3, 3)
        accent:SetWidth(3)
        accent:SetColorTexture(c[1], c[2], c[3], 0.9)

        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", 12, 0)
        icon:SetTexture(o.texture)

        local name = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 2)
        name:SetPoint("RIGHT", card, "RIGHT", -6, 0)
        name:SetJustifyH("LEFT"); name:SetWordWrap(false)
        name:SetText(o.title)
        name:SetTextColor(1, 0.82, 0)

        local roleFs = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        roleFs:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, -2)
        roleFs:SetPoint("RIGHT", card, "RIGHT", -6, 0)
        roleFs:SetJustifyH("LEFT"); roleFs:SetWordWrap(false)
        roleFs:SetText(o.role)
        roleFs:SetTextColor(0.55, 0.55, 0.55)

        card:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.17, 0.17, 0.17, 0.95)
            self:SetBackdropBorderColor(c[1], c[2], c[3], 1)
            name:SetTextColor(1, 0.9, 0.35)
            if o.copy then
                -- Link cards: source cards encourage visiting the source; all
                -- show the destination and the copy hint.
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                if o.visitName then
                    GameTooltip:SetText(ns.L["attribution.visit_source"]:format(o.visitName), 1, 0.82, 0)
                else
                    GameTooltip:SetText(ns.L["attribution.copy_url"], 1, 0.82, 0)
                end
                local url = o.urlFn and o.urlFn()
                if url then GameTooltip:AddLine(url, 0.6, 0.6, 0.6, true) end
                if o.visitName then
                    -- Blank line + green actionable hint (WoW instruction-line idiom).
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(ns.L["attribution.copy_url"], 0.45, 0.75, 0.45)
                end
                GameTooltip:Show()
            elseif o.hint then
                -- Action cards: what the click does, in-game.
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(o.hint, 1, 0.82, 0)
                GameTooltip:Show()
            end
        end)
        card:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.12, 0.12, 0.12, 0.9)
            self:SetBackdropBorderColor(restR, restG, restB, restA)
            name:SetTextColor(1, 0.82, 0)
            GameTooltip:Hide()
        end)
        card:SetScript("OnClick", function(self) if o.onClick then o.onClick(self) end end)
        return card
    end

    local function copyCard(o)
        o.copy = true
        o.onClick = function(self)
            local url = o.urlFn()
            if url and ns.ShowCopyPopup then ns.ShowCopyPopup(url, self) end
        end
        return CreateCard(o)
    end

    local function sectionLabel(text)
        local fs = opts.parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetText(text)
        fs:SetTextColor(0.7, 0.7, 0.7)
        fs:Hide()
        return fs
    end

    -- Class Codex (addon actions + community): issue tracker + settings.
    -- Upstream had a Discord card and a Patreon card here. The Discord
    -- belongs to the discontinued project, so it pointed at a room where
    -- nobody answers; the Patreon both asked for money in-game (against
    -- Blizzard policy rule 5) and asked for it on behalf of a project that
    -- is no longer maintained. The Compendium lives on the title bar now.
    panel.addonLabel = sectionLabel("Class Codex")
    panel.addonCards = {
        copyCard({
            texture = "Interface\\Icons\\INV_Misc_Note_01", color = { 0.55, 0.60, 0.68 },
            title = "GitHub", role = L["about.role.github"],
            urlFn = function() return "https://github.com/Sparxx947/ClassCodex/issues" end,
        }),
        CreateCard({
            texture = "Interface\\AddOns\\ClassCodex\\Textures\\gear", color = { 0.55, 0.55, 0.58 },
            title = "Settings", role = L["about.role.settings"],
            hint = L["compendium.open_settings"],
            onClick = function()
                if Settings and Settings.OpenToCategory and ns.settingsCategory then
                    Settings.OpenToCategory(ns.settingsCategory:GetID())
                end
            end,
        }),
    }

    -- Data Sources — credited once each, linking the source's page for the
    -- current spec. The precise per-surface links live on their own tabs.
    panel.dataLabel = sectionLabel(L["about.data_sources"])
    local function sourceCard(key, role, urlFn)
        local src = ns.SOURCES[key]
        return copyCard({
            texture = ns.SourceTexturePath(key), color = src.color,
            title = src.name, role = role, urlFn = urlFn, visitName = src.name,
        })
    end
    panel.sourceCards = {
        sourceCard("wowhead", L["about.source_role.wowhead"], function()
            return ns.SourceUrls.wowheadGuide()
        end),
        sourceCard("icyveins", L["about.source_role.icyveins"], function()
            local class, spec = classSpec(); return ns.SourceUrls.icyVeinsGear(class, spec)
        end),
        sourceCard("archon", L["about.source_role.archon"], function()
            local class, spec = classSpec(); return ns.SourceUrls.archonOverview(class, spec) or ns.SOURCES.archon.homepage
        end),
        sourceCard("murlok", L["about.source_role.murlok"], function()
            local class, spec = classSpec(); return ns.SourceUrls.murlok(class, spec)
        end),
    }

    -- Separators are lazily created in LayoutPanel (matches the original
    -- inline-creation flow so re-renders are cheap).
    panel.separators = {}
end

local function MakeSeparator()
    local sep = panel.parent:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    return sep
end

local function GetSep(key)
    if not panel.separators[key] then
        panel.separators[key] = MakeSeparator()
    end
    return panel.separators[key]
end

-- y = top offset; opts.parent + opts.inset
function About.LayoutPanel(y, opts)
    local inset = opts.inset

    -- Fall back to /classcodex in the help hint if another addon grabbed /cc.
    if ns.FixSlash then panel.slashHint:SetText(ns.FixSlash(L["about.help_hint"])) end

    panel.title:Show()
    panel.title:ClearAllPoints()
    panel.title:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", inset, y)
    panel.title:SetPoint("RIGHT", opts.parent, "RIGHT", -inset, 0)
    y = y - ns.SECTION_HEADER_HEIGHT

    panel.content:Show()
    panel.content:ClearAllPoints()
    panel.content:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", inset, y)
    panel.content:SetPoint("RIGHT", opts.parent, "RIGHT", -inset, 0)
    local lastBottom = panel.lastChild and panel.lastChild:GetBottom()
    local contentTop = panel.content:GetTop()
    local contentH = (lastBottom and contentTop) and (contentTop - lastBottom) or 200
    panel.content:SetHeight(contentH)
    y = y - contentH - 8

    -- Optional leftover space to bottom-align the section block (the caller
    -- passes it on the second layout pass once panel height is known).
    y = y - (opts.gap or 0)

    local function placeSeparator(key)
        local sep = GetSep(key)
        y = y - 4
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", inset, y)
        sep:SetPoint("RIGHT", opts.parent, "RIGHT", -inset, 0)
        sep:Show()
        y = y - 7
    end

    -- Cards laid out two per row, split at the panel's horizontal midpoint.
    -- A lone trailing card (odd count) spans the full width.
    local CARD_GAP = 6
    local function placeCardGrid(cards)
        for i = 1, #cards, 2 do
            local left, right = cards[i], cards[i + 1]
            left:ClearAllPoints()
            left:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", inset, y)
            if right then
                left:SetPoint("TOPRIGHT", opts.parent, "TOP", -CARD_GAP / 2, y)
                right:ClearAllPoints()
                right:SetPoint("TOPLEFT", opts.parent, "TOP", CARD_GAP / 2, y)
                right:SetPoint("TOPRIGHT", opts.parent, "RIGHT", -inset, y)
                right:Show()
            else
                left:SetPoint("TOPRIGHT", opts.parent, "RIGHT", -inset, y)
            end
            left:Show()
            y = y - 38 - CARD_GAP
        end
    end

    local function placeSectionLabel(fs)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", inset, y)
        fs:Show()
        y = y - 18
    end

    placeSeparator("top")
    placeSectionLabel(panel.addonLabel)
    placeCardGrid(panel.addonCards)
    placeSeparator("data")
    placeSectionLabel(panel.dataLabel)
    placeCardGrid(panel.sourceCards)

    return y
end

function About.HidePanel()
    if not panel.title then return end
    panel.title:Hide()
    panel.content:Hide()
    panel.addonLabel:Hide()
    panel.dataLabel:Hide()
    for _, card in ipairs(panel.addonCards or {}) do card:Hide() end
    for _, card in ipairs(panel.sourceCards or {}) do card:Hide() end
    for _, sep in pairs(panel.separators or {}) do sep:Hide() end
end
