local _, ns = ...

-------------------------------------------------------------------------------
-- Data-source registry — single source of truth for every external provider
-- whose data the addon surfaces. Name, homepage and brand icon all live here;
-- dropdown labels, About-tab links and per-section attribution buttons read
-- from this table instead of redefining texture-escape strings inline.
-------------------------------------------------------------------------------

local TEX = "Interface\\AddOns\\ClassCodex\\Textures\\"

-- `color` is the brand accent (r, g, b 0-1) used by the About-tab source cards.
ns.SOURCES = {
    wowhead  = { key = "wowhead",  name = "Wowhead",   homepage = "https://www.wowhead.com",   iconTex = "wowhead",  color = { 0.97, 0.71, 0.13 } },
    icyveins = { key = "icyveins", name = "Icy Veins", homepage = "https://www.icy-veins.com", iconTex = "icyveins", color = { 0.30, 0.62, 0.90 } },
    archon   = { key = "archon",   name = "Archon",    homepage = "https://www.archon.gg/wow", iconTex = "archon",   color = { 0.55, 0.42, 0.95 } },
    murlok   = { key = "murlok",   name = "Murlok",    homepage = "https://murlok.io",         iconTex = "murlok",   color = { 0.20, 0.74, 0.69 } },
    bnet     = { key = "bnet",     name = "Blizzard",  homepage = "https://worldofwarcraft.blizzard.com", iconTex = "bnet", color = { 0.10, 0.58, 0.90 } },
}

-- Inline 12px brand icon (texture-escape string) for a source key.
function ns.SourceIcon(key, size, yoff)
    local src = ns.SOURCES[key]
    if not src then return "" end
    size = size or 12
    return "|T" .. TEX .. src.iconTex .. ":" .. size .. ":" .. size .. ":0:" .. (yoff or 0) .. "|t"
end

-- "<icon>  Name" label used by the source dropdowns.
function ns.SourceLabelText(key)
    local src = ns.SOURCES[key]
    if not src then return "" end
    return ns.SourceIcon(key) .. "  " .. src.name
end

-- The texture path consumed by Texture:SetTexture for a source key.
function ns.SourceTexturePath(key)
    local src = ns.SOURCES[key]
    return src and (TEX .. src.iconTex) or nil
end

-- "PvP" is never a real source. Resolve the actual provider by data type:
-- talents come from Blizzard's armory API (bnet); gear / enchants / gems /
-- stats / embellishments come from Murlok.
function ns.ResolvePvPSource(dataType)
    if dataType == "talents" then return "bnet" end
    return "murlok"
end

-------------------------------------------------------------------------------
-- Source attribution affordance — a footer source tag (see CreateSourceTag).
-------------------------------------------------------------------------------
-- Source tag: a right-aligned, click-to-copy label reading "Source:  <logo>
-- Name" (or just "<logo> Name" when opts.noPrefix) for whatever source feeds
-- the active view. The caller anchors it. Call :SetSource(key, url) per render;
-- a nil/unknown key hides it.
function ns.CreateSourceTag(parent, opts)
    opts = opts or {}
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(18)
    btn:RegisterForClicks("LeftButtonUp")

    -- Source logo as a real texture pinned to the right edge. Both the logo and
    -- the text anchor independently to the button (not to each other), so the
    -- +1 y-nudge lifts the logo onto the text's visual centre — the small font's
    -- unused descender space sits the bbox centre ~1px below the visual middle.
    local ICON = 11
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("RIGHT", btn, "RIGHT", 0, 1)
    btn.icon = icon

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("RIGHT", btn, "RIGHT", -(ICON + 3), 0)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(0.5, 0.5, 0.5)
    btn.text = fs
    btn:Hide()

    function btn:SetSource(key, url)
        local src = key and ns.SOURCES[key]
        if not src then
            self.url, self.srcName = nil, nil
            self:Hide()
            return
        end
        self.url = url
        self.srcName = src.name
        -- "[Check out] Name <logo>" — text, then the source logo at the end.
        self.icon:SetTexture(ns.SourceTexturePath(key))
        local cta = opts.noPrefix and "" or (ns.L["attribution.visit_cta"] .. " ")
        fs:SetText(cta .. src.name)
        self:SetWidth(fs:GetStringWidth() + 3 + self.icon:GetWidth() + 1)
        self:Show()
    end

    btn:SetScript("OnEnter", function(self)
        if not self.srcName then return end
        self.text:SetTextColor(0.9, 0.9, 0.9)
        -- Footer tags sit at the bottom of the panel — anchor the tooltip above
        -- them so it doesn't run off-screen. Others anchor to the left.
        if opts.tooltipAbove then
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("BOTTOMRIGHT", self, "TOPRIGHT", 0, 4)
        else
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        end
        -- Title invites the visit, the page URL shows the destination, then a
        -- blank line and a green actionable hint (the WoW instruction-line idiom).
        GameTooltip:SetText(ns.L["attribution.visit_source"]:format(self.srcName), 1, 0.82, 0)
        if self.url then GameTooltip:AddLine(self.url, 0.6, 0.6, 0.6, true) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(ns.L["attribution.copy_url"], 0.45, 0.75, 0.45)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self.text:SetTextColor(0.5, 0.5, 0.5)
        GameTooltip:Hide()
    end)
    btn:SetScript("OnClick", function(self)
        if self.url and ns.ShowCopyPopup then ns.ShowCopyPopup(self.url, self) end
    end)

    return btn
end

-------------------------------------------------------------------------------
-- Attribution resolution
--
-- Given a logical surface (the active tab / section) and the current class /
-- spec, return the source key + exact page URL to credit. Resolution reads the
-- same saved-vars and data accessors the sections themselves use, so it tracks
-- whatever the user currently has selected without reaching into render state.
-- Returns (key, url) or nil when there's nothing to attribute.
-------------------------------------------------------------------------------

local function perSpec(specKey)
    if specKey and ClassCodexCharDB and ClassCodexCharDB.perSpec then
        return ClassCodexCharDB.perSpec[specKey]
    end
    return nil
end

-- All attribution URLs live in one consolidated table, grouped by source then
-- page, generated per class (see scraper/generate-sources-lua.ts):
--   ClassCodexSources[classToken][specSlug] = {
--     wowhead = { guide, bis }, icyveins = { bis, talents, leveling },
--     archon = { build }, murlok = { pvp } }
-- The helpers below just read from it.

-- Player's class token + spec slug, for the no-arg helpers (docked pane / About
-- tab), which always credit the active spec.
local function playerClassSpec()
    local classToken = select(2, UnitClass("player"))
    local specKey = ns.GetSpecKey and ns.GetSpecKey()
    local spec = specKey and (specKey:match("-(.+)") or specKey) or nil
    return classToken, spec
end

local function srcUrl(class, spec, source, page)
    if not (class and spec) then class, spec = playerClassSpec() end
    local s = _G.ClassCodexSources
    local rec = class and spec and s and s[class] and s[class][spec]
    local pages = rec and rec[source]
    return pages and pages[page] or nil
end

local function wowheadGuideUrl(class, spec)
    return srcUrl(class, spec, "wowhead", "guide") or ns.SOURCES.wowhead.homepage
end

local function wowheadBisUrl(class, spec)
    return srcUrl(class, spec, "wowhead", "bis") or wowheadGuideUrl(class, spec)
end

local function icyVeinsGearUrl(class, spec)
    return srcUrl(class, spec, "icyveins", "bis") or ns.SOURCES.icyveins.homepage
end

-- Icy Veins talents page; pass leveling=true for the leveling-guide URL.
local function icyVeinsTalentsUrl(class, spec, leveling)
    if leveling then
        return srcUrl(class, spec, "icyveins", "leveling")
            or srcUrl(class, spec, "icyveins", "talents")
            or ns.SOURCES.icyveins.homepage
    end
    return srcUrl(class, spec, "icyveins", "talents") or ns.SOURCES.icyveins.homepage
end

local function archonOverviewUrl(class, spec)
    return srcUrl(class, spec, "archon", "build")
end

local function murlokUrl(class, spec)
    return srcUrl(class, spec, "murlok", "pvp") or ns.SOURCES.murlok.homepage
end

-- URL helpers exposed for surfaces that resolve their own selection state
-- (e.g. the Compendium, the talent dropdown). Each falls back to the source
-- homepage when the exact page is unavailable.
ns.SourceUrls = {
    wowheadGuide   = wowheadGuideUrl,
    wowheadBis     = wowheadBisUrl,
    icyVeinsGear   = icyVeinsGearUrl,
    icyVeinsTalents = icyVeinsTalentsUrl,
    archonOverview = archonOverviewUrl,
    murlok         = murlokUrl,
}

-- BiS page URL for a resolved gear-source key. Shared by the docked Gear
-- panel and the Compendium so the per-source link logic lives in one place.
function ns.BisUrlForKey(key, class, spec)
    if key == "icyveins" then return icyVeinsGearUrl(class, spec) end
    if key == "archon" then return archonOverviewUrl(class, spec) or ns.SOURCES.archon.homepage end
    if key == "murlok" then return murlokUrl(class, spec) end
    return wowheadBisUrl(class, spec)
end

-- Map the Gear/Enhancements dropdown string ("Wowhead"/"Icy Veins"/"Archon"/
-- "PvP") to a registry key + URL for the given data type.
local function fromDropdown(picked, dataType, class, spec)
    if picked == "Icy Veins" then return "icyveins", icyVeinsGearUrl(class, spec) end
    if picked == "Archon" then return "archon", archonOverviewUrl(class, spec) or ns.SOURCES.archon.homepage end
    if picked == "PvP" then
        local key = ns.ResolvePvPSource(dataType)
        if key == "murlok" then return "murlok", murlokUrl(class, spec) end
        return "bnet", ns.SOURCES.bnet.homepage
    end
    return "wowhead", (dataType == "bis") and wowheadBisUrl(class, spec) or wowheadGuideUrl(class, spec)
end

-- surface: the active tab. class: class token ("MAGE"). specKey: the per-spec
-- saved-var key ("MAGE-frost"); the data-lookup slug ("frost") is derived from
-- it. Returns (key, url) or nil.
function ns.ResolveAttribution(surface, class, specKey)
    local ps = perSpec(specKey)
    local spec = specKey and (specKey:match("-(.+)") or specKey) or nil

    if surface == "guide" or surface == "trinkets" then
        return "wowhead", wowheadGuideUrl(class, spec)

    elseif surface == "talents" then
        -- Tracks the docked Talents tab's source dropdown. PvP talents come
        -- from Blizzard's armory; the rest from their respective guides.
        local ts = ns.GetEffectiveTalentSource and ns.GetEffectiveTalentSource() or "wowhead"
        if ts == "archon" then return "archon", archonOverviewUrl(class, spec) or ns.SOURCES.archon.homepage end
        if ts == "icyveins" then return "icyveins", icyVeinsTalentsUrl(class, spec) end
        if ts == "pvp" then return "bnet", ns.SOURCES.bnet.homepage end
        return "wowhead", wowheadGuideUrl(class, spec)

    elseif surface == "bis" then
        local picked = (ps and ps.bisSource) or "Wowhead"
        return fromDropdown(picked, "bis", class, spec)

    elseif surface == "enhancements" then
        local key = ns.Sections and ns.Sections.Enhancements
            and ns.Sections.Enhancements.GetActiveSourceKey
            and ns.Sections.Enhancements.GetActiveSourceKey()
        if key == "murlok" then return "murlok", murlokUrl(class, spec) end
        return "wowhead", wowheadGuideUrl(class, spec)

    elseif surface == "crafting" then
        local ctx = ps and ps.craftingContext
        if ctx == "pvp" then return "murlok", murlokUrl(class, spec) end
        return "archon", archonOverviewUrl(class, spec) or ns.SOURCES.archon.homepage

    elseif surface == "stats" then
        -- Stat targets come from Archon (Mythic+/Raid) or Murlok (PvP context).
        local ctx = ns.Sections and ns.Sections.StatTargets
            and ns.Sections.StatTargets.GetActiveContext
            and ns.Sections.StatTargets.GetActiveContext()
        if ctx == "PvP" then return "murlok", murlokUrl(class, spec) end
        return "archon", archonOverviewUrl(class, spec) or ns.SOURCES.archon.homepage
    end

    return nil
end
