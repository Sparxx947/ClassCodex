local _, ns = ...

-------------------------------------------------------------------------------
-- CollapsibleSection — the addon-wide collapsible section pattern.
--
-- Two layers:
--
--   ns.CreateSectionHeader(parent, label[, collapsible])
--     Just the header chrome: Button + BackdropTemplate background +
--     hover highlight + right-aligned +/− arrow. Returns the button
--     with `.label`, `.bg`, `.arrow` exposed. Used directly when the
--     caller wants full control over the section's frame layout
--     (e.g. Compendium tabs).
--
--   ns.SetCollapsed(content, header, collapsed)
--     Toggle helper. Hides/shows the content frame and swaps the
--     arrow texture between + and −.
--
--   ns.CreateCollapsibleSection(parent, opts) → section, header, content
--     The common pattern Enhancements duplicated three times: a
--     section frame containing a header + content frame, with state
--     persisted in ClassCodexCharDB.collapsed[stateKey] and a click
--     handler that toggles and re-renders. Use this when you'd
--     otherwise be writing the same 10 lines of plumbing.
--
-- These used to live inside ClassCodex.lua; extracted here so any
-- Section or surface can build a collapsible block without reaching
-- into the main file.
-------------------------------------------------------------------------------

function ns.CreateSectionHeader(parent, labelText, collapsible)
    if collapsible == nil then collapsible = true end
    local headerHeight = ns.SECTION_HEADER_HEIGHT or 24

    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(headerHeight)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:RegisterForClicks("LeftButtonUp")
    header:EnableMouse(true)

    local bg = CreateFrame("Frame", nil, header, "BackdropTemplate")
    bg:SetAllPoints()
    bg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bg:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
    header.bg = bg

    local text = bg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", 8, 0)
    text:SetText(labelText)
    text:SetTextColor(1, 0.82, 0)
    header.label = text
    header.text = text -- back-compat alias

    if collapsible then
        local arrow = bg:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(12, 12)
        arrow:SetPoint("RIGHT", -6, 0)
        arrow:SetTexture("Interface\\Buttons\\UI-MinusButton-Up")
        header.arrow = arrow

        header:SetScript("OnEnter", function(self)
            self.bg:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
            self.bg:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
        end)
        header:SetScript("OnLeave", function(self)
            self.bg:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            self.bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
        end)
    end

    return header
end

function ns.SetCollapsed(content, header, collapsed)
    if collapsed then
        content:Hide()
        if header.arrow then header.arrow:SetTexture("Interface\\Buttons\\UI-PlusButton-Up") end
    else
        content:Show()
        if header.arrow then header.arrow:SetTexture("Interface\\Buttons\\UI-MinusButton-Up") end
    end
end

-- ns.CreateCollapsibleSection(parent, opts) → section, header, content
--
-- opts:
--   label     (string)   header text
--   stateKey  (string)   path in ClassCodexCharDB.collapsed, dot-
--                        separated. e.g. "crafting.crafts" persists at
--                        ClassCodexCharDB.collapsed.crafting.crafts
--   refresh   (function) optional callback fired after toggle (used by
--                        consumers that need to re-layout when a
--                        section's content visibility changes)
--   collapsible (bool)   default true; pass false for a non-collapsible
--                        section (still uses the same chrome for visual
--                        consistency)
--
-- Returns the section frame (sized to the header initially — caller
-- grows it after laying out content), the header button, and the
-- content frame anchored below the header.
local function GetNested(t, parts)
    for i = 1, #parts do
        if not t then return nil end
        t = t[parts[i]]
    end
    return t
end

local function SetNested(t, parts, value)
    for i = 1, #parts - 1 do
        t[parts[i]] = t[parts[i]] or {}
        t = t[parts[i]]
    end
    t[parts[#parts]] = value
end

local function splitStateKey(key)
    local parts = {}
    for segment in tostring(key):gmatch("[^.]+") do parts[#parts + 1] = segment end
    return parts
end

function ns.CreateCollapsibleSection(parent, opts)
    opts = opts or {}
    local section = CreateFrame("Frame", nil, parent)
    section:SetHeight(ns.SECTION_HEADER_HEIGHT or 24)
    local header = ns.CreateSectionHeader(section, opts.label, opts.collapsible)
    local content = CreateFrame("Frame", nil, section)
    content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    content:SetPoint("RIGHT", 0, 0)

    local keyParts = opts.stateKey and splitStateKey(opts.stateKey) or nil

    local function readCollapsed()
        if not keyParts or not ClassCodexCharDB or not ClassCodexCharDB.collapsed then
            return false
        end
        return GetNested(ClassCodexCharDB.collapsed, keyParts) == true
    end

    local function writeCollapsed(value)
        if not keyParts or not ClassCodexCharDB then return end
        ClassCodexCharDB.collapsed = ClassCodexCharDB.collapsed or {}
        -- Store nil for the default (expanded) so the table doesn't bloat.
        SetNested(ClassCodexCharDB.collapsed, keyParts, value and true or nil)
    end

    ns.SetCollapsed(content, header, readCollapsed())

    if opts.collapsible ~= false then
        header:SetScript("OnClick", function()
            local nowCollapsed = not readCollapsed()
            writeCollapsed(nowCollapsed)
            ns.SetCollapsed(content, header, nowCollapsed)
            if opts.refresh then opts.refresh() end
        end)
    end

    section.header = header
    section.content = content
    section.IsCollapsed = readCollapsed
    return section, header, content
end
