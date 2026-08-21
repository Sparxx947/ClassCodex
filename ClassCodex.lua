local addonName, ns = ...

-- Saved variables (initialized in ADDON_LOADED)
-- ClassCodexDB: account-wide settings
-- ClassCodexCharDB: per-character state

local DATA = ClassCodexData
if not DATA then return end

local L = ns.L

-- When another addon has claimed /cc (detected at PLAYER_ENTERING_WORLD), fall
-- back to the always-unique /classcodex everywhere we tell the user to type /cc.
ns.ccContested = false
function ns.FixSlash(s)
    if ns.ccContested and type(s) == "string" then
        return (s:gsub("/cc", "/classcodex"))
    end
    return s
end

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local PANEL_WIDTH = 312
local PANEL_PADDING = 12
local CONTENT_INSET = 8 -- less than PANEL_PADDING to compensate for dropdown/section internal offsets
local BUTTON_SIZE = 36
local WIDGET_DEFAULT_OFFSET_X = -1
local WIDGET_DEFAULT_OFFSET_Y = -148
local WIDGET_OFFSET_MIN = -500
local WIDGET_OFFSET_MAX = 500
local FADE_DURATION = 0.15
local ROW_HEIGHT = 22
local SECTION_HEADER_HEIGHT = 24
local DROPDOWN_HEIGHT = 26
local SUBHEADER_HEIGHT = 30

local RANK_COLORS = {
    { r = 0.64, g = 0.21, b = 0.93 }, -- #1 epic purple
    { r = 0.00, g = 0.44, b = 0.87 }, -- #2 rare blue
    { r = 0.12, g = 1.00, b = 0.00 }, -- #3 uncommon green
    { r = 1.00, g = 1.00, b = 1.00 }, -- #4 common white
    { r = 0.62, g = 0.62, b = 0.62 }, -- #5 poor gray
}

local HERO_TALENT_ATLAS = {
    -- Death Knight
    ["San'layn"]                  = "talents-heroclass-deathknight-sanlayn",
    ["Rider of the Apocalypse"]   = "talents-heroclass-deathknight-rideroftheapocalypse",
    ["Deathbringer"]              = "talents-heroclass-deathknight-deathbringer",
    -- Demon Hunter
    ["Fel-Scarred"]               = "talents-heroclass-demonhunter-felscarred",
    ["Aldrachi Reaver"]           = "talents-heroclass-demonhunter-aldrachireaver",
    ["Annihilator"]               = "talents-heroclass-demonhunter-annihilator",
    ["Void-Scarred"]              = "talents-heroclass-demonhunter-felscarred2",
    -- Druid
    ["Druid of the Claw"]         = "talents-heroclass-druid-druidoftheclaw",
    ["Wildstalker"]               = "talents-heroclass-druid-wildstalker",
    ["Keeper of the Grove"]       = "talents-heroclass-druid-keeperofthegrove",
    ["Elune's Chosen"]            = "talents-heroclass-druid-eluneschosen",
    -- Evoker
    ["Scalecommander"]            = "talents-heroclass-evoker-scalecommander",
    ["Flameshaper"]               = "talents-heroclass-evoker-flameshaper",
    ["Chronowarden"]              = "talents-heroclass-evoker-chronowarden",
    -- Hunter
    ["Sentinel"]                  = "talents-heroclass-hunter-sentinel",
    ["Pack Leader"]               = "talents-heroclass-hunter-packleader",
    ["Dark Ranger"]               = "talents-heroclass-hunter-darkranger",
    -- Mage
    ["Sunfury"]                   = "talents-heroclass-mage-sunfury",
    ["Spellslinger"]              = "talents-heroclass-mage-spellslinger",
    ["Frostfire"]                 = "talents-heroclass-mage-frostfire",
    -- Monk
    ["Conduit of the Celestials"] = "talents-heroclass-monk-conduitofthecelestials",
    ["Shado-Pan"]                 = "talents-heroclass-monk-shadopan",
    ["Shado-pan"]                 = "talents-heroclass-monk-shadopan",
    ["Master of Harmony"]         = "talents-heroclass-monk-masterofharmony",
    -- Paladin
    ["Templar"]                   = "talents-heroclass-paladin-templar",
    ["Lightsmith"]                = "talents-heroclass-paladin-lightsmith",
    ["Herald of the Sun"]         = "talents-heroclass-paladin-heraldofthesun",
    -- Priest
    ["Voidweaver"]                = "talents-heroclass-priest-voidweaver",
    ["Archon"]                    = "talents-heroclass-priest-archon",
    ["Oracle"]                    = "talents-heroclass-priest-oracle",
    -- Rogue
    ["Trickster"]                 = "talents-heroclass-rogue-trickster",
    ["Fatebound"]                 = "talents-heroclass-rogue-fatebound",
    ["Deathstalker"]              = "talents-heroclass-rogue-deathstalker",
    -- Shaman
    ["Totemic"]                   = "talents-heroclass-shaman-totemic",
    ["Stormbringer"]              = "talents-heroclass-shaman-stormbringer",
    ["Farseer"]                   = "talents-heroclass-shaman-farseer",
    -- Warlock
    ["Soul Harvester"]            = "talents-heroclass-warlock-soulharvester",
    ["Hellcaller"]                = "talents-heroclass-warlock-hellcaller",
    ["Diabolist"]                 = "talents-heroclass-warlock-diabolist",
    -- Warrior
    ["Slayer"]                    = "talents-heroclass-warrior-slayer",
    ["Mountain Thane"]            = "talents-heroclass-warrior-mountainthane",
    ["Colossus"]                  = "talents-heroclass-warrior-colossus",
}

-- Reverse map: atlas texture → English hero talent name (locale-independent).
-- Used by GetActiveHeroTalentName() to convert the API's iconAtlas into the
-- English key that matches data.lua entries and HERO_TALENT_ATLAS lookups.
local ATLAS_TO_HERO = {}
for name, atlas in pairs(HERO_TALENT_ATLAS) do
    ATLAS_TO_HERO[atlas] = ATLAS_TO_HERO[atlas] or name
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local isFloating = false
local isMinimized = false

-- Registered dock hosts (frames the docked panel can anchor to). External UI
-- suites (e.g. GW2_UI) populate this via ns.RegisterDockHost; built-in entries
-- for PaperDollFrame and CharacterFrame are added during panel setup.
local dockHosts = {}

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

-- Locale-independent spec key lookup: maps (classToken, specIndex) → data key.
-- specIndex from GetSpecialization() is a number (1-4) and never localized.
local SPEC_KEYS = {
    DEATHKNIGHT  = { "blood", "frost", "unholy" },
    DEMONHUNTER  = { "havoc", "vengeance", "devourer" },
    DRUID        = { "balance", "feral", "guardian", "restoration" },
    EVOKER       = { "devastation", "preservation", "augmentation" },
    HUNTER       = { "beast-mastery", "marksmanship", "survival" },
    MAGE         = { "arcane", "fire", "frost" },
    MONK         = { "brewmaster", "mistweaver", "windwalker" },
    PALADIN      = { "holy", "protection", "retribution" },
    PRIEST       = { "discipline", "holy", "shadow" },
    ROGUE        = { "assassination", "outlaw", "subtlety" },
    SHAMAN       = { "elemental", "enhancement", "restoration" },
    WARLOCK      = { "affliction", "demonology", "destruction" },
    WARRIOR      = { "arms", "fury", "protection" },
}

local function GetClassAndSpec()
    local _, classToken = UnitClass("player")
    local specIndex = GetSpecialization()
    if not specIndex then return classToken, nil end
    local keys = SPEC_KEYS[classToken]
    if not keys or not keys[specIndex] then return classToken, nil end
    return classToken, keys[specIndex]
end

local function GetSpecData()
    local classToken, specKey = GetClassAndSpec()
    if not classToken or not specKey then return nil end
    local classData = DATA[classToken]
    if not classData then return nil end
    return classData[specKey], classToken, specKey
end

local function GetSpecKey()
    local classToken, specKey = GetClassAndSpec()
    if classToken and specKey then return classToken .. "-" .. specKey end
    return nil
end

local function GetActiveHeroTalentName()
    if not C_ClassTalents or not C_ClassTalents.GetActiveHeroTalentSpec then return nil end
    local subTreeID = C_ClassTalents.GetActiveHeroTalentSpec()
    if not subTreeID or subTreeID == 0 then return nil end
    -- C_Traits.GetSubTreeInfo may need configID in some builds; wrap in pcall
    if C_Traits and C_Traits.GetSubTreeInfo then
        local ok, info = pcall(C_Traits.GetSubTreeInfo, subTreeID)
        if not ok and C_ClassTalents.GetActiveConfigID then
            -- Try with configID if single-arg failed
            local configID = C_ClassTalents.GetActiveConfigID()
            if configID then
                ok, info = pcall(C_Traits.GetSubTreeInfo, configID, subTreeID)
            end
        end
        if ok and info then
            -- Prefer locale-independent atlas reverse lookup over localized name
            if info.iconAtlas and ATLAS_TO_HERO[info.iconAtlas] then
                return ATLAS_TO_HERO[info.iconAtlas]
            end
            if info.name then return info.name end
        end
    end
    return nil
end

local function GetSpecIcon()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    local _, _, _, icon = GetSpecializationInfo(specIndex)
    return icon
end

local function FadeIn(frame)
    if frame.fadeAnim then frame.fadeAnim:Stop() end
    frame:SetAlpha(0)
    frame:Show()
    if not frame.fadeAnim then
        local ag = frame:CreateAnimationGroup()
        local fade = ag:CreateAnimation("Alpha")
        fade:SetFromAlpha(0)
        fade:SetToAlpha(1)
        fade:SetDuration(FADE_DURATION)
        ag:SetScript("OnFinished", function() frame:SetAlpha(1) end)
        frame.fadeAnim = ag
    end
    frame.fadeAnim:Play()
end

-- Panel width is a numeric setting (px), tuned via a slider in the
-- main Settings panel. The 260..500 bounds match the slider — values
-- outside that range get clamped back to PANEL_WIDTH so a manually-
-- edited SavedVar can't ship a layout-breaking width.
local PANEL_WIDTH_MIN = 260
local PANEL_WIDTH_MAX = 500

local function GetPanelWidth()
    local w = ClassCodexDB and ClassCodexDB.panelWidth
    if type(w) ~= "number" or w < PANEL_WIDTH_MIN or w > PANEL_WIDTH_MAX then
        return PANEL_WIDTH
    end
    return w
end

local function GetHeroTalentOptions(specData)
    local seen, options = {}, {}
    local function add(name)
        if name and name ~= "All" and not seen[name] then
            seen[name] = true
            options[#options + 1] = name
        end
    end
    -- Only use priorities — the cleanest source of canonical hero talent names
    if specData.priorities then for _, p in ipairs(specData.priorities) do add(p.heroTalent) end end
    return options
end

local function GetContextOptions(specData, heroTalent)
    local seen, options = {}, {}
    local function add(ctx)
        if ctx and not seen[ctx] then seen[ctx] = true; options[#options + 1] = ctx end
    end
    local function matchesHero(h)
        return h == heroTalent or h == "All" or heroTalent == "All"
    end
    -- Use talent contexts as the primary context source (Raid ST, Mythic+, Delves)
    if specData.talents then
        for _, t in ipairs(specData.talents) do if matchesHero(t.heroTalent) then add(t.context) end end
    end
    -- Fallback: priority contexts
    if #options == 0 and specData.priorities then
        for _, p in ipairs(specData.priorities) do if matchesHero(p.heroTalent) then add(p.context) end end
    end
    return options
end

local function HeroMatches(entryHero, heroTalent)
    if entryHero == heroTalent then return true end
    -- Prefix match: "Templar" matches "Templar ES", "Templar RG", etc.
    if heroTalent and entryHero:sub(1, #heroTalent) == heroTalent
        and entryHero:sub(#heroTalent + 1, #heroTalent + 1) == " " then
        return true
    end
    -- Reverse: heroTalent is longer (e.g. "Templar ES" matches entry "Templar")
    if entryHero and heroTalent:sub(1, #entryHero) == entryHero
        and heroTalent:sub(#entryHero + 1, #entryHero + 1) == " " then
        return true
    end
    return false
end

-- Get unique rotation contexts for a given hero talent (preserves data order)
local function GetRotationContextOptions(specData, heroTalent)
    if not specData.rotation then return {} end
    local seen, options = {}, {}
    local function add(ctx)
        if ctx and not seen[ctx] then seen[ctx] = true; options[#options + 1] = ctx end
    end
    for _, r in ipairs(specData.rotation) do
        if r.heroTalent == heroTalent or r.heroTalent == "All" or HeroMatches(r.heroTalent, heroTalent) then
            add(r.context)
        end
    end
    -- If no matches for this hero, fall back to all available contexts
    if #options == 0 then
        for _, r in ipairs(specData.rotation) do add(r.context) end
    end
    return options
end

-- Find a rotation entry matching hero + rotation context
local function FindRotationByContext(rotations, heroTalent, rotContext)
    if not rotations then return nil end
    -- Exact hero + context
    for _, r in ipairs(rotations) do
        if r.heroTalent == heroTalent and r.context == rotContext then return r end
    end
    -- Prefix hero + context
    for _, r in ipairs(rotations) do
        if HeroMatches(r.heroTalent, heroTalent) and r.context == rotContext then return r end
    end
    -- "All" hero + context
    for _, r in ipairs(rotations) do
        if r.heroTalent == "All" and r.context == rotContext then return r end
    end
    -- Last resort: first entry matching context
    for _, r in ipairs(rotations) do
        if r.context == rotContext then return r end
    end
    return nil
end

-- Get talent builds matching hero + context, returns list of {build, label}
local function GetTalentBuilds(specData, heroTalent, context)
    if not specData.talents then return {} end
    local builds = {}
    -- 1. Exact hero + context
    for _, t in ipairs(specData.talents) do
        if (t.heroTalent == heroTalent or t.heroTalent == "All") and t.context == context then
            builds[#builds + 1] = t
        end
    end
    -- 2. Exact hero, any context
    if #builds == 0 then
        for _, t in ipairs(specData.talents) do
            if t.heroTalent == heroTalent or t.heroTalent == "All" then
                builds[#builds + 1] = t
            end
        end
    end
    return builds
end

-- Get all talent builds for a hero (regardless of context), for the rows display
local function GetAllTalentBuildsForHero(specData, heroTalent)
    if not specData.talents then return {} end
    local builds = {}
    for _, t in ipairs(specData.talents) do
        if t.heroTalent == heroTalent or t.heroTalent == "All" or HeroMatches(t.heroTalent, heroTalent) then
            builds[#builds + 1] = t
        end
    end
    return builds
end

-- Check if stat priorities differ across contexts for a given hero
local function GetStatContextOptions(specData, heroTalent)
    if not specData.priorities then return {} end
    local seen, options = {}, {}
    local statsPerContext = {}
    for _, p in ipairs(specData.priorities) do
        if p.heroTalent == heroTalent or p.heroTalent == "All" or HeroMatches(p.heroTalent, heroTalent) then
            if not seen[p.context] then
                seen[p.context] = true
                options[#options + 1] = p.context
                -- Serialize stats for comparison
                local key = ""
                for _, tier in ipairs(p.stats) do
                    key = key .. table.concat(tier, "=") .. ">"
                end
                statsPerContext[p.context] = key
            end
        end
    end
    -- Only return options if stats actually differ across contexts
    if #options <= 1 then return {} end
    local firstStats = statsPerContext[options[1]]
    for i = 2, #options do
        if statsPerContext[options[i]] ~= firstStats then
            return options -- stats differ, show dropdown
        end
    end
    return {} -- all same, no dropdown needed
end

local function GetPerSpecState()
    local specKey = GetSpecKey()
    if not specKey or not ClassCodexCharDB then return nil end
    if not ClassCodexCharDB.perSpec then ClassCodexCharDB.perSpec = {} end
    if not ClassCodexCharDB.perSpec[specKey] then
        ClassCodexCharDB.perSpec[specKey] = { heroTalent = nil, statContext = nil, rotationContext = nil, trinketContext = nil, bisTab = nil }
    end
    return ClassCodexCharDB.perSpec[specKey]
end

local function FormatRotationStep(stepText)
    return stepText:gsub("{(%d+)}", function(id)
        local spellId = tonumber(id)
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellId)
        if info and info.name then return info.name end
        return "Unknown Spell"
    end)
end

-- Evaluate a compound boolean expression over spell IDs and hero-tree labels:
--   number       → IsPlayerSpell(n)
--   H"label"     → currentHeroTalent == label
--   !x           → not x
--   x & y        → both
--   x | y        → either
--   ( ... )      → grouping
-- `&` binds tighter than `|`. Whitespace tolerated. Returns false on any
-- parse failure (safer than throwing — the step just hides).
local function EvalConditionExpr(expr, currentHeroTalent)
    local pos, len = 1, #expr
    local function peek()
        if pos > len then return nil end
        return expr:sub(pos, pos)
    end
    local function eatWs()
        while pos <= len and expr:sub(pos, pos) == " " do pos = pos + 1 end
    end
    local parseOr
    local function parseUnary()
        eatWs()
        local c = peek()
        if c == "!" then
            pos = pos + 1
            return not parseUnary()
        elseif c == "(" then
            pos = pos + 1
            local v = parseOr()
            eatWs()
            if peek() == ")" then pos = pos + 1 end
            return v
        elseif c == "H" and expr:sub(pos + 1, pos + 1) == '"' then
            -- Hero-tree literal: H"<label>". Both sides are normalized to
            -- English (currentHeroTalent via ATLAS_TO_HERO reverse-lookup
            -- in GetActiveHeroTalentName; the label here from Wowhead's
            -- English BBCode), but the addon already case-insensitive-
            -- matches hero options elsewhere (see line ~2714) so we mirror
            -- that here to absorb Wowhead casing drift like Shado-Pan vs
            -- Shado-pan.
            local closing = expr:find('"', pos + 2, true)
            if not closing then return false end
            local label = expr:sub(pos + 2, closing - 1)
            pos = closing + 1
            if not currentHeroTalent then return false end
            return currentHeroTalent:lower() == label:lower()
        else
            local s, e = expr:find("^(%d+)", pos)
            if not s then return false end
            pos = e + 1
            return IsPlayerSpell(tonumber(expr:sub(s, e))) and true or false
        end
    end
    local function parseAnd()
        local v = parseUnary()
        eatWs()
        while peek() == "&" do
            pos = pos + 1
            v = parseUnary() and v
            eatWs()
        end
        return v
    end
    parseOr = function()
        local v = parseAnd()
        eatWs()
        while peek() == "|" do
            pos = pos + 1
            v = parseAnd() or v
            eatWs()
        end
        return v
    end
    return parseOr() and true or false
end

local function ShouldShowStep(stepText, currentHeroTalent)
    local reqId = stepText:match("^%?{(%d+)}:")
    if reqId then return IsPlayerSpell(tonumber(reqId)) end
    local negId = stepText:match("^%?!{(%d+)}:")
    if negId then return not IsPlayerSpell(tonumber(negId)) end
    -- %b() balances nested parens correctly; lazy `.-` would stop at the
    -- first ')' inside an expression like ?((1&2)|3):.
    local exprParen = stepText:match("^%?(%b()):")
    if exprParen then return EvalConditionExpr(exprParen:sub(2, -2), currentHeroTalent) end
    return true
end

local function StripConditionPrefix(stepText)
    stepText = stepText:gsub("^%?!?{%d+}:%s*", "")
    stepText = stepText:gsub("^%?%b():%s*", "")
    return stepText
end

local function GetStepSpellIcon(stepText)
    local stripped = StripConditionPrefix(stepText)
    local spellId = stripped:match("{(%d+)}")
    if spellId then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(spellId))
        if info and info.iconID then return info.iconID end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function FindMatch(entries, heroTalent, context)
    if not entries then return nil end
    -- Exact hero + context
    for _, e in ipairs(entries) do
        if e.heroTalent == heroTalent and e.context == context then return e end
    end
    -- Exact hero, any context
    for _, e in ipairs(entries) do
        if e.heroTalent == heroTalent then return e end
    end
    -- Prefix hero + context
    for _, e in ipairs(entries) do
        if HeroMatches(e.heroTalent, heroTalent) and e.context == context then return e end
    end
    -- Prefix hero, any context
    for _, e in ipairs(entries) do
        if HeroMatches(e.heroTalent, heroTalent) then return e end
    end
    -- "All" + context
    for _, e in ipairs(entries) do
        if e.heroTalent == "All" and e.context == context then return e end
    end
    -- "All", any context
    for _, e in ipairs(entries) do
        if e.heroTalent == "All" then return e end
    end
    return entries[1]
end

local function FindOpener(rotations, heroTalent)
    if not rotations then return nil end
    -- Exact hero match first
    for _, r in ipairs(rotations) do
        if r.context:lower():find("opener") and r.heroTalent == heroTalent then
            return r
        end
    end
    -- Prefix hero match
    for _, r in ipairs(rotations) do
        if r.context:lower():find("opener") and HeroMatches(r.heroTalent, heroTalent) then
            return r
        end
    end
    -- Fallback to "All"
    for _, r in ipairs(rotations) do
        if r.context:lower():find("opener") and r.heroTalent == "All" then
            return r
        end
    end
    -- Last resort: first opener entry
    for _, r in ipairs(rotations) do
        if r.context:lower():find("opener") then
            return r
        end
    end
    return nil
end

local function FindRotation(rotations, heroTalent, context)
    if not rotations then return nil end
    -- Exact hero + context match
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener")
            and r.heroTalent == heroTalent and r.context == context then
            return r
        end
    end
    -- Exact hero, any context
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener") and r.heroTalent == heroTalent then
            return r
        end
    end
    -- Prefix hero + context match
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener")
            and HeroMatches(r.heroTalent, heroTalent) and r.context == context then
            return r
        end
    end
    -- Prefix hero, any context
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener") and HeroMatches(r.heroTalent, heroTalent) then
            return r
        end
    end
    -- "All" + context match
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener")
            and r.heroTalent == "All" and r.context == context then
            return r
        end
    end
    -- "All", any context
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener") and r.heroTalent == "All" then
            return r
        end
    end
    -- Last resort: first non-opener entry (e.g., priorities use "All" but rotation has specific heroes)
    for _, r in ipairs(rotations) do
        if not r.context:lower():find("opener") then
            return r
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Panel Frame
-------------------------------------------------------------------------------

local panel = CreateFrame("Frame", "ClassCodexPanel", UIParent, "BackdropTemplate")
panel:SetSize(PANEL_WIDTH, 1)
panel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
panel:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
panel:SetFrameStrata("HIGH")
panel:SetClampedToScreen(true)
panel:EnableMouse(true)
panel:Hide()

-------------------------------------------------------------------------------
-- Title Bar
-------------------------------------------------------------------------------

local titleBar = CreateFrame("Frame", nil, panel)
titleBar:SetHeight(24)
titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -6)
titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -6)

local ADDON_ICON_PATH = "Interface\\AddOns\\ClassCodex\\icon"

local specIcon = titleBar:CreateTexture(nil, "ARTWORK")
specIcon:SetSize(18, 18)
specIcon:SetPoint("LEFT", titleBar, "LEFT", PANEL_PADDING, 0)

local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
titleText:SetPoint("LEFT", specIcon, "RIGHT", 6, 0)
local addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version") or ""
titleText:SetText("Class Codex")
titleText:SetTextColor(1, 0.82, 0)
titleText:SetWordWrap(false)
titleText:SetNonSpaceWrap(false)
titleText:SetMaxLines(1)

local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButtonNoScripts")
closeBtn:SetSize(20, 20)
closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -PANEL_PADDING + 2, 0)
closeBtn:RegisterForClicks("LeftButtonUp")
closeBtn:SetScript("OnClick", function()
    panel:Hide()
    if ClassCodexCharDB then ClassCodexCharDB.panelOpen = false end
end)
closeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(CLOSE, 1, 0.82, 0) -- Blizzard global, already localized
    GameTooltip:AddLine(ns.FixSlash(L["title_bar.close_hint"]), 0.45, 0.75, 0.45)
    GameTooltip:Show()
end)
closeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Title-bar buttons, right to left: close, Compendium (Class Codex logo), gear,
-- minimize (floating only). So the docked reading order is gear / Compendium /
-- close, with even 6px gaps between the icons.
local compendiumBtn = CreateFrame("Button", nil, titleBar)
compendiumBtn:SetSize(17, 17)
compendiumBtn:SetPoint("RIGHT", closeBtn, "LEFT", -3, 0)
compendiumBtn:RegisterForClicks("LeftButtonUp")
compendiumBtn:SetNormalTexture(ADDON_ICON_PATH)
compendiumBtn:SetHighlightTexture(ADDON_ICON_PATH)
compendiumBtn:GetHighlightTexture():SetAlpha(0.3)
compendiumBtn:SetScript("OnClick", function()
    if ns.OpenCompendium then ns:OpenCompendium() end
end)
compendiumBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Compendium", 1, 0.82, 0)
    GameTooltip:AddLine(L["title_bar.compendium_hint"], 0.45, 0.75, 0.45)
    GameTooltip:Show()
end)
compendiumBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pinBtn = CreateFrame("Button", nil, titleBar)
pinBtn:SetSize(14, 14)
pinBtn:SetPoint("RIGHT", compendiumBtn, "LEFT", -3, 0)
pinBtn:SetNormalTexture("Interface\\AddOns\\ClassCodex\\Textures\\gear")
pinBtn:SetHighlightTexture("Interface\\AddOns\\ClassCodex\\Textures\\gear")
pinBtn:GetHighlightTexture():SetAlpha(0.3)
local pinBtnTex = pinBtn:GetNormalTexture()
pinBtnTex:SetVertexColor(0.7, 0.7, 0.7, 0.9) -- idle, matches the Crafting tab cog
pinBtn:SetScript("OnEnter", function(self)
    pinBtnTex:SetVertexColor(1, 1, 1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- Same shape as the Compendium / close tooltips: gold title, green action hint.
    GameTooltip:SetText(SETTINGS, 1, 0.82, 0) -- Blizzard global, already localized
    GameTooltip:AddLine(L["title_bar.menu_hint"], 0.45, 0.75, 0.45)
    GameTooltip:Show()
end)
pinBtn:SetScript("OnLeave", function()
    pinBtnTex:SetVertexColor(0.7, 0.7, 0.7, 0.9)
    GameTooltip:Hide()
end)
pinBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

local minimizeBtn = CreateFrame("Button", nil, titleBar)
minimizeBtn:SetSize(18, 18)
minimizeBtn:SetPoint("RIGHT", pinBtn, "LEFT", -3, 0)
minimizeBtn:RegisterForClicks("LeftButtonUp")
minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
minimizeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Highlight")
minimizeBtn:Hide() -- hidden by default (docked mode); shown by FloatPanel()
minimizeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(isMinimized and "Expand" or "Minimize", 1, 1, 1)
    GameTooltip:Show()
end)
minimizeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Constrain title text to not overlap buttons (gear is leftmost when docked).
titleText:SetPoint("RIGHT", pinBtn, "LEFT", -4, 0)

-- Dragging (only when floating)
titleBar:EnableMouse(true)
titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", function()
    if isFloating then panel:StartMoving() end
end)
titleBar:SetScript("OnDragStop", function()
    panel:StopMovingOrSizing()
    if ClassCodexCharDB and isFloating then
        ClassCodexCharDB.floatX = panel:GetLeft()
        ClassCodexCharDB.floatY = panel:GetTop()
    end
end)

-------------------------------------------------------------------------------
-- Side Tabs
-------------------------------------------------------------------------------

local SIDE_TAB_W = 26
local SIDE_TAB_H = 28
local SIDE_TAB_GAP = 2
local activeTab = "guide" -- "guide", "stats", "talents", "bis", "trinkets", "enhancements", "crafting", "about", "supporters"

-- Side tabs use the same BackdropTemplate idiom as section headers and
-- the rest of the addon, plus a HIGHLIGHT layer for native mouse hover
-- (no manual OnEnter alpha tween). The tab anchors with a 1-pixel
-- overlap into the panel so the BackdropTemplate left edge tucks under
-- the panel's own border — visually the two frames still merge.
local function CreateSideTab(parent, icon, tooltip, tabKey)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(SIDE_TAB_W, SIDE_TAB_H)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    btn:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
    btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)

    -- Native hover highlight (auto-shown on MouseEnter by the engine).
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetSize(16, 16)
    tex:SetPoint("CENTER", -1, 0)
    if type(icon) == "number" then
        tex:SetTexture(icon)
    elseif type(icon) == "string" and icon:find("[\\/]") then
        tex:SetTexture(icon)
    else
        tex:SetAtlas(icon)
    end
    tex:SetDesaturated(true)
    btn.icon = tex
    btn.tabKey = tabKey

    btn:SetScript("OnEnter", function(self)
        self.icon:SetDesaturated(false)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tooltip, 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        if activeTab ~= self.tabKey and not self.noDesaturate then self.icon:SetDesaturated(true) end
        GameTooltip:Hide()
    end)
    return btn
end

local sideTabs = {}
local bottomTabs = {}

local guideTab = CreateSideTab(panel, "Interface\\Icons\\INV_Misc_Book_11", L["tab.guide"], "guide")
guideTab:SetPoint("TOPLEFT", panel, "TOPRIGHT", -1, -40)
sideTabs[#sideTabs + 1] = guideTab

local statsTab = CreateSideTab(panel, "Interface\\Icons\\INV_Misc_Note_01", L["section.stat_targets"], "stats")
statsTab:SetPoint("TOPLEFT", guideTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = statsTab

local talentsTab = CreateSideTab(panel, "Interface\\Icons\\INV_Inscription_TalentTome01", L["section.talents"], "talents")
talentsTab:SetPoint("TOPLEFT", statsTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = talentsTab

local bisTab = CreateSideTab(panel, 132349, L["tab.bis_gear"], "bis") -- INV_Chest_Chain_15 (armor)
bisTab:SetPoint("TOPLEFT", talentsTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = bisTab

local trinketsTab = CreateSideTab(panel, 135934, L["tab.trinkets"], "trinkets") -- INV_Jewelry_Talisman_07
trinketsTab:SetPoint("TOPLEFT", bisTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = trinketsTab

local enhancementsTab = CreateSideTab(panel, 136244, L["tab.enhancements"], "enhancements") -- Trade_Engraving
enhancementsTab:SetPoint("TOPLEFT", trinketsTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = enhancementsTab

local craftsTab = CreateSideTab(panel, 136241, L["tab.crafting"], "crafting") -- Trade_BlackSmithing
craftsTab:SetPoint("TOPLEFT", enhancementsTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
sideTabs[#sideTabs + 1] = craftsTab

local supporters = {}
-- The tab key stays "supporters" even though the tab is now Credits:
-- it is persisted as ClassCodexCharDB.activeTab, so renaming it would
-- invalidate the remembered tab for anyone who had this one open.
supporters.tab = CreateSideTab(panel, "Interface\\Icons\\INV_Misc_Book_09", L["about.credits"], "supporters")
supporters.tab.noDesaturate = true -- kept in colour so the tab reads as a distinct destination
supporters.tab.icon:SetDesaturated(false)
bottomTabs[#bottomTabs + 1] = supporters.tab

local aboutTab = CreateSideTab(panel, "Interface\\Icons\\Achievement_Faction_Lorewalkers", L["tab.about"], "about")
bottomTabs[#bottomTabs + 1] = aboutTab

local allTabs = {}
local function UpdateTabAppearance()
    for _, tab in ipairs(allTabs) do
        if activeTab == tab.tabKey then
            tab:SetBackdropBorderColor(1, 0.82, 0, 1)
            tab:SetBackdropColor(0.15, 0.15, 0.15, 0.95)
            tab.icon:SetDesaturated(false)
        else
            tab:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.6)
            tab:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
            if not tab.noDesaturate then tab.icon:SetDesaturated(true) end
        end
    end
end

for _, t in ipairs(sideTabs) do allTabs[#allTabs + 1] = t end
for _, t in ipairs(bottomTabs) do allTabs[#allTabs + 1] = t end
UpdateTabAppearance()

for _, tab in ipairs(allTabs) do
    tab:SetScript("OnClick", function(self)
        activeTab = self.tabKey
        if ClassCodexCharDB then ClassCodexCharDB.activeTab = activeTab end
        UpdateTabAppearance()
        ns:UpdatePanel()
    end)
end

-- Tab visibility rules: which DB keys must ALL be false to hide a tab.
-- The Stats tab uses the same `Stats` DB key as the Guide tab's stat-priority
-- section — toggling stats off in settings hides both surfaces consistently.
local TAB_VISIBILITY_RULES = {
    { tab = guideTab,         tabKey = "guide",         keys = { "Stats", "Talents", "Rotation" } },
    { tab = statsTab,         tabKey = "stats",         keys = { "StatTargets" } },
    { tab = talentsTab,       tabKey = "talents",       keys = { "Talents" } },
    { tab = bisTab,           tabKey = "bis",           keys = { "BisGear" } },
    { tab = trinketsTab,      tabKey = "trinkets",      keys = { "Trinkets" } },
    { tab = enhancementsTab,  tabKey = "enhancements",  keys = { "Enchants", "Gems", "Consumables" } },
    { tab = craftsTab,        tabKey = "crafting",      keys = { "Crafts", "Crafting" } },
}

function ns:UpdateSideTabVisibility(prefix, currentActiveTab)
    local db = ClassCodexDB
    if not db then return currentActiveTab end
    for _, rule in ipairs(TAB_VISIBILITY_RULES) do
        local allDisabled = true
        for _, key in ipairs(rule.keys) do
            if db[prefix .. key] ~= false then allDisabled = false; break end
        end
        if allDisabled then
            rule.tab:Hide()
            if currentActiveTab == rule.tabKey then
                currentActiveTab = "about"
                UpdateTabAppearance()
            end
        else
            rule.tab:Show()
        end
    end
    return currentActiveTab
end

-------------------------------------------------------------------------------
-- Content Container
-------------------------------------------------------------------------------

local contentFrame = CreateFrame("Frame", nil, panel)
contentFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -2)
contentFrame:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
contentFrame:SetHeight(400) -- initial height, updated in LayoutPanel

-------------------------------------------------------------------------------
-- Sub-header: Hero Talent + Context Dropdowns
-------------------------------------------------------------------------------

local subheaderFrame = CreateFrame("Frame", nil, contentFrame)
subheaderFrame:SetHeight(SUBHEADER_HEIGHT)
subheaderFrame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, 0)
subheaderFrame:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", -CONTENT_INSET, 0)

-- ns.CreateOptionDropdown(name, parent, width) -> Frame
-- Native Blizzard dropdown (WowStyle1DropdownTemplate) wrapped in the
-- minimal API the addon needs. Caller drives state via SetOptions:
--
--   dd:SetOptions(opts, current, onSelect)
--     opts:    array of strings or { label = "Display", value = "key" }
--     current: the value currently selected (drives the closed-state
--              label and the radio checkmark)
--     onSelect(value): invoked when the user picks an option
--
-- The popup, hover state, outside-click dismissal, and gold-on-current
-- styling come from the template — same widget the talent-pane source
-- picker (and now every other dropdown in the addon) uses.
local function CreateOptionDropdown(name, parent, width)
    local dd = CreateFrame("DropdownButton", name, parent, "WowStyle1DropdownTemplate")
    dd:SetSize(width or 140, DROPDOWN_HEIGHT)

    dd._opts, dd._current, dd._onSelect = nil, nil, nil
    dd:SetupMenu(function(_, rootDescription)
        if not dd._opts then return end
        for _, opt in ipairs(dd._opts) do
            local label, value
            if type(opt) == "table" then
                label, value = opt.label or opt.value, opt.value
            else
                label, value = opt, opt
            end
            rootDescription:CreateRadio(
                label,
                function() return value == dd._current end,
                function() if dd._onSelect then dd._onSelect(value) end end
            )
        end
    end)

    function dd:SetOptions(opts, current, onSelect)
        self._opts, self._current, self._onSelect = opts, current, onSelect
        -- WowStyle1Dropdown reads the closed-state label off the option
        -- whose IsSelected returns true. SetDefaultText is the fallback
        -- when no option matches (e.g. spec has no contexts available).
        local fallbackLabel
        if opts and current then
            for _, opt in ipairs(opts) do
                local l, v
                if type(opt) == "table" then l, v = opt.label or opt.value, opt.value
                else l, v = opt, opt end
                if v == current then fallbackLabel = l; break end
            end
        end
        if self.SetDefaultText then self:SetDefaultText(fallbackLabel or current or "") end
        if self.GenerateMenu then self:GenerateMenu() end
    end

    return dd
end

-- Hero dropdown: width is recomputed in LayoutSubheader to span the
-- subheader. The hero atlas icon is embedded inline in the option
-- label via |A:atlas:14:14|a so the closed-state shows the icon
-- without needing a separate texture child anchored to the template.
local heroDropdown = CreateOptionDropdown("ClassCodexHeroDropdown", subheaderFrame)

local function LayoutSubheader(showHero)
    heroDropdown:ClearAllPoints()
    if showHero then
        -- Anchor TOP (not LEFT) so the dropdown sits flush against the
        -- subheader's top edge — without this the LEFT anchor centers
        -- it vertically inside the 30-px subheader, which puts ~3 px of
        -- gap above the dropdown and breaks parity with the Stats tab.
        heroDropdown:SetPoint("TOPLEFT", subheaderFrame, "TOPLEFT", 0, 0)
        heroDropdown:SetPoint("TOPRIGHT", subheaderFrame, "TOPRIGHT", 0, 0)
        heroDropdown:Show()
    else
        heroDropdown:Hide()
        subheaderFrame:SetHeight(1)
    end
end

-- The bespoke dropdownMenu / pool / hider machinery used to live here.
-- Migrated to WowStyle1DropdownTemplate (see CreateOptionDropdown above);
-- the template owns its own popup, hover, outside-click dismissal, and
-- panel-hide cleanup, so none of that scaffolding is needed anymore.

-------------------------------------------------------------------------------
-- Section: Stat Priority
-------------------------------------------------------------------------------

-- CreateSectionHeader + SetCollapsed live in UI/CollapsibleSection.lua
-- as ns.CreateSectionHeader / ns.SetCollapsed. Local aliases below so
-- the existing call sites in this file keep working without prefix.
local CreateSectionHeader = ns.CreateSectionHeader
local SetCollapsed = ns.SetCollapsed

-- Tab title (non-collapsible, text set dynamically per active tab)
local tabTitle = CreateFrame("Frame", nil, contentFrame)
tabTitle:SetHeight(SECTION_HEADER_HEIGHT)
local tabTitleText = tabTitle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tabTitleText:SetPoint("LEFT", 2, 0)
tabTitleText:SetTextColor(1, 0.82, 0)
tabTitle:Hide()

local TAB_TITLE_LABELS = {
    guide        = L["tab.guide"],
    stats        = L["section.stat_targets"],
    talents      = L["section.talents"],
    enhancements = L["tab.enhancements"],
    crafting     = L["tab.crafting"],
}

-- Stat priority info icon on Guide title row (right-aligned)
local statInfoBtn = CreateFrame("Button", nil, tabTitle)
statInfoBtn:SetSize(12, 12)
statInfoBtn:SetPoint("RIGHT", -2, 0)
local statInfoIcon = statInfoBtn:CreateTexture(nil, "ARTWORK")
statInfoIcon:SetAllPoints()
statInfoIcon:SetAtlas("QuestTurnin")
statInfoIcon:SetVertexColor(0.5, 0.5, 0.5)
statInfoBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["settings.label.stat_priority_on_tooltips"], 1, 0.82, 0)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Item tooltips show the stat priority rank (e.g. #1, #2, #3) next to each stat name based on the currently selected hero talent and context.", 1, 1, 1, true)
    GameTooltip:Show()
    statInfoIcon:SetVertexColor(1, 1, 1)
end)
statInfoBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
    statInfoIcon:SetVertexColor(0.5, 0.5, 0.5)
end)

-- Crafting tab info icon. Created lazily after the Crafting section
-- module loads (see Sections/Crafting.lua: Crafting.AttachInfoButton).
-- Shown only on the crafting tab via UpdatePanel below.
local craftingInfoBtn = ns.Sections.Crafting.AttachInfoButton(tabTitle)
craftingInfoBtn:Hide()

-- Crafting tab options gear. Sits left of the help icon; opens a
-- context menu with the "Show top picks only" toggle (mirrored in
-- the main settings panel).
local craftingOptionsBtn = ns.Sections.Crafting.AttachOptionsButton(tabTitle)
craftingOptionsBtn:Hide()

-------------------------------------------------------------------------------
-- Early ns exports for Section modules
--
-- Section/* InitPanel calls happen at file-scope below this point. They
-- reference ns.SECTION_HEADER_HEIGHT / ns.ROW_HEIGHT / ns.CreateOptionDropdown
-- etc. at runtime, so those must already be on `ns` by the time Init runs.
-- The full export table further down (with GetSpecData, isFloating, etc.) is
-- still authoritative — these are just the subset needed before the Init
-- calls execute.
-------------------------------------------------------------------------------
ns.SECTION_HEADER_HEIGHT = SECTION_HEADER_HEIGHT
ns.ROW_HEIGHT = ROW_HEIGHT
ns.CONTENT_INSET = CONTENT_INSET
ns.PANEL_PADDING = PANEL_PADDING
ns.contentFrame = contentFrame
ns.CreateSectionHeader = CreateSectionHeader
ns.SetCollapsed = SetCollapsed
ns.CreateOptionDropdown = CreateOptionDropdown
ns.GetPanelWidth = GetPanelWidth

-- Stat Priority section — extracted to Sections/Stats.lua. The module owns
-- the section frame, row pool, and context dropdown. We keep the header
-- handle so this file can hook its collapse-on-click and persistence.
local statSection, statHeader, statContent = ns.Sections.Stats.InitPanel({
    parent = contentFrame,
    header = CreateSectionHeader,
})
local MAX_STATS = 10
local currentStatContext = nil
local statSectionCollapsed = false
local lastStatRowCount = 0

-------------------------------------------------------------------------------
-- Section: Stat Targets (only shown on the Stats tab)
--
-- Pairs the priority list above with empirical secondary-stat rating
-- targets harvested from Archon (M+ / Raid). Each row carries the live
-- player rating, a Blizzard StatusBar filled toward the target, and a
-- coloured delta arrow. Bars use the standard UI-StatusBar texture so the
-- visual language matches the rest of WoW (cast bars, talent points, etc).
-------------------------------------------------------------------------------

-- Stat-targets live bars — extracted to Sections/StatTargets.lua. The
-- module owns the section frame, row pool, custom StatusBar textures,
-- context dropdown, and PvP / in-combat fallback lines.
local _statTargetsSection = ns.Sections.StatTargets.InitPanel({ parent = contentFrame })
-- Mirror the previous {section, content, ctxDropdown} surface so the
-- LayoutPanel code below (which still references statTargets.section)
-- doesn't need rewiring; the table is now a thin facade.
local statTargets = {
    section = _statTargetsSection,
    content = ns.Sections.StatTargets.GetPanelContent(),
}

-------------------------------------------------------------------------------
-- Section: Talents
-------------------------------------------------------------------------------

-- Talents Guide-tab preview — extracted to Sections/Talents.lua. The
-- module owns the section frame, button pool, action button factory, and
-- preview render. The standalone Talents-tab full-builds renderer
-- (UpdateAllTalents below) still lives here because of its on-demand
-- pools + Archon-section collapse state.
local talentSection, talentHeader, talentContent = ns.Sections.Talents.InitPanel({
    parent = contentFrame,
    header = CreateSectionHeader,
})
local MAX_TALENT_BUTTONS = ns.Sections.Talents.GetPanelMax()
local TALENT_BTN_HEIGHT = ns.TALENT_BTN_HEIGHT
local TALENT_BTN_GAP = ns.TALENT_BTN_GAP
local TALENT_ACTION_GAP = ns.TALENT_ACTION_GAP
local CreateTalentActionButton = ns.CreateTalentActionButton
local talentButtons = ns.Sections.Talents.GetPanelButtons()
local lastTalentContentHeight = 0

-- Copy popup — one shared instance for talent strings, source URLs,
-- and anything else the addon wants the user to paste elsewhere.
-- Uses the standard DialogBox bgFile + InputBoxTemplate edit so it
-- reads as a Blizzard dialog rather than yet another bespoke widget.
local copyPopup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
copyPopup:SetSize(280, 28)
copyPopup:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
})
copyPopup:SetFrameStrata("DIALOG")
copyPopup:Hide()

local copyEdit = CreateFrame("EditBox", nil, copyPopup, "InputBoxTemplate")
copyEdit:SetSize(260, 18)
copyEdit:SetPoint("CENTER")
copyEdit:SetAutoFocus(true)
copyEdit:SetScript("OnEscapePressed", function() copyPopup:Hide() end)
copyEdit:SetScript("OnEditFocusLost", function() copyPopup:Hide() end)

-- Show the popup with `text` pre-selected. When `anchor` is provided
-- the popup sits below it; otherwise it centers on UIParent (used by
-- the talent-pane build picker, which has no convenient row anchor).
-- Replaces the per-section talentCopyBox / sourceCopyBox / UI.copyBox
-- / TalentPaneDropdown copyBox quartet — one shared widget across
-- every surface that lets the user copy a string.
local function ShowCopyPopup(text, anchor, yOffset)
    copyPopup:ClearAllPoints()
    if anchor then
        copyPopup:SetPoint("TOP", anchor, "BOTTOM", 0, yOffset or -4)
    else
        copyPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    copyEdit:SetText(text or "")
    copyPopup:Show()
    copyEdit:SetFocus()
    copyEdit:HighlightText()
end
ns.ShowCopyPopup = ShowCopyPopup

local talentSectionCollapsed = false

-------------------------------------------------------------------------------
-- Talents Tab: grouped-by-context layout (all heroes, all builds)
--
-- All construction + render helpers below are scoped inside a do block
-- to keep them off the chunk's local table — ClassCodex.lua's main
-- function is dense and brushes against Lua's 200-local cap.
-------------------------------------------------------------------------------

local allTalentContent = CreateFrame("Frame", nil, contentFrame)
allTalentContent:SetHeight(1)
allTalentContent:Hide()

do
local TALENT_CONTEXT_HEADER_HEIGHT = 22
local ALL_TALENT_INDENT = 8
local ALL_TALENT_TOGGLE_HEIGHT = 32 -- DROPDOWN_HEIGHT (26) + 6 gap before sections

-- Header + row pools grow on demand: Wowhead path tops out at ~5
-- hero × ~3 contexts, but Archon adds ~30 encounter rows (M+ overview
-- + dungeons + raid Heroic/Mythic overviews + bosses) plus 3 section
-- headers, so a fixed pre-allocation isn't enough.
-- Per-section collapse state, keyed by header text. Stored alongside
-- the addon's other section-collapse flags so Mythic+ etc. persist
-- across reloads.
local function GetArchonSectionCollapsed(name)
    if not ClassCodexCharDB or not ClassCodexCharDB.collapsed then return false end
    local s = ClassCodexCharDB.collapsed.archonSections
    return s and s[name] or false
end

local function SetArchonSectionCollapsed(name, collapsed)
    if not ClassCodexCharDB then return end
    ClassCodexCharDB.collapsed = ClassCodexCharDB.collapsed or {}
    ClassCodexCharDB.collapsed.archonSections = ClassCodexCharDB.collapsed.archonSections or {}
    -- Store nil for the default (expanded) so the table doesn't grow
    -- with every section the user has ever seen.
    ClassCodexCharDB.collapsed.archonSections[name] = collapsed and true or nil
end

-- Talents-tab section headers reuse the same ns.CreateSectionHeader as
-- every other section in the panel (BackdropTemplate background +
-- right-side arrow + hover highlight), so the Archon Mythic+ / Raid
-- Heroic / Raid Mythic rows look identical to Stat Priority, Talents,
-- Rotation, Enchants, Gems, Consumables.
local allTalentHeaders = {}
local function EnsureTalentHeader(i)
    if allTalentHeaders[i] then return allTalentHeaders[i] end
    local hdr = CreateSectionHeader(allTalentContent, "", true)
    hdr:Hide()
    allTalentHeaders[i] = hdr
    return hdr
end

local allTalentRows = {}
local function EnsureTalentRow(i)
    if allTalentRows[i] then return allTalentRows[i] end
    local row = CreateFrame("Frame", nil, allTalentContent, "BackdropTemplate")
    row:SetHeight(TALENT_BTN_HEIGHT)
    row:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
    row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

    local applyBtn = CreateTalentActionButton(row,
        "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "Apply talents")
    applyBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.applyBtn = applyBtn

    local copyBtn = CreateTalentActionButton(row,
        "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "Copy talent string")
    copyBtn:SetPoint("RIGHT", applyBtn, "LEFT", -TALENT_ACTION_GAP, 0)
    row.copyBtn = copyBtn

    local heroIcon = row:CreateTexture(nil, "ARTWORK")
    heroIcon:SetSize(14, 14)
    heroIcon:SetPoint("LEFT", 6, 0)
    row.heroIcon = heroIcon

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", heroIcon, "RIGHT", 4, 0)
    text:SetPoint("RIGHT", copyBtn, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetTextColor(0.8, 0.8, 0.8)
    row.label = text

    row:SetScript("OnEnter", function(self)
        if not self.isActive then
            self:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        end
        self.label:SetTextColor(1, 1, 1)
    end)
    row:SetScript("OnLeave", function(self)
        if not self.isActive then
            self:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
        end
        self.label:SetTextColor(self.isActive and 0.3 or 0.8, self.isActive and 1 or 0.8, self.isActive and 0.3 or 0.8)
    end)
    row:Hide()
    allTalentRows[i] = row
    return row
end

local allTalentFallback = allTalentContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
allTalentFallback:SetTextColor(0.5, 0.5, 0.5)
allTalentFallback:SetText(L["loadout_dock.no_talent_builds"])
allTalentFallback:Hide()

-- Source dropdown (Wowhead | Archon). Persisted via the same per-spec
-- key as the talent pane and Compendium, so flipping one updates all.
-- Each option is prefixed with the source's brand icon via a |T...|t
-- texture escape — no extra widget plumbing needed.
local SOURCE_ICON_WOWHEAD  = "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12:0:0|t  Wowhead"
local SOURCE_ICON_ARCHON   = "|TInterface\\AddOns\\ClassCodex\\Textures\\archon:12:12:0:0|t  Archon"
local SOURCE_ICON_ICYVEINS = "|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:12:12:0:0|t  Icy Veins"
local SOURCE_ICON_PVP      = "|TInterface\\AddOns\\ClassCodex\\Textures\\bnet:12:12:0:0|t  PvP"

local allTalentSourceDropdown = CreateOptionDropdown("ClassCodexAllTalentSourceDropdown", allTalentContent, 140)
allTalentSourceDropdown:Hide()
-- Options + current selection are pushed in by UpdateAllTalents via
-- :SetOptions; the WowStyle1Dropdown template owns click + popup.

local function BindAllTalentCopy(row, exportString)
    row.copyBtn:SetScript("OnClick", function()
        ShowCopyPopup(exportString, row)
    end)
end

local function BindAllTalentApply(row, exportString, loadoutLabel)
    row.applyBtn:SetScript("OnClick", function(self)
        local ok, err = ns.ApplyTalentExportString(exportString, loadoutLabel)
        if not ok then
            self.icon:SetVertexColor(1, 0.2, 0.2)
            print("|cff00ccffClass Codex:|r " .. (err or "Failed to apply talents"))
        else
            self.icon:SetVertexColor(1, 0.8, 0)
        end
        C_Timer.After(1.5, function()
            if self.icon then
                self.icon:SetDesaturated(true)
                self.icon:SetVertexColor(0.7, 0.7, 0.7)
            end
        end)
    end)
end

local function RenderAllTalentsWowhead(specData, yPos)
    local talents = specData.talents
    if not talents or #talents == 0 then
        allTalentFallback:SetText(L["loadout_dock.no_talent_builds"])
        allTalentFallback:ClearAllPoints()
        allTalentFallback:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        allTalentFallback:Show()
        return yPos + 20
    end

    local activeTalentData = ns.GetActiveTalentSignature()
    local activeHero = GetActiveHeroTalentName and GetActiveHeroTalentName() or nil
    local heroOrder, heroBuilds = ns.GroupBuildsByHero(talents)

    local hdrIdx, rowIdx = 0, 0
    for _, hero in ipairs(heroOrder) do
        hdrIdx = hdrIdx + 1
        local hdr = EnsureTalentHeader(hdrIdx)

        hdr.label:SetText(ns.FormatHeroHeaderText(hero))
        if activeHero and hero ~= activeHero then
            hdr.label:SetTextColor(0.6, 0.55, 0.35)
        else
            hdr.label:SetTextColor(1, 0.82, 0)
        end
        -- Wowhead headers aren't collapsible per-hero — hide the
        -- arrow and clear any leftover OnClick from a prior Archon
        -- render. (The shared CreateSectionHeader's hover effect
        -- stays so the visual style matches the rest of the panel.)
        if hdr.arrow then hdr.arrow:Hide() end
        hdr:SetScript("OnClick", nil)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        hdr:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
        hdr:Show()
        yPos = yPos + TALENT_CONTEXT_HEADER_HEIGHT

        local isActiveHero = not activeHero or hero == activeHero

        for _, build in ipairs(heroBuilds[hero]) do
            rowIdx = rowIdx + 1
            local row = EnsureTalentRow(rowIdx)
            row.heroIcon:Hide()

            local isActive = activeTalentData and ns.ExtractTalentBits(build.exportString) == activeTalentData
            row.isActive = isActive
            if isActive then
                row:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
                row.label:SetTextColor(0.3, 1, 0.3)
            else
                row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
                if isActiveHero then
                    row.label:SetTextColor(0.8, 0.8, 0.8)
                else
                    row.label:SetTextColor(0.55, 0.55, 0.55)
                end
            end
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", row.heroIcon, "RIGHT", 4, 0)
            row.label:SetPoint("RIGHT", row.copyBtn, "LEFT", -4, 0)
            row.label:SetText(ns.FormatBuildLabel(build))

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", ALL_TALENT_INDENT, -yPos)
            row:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)

            BindAllTalentCopy(row, build.exportString)
            BindAllTalentApply(row, build.exportString, hero .. " " .. (build.context or ""))

            row:Show()
            yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
        end
        yPos = yPos + 4
    end
    return yPos
end

local function RenderAllTalentsArchon(class, spec, yPos)
    local archon = ns.GetArchonSpecData and ns.GetArchonSpecData(class, spec) or nil
    if not archon or not archon.contexts or not next(archon.contexts) then
        allTalentFallback:SetText(L["loadout_dock.no_archon_builds"] or "No Archon builds available.")
        allTalentFallback:ClearAllPoints()
        allTalentFallback:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        allTalentFallback:Show()
        return yPos + 20
    end

    -- ns.BuildMatchesActive (lifted from TalentPaneDropdown.lua) does
    -- map-based equality so Archon's bit-ordering quirks don't hide the
    -- applied build. Falls back to bit-compare if the helper isn't
    -- loaded yet (toc order makes this unreachable in practice but
    -- the guard is cheap).
    local matchActive = ns.BuildMatchesActive
    local activeTalentBits = (not matchActive) and ns.GetActiveTalentSignature() or nil
    local groups = ns.GroupArchonContexts(archon)
    local hdrIdx, rowIdx = 0, 0

    local function emitSection(headerText, entries)
        if not entries or #entries == 0 then return end
        hdrIdx = hdrIdx + 1
        local hdr = EnsureTalentHeader(hdrIdx)
        local collapsed = GetArchonSectionCollapsed(headerText)

        hdr.label:SetText(headerText)
        hdr.label:SetTextColor(1, 0.82, 0)
        if hdr.arrow then
            hdr.arrow:SetTexture(collapsed
                and "Interface\\Buttons\\UI-PlusButton-Up"
                or "Interface\\Buttons\\UI-MinusButton-Up")
            hdr.arrow:Show()
        end
        hdr:SetScript("OnClick", function()
            SetArchonSectionCollapsed(headerText, not GetArchonSectionCollapsed(headerText))
            ns:UpdatePanel()
        end)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        hdr:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
        hdr:Show()
        yPos = yPos + TALENT_CONTEXT_HEADER_HEIGHT

        if collapsed then
            yPos = yPos + 4
            return
        end

        for _, entry in ipairs(entries) do
            local ctx = entry.ctx
            local build = ctx.builds and ctx.builds[1]
            if build then
                rowIdx = rowIdx + 1
                local row = EnsureTalentRow(rowIdx)

                local heroAtlas = build.heroTalent and ns.HERO_TALENT_ATLAS
                    and ns.HERO_TALENT_ATLAS[build.heroTalent]
                if heroAtlas then
                    row.heroIcon:SetAtlas(heroAtlas)
                    row.heroIcon:Show()
                else
                    row.heroIcon:Hide()
                end

                local isActive
                if matchActive then
                    isActive = matchActive(build)
                elseif activeTalentBits then
                    isActive = ns.ExtractTalentBits(build.exportString) == activeTalentBits
                else
                    isActive = false
                end
                row.isActive = isActive
                if isActive then
                    row:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
                    row.label:SetTextColor(0.3, 1, 0.3)
                else
                    row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
                    row.label:SetTextColor(0.8, 0.8, 0.8)
                end

                row.label:ClearAllPoints()
                local labelLeftOffset = heroAtlas and 24 or 8
                row.label:SetPoint("LEFT", row, "LEFT", labelLeftOffset, 0)
                row.label:SetPoint("RIGHT", row.copyBtn, "LEFT", -4, 0)
                local fullLabel = (ns.GetArchonEncounterLabel and ns.GetArchonEncounterLabel(ctx))
                    or ctx.encounterLabel or "Build"
                row.label:SetText(fullLabel)

                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", ALL_TALENT_INDENT, -yPos)
                row:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)

                BindAllTalentCopy(row, build.exportString)
                BindAllTalentApply(row, build.exportString,
                    (build.heroTalent or "Archon") .. " " .. fullLabel)

                row:Show()
                yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
            end
        end
        yPos = yPos + 4
    end

    local mplus = {}
    if groups.mplusOverview then mplus[#mplus + 1] = groups.mplusOverview end
    for _, e in ipairs(groups.mplusDungeons) do mplus[#mplus + 1] = e end
    emitSection("Mythic+", mplus)

    local heroic = {}
    if groups.raidOverviewHeroic then heroic[#heroic + 1] = groups.raidOverviewHeroic end
    for _, e in ipairs(groups.raidHeroicBosses) do heroic[#heroic + 1] = e end
    emitSection("Raid — Heroic", heroic)

    local mythic = {}
    if groups.raidOverviewMythic then mythic[#mythic + 1] = groups.raidOverviewMythic end
    for _, e in ipairs(groups.raidMythicBosses) do mythic[#mythic + 1] = e end
    emitSection("Raid — Mythic", mythic)

    return yPos
end

-- Render the PvP source on the docked Talents side tab. Brackets are
-- grouped under "Arena" / "Battleground" headers (same split the
-- LoadoutDock submenu uses) and rendered using the existing talent-row
-- pool. When no PvP data exists for the spec, writes the talent
-- fallback line — same pattern as RenderAllTalentsArchon.
local function RenderAllTalentsPvP(class, spec, yPos)
    local brackets = ns.GetPvPBracketsWithData
        and ns.GetPvPBracketsWithData(class, spec)
        or {}
    if not brackets or #brackets == 0 then
        allTalentFallback:SetText(L["pvp.no_builds"] or "No PvP builds available.")
        allTalentFallback:ClearAllPoints()
        allTalentFallback:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        allTalentFallback:Show()
        return yPos + 20
    end

    local ARENA_GROUP = { "pvp-shuffle", "pvp-2v2", "pvp-3v3" }
    local BG_GROUP    = { "pvp-blitz", "pvp-rbg" }
    local available = {}
    for _, k in ipairs(brackets) do available[k] = true end

    local matchActive = ns.BuildMatchesActive
    local hdrIdx, rowIdx = 0, 0

    local function emitSection(headerText, group)
        local hasAny = false
        for _, k in ipairs(group) do if available[k] then hasAny = true; break end end
        if not hasAny then return end
        hdrIdx = hdrIdx + 1
        local hdr = EnsureTalentHeader(hdrIdx)
        hdr.label:SetText(headerText)
        hdr.label:SetTextColor(1, 0.82, 0)
        if hdr.arrow then hdr.arrow:Hide() end
        hdr:SetScript("OnClick", nil)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        hdr:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
        hdr:Show()
        yPos = yPos + TALENT_CONTEXT_HEADER_HEIGHT

        for _, bracketKey in ipairs(group) do
            if available[bracketKey] then
                local data = ns.GetPvPBuilds and ns.GetPvPBuilds(class, spec, bracketKey)
                local build = data and data.builds and data.builds[1]
                if build then
                    rowIdx = rowIdx + 1
                    local row = EnsureTalentRow(rowIdx)
                    if row.heroIcon then row.heroIcon:Hide() end

                    local isActive = matchActive and matchActive({ exportString = build.exportString }) or false
                    row.isActive = isActive
                    if isActive then
                        row:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
                        row.label:SetTextColor(0.3, 1, 0.3)
                    else
                        row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
                        row.label:SetTextColor(0.8, 0.8, 0.8)
                    end

                    local bracketLabel = (ns.GetPvPBracketName and ns.GetPvPBracketName(bracketKey)) or bracketKey
                    if data.lowConfidence then
                        bracketLabel = bracketLabel .. " |cff999999(low confidence)|r"
                    end
                    row.label:ClearAllPoints()
                    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                    row.label:SetPoint("RIGHT", row.copyBtn, "LEFT", -4, 0)
                    row.label:SetText(bracketLabel)

                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", ALL_TALENT_INDENT, -yPos)
                    row:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
                    BindAllTalentCopy(row, build.exportString)
                    BindAllTalentApply(row, build.exportString, "PvP " .. bracketLabel)
                    row:Show()
                    yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
                end
            end
        end
        yPos = yPos + 4
    end

    emitSection(L["pvp.arena"] or "Arena", ARENA_GROUP)
    emitSection(L["pvp.battleground"] or "Battleground", BG_GROUP)
    return yPos
end

-- Render the Icy Veins talent source. IV builds are context-labeled (not
-- hero-grouped like Wowhead). Bucket by context in a sensible order and
-- render in place — a context with several builds gets a section header;
-- a lone build is shown as a bare row with no header over it. Same row/
-- header pools and active-build highlight as the Archon/PvP renderers.
local IV_TALENT_CONTEXT_ORDER = { "Raid", "Mythic+", "Delves", "General", "Leveling" }

local function RenderAllTalentsIcyVeins(class, spec, yPos)
    local ivt = ns.GetIcyVeinsTalentSpecData and ns:GetIcyVeinsTalentSpecData(class, spec) or nil
    local builds = ivt and ivt.talents
    if not builds or #builds == 0 then
        allTalentFallback:SetText(L["loadout_dock.no_icyveins_builds"] or "No Icy Veins talent builds available.")
        allTalentFallback:ClearAllPoints()
        allTalentFallback:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
        allTalentFallback:Show()
        return yPos + 20
    end

    local buckets = {}
    for _, b in ipairs(builds) do
        local key = b.leveling and "Leveling" or (b.context or "General")
        buckets[key] = buckets[key] or {}
        buckets[key][#buckets[key] + 1] = b
    end

    local matchActive = ns.BuildMatchesActive
    local hdrIdx, rowIdx = 0, 0

    local function emitRow(build, indent)
        rowIdx = rowIdx + 1
        local row = EnsureTalentRow(rowIdx)
        if row.heroIcon then row.heroIcon:Hide() end

        local isActive = matchActive and matchActive({ exportString = build.exportString }) or false
        row.isActive = isActive
        if isActive then
            row:SetBackdropBorderColor(0.2, 0.8, 0.2, 1)
            row.label:SetTextColor(0.3, 1, 0.3)
        else
            row:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            row.label:SetTextColor(0.8, 0.8, 0.8)
        end

        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.label:SetPoint("RIGHT", row.copyBtn, "LEFT", -4, 0)
        row.label:SetText(build.buildLabel or build.context or "Build")

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", indent, -yPos)
        row:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
        BindAllTalentCopy(row, build.exportString)
        BindAllTalentApply(row, build.exportString, "Icy Veins " .. (build.buildLabel or build.context or ""))
        row:Show()
        yPos = yPos + TALENT_BTN_HEIGHT + TALENT_BTN_GAP
    end

    local seen = {}
    local function emitBucket(key)
        local group = buckets[key]
        if not group or #group == 0 or seen[key] then return end
        seen[key] = true

        if #group >= 2 then
            -- Multi-build context: show a header, indent its rows.
            hdrIdx = hdrIdx + 1
            local hdr = EnsureTalentHeader(hdrIdx)
            hdr.label:SetText(key == "Leveling" and (L["talents.leveling"] or "Leveling") or key)
            hdr.label:SetTextColor(1, 0.82, 0)
            if hdr.arrow then hdr.arrow:Hide() end
            hdr:SetScript("OnClick", nil)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, -yPos)
            hdr:SetPoint("RIGHT", allTalentContent, "RIGHT", 0, 0)
            hdr:Show()
            yPos = yPos + TALENT_CONTEXT_HEADER_HEIGHT
            for _, build in ipairs(group) do emitRow(build, ALL_TALENT_INDENT) end
        else
            -- Lone build: a bare row, no section header.
            emitRow(group[1], 0)
        end
        yPos = yPos + 4
    end

    for _, key in ipairs(IV_TALENT_CONTEXT_ORDER) do emitBucket(key) end
    for key in pairs(buckets) do emitBucket(key) end -- any unforeseen context

    return yPos
end

function ns:UpdateAllTalents(specData, classToken, specKey)
    for _, h in ipairs(allTalentHeaders) do h:Hide() end
    for _, r in ipairs(allTalentRows) do r:Hide() end
    allTalentFallback:Hide()

    local archonAvailable = classToken and specKey
        and ns.GetArchonSpecData and ns.GetArchonSpecData(classToken, specKey) ~= nil

    local icyVeinsAvailable = classToken and specKey
        and ns.GetIcyVeinsTalentSpecData
        and ns:GetIcyVeinsTalentSpecData(classToken, specKey) ~= nil

    local source = (ns.GetEffectiveTalentSource and ns.GetEffectiveTalentSource()) or "wowhead"
    if source == "archon" and not archonAvailable then source = "wowhead" end
    if source == "icyveins" and not icyVeinsAvailable then source = "wowhead" end

    allTalentSourceDropdown:ClearAllPoints()
    allTalentSourceDropdown:SetPoint("TOPLEFT", allTalentContent, "TOPLEFT", 0, 0)
    allTalentSourceDropdown:SetPoint("TOPRIGHT", allTalentContent, "TOPRIGHT", 0, 0)
    -- PvP always appears for discoverability; RenderAllTalentsPvP shows
    -- the fallback line when no data exists for the spec.
    local sourceOpts = {
        { label = SOURCE_ICON_WOWHEAD, value = "wowhead" },
    }
    if archonAvailable then
        sourceOpts[#sourceOpts + 1] = { label = SOURCE_ICON_ARCHON, value = "archon" }
    end
    if icyVeinsAvailable then
        sourceOpts[#sourceOpts + 1] = { label = SOURCE_ICON_ICYVEINS, value = "icyveins" }
    end
    sourceOpts[#sourceOpts + 1] = { label = SOURCE_ICON_PVP, value = "pvp" }
    allTalentSourceDropdown:SetOptions(sourceOpts, source, function(picked)
        if ns.SetPersistedTalentSource then ns.SetPersistedTalentSource(picked) end
        ns:UpdatePanel()
    end)
    allTalentSourceDropdown:Show()

    local yPos = ALL_TALENT_TOGGLE_HEIGHT
    if source == "archon" then
        yPos = RenderAllTalentsArchon(classToken, specKey, yPos)
    elseif source == "icyveins" then
        yPos = RenderAllTalentsIcyVeins(classToken, specKey, yPos)
    elseif source == "pvp" then
        yPos = RenderAllTalentsPvP(classToken, specKey, yPos)
    else
        yPos = RenderAllTalentsWowhead(specData, yPos)
    end

    allTalentContent:SetHeight(yPos)
    allTalentContent:Show()
end
end -- talents tab construction block

-------------------------------------------------------------------------------
-- Section: Rotation
-------------------------------------------------------------------------------

-- Rotation section — extracted to Sections/Rotation.lua. Module owns the
-- step pool, context dropdown, and fallback line. Header collapse hooks
-- below.
local rotationSection, rotationHeader, rotationContent = ns.Sections.Rotation.InitPanel({
    parent = contentFrame,
    header = CreateSectionHeader,
})
local MAX_ROTATION_STEPS = 20
local currentRotationContext = nil
local lastRotationContentHeight = 0
local rotationSectionCollapsed = false

-------------------------------------------------------------------------------
-- Footer
-------------------------------------------------------------------------------

local footerSeparator = contentFrame:CreateTexture(nil, "ARTWORK")
footerSeparator:SetHeight(1)
footerSeparator:SetColorTexture(0.4, 0.4, 0.4, 0.5)

local footerFrame = CreateFrame("Frame", nil, contentFrame)
footerFrame:SetHeight(18)

local footerVersion = footerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
footerVersion:SetPoint("LEFT", 0, 0)
footerVersion:SetTextColor(0.4, 0.4, 0.4)
footerVersion:SetText("v" .. (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or GetAddOnMetadata(addonName, "Version") or "?"))

-- Wrapped in `do ... end` so the date helpers don't add to the main-chunk
-- local count — ClassCodex.lua sits close to Lua's 200-locals-per-function
-- ceiling and these helpers don't need to leak outward.
do
    -- Sits just right of the version string so the footer reads
    -- "v1.2.3 · <date>" as one left-aligned group.
    local footerDateButton = CreateFrame("Frame", nil, footerFrame)
    -- No x-offset; the separator's leading/trailing spaces (" · ") give an even
    -- gap on both sides of the dot.
    footerDateButton:SetPoint("LEFT", footerVersion, "RIGHT", 0, 0)
    footerDateButton:SetHeight(18)
    footerDateButton:EnableMouse(true)
    footerDateButton:Hide()

    local footerDate = footerDateButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footerDate:SetAllPoints(footerDateButton)
    footerDate:SetJustifyH("LEFT")
    footerDate:SetTextColor(0.4, 0.4, 0.4)

    local MONTH_ABBREV = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

    local function ParseISODate(iso)
        if type(iso) ~= "string" then return nil end
        local y, m, d = iso:match("^(%d+)-(%d+)-(%d+)$")
        if not y then return nil end
        return tonumber(y), tonumber(m), tonumber(d)
    end

    local function DaysSinceISO(iso)
        local y, m, d = ParseISODate(iso)
        if not y then return nil end
        local then_ = time({ year = y, month = m, day = d, hour = 12 })
        local diff = math.floor((time() - then_) / 86400)
        if diff < 0 then return 0 end
        return diff
    end

    local function FormatAbsoluteDate(iso)
        local y, m, d = ParseISODate(iso)
        if not y then return iso or "" end
        return string.format("%s %d, %d", MONTH_ABBREV[m] or tostring(m), d, y)
    end

    local function FormatRelativeDate(iso)
        local days = DaysSinceISO(iso)
        if not days then return iso or "" end
        if days == 0 then return L["footer.today"] end
        if days == 1 then return L["footer.yesterday"] end
        if days <= 6 then return L["footer.days_ago"]:format(days) end
        return FormatAbsoluteDate(iso)
    end

    -- Muted yellow/red so a stale stamp catches the eye without looking jarring
    -- against the soft-grey footer text the player sees on normal days.
    local function StaleColor(iso)
        local days = DaysSinceISO(iso)
        if not days then return 0.4, 0.4, 0.4 end
        if days >= 5 then return 0.78, 0.40, 0.40 end
        if days >= 2 then return 0.80, 0.66, 0.30 end
        return 0.4, 0.4, 0.4
    end

    local function RefreshFooterDate()
        local iso = ClassCodex_LastScrape
        if type(iso) ~= "string" or iso == "" then
            footerDate:SetText("")
            footerDateButton:Hide()
            return
        end
        footerDate:SetText(" · " .. FormatRelativeDate(iso))
        footerDate:SetTextColor(StaleColor(iso))
        footerDateButton:SetWidth(math.max(footerDate:GetStringWidth() + 4, 1))
        footerDateButton:Show()
    end

    footerDateButton:SetScript("OnEnter", function(self)
        local iso = ClassCodex_LastScrape
        if type(iso) ~= "string" or iso == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["footer.last_refreshed"]:format(FormatAbsoluteDate(iso)), 1, 0.82, 0)
        GameTooltip:AddLine(L["footer.data_refresh_hint"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    footerDateButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    RefreshFooterDate()
end

-- Source attribution lives at the right of the footer: the source feeding the
-- tab the player is currently looking at, click to copy its page link.
local footerSourceTag = ns.CreateSourceTag(footerFrame, { tooltipAbove = true })
footerSourceTag:SetPoint("RIGHT", footerFrame, "RIGHT", 0, 0)

local function UpdateFooterSource()
    -- ResolveAttribution reads per-spec saved vars by the compound key
    -- ("MAGE-frost"), so pass GetSpecKey() — GetSpecData's 3rd return is the
    -- bare slug ("frost") and would miss the bisSource / craftingContext lookup.
    local _sd, classToken = GetSpecData()
    local key, url = ns.ResolveAttribution(activeTab, classToken, GetSpecKey())
    footerSourceTag:SetSource(key, url)
end


-- Credits tab content — lives in Sections/Credits.lua.
ns.Sections.Credits.InitPanel({
    parent = contentFrame,
    contentWidth = PANEL_WIDTH - SIDE_TAB_W - CONTENT_INSET * 2 - 10,
})

-- About tab content — extracted to Sections/About.lua. The module owns the
-- title, description, slash hint, all action buttons, the button factory,
-- and the lazy separators.
do
    local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(addonName, "Version")
        or GetAddOnMetadata(addonName, "Version")
        or "?"
    ns.Sections.About.InitPanel({
        parent = contentFrame,
        contentWidth = PANEL_WIDTH - SIDE_TAB_W - CONTENT_INSET * 2 - 10,
        version = addonVersion,
    })
end

-------------------------------------------------------------------------------
-- Section Collapse
-------------------------------------------------------------------------------

statHeader:SetScript("OnClick", function()
    statSectionCollapsed = not statSectionCollapsed
    SetCollapsed(statContent, statHeader, statSectionCollapsed)
    if ClassCodexCharDB and ClassCodexCharDB.collapsed then
        ClassCodexCharDB.collapsed.stats = statSectionCollapsed
    end
    ns:LayoutPanel()
end)
talentHeader:SetScript("OnClick", function()
    talentSectionCollapsed = not talentSectionCollapsed
    SetCollapsed(talentContent, talentHeader, talentSectionCollapsed)
    if ClassCodexCharDB and ClassCodexCharDB.collapsed then
        ClassCodexCharDB.collapsed.talents = talentSectionCollapsed
    end
    ns:LayoutPanel()
end)
rotationHeader:SetScript("OnClick", function()
    rotationSectionCollapsed = not rotationSectionCollapsed
    SetCollapsed(rotationContent, rotationHeader, rotationSectionCollapsed)
    if ClassCodexCharDB and ClassCodexCharDB.collapsed then
        ClassCodexCharDB.collapsed.rotation = rotationSectionCollapsed
    end
    ns:LayoutPanel()
end)

-------------------------------------------------------------------------------
-- Collapse state restore (extracted to avoid upvalue pressure on UpdatePanel)
-------------------------------------------------------------------------------

local function RestoreCollapseState()
    local saved = ClassCodexCharDB and ClassCodexCharDB.collapsed
    if saved then
        statSectionCollapsed = saved.stats or false
        talentSectionCollapsed = saved.talents or false
        rotationSectionCollapsed = saved.rotation or false
        SetCollapsed(statContent, statHeader, statSectionCollapsed)
        SetCollapsed(talentContent, talentHeader, talentSectionCollapsed)
        SetCollapsed(rotationContent, rotationHeader, rotationSectionCollapsed)
    end
end

-------------------------------------------------------------------------------
-- Late ns exports — the scaffold/constant exports landed earlier so the
-- Section InitPanel calls could see them; here we add the things that
-- depend on locals defined later in this file (GetSpecData,
-- GetActiveHeroTalentName, isFloating, activeTab, etc.).
-------------------------------------------------------------------------------

ns.panel = panel
ns.GetClassAndSpec = GetClassAndSpec
ns.GetSpecKey = GetSpecKey
ns.GetSpecData = GetSpecData
ns.GetPerSpecState = GetPerSpecState
ns.GetActiveHeroTalentName = GetActiveHeroTalentName
ns.isFloating = function() return isFloating end
ns.getActiveTab = function() return activeTab end
ns.setActiveTab = function(tab) activeTab = tab; UpdateTabAppearance() end
ns.HERO_TALENT_ATLAS = HERO_TALENT_ATLAS
ns.SPEC_KEYS = SPEC_KEYS

-------------------------------------------------------------------------------
-- Main Update
-------------------------------------------------------------------------------

local currentHeroTalent = nil

function ns:UpdatePanel()
    cachedRanks = nil -- invalidate stat rank cache on hero/context change
    local specData, classToken, specKey = GetSpecData()
    if not specData then panel:Hide(); return end

    RestoreCollapseState()

    local panelWidth = GetPanelWidth()
    panel:SetWidth(panelWidth)

    -- Spec icon
    local icon = GetSpecIcon()
    if icon then specIcon:SetTexture(icon); specIcon:Show() else specIcon:Hide() end

    -- Hero talent
    local heroOptions = GetHeroTalentOptions(specData)
    local showHero = #heroOptions > 1
    local perSpec = GetPerSpecState()

    if perSpec and perSpec.heroTalent then
        currentHeroTalent = perSpec.heroTalent
    else
        local detected = GetActiveHeroTalentName()
        if detected then
            local matched = false
            for _, opt in ipairs(heroOptions) do
                if opt:lower() == detected:lower() then
                    currentHeroTalent = opt
                    matched = true
                    break
                end
            end
            if not matched then currentHeroTalent = heroOptions[1] or "All" end
        else
            currentHeroTalent = heroOptions[1] or "All"
        end
    end

    -- Subheader (hero dropdown only)
    LayoutSubheader(showHero)
    if not showHero then
        subheaderFrame:SetHeight(1)
    else
        subheaderFrame:SetHeight(SUBHEADER_HEIGHT)
    end
    if showHero then
        -- Wrap each hero option with its atlas icon so the closed-state
        -- and the menu both show the icon inline (replaces the old
        -- heroIcon texture child that the WowStyle1Dropdown can't host).
        local heroOpts = {}
        for _, hero in ipairs(heroOptions) do
            local atlas = HERO_TALENT_ATLAS[hero]
            local label = atlas and ("|A:" .. atlas .. ":14:14|a  " .. hero) or hero
            heroOpts[#heroOpts + 1] = { label = label, value = hero }
        end
        heroDropdown:SetOptions(heroOpts, currentHeroTalent, function(selected)
            local perSpec = GetPerSpecState()
            if not perSpec then return end
            perSpec.heroTalent = selected
            ns:UpdatePanel()
        end)
    end

    -- Stats — context resolution stays here (uses panel-internal helpers),
    -- delegated to Sections/Stats.lua for the actual render.
    local statCtxOptions = GetStatContextOptions(specData, currentHeroTalent)
    if #statCtxOptions > 0 then
        if perSpec and perSpec.statContext then
            local found = false
            for _, c in ipairs(statCtxOptions) do
                if c == perSpec.statContext then found = true; break end
            end
            currentStatContext = found and perSpec.statContext or statCtxOptions[1]
        else
            currentStatContext = statCtxOptions[1]
        end
    else
        currentStatContext = nil
    end
    local statLookupCtx = currentStatContext or "General"
    local priority = FindMatch(specData.priorities, currentHeroTalent, statLookupCtx)
    lastStatRowCount = ns.Sections.Stats.RenderPanel({
        contextOptions = statCtxOptions,
        currentContext = currentStatContext,
        priorityStats  = priority and priority.stats or nil,
        rankColors     = RANK_COLORS,
        onCtxChange    = function(picked)
            local ps = GetPerSpecState()
            if not ps then return end
            ps.statContext = picked
            ns:UpdatePanel()
        end,
    })

    -- Talents Guide-tab preview — Section module owns the render. We resolve
    -- the build list + active-talent signature here (panel-internal helpers)
    -- and pass them in.
    local emptyText, noneText, builds
    if not specData.talents or #specData.talents == 0 then
        emptyText = L["empty.no_builds_details"]
    else
        builds = GetAllTalentBuildsForHero(specData, currentHeroTalent)
        if #builds == 0 then
            noneText = L["empty.no_builds_for"]:format(currentHeroTalent)
        end
    end
    lastTalentContentHeight = ns.Sections.Talents.RenderPanel({
        builds            = builds,
        activeTalentBits  = ns.GetActiveTalentSignature(),
        fallbackEmptyText = emptyText,
        fallbackNoneText  = noneText,
        onCopy = function(t)
            ShowCopyPopup(t.exportString, talentSection)
        end,
        onApply = function(self, t)
            local rawLabel = t.context or "Build"
            if t.buildLabel and t.buildLabel ~= "" then
                rawLabel = rawLabel .. " — " .. t.buildLabel
            end
            local loadoutLabel = currentHeroTalent and currentHeroTalent ~= "All"
                and (currentHeroTalent .. " " .. rawLabel) or rawLabel
            local ok, err = ns.ApplyTalentExportString(t.exportString, loadoutLabel)
            if not ok then
                self.icon:SetVertexColor(1, 0.2, 0.2)
                print("|cff00ccffClass Codex:|r " .. (err or "Failed to apply talents"))
            else
                self.icon:SetVertexColor(1, 0.8, 0)
            end
            C_Timer.After(1.5, function()
                if self.icon then
                    self.icon:SetDesaturated(true)
                    self.icon:SetVertexColor(0.7, 0.7, 0.7)
                end
            end)
        end,
    })

    -- Rotation — context resolution stays here, render delegated to module.
    local rotCtxOptions = GetRotationContextOptions(specData, currentHeroTalent)
    local perSpecRot = GetPerSpecState()
    if perSpecRot and perSpecRot.rotationContext then
        local found = false
        for _, c in ipairs(rotCtxOptions) do
            if c == perSpecRot.rotationContext then found = true; break end
        end
        currentRotationContext = found and perSpecRot.rotationContext or (rotCtxOptions[1] or "General")
    else
        currentRotationContext = rotCtxOptions[1] or "General"
    end

    local rotation = FindRotationByContext(specData.rotation, currentHeroTalent, currentRotationContext)
    lastRotationContentHeight = ns.Sections.Rotation.RenderPanel({
        contextOptions = rotCtxOptions,
        currentContext = currentRotationContext,
        rotation       = rotation,
        heroTalent     = currentHeroTalent,
        hasAnyRotation = specData.rotation and #specData.rotation > 0,
        textAreaWidth  = GetPanelWidth() - CONTENT_INSET * 2 - 42,
        helpers = {
            shouldShow = ShouldShowStep,
            strip      = StripConditionPrefix,
            getIcon    = GetStepSpellIcon,
            format     = FormatRotationStep,
        },
        onCtxChange    = function(picked)
            local ps = GetPerSpecState()
            if not ps then return end
            ps.rotationContext = picked
            ns:UpdatePanel()
        end,
    })

    -- Talents tab: grouped-by-context layout showing all builds
    if activeTab == "talents" then
        ns:UpdateAllTalents(specData, classToken, specKey)
    else
        allTalentContent:Hide()
    end

    -- Gearing sections
    if ns.UpdateGearingSections then ns:UpdateGearingSections() end

    -- Tab visibility:
    --   guide → priority list + talents + rotation
    --   stats → just the live target bars
    --   other → everything hidden
    if activeTab == "guide" then
        subheaderFrame:Show()
        statTargets.section:Hide()
    elseif activeTab == "stats" then
        statSection:Hide() -- priority list lives on Guide; no duplication here
        talentSection:Hide()
        rotationSection:Hide()
        subheaderFrame:SetHeight(1)
        subheaderFrame:Hide()
        local statRowCount = ns.Sections.StatTargets.RenderPanel({
            classToken = classToken,
            specKey    = specKey,
            refresh    = function() ns:UpdatePanel() end,
        })
        if statRowCount > 0 then
            statTargets.section:Show()
        else
            statTargets.section:Hide()
        end
    else
        statSection:Hide()
        statTargets.section:Hide()
        talentSection:Hide()
        rotationSection:Hide()
        subheaderFrame:SetHeight(1)
        subheaderFrame:Hide()
    end
    -- GearingSections.lua handles its own tab visibility via ns.getActiveTab()

    -- Hide sections disabled for current mode + hide empty tabs
    if ClassCodexDB then
        local prefix = isFloating and "floatShow" or "dockShow"
        if activeTab == "guide" then
            if not ClassCodexDB[prefix .. "Stats"] then statSection:Hide() end
            if not ClassCodexDB[prefix .. "Talents"] then talentSection:Hide() end
            if not ClassCodexDB[prefix .. "Rotation"] then rotationSection:Hide() end
        elseif activeTab == "stats" then
            if not ClassCodexDB[prefix .. "StatTargets"] then statTargets.section:Hide() end
        elseif activeTab == "talents" then
            if not ClassCodexDB[prefix .. "Talents"] then allTalentContent:Hide() end
        end
        activeTab = ns:UpdateSideTabVisibility(prefix, activeTab)
    end

    ns:LayoutPanel()
end

-------------------------------------------------------------------------------
-- Layout
-------------------------------------------------------------------------------

function ns:LayoutPanel()
    local y = 0

    -- Tab title
    local titleLabel = TAB_TITLE_LABELS[activeTab]
    if titleLabel then
        tabTitleText:SetText(titleLabel)
        tabTitle:Show()
        tabTitle:ClearAllPoints()
        tabTitle:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, y)
        tabTitle:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET, 0)
        statInfoBtn:SetShown(activeTab == "guide")
        craftingInfoBtn:SetShown(activeTab == "crafting")
        craftingOptionsBtn:SetShown(activeTab == "crafting")
        y = y - SECTION_HEADER_HEIGHT
    else
        tabTitle:Hide()
    end

    -- Subheader (only shown on guide tab). No leading gap so the
    -- dropdowns sit flush against the tab title — matches the Stats tab
    -- where the context dropdown is immediately below the title.
    subheaderFrame:ClearAllPoints()
    if subheaderFrame:IsShown() then
        subheaderFrame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, y)
        subheaderFrame:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET, 0)
        y = y - SUBHEADER_HEIGHT - 2
    end

    -- Helper to layout a section
    local function LayoutSection(section, collapsed, contentHeight)
        if not section:IsShown() then return end
        section:ClearAllPoints()
        section:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, y)
        section:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET, 0)
        local sectionHeight = SECTION_HEADER_HEIGHT
        if not collapsed then
            sectionHeight = sectionHeight + contentHeight + 4
        end
        section:SetHeight(sectionHeight)
        y = y - sectionHeight - 3
    end

    -- Stat section: height comes from the Section module (rows + optional
    -- context dropdown). Section module handles its own row counting.
    local statContentHeight = 0
    if statSection:IsShown() and not statSectionCollapsed then
        statContentHeight = ns.Sections.Stats.GetPanelContentHeight(lastStatRowCount)
    end
    LayoutSection(statSection, statSectionCollapsed, statContentHeight)

    -- Stat targets section — height computed by Sections/StatTargets.lua.
    if statTargets.section:IsShown() then
        local h = ns.Sections.StatTargets.GetPanelHeight()
        statTargets.section:ClearAllPoints()
        statTargets.section:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, y)
        statTargets.section:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET, 0)
        statTargets.section:SetHeight(h)
        y = y - h - 3
    end

    -- Talent section — height computed by Sections/Talents.lua during
    -- RenderPanel and stored in lastTalentContentHeight.
    local talentContentHeight = 0
    if talentSection:IsShown() and not talentSectionCollapsed then
        talentContentHeight = lastTalentContentHeight
        if talentContentHeight == 0 then talentContentHeight = 20 end
    end
    LayoutSection(talentSection, talentSectionCollapsed, talentContentHeight)

    -- Rotation section
    local rotationContentHeight = 0
    if rotationSection:IsShown() and not rotationSectionCollapsed then
        if ns.Sections.Rotation.IsPanelCtxDropdownShown() then
            rotationContentHeight = rotationContentHeight + 30
        end
        rotationContentHeight = rotationContentHeight + lastRotationContentHeight
    end
    LayoutSection(rotationSection, rotationSectionCollapsed, rotationContentHeight)

    -- Talents tab: all-builds grouped content
    if allTalentContent:IsShown() then
        allTalentContent:ClearAllPoints()
        allTalentContent:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", CONTENT_INSET, y)
        allTalentContent:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET, 0)
        y = y - allTalentContent:GetHeight() - 8
    end

    -- Gearing sections layout
    if ns.LayoutGearingSections then
        y = ns:LayoutGearingSections(y)
    end

    -- Credits tab — Sections/Credits.lua owns layout when active.
    if activeTab == "supporters" then
        y = ns.Sections.Credits.LayoutPanel(y, { parent = contentFrame, inset = CONTENT_INSET })
    else
        ns.Sections.Credits.HidePanel()
    end

    -- About tab — Sections/About.lua owns layout when active.
    local yBeforeAbout = y
    if activeTab == "about" then
        y = ns.Sections.About.LayoutPanel(y, { parent = contentFrame, inset = CONTENT_INSET })
    else
        ns.Sections.About.HidePanel()
    end

    -- Calculate minimum panel height
    local contentBottom = math.abs(y)
    local footerHeight = 24 + 3 -- separator + footer
    local panelOverhead = 24 + 2 + PANEL_PADDING + 2

    -- Minimum height: enough for all side + bottom tabs to be visible
    -- Side tabs are now a single top-anchored stack (top tabs → section gap → bottom tabs).
    local SIDE_TAB_SECTION_GAP = 12
    local tabMinHeight = 40 + #sideTabs * (SIDE_TAB_H + SIDE_TAB_GAP) + SIDE_TAB_SECTION_GAP + #bottomTabs * (SIDE_TAB_H + SIDE_TAB_GAP) + 10
    local minPanelHeight = tabMinHeight
    -- When docked, also match CharacterFrame height
    if not isFloating and CharacterFrame and CharacterFrame:IsShown() then
        local charHeight = CharacterFrame:GetHeight()
        if charHeight and charHeight > minPanelHeight then minPanelHeight = charHeight end
    end

    local naturalHeight = contentBottom + footerHeight + panelOverhead
    local panelHeight = math.max(naturalHeight, minPanelHeight)
    local contentHeight = panelHeight - panelOverhead

    -- About tab: when the panel is taller than its content (docked, matching the
    -- character frame), bottom-align the section block by re-laying it out with
    -- the leftover space inserted under the description, so the sections sit
    -- flush above the footer instead of leaving a gap at the bottom.
    if activeTab == "about" and panelHeight > naturalHeight then
        ns.Sections.About.LayoutPanel(yBeforeAbout, {
            parent = contentFrame, inset = CONTENT_INSET, gap = panelHeight - naturalHeight,
        })
    end

    if isMinimized then
        contentFrame:Hide()
        panel:SetHeight(36)
        for _, tab in ipairs(allTabs) do tab:Hide() end
    else
        -- Show all tabs first, then re-apply mode visibility and re-layout.
        for _, tab in ipairs(bottomTabs) do tab:Show() end
        for _, tab in ipairs(sideTabs) do tab:Show() end
        if ClassCodexDB then
            local prefix = isFloating and "floatShow" or "dockShow"
            activeTab = ns:UpdateSideTabVisibility(prefix, activeTab)
        end
        -- Re-layout visible side tabs to remove gaps
        local prevTab = nil
        for _, tab in ipairs(sideTabs) do
            if tab:IsShown() then
                tab:ClearAllPoints()
                if prevTab then
                    tab:SetPoint("TOPLEFT", prevTab, "BOTTOMLEFT", 0, -SIDE_TAB_GAP)
                else
                    tab:SetPoint("TOPLEFT", panel, "TOPRIGHT", -1, -40)
                end
                prevTab = tab
            end
        end
        -- Bottom side tabs (About, Credits):
        --   Floating: anchor to the last top tab so they don't drift down when the
        --             panel expands to fit tall content.
        --   Docked:   anchor to panel bottom (CharacterFrame is fixed-height, so they
        --             sit near the end of the frame as expected).
        if isFloating then
            local gap = SIDE_TAB_SECTION_GAP
            for _, tab in ipairs(bottomTabs) do
                tab:ClearAllPoints()
                if prevTab then
                    tab:SetPoint("TOPLEFT", prevTab, "BOTTOMLEFT", 0, -gap)
                else
                    tab:SetPoint("TOPLEFT", panel, "TOPRIGHT", -1, -40)
                end
                prevTab = tab
                gap = SIDE_TAB_GAP
            end
        else
            -- bottomTabs order is [supporters.tab, aboutTab]; About sits at the bottom
            aboutTab:ClearAllPoints()
            aboutTab:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", -1, 30)
            supporters.tab:ClearAllPoints()
            supporters.tab:SetPoint("BOTTOMLEFT", aboutTab, "TOPLEFT", 0, SIDE_TAB_GAP)
        end
        contentFrame:Show()
        contentFrame:SetHeight(contentHeight)
        panel:SetHeight(panelHeight)

        -- Footer always at the bottom of content
        footerSeparator:ClearAllPoints()
        footerSeparator:SetPoint("BOTTOMLEFT", contentFrame, "BOTTOMLEFT", CONTENT_INSET + 2, 24)
        footerSeparator:SetPoint("RIGHT", contentFrame, "RIGHT", -CONTENT_INSET - 2, 0)

        footerFrame:ClearAllPoints()
        footerFrame:SetPoint("BOTTOMLEFT", contentFrame, "BOTTOMLEFT", PANEL_PADDING, 2)
        footerFrame:SetPoint("RIGHT", contentFrame, "RIGHT", -PANEL_PADDING, 0)

        UpdateFooterSource()
    end
end

-------------------------------------------------------------------------------
-- Float / Dock
-------------------------------------------------------------------------------

-- Returns the highest-priority registered dock host that is currently shown,
-- or nil if none are visible.
local function GetActiveDockHost()
    for _, host in ipairs(dockHosts) do
        local frame = host.frame
        if frame and frame.IsShown and frame:IsShown() then
            return host
        end
    end
end

-- Anchor the docked panel next to the active host frame. PaperDollFrame is the
-- default high-priority host; external UI suites can register their own.
local function AnchorDockedPanel()
    if isFloating then return end
    local host = GetActiveDockHost()
    if not host then return end
    local xDelta = 0
    if ClassCodexDB and ClassCodexDB.widgetOffsetX then
        xDelta = ClassCodexDB.widgetOffsetX - WIDGET_DEFAULT_OFFSET_X
    end
    panel:ClearAllPoints()
    panel:SetPoint(host.point, host.frame, host.relativePoint, host.xOffset + xDelta, host.yOffset)
end

local function DockPanel()
    isFloating = false
    -- Auto-expand if minimized when docking
    if isMinimized then
        isMinimized = false
        minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
    end
    minimizeBtn:Hide()
    panel:SetMovable(false)
    local host = GetActiveDockHost()
    panel:SetParent((host and host.parent) or CharacterFrame)
    AnchorDockedPanel()
    panel:SetFrameStrata("DIALOG")
    if ClassCodexCharDB then ClassCodexCharDB.floating = false end
end

local function FloatPanel()
    isFloating = true
    panel:SetParent(UIParent)
    panel:SetFrameStrata("HIGH")
    panel:SetMovable(true)
    if ClassCodexCharDB and ClassCodexCharDB.floatX and ClassCodexCharDB.floatY then
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ClassCodexCharDB.floatX, ClassCodexCharDB.floatY)
    else
        panel:ClearAllPoints()
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if ClassCodexCharDB then ClassCodexCharDB.floating = true end
    minimizeBtn:Show()
    -- Restore minimized state when floating
    if ClassCodexCharDB and ClassCodexCharDB.minimized then
        isMinimized = true
        minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-ExpandButton-Up")
    end
end

-------------------------------------------------------------------------------
-- Dock Host API — for UI suites that replace the Blizzard character window.
-------------------------------------------------------------------------------
-- The docked panel anchors to whichever registered host is currently shown
-- (highest priority wins). Built-ins:
--   PaperDollFrame  priority 10  (default Blizzard content area)
--   CharacterFrame  priority  0  (fallback for non-PaperDoll tabs)
-- GW2_UI's GwCharacterWindow is auto-registered at PLAYER_ENTERING_WORLD with
-- priority 50; calling RegisterDockHost again just overwrites that entry.
--
-- Integrating a new UI suite:
--   1. Once your replacement character window frame exists (typically during
--      your addon init or on first show), call:
--          ClassCodex.RegisterDockHost(MyCharWindow, { priority = 50 })
--      We auto-hook OnShow/OnHide on the registered frame, so the docked
--      panel and widget button appear/disappear with your window — no extra
--      hooking needed on your side.
--   2. To clean up if your suite is disabled, call
--          ClassCodex.UnregisterDockHost(MyCharWindow)
--   3. ClassCodex.RefreshDock() is available if you ever need to nudge the
--      panel to re-anchor without a show/hide cycle.
--
-- opts (all optional):
--   priority      number  default 0    higher wins when multiple hosts shown
--   parent        Frame   default frame frame to SetParent panel to (use the
--                                       enclosing window if your host is
--                                       nested, e.g. a content sub-frame)
--   point         string  default "TOPLEFT"   anchor point on the panel
--   relativePoint string  default "TOPRIGHT"  anchor point on the host frame
--   xOffset       number  default -2          x offset for SetPoint
--   yOffset       number  default 0           y offset for SetPoint
--
-- Things to verify when integrating:
--   - The frame you pass must be the visible/sized window (its IsShown/edges
--     are what we read). Don't pass a hidden parent or a 0-sized container.
--   - Set priority above 10 to win over PaperDollFrame, below 10 to be a
--     fallback only when PaperDollFrame isn't shown.
function ns.RegisterDockHost(frame, opts)
    if type(frame) ~= "table" then return end
    opts = opts or {}
    local host
    for _, h in ipairs(dockHosts) do
        if h.frame == frame then host = h; break end
    end
    local isNew = not host
    host = host or { frame = frame }
    host.parent        = opts.parent or frame
    host.point         = opts.point or "TOPLEFT"
    host.relativePoint = opts.relativePoint or "TOPRIGHT"
    host.xOffset       = opts.xOffset or -2
    host.yOffset       = opts.yOffset or 0
    host.priority      = opts.priority or 0
    if isNew then
        table.insert(dockHosts, host)
        if ns.InstallHostHooks then ns.InstallHostHooks(host) end
    end
    table.sort(dockHosts, function(a, b) return a.priority > b.priority end)
    if not isFloating and panel and panel:IsShown() then DockPanel() end
end

function ns.UnregisterDockHost(frame)
    for i, h in ipairs(dockHosts) do
        if h.frame == frame then
            table.remove(dockHosts, i)
            if not isFloating and panel and panel:IsShown() then DockPanel() end
            return
        end
    end
end

-- Re-runs dock anchoring; call from a host frame's OnShow/OnHide if its show
-- state isn't already tied to PaperDollFrame's lifecycle.
function ns.RefreshDock()
    if not isFloating and panel and panel:IsShown() then
        AnchorDockedPanel()
        ns:LayoutPanel()
    end
end

-- Built-in dock hosts: PaperDollFrame is the active content area when the
-- character pane is open; CharacterFrame is the fallback (slightly different
-- offset to account for its visual chrome).
ns.RegisterDockHost(PaperDollFrame, { priority = 10, parent = CharacterFrame, xOffset = -2, yOffset = 0 })
ns.RegisterDockHost(CharacterFrame, { priority = 0, parent = CharacterFrame, xOffset = -2, yOffset = -1 })

-- Public global namespace for cross-addon integration (e.g. UI suites that want
-- to register their character window as a dock host).
_G.ClassCodex = _G.ClassCodex or {}
_G.ClassCodex.RegisterDockHost   = ns.RegisterDockHost
_G.ClassCodex.UnregisterDockHost = ns.UnregisterDockHost
_G.ClassCodex.RefreshDock        = ns.RefreshDock

local function SectionVisibilityOptions()
    -- Built at menu-open time so the dock/float prefix reflects the
    -- live mode (toggling Float while the menu is open is rare but
    -- handled cleanly by reopening; the captured prefix is fine for
    -- one menu session).
    local prefix = isFloating and "float" or "dock"
    local options = {
        { key = prefix .. "ShowStats",    label = L["section.stat_priority"] },
        { key = prefix .. "ShowTalents",  label = L["section.talents"] },
        { key = prefix .. "ShowRotation", label = L["section.rotation"] },
    }
    local gearingOpts = isFloating and ns.gearingFloatOptions or ns.gearingDockOptions
    if gearingOpts then
        for _, opt in ipairs(gearingOpts) do options[#options + 1] = opt end
    end
    return options
end

-- Width presets used by the cog menu's Width submenu. Selecting a
-- preset writes the numeric value directly into ClassCodexDB.panelWidth,
-- which is the same SavedVar the Settings-panel slider mutates — so
-- the two paths always agree on the current width.
local WIDTH_PRESETS = {
    { key = "narrow",     value = 280 },
    { key = "default",    value = PANEL_WIDTH }, -- 312
    { key = "wide",       value = 380 },
    { key = "extra_wide", value = 460 },
}

pinBtn:SetScript("OnClick", function(_, _)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(pinBtn, function(_, root)
        root:CreateTitle("Class Codex")

        root:CreateButton(
            isFloating and L["title_bar.menu.dock"] or L["title_bar.menu.float"],
            function()
                if isFloating then DockPanel() else FloatPanel() end
                ns:UpdatePanel()
                return MenuResponse.Close
            end
        )

        root:CreateDivider()

        local widthMenu = root:CreateButton(L["title_bar.menu.width"])
        for _, preset in ipairs(WIDTH_PRESETS) do
            widthMenu:CreateRadio(
                L["title_bar.menu.width_" .. preset.key],
                function() return GetPanelWidth() == preset.value end,
                function()
                    if not ClassCodexDB then return end
                    ClassCodexDB.panelWidth = preset.value
                    if panel:IsShown() then ns:UpdatePanel() end
                    return MenuResponse.Refresh
                end
            )
        end

        local sectionsMenu = root:CreateButton(L["title_bar.menu.sections"])
        for _, opt in ipairs(SectionVisibilityOptions()) do
            sectionsMenu:CreateCheckbox(
                opt.label,
                function() return ClassCodexDB[opt.key] ~= false end,
                function()
                    ClassCodexDB[opt.key] = not (ClassCodexDB[opt.key] ~= false)
                    if panel:IsShown() then ns:UpdatePanel() end
                    return MenuResponse.Refresh
                end
            )
        end

        root:CreateDivider()

        root:CreateButton(L["title_bar.menu.all_settings"], function()
            if ns.OpenSettings then ns.OpenSettings() end
            return MenuResponse.Close
        end)
    end)
end)

minimizeBtn:SetScript("OnClick", function()
    isMinimized = not isMinimized
    if ClassCodexCharDB then ClassCodexCharDB.minimized = isMinimized end
    minimizeBtn:SetNormalTexture(isMinimized
        and "Interface\\Buttons\\UI-Panel-ExpandButton-Up"
        or "Interface\\Buttons\\UI-Panel-CollapseButton-Up")
    ns:LayoutPanel()
end)

-- Rotation dropdown wiring lives in Sections/Rotation.lua's RenderPanel.

-- heroDropdown wiring lives in UpdatePanel via :SetOptions; the
-- WowStyle1Dropdown template owns the click + popup itself.

-- Stat-priority dropdown wiring lives in Sections/Stats.lua's RenderPanel.


-------------------------------------------------------------------------------
-- Widget Button (deferred until PaperDollFrame exists)
-------------------------------------------------------------------------------

local widgetContainer, widgetBtn, widgetIcon, activeGlow

local function ApplyWidgetPosition()
    if not widgetContainer or not ClassCodexDB then return end
    local host = GetActiveDockHost()
    local anchor = (host and host.frame) or PaperDollFrame
    local x = ClassCodexDB.widgetOffsetX or WIDGET_DEFAULT_OFFSET_X
    local y = ClassCodexDB.widgetOffsetY or WIDGET_DEFAULT_OFFSET_Y
    if widgetContainer:GetParent() ~= anchor then
        widgetContainer:SetParent(anchor)
    end
    widgetContainer:ClearAllPoints()
    widgetContainer:SetPoint("CENTER", anchor, "TOPRIGHT", x, y)
    if not isFloating and panel and panel:IsShown() then
        AnchorDockedPanel()
    end
end
ns.ApplyWidgetPosition = ApplyWidgetPosition

local function RefreshWidgetTooltip()
    if not widgetBtn or not GameTooltip:IsOwned(widgetBtn) then return end
    widgetBtn:GetScript("OnEnter")(widgetBtn)
end
ns.RefreshWidgetTooltip = RefreshWidgetTooltip

local function SetupWidgetButton()
    if widgetContainer then return end -- already set up

    widgetContainer = CreateFrame("Frame", nil, PaperDollFrame)
    widgetContainer:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    widgetContainer:SetFrameStrata("TOOLTIP")
    widgetContainer:SetMovable(true)
    widgetContainer:SetClampedToScreen(true)

    widgetBtn = CreateFrame("Button", "ClassCodexWidgetButton", widgetContainer)
    widgetBtn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    widgetBtn:SetPoint("CENTER")
    widgetBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    widgetBtn:RegisterForDrag("LeftButton")

    widgetIcon = widgetBtn:CreateTexture(nil, "ARTWORK")
    widgetIcon:SetSize(BUTTON_SIZE - 8, BUTTON_SIZE - 8)
    widgetIcon:SetPoint("CENTER")
    widgetIcon:SetAtlas("mechagon-projects")
    widgetIcon:SetDesaturated(true)
    widgetIcon:SetVertexColor(0.85, 0.85, 0.85)

    local widgetHighlight = widgetBtn:CreateTexture(nil, "HIGHLIGHT")
    widgetHighlight:SetAllPoints(widgetIcon)
    widgetHighlight:SetAtlas("mechagon-projects")
    widgetHighlight:SetAlpha(0.4)
    widgetHighlight:SetBlendMode("ADD")

    activeGlow = widgetBtn:CreateTexture(nil, "OVERLAY")
    activeGlow:SetSize(BUTTON_SIZE + 4, BUTTON_SIZE + 4)
    activeGlow:SetPoint("CENTER")
    activeGlow:SetAtlas("bags-glow-flash")
    activeGlow:SetVertexColor(0.3, 0.6, 1.0, 0.6)
    activeGlow:SetBlendMode("ADD")
    activeGlow:Hide()

    local function IsLocked()
        return ClassCodexDB and ClassCodexDB.widgetLocked
    end

    widgetBtn:SetScript("OnEnter", function(self)
        widgetIcon:SetDesaturated(false)
        widgetIcon:SetVertexColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Class Codex", 1, 1, 1)
        GameTooltip:AddLine(L["character_pane.click_to_toggle"], 0.7, 0.7, 0.7)
        if IsLocked() then
            GameTooltip:AddLine(L["character_pane.position_locked"], 0.55, 0.55, 0.55)
        else
            GameTooltip:AddLine(L["character_pane.shift_drag_hint"], 0.45, 0.75, 0.45)
        end
        GameTooltip:Show()
    end)
    widgetBtn:SetScript("OnLeave", function()
        widgetIcon:SetDesaturated(true)
        widgetIcon:SetVertexColor(0.85, 0.85, 0.85)
        GameTooltip:Hide()
    end)

    widgetBtn:SetScript("OnDragStart", function()
        if IsLocked() or not IsShiftKeyDown() then return end
        widgetContainer:StartMoving()
        widgetContainer.isMoving = true
    end)

    widgetBtn:SetScript("OnDragStop", function()
        if not widgetContainer.isMoving then return end
        widgetContainer:StopMovingOrSizing()
        widgetContainer.isMoving = false
        local cx, cy = widgetContainer:GetCenter()
        local anchor = widgetContainer:GetParent() or PaperDollFrame
        local right, top = anchor:GetRight(), anchor:GetTop()
        if cx and cy and right and top then
            ClassCodexDB.widgetOffsetX = math.floor(cx - right + 0.5)
            ClassCodexDB.widgetOffsetY = math.floor(cy - top + 0.5)
        end
        ApplyWidgetPosition()
        RefreshWidgetTooltip()
    end)

    widgetBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if IsLocked() or not IsShiftKeyDown() then return end
            ClassCodexDB.widgetOffsetX = WIDGET_DEFAULT_OFFSET_X
            ClassCodexDB.widgetOffsetY = WIDGET_DEFAULT_OFFSET_Y
            ApplyWidgetPosition()
            return
        end
        if IsShiftKeyDown() and not IsLocked() then return end -- swallow shift-clicks used for repositioning
        if panel:IsShown() and not isFloating then
            panel:Hide()
            ClassCodexCharDB.panelOpen = false
            activeGlow:Hide()
        else
            if not isFloating then DockPanel() end
            ns:UpdatePanel()
            FadeIn(panel)
            ClassCodexCharDB.panelOpen = true
            activeGlow:Show()
        end
    end)

    -- Shared show/hide handlers usable by any registered dock host
    -- (PaperDollFrame, GW2_UI's GwCharacterWindow, etc.)
    local function OnAnyHostShow()
        local ok, err = pcall(function()
            ApplyWidgetPosition()
            if not isFloating then
                DockPanel()
                if ClassCodexCharDB and ClassCodexCharDB.panelOpen then
                    ns:UpdatePanel()
                    FadeIn(panel)
                    if activeGlow then activeGlow:Show() end
                elseif activeGlow then
                    activeGlow:Hide()
                end
                -- Deferred re-anchor: addons like Chonky reposition CharacterFrame
                -- children in a hooksecurefunc on Show that runs after this hook
                C_Timer.After(0, function()
                    if not isFloating and panel:IsShown() then
                        AnchorDockedPanel()
                        ns:LayoutPanel()
                    end
                end)
            end
        end)
        if not ok then
            print("|cffff0000Class Codex:|r Panel error: " .. tostring(err))
        end
    end

    local function OnAnyHostHide()
        if not isFloating then
            panel:Hide()
            copyPopup:Hide()
        end
        if activeGlow then activeGlow:Hide() end
    end

    PaperDollFrame:HookScript("OnShow", OnAnyHostShow)
    PaperDollFrame:HookScript("OnHide", OnAnyHostHide)

    -- Re-layout when CharacterFrame is resized (e.g. by Chonky Character Sheet)
    -- so the panel height stays in sync.
    CharacterFrame:HookScript("OnSizeChanged", function()
        if not isFloating and panel:IsShown() then
            AnchorDockedPanel()
            ns:LayoutPanel()
        end
    end)

    -- Install hooks on external dock hosts (e.g. GW2_UI's GwCharacterWindow)
    -- so the panel and widget appear/disappear with their character window.
    function ns.InstallHostHooks(host)
        if host._hooked then return end
        if host.frame == PaperDollFrame or host.frame == CharacterFrame then return end
        host._hooked = true
        host.frame:HookScript("OnShow", OnAnyHostShow)
        host.frame:HookScript("OnHide", OnAnyHostHide)
    end
    -- Catch any external hosts registered before SetupWidgetButton ran.
    for _, host in ipairs(dockHosts) do ns.InstallHostHooks(host) end

end

-------------------------------------------------------------------------------
-- Addon Compartment
-------------------------------------------------------------------------------

function ClassCodex_OnAddonCompartmentClick()
    if ns.OpenCompendium then
        ns:OpenCompendium()
    end
end

function ClassCodex_OnAddonCompartmentEnter(_, menuButtonFrame)
    local ver = C_AddOns.GetAddOnMetadata(addonName, "Version") or ""
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Class Codex v" .. ver, 1, 1, 1)
    GameTooltip:AddLine("Click to open Compendium", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function ClassCodex_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- Tooltip Rank Badges
-------------------------------------------------------------------------------

-- Map localized stat names → English data keys for tooltip matching.
-- Uses WoW global strings so tooltips work in every locale (ko, zh, de, …).
-- Some locales (e.g. deDE) use a different word in STAT_* (character sheet)
-- vs ITEM_MOD_*_SHORT (item tooltips), so we register both as fallbacks.
local STAT_LOOKUP = {}
do
    local stats = {
        { key = "Critical Strike", globals = { "STAT_CRITICAL_STRIKE", "ITEM_MOD_CRIT_RATING_SHORT" } },
        { key = "Haste",           globals = { "STAT_HASTE", "ITEM_MOD_HASTE_RATING_SHORT" } },
        { key = "Mastery",         globals = { "STAT_MASTERY", "ITEM_MOD_MASTERY_RATING_SHORT" } },
        { key = "Versatility",     globals = { "STAT_VERSATILITY", "ITEM_MOD_VERSATILITY" } },
    }
    for _, s in ipairs(stats) do
        for _, g in ipairs(s.globals) do
            local localized = _G[g]
            if localized and localized ~= "" and not STAT_LOOKUP[localized] then
                STAT_LOOKUP[localized] = s.key
            end
        end
        -- Ensure English key is always present as a fallback
        if not STAT_LOOKUP[s.key] then
            STAT_LOOKUP[s.key] = s.key
        end
    end
end

-- Tooltip helpers (hoisted to file scope to avoid re-creation per hover)
local BIS_TIER_HEX = {
    S = "|cffff8000", A = "|cffa336ee",
    B = "|cff0070dd", C = "|cff1eff00",
    D = "|cff9e9e9e",
}
local BIS_TIER_ORDER = { S = 1, A = 2, B = 3, C = 4, D = 5 }
local BIS_CLASS_ID_MAP = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
    DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

-- Pre-cached icon/color strings: classToken → string, classToken|specKey → string
local iconCache = {}
local colorCache = {}

local function GetClassColorHex(classToken)
    local cached = colorCache[classToken]
    if cached then return cached end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if color then
        cached = string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
    else
        cached = "|cffffffff"
    end
    colorCache[classToken] = cached
    return cached
end

local function GetClassIcon(classToken)
    local key = classToken
    local cached = iconCache[key]
    if cached then return cached end
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classToken]
    if coords then
        local l, r, t, b = coords[1], coords[2], coords[3], coords[4]
        cached = string.format("|TInterface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes:14:14:0:0:256:256:%d:%d:%d:%d|t",
            l * 256 + 6, r * 256 - 6, t * 256 + 6, b * 256 - 6)
    else
        cached = ""
    end
    iconCache[key] = cached
    return cached
end

local function GetSpecIcon(classToken, specKey)
    local key = classToken .. "|" .. specKey
    local cached = iconCache[key]
    if cached then return cached end
    local classID = BIS_CLASS_ID_MAP[classToken]
    if classID and GetSpecializationInfoForClassID then
        local keys = SPEC_KEYS[classToken]
        if keys then
            for i, k in ipairs(keys) do
                if k == specKey then
                    local _, _, _, icon = GetSpecializationInfoForClassID(classID, i)
                    if icon then
                        cached = string.format("|T%s:14:14:0:0|t", tostring(icon))
                        iconCache[key] = cached
                        return cached
                    end
                    break
                end
            end
        end
    end
    cached = GetClassIcon(classToken)
    iconCache[key] = cached
    return cached
end

local function GetEntryIcon(entry)
    if entry.consolidated then
        return GetClassIcon(entry.class)
    else
        return GetSpecIcon(entry.class, entry.spec)
    end
end

-- Multi-item tooltip cache: handles simultaneous tooltips (bag item + 2 equipped comparisons)
local tooltipCache = {}       -- cacheKey → { entries, source, hasTrinketEntries }
local tooltipCacheScopeKey = nil  -- tracks scope+roster fingerprint the cache was built with
local playerClassToken = nil  -- set once at ADDON_LOADED

-- Returns a class-token set (or nil for "no filter") representing the
-- subset of class tokens whose BiS entries the user wants to see, plus
-- a stable fingerprint used to invalidate the tooltip cache when the
-- scope or group composition changes.
--
-- Scope values:
--   "all"   → nil (no filter)
--   "group" → player + every party/raid member's class. Falls back to
--             just the player's class when solo (you're always in your
--             own group), so the user still sees something useful.
--   "self"  → just the player's class
--   "off"   → empty set (no entries pass)
local function ResolveBisScope()
    local scope = ClassCodexDB.tooltipBisScope or "all"
    if scope == "all" then
        return nil, "all"
    end
    if scope == "off" then
        return {}, "off"
    end
    local set = {}
    if playerClassToken then set[playerClassToken] = true end
    if scope == "group" then
        local n = GetNumGroupMembers() or 0
        if n > 0 then
            local unitPrefix = IsInRaid() and "raid" or "party"
            for i = 1, n do
                local _, class = UnitClass(unitPrefix .. i)
                if class then set[class] = true end
            end
        end
    end
    -- Fingerprint: scope + sorted class tokens. Stable across calls
    -- with the same roster, changes when the group composition does.
    local tokens = {}
    for c in pairs(set) do tokens[#tokens + 1] = c end
    table.sort(tokens)
    return set, scope .. ":" .. table.concat(tokens, ",")
end

local function BuildTooltipEntries(itemId)
    local filterSet, scopeKey = ResolveBisScope()

    -- Invalidate entire cache if scope or group composition changed
    if tooltipCacheScopeKey ~= scopeKey then
        wipe(tooltipCache)
        tooltipCacheScopeKey = scopeKey
    end

    local cached = tooltipCache[itemId]
    if cached then
        return cached.entries, cached.source, cached.hasTrinketEntries
    end

    local entries = {}
    local seen = {}
    local hasTrinketEntries = false
    local source = nil

    -- Trinket tiers
    if ClassCodexDB.showTrinketTooltip and ns.GetTrinketSpecs then
        local trinketSpecs = ns:GetTrinketSpecs(itemId)
        if trinketSpecs then
            if ns.GetTrinketSource then source = ns:GetTrinketSource(itemId) end
            for _, entry in ipairs(trinketSpecs) do
                if not filterSet or filterSet[entry.class] then
                    local hex = BIS_TIER_HEX[entry.tier] or "|cffffffff"
                    entries[#entries + 1] = {
                        left = GetEntryIcon(entry) .. " " .. GetClassColorHex(entry.class) .. entry.label .. "|r",
                        right = hex .. entry.tier .. "|r",
                        classToken = entry.class,
                        sortKey = BIS_TIER_ORDER[entry.tier] or 6,
                        isTrinketEntry = true,
                    }
                    seen[entry.label] = true
                    hasTrinketEntries = true
                end
            end
        end
    end

    -- BiS gear — merged per-spec approach (Wowhead + Icy Veins)
    local showWH = ClassCodexDB.showWowheadBisTooltip
    local showIV = ClassCodexDB.showIcyVeinsBisTooltip
    local bothEnabled = showWH and showIV

    -- Collect WH entries by spec label
    local bisBySpec = {} -- label → { class, hasWH, hasIV, ivTabs = {} }
    local bisOrder = {}

    if showWH and ns.GetWowheadBisSpecs then
        local bisSpecs = ns:GetWowheadBisSpecs(itemId)
        if bisSpecs then
            for _, entry in ipairs(bisSpecs) do
                if not seen[entry.label] and (not filterSet or filterSet[entry.class]) then
                    bisBySpec[entry.label] = { class = entry.class, spec = entry.spec, consolidated = entry.consolidated, hasWH = true, hasIV = false, ivTabs = {} }
                    bisOrder[#bisOrder + 1] = entry.label
                end
            end
        end
    end

    -- Collect IV entries by spec label, merge into same table
    -- Skip IV for trinkets — tier info is sufficient
    if showIV and not hasTrinketEntries and ns.GetIcyVeinsBisSpecs then
        local ivSpecs = ns:GetIcyVeinsBisSpecs(itemId)
        if ivSpecs then
            for _, entry in ipairs(ivSpecs) do
                if not filterSet or filterSet[entry.class] then
                    local existing = bisBySpec[entry.label]
                    if existing then
                        -- Merge IV tabs into existing entry
                        existing.hasIV = true
                        if entry.tabs then
                            for _, t in ipairs(entry.tabs) do
                                existing.ivTabs[#existing.ivTabs + 1] = t
                            end
                        end
                    else
                        -- New spec only in IV
                        bisBySpec[entry.label] = { class = entry.class, spec = entry.spec, consolidated = entry.consolidated, hasWH = false, hasIV = true, ivTabs = entry.tabs or {} }
                        bisOrder[#bisOrder + 1] = entry.label
                    end
                end
            end
        end
    end

    -- Build merged entries
    for _, label in ipairs(bisOrder) do
        if not seen[label] then
            local info = bisBySpec[label]
            local rightLabel = nil

            if info.hasWH or info.hasIV then
                local style = ClassCodexDB.tooltipSourceStyle or 1
                local showIcon = style == 1 or style == 3
                local showLabel = style == 2 or style == 3
                local parts = {}
                if info.hasWH then
                    local s = ""
                    if showIcon then s = s .. "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12:0:0|t" end
                    if showLabel then s = s .. (showIcon and " " or "") .. "|cffff8000WH|r" end
                    parts[#parts + 1] = s
                end
                if info.hasIV then
                    -- Deduplicate tabs
                    local uniqueTabs = {}
                    local tabSeen = {}
                    for _, t in ipairs(info.ivTabs) do
                        if not tabSeen[t] then
                            tabSeen[t] = true
                            uniqueTabs[#uniqueTabs + 1] = t
                        end
                    end
                    local s = ""
                    if showIcon then s = s .. "|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:12:12:0:0|t" end
                    -- Show tab context when not all tabs. Mythic+ collapses to the
                    -- universal "M+" abbreviation; Overall/Raid are localized.
                    -- "Overall (...)" variants (Blood DK San'layn / Deathbringer)
                    -- collapse to the plain localized "Overall".
                    if #uniqueTabs > 0 and #uniqueTabs < 3 then
                        local shortTabs = {}
                        for _, t in ipairs(uniqueTabs) do
                            local short
                            if t == "Mythic+" then short = "M+"
                            elseif t == "Raid" then short = L["context.raid"]
                            elseif t == "Overall" or t:sub(1, 8) == "Overall " then short = L["context.overall"]
                            else short = t end
                            shortTabs[#shortTabs + 1] = short
                        end
                        s = s .. " \194\183 " .. "|cff00ccff" .. table.concat(shortTabs, ", ") .. "|r"
                    elseif showLabel then
                        s = s .. (showIcon and " " or "") .. "|cff00ccffIV|r"
                    end
                    parts[#parts + 1] = s
                end
                rightLabel = table.concat(parts, "  ")
            end

            entries[#entries + 1] = {
                left = GetEntryIcon(info) .. " " .. GetClassColorHex(info.class) .. label .. "|r",
                right = rightLabel,
                classToken = info.class,
                sortKey = 0,
            }
            seen[label] = true
        end
    end

    if #entries > 0 then
        table.sort(entries, function(a, b) return a.sortKey < b.sortKey end)
    end

    tooltipCache[itemId] = { entries = entries, source = source, hasTrinketEntries = hasTrinketEntries }
    return entries, source, hasTrinketEntries
end

-- Cached stat priority ranks (invalidated when hero/context changes)
local cachedRanks = nil
local cachedRanksHero = nil
local cachedRanksCtx = nil

local function GetCachedRanks()
    local specData = GetSpecData()
    if not specData then return nil end
    -- Lazy-detect hero talent so tooltip ranks are correct before panel opens
    if not currentHeroTalent then
        local perSpec = GetPerSpecState()
        if perSpec and perSpec.heroTalent then
            currentHeroTalent = perSpec.heroTalent
        else
            local detected = GetActiveHeroTalentName()
            if detected then
                local heroOptions = GetHeroTalentOptions(specData)
                for _, opt in ipairs(heroOptions) do
                    if opt:lower() == detected:lower() then
                        currentHeroTalent = opt
                        break
                    end
                end
            end
        end
    end
    local hero = currentHeroTalent or "All"
    local ctx = currentStatContext or "General"
    if cachedRanks and cachedRanksHero == hero and cachedRanksCtx == ctx then
        return cachedRanks
    end
    local priority = FindMatch(specData.priorities, hero, ctx)
    if not priority then cachedRanks = nil; return nil end
    cachedRanks = {}
    for i, tier in ipairs(priority.stats) do
        for _, stat in ipairs(tier) do cachedRanks[stat] = i end
    end
    cachedRanksHero = hero
    cachedRanksCtx = ctx
    return cachedRanks
end

local function OnTooltipItem(tooltip, tooltipData)
    if not ClassCodexDB then return end

    -- Extract item ID from tooltip data
    local itemId = tooltipData and tooltipData.id

    -- Trinket tier badge on the title line (right side) — current spec only
    if ClassCodexDB.showTrinketTooltip and itemId and ns.GetTrinketTier then
        local tier, tierColor = ns:GetTrinketTier(itemId)
        if tier and tierColor then
            local titleRight = _G[tooltip:GetName() .. "TextRight1"]
            if titleRight and titleRight:GetFont() then
                local hex = string.format("|cff%02x%02x%02x", tierColor.r * 255, tierColor.g * 255, tierColor.b * 255)
                titleRight:SetText(hex .. tier .. "|r")
                titleRight:Show()
            end
        end
    end

    -- Cross-spec BiS + trinket tier info
    local bisScope = ClassCodexDB.tooltipBisScope or "all"
    if itemId and bisScope ~= "off" and (ClassCodexDB.showWowheadBisTooltip or ClassCodexDB.showIcyVeinsBisTooltip or ClassCodexDB.showTrinketTooltip) then
        local entries, source, hasTrinketEntries = BuildTooltipEntries(itemId)

        if #entries > 0 then
            tooltip:AddLine(" ")
            local style = ClassCodexDB.tooltipSourceStyle or 1
            local showIcon = style == 1 or style == 3
            local showLabel = style == 2 or style == 3
            local headerSources = {}
            if ClassCodexDB.showWowheadBisTooltip then
                local s = ""
                if showIcon then s = s .. "|TInterface\\AddOns\\ClassCodex\\Textures\\wowhead:12:12:0:0|t" end
                if showLabel then s = s .. (showIcon and " " or "") .. "|cffff8000WH|r" end
                headerSources[#headerSources + 1] = s
            end
            if ClassCodexDB.showIcyVeinsBisTooltip then
                local s = ""
                if showIcon then s = s .. "|TInterface\\AddOns\\ClassCodex\\Textures\\icyveins:12:12:0:0|t" end
                if showLabel then s = s .. (showIcon and " " or "") .. "|cff00ccffIV|r" end
                headerSources[#headerSources + 1] = s
            end
            if #headerSources > 0 then
                tooltip:AddDoubleLine(L["tooltip.bis_header"], table.concat(headerSources, "  "), 0.9, 0.8, 0.5, 0.9, 0.8, 0.5)
            else
                tooltip:AddLine(L["tooltip.bis_header"], 0.9, 0.8, 0.5)
            end

            if hasTrinketEntries and source then
                tooltip:AddDoubleLine(L["tooltip.source"], source, 0.5, 0.5, 0.5, 1, 0.82, 0)
            end

            for _, e in ipairs(entries) do
                local cclr = RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.classToken]
                local cr, cg, cb = 1, 1, 1
                if cclr then cr, cg, cb = cclr.r, cclr.g, cclr.b end
                if e.right then
                    tooltip:AddDoubleLine(e.left, e.right, cr, cg, cb, cr, cg, cb)
                else
                    tooltip:AddLine(e.left, cr, cg, cb)
                end
            end
        end
    end

    -- Stat priority ranks (cached until hero/context changes)
    if not ClassCodexDB.showTooltipBadges then return end
    local ranks = GetCachedRanks()
    if not ranks then return end

    local annotated = false
    for i = 2, tooltip:NumLines() do
        local line = _G[tooltip:GetName() .. "TextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                -- Skip tainted/secret strings (secure tooltip contexts like quest items)
                local ok, _ = pcall(string.len, text)
                if ok and line:GetFont() then
                    for localizedStat, englishStat in pairs(STAT_LOOKUP) do
                        if text:find(localizedStat, 1, true) and not text:find("#%d") then
                            local rank = ranks[englishStat]
                            if rank then
                                local color = RANK_COLORS[rank]
                                if color then
                                    local hex = string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
                                    line:SetText(text .. "  " .. hex .. "#" .. rank .. "|r")
                                    annotated = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Optional footer line: which hero/context the ranks come from.
    -- tooltipFooterMode: 0 = off, 1 = always, 2 = only when resolved
    -- hero differs from the player's currently active hero.
    if annotated then
        local mode = ClassCodexDB.tooltipFooterMode or 0
        if mode > 0 then
            local activeHero = GetActiveHeroTalentName()
            local heroDiffers = activeHero
                and cachedRanksHero
                and cachedRanksHero ~= "All"
                and activeHero:lower() ~= cachedRanksHero:lower()
            local suppress = (mode == 2) and not heroDiffers
            if not suppress then
                tooltip:AddLine(string.format("|cff808080%s: %s · %s|r",
                    L["tooltip.stat_priority_footer"], cachedRanksHero or "All", cachedRanksCtx or "General"))
            end
        end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
end

-------------------------------------------------------------------------------
-- Static Popups
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- Settings panel helpers
--
-- ns.RegisterSettings (defined in Settings.lua) calls these to refresh the
-- panel after a setting changes, instead of capturing panel/isFloating
-- directly from this file's scope.
-------------------------------------------------------------------------------

function ns.UpdatePanelIfVisible(mode)
    if not panel:IsShown() then return end
    if mode == "docked" and isFloating then return end
    if mode == "floating" and not isFloating then return end
    ns:UpdatePanel()
end

function ns.InvalidateTooltipCache()
    wipe(tooltipCache)
    tooltipCacheScopeKey = nil
end


-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
-- Live stat target updates: refresh bars when ratings change. Throttled
-- via the existing UpdatePanel call path so a flurry of equipment swaps
-- collapses to one re-render.
eventFrame:RegisterEvent("COMBAT_RATING_UPDATE")
eventFrame:RegisterEvent("UNIT_STATS")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- Drives the "owned" overlay on BiS rows. Blizzard debounces this
-- event already, so loot/bank/mail churn collapses to one refresh.
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
-- Re-render Stat Targets on combat transitions so the in-combat
-- placeholder swaps in/out predictably (GetCombatRating only returns
-- real values to tainted code outside combat).
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Group composition changes invalidate the tooltip BiS cache when the
-- scope is set to "group" so the next hover reflects the new roster.
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        local dbDefaults = {
            showLoginMessage = false,
            showTooltipBadges = true,
            tooltipFooterMode = 0, -- 0 off, 1 always, 2 only when different
            craftingTopPicksOnly = true,
            showWowheadBisTooltip = true,
            showIcyVeinsBisTooltip = true,
            showTrinketTooltip = true,
            tooltipBisScope = "all", -- "all", "group", "self", "off"
            panelWidth = PANEL_WIDTH, -- numeric px; slider clamped 260..500
            highlightOwnedGear = true,
            tooltipSourceStyle = 1,
            minimap = { hide = false },
            showMinimapButton = true,
            floatShowStats = true,
            floatShowStatTargets = true,
            floatShowTalents = true,
            floatShowRotation = true,
            floatShowEnchants = true,
            floatShowGems = true,
            floatShowConsumables = true,
            floatShowTrinkets = true,
            floatShowCrafts = true,
            floatShowEmbellishments = true,
            floatShowBisGear = true,
            dockShowStats = true,
            dockShowStatTargets = true,
            dockShowTalents = true,
            dockShowRotation = true,
            dockShowEnchants = true,
            dockShowGems = true,
            dockShowConsumables = true,
            dockShowTrinkets = true,
            dockShowCrafts = true,
            dockShowEmbellishments = true,
            dockShowBisGear = true,
            widgetOffsetX = WIDGET_DEFAULT_OFFSET_X,
            widgetOffsetY = WIDGET_DEFAULT_OFFSET_Y,
            widgetLocked = false,
            dockLoadoutEnabled = false,
            dockLoadoutHideInCombat = true,
            dockLoadoutLocked = false,
            dockLoadoutShowSpecIcon = true,
            dockLoadoutShowHeroIcon = true,
            dockLoadoutShowSaved = true,
            dockLoadoutShowWowhead = true,
            dockLoadoutShowArchon = true,
            dockLoadoutShowIcyVeins = true,
            dockLoadoutOpacity = 95,
            dockLoadoutWidth = 200,
            dockLoadoutAutoWidth = false,
            dockLoadoutScale = 100,
            dockLoadoutAlignment = "LEFT",
            dockLoadoutShowBorder = true,
        }
        local charDefaults = {
        panelOpen = true, floating = false, minimized = false, perSpec = {},
        collapsed = {
            stats = false,
            statTargets = false,
            talents = false,
            rotation = false,
            enchants = false,
            gems = false,
        },
    }

        if not ClassCodexDB then ClassCodexDB = {} end
        -- Migrate old showBisTooltip → showWowheadBisTooltip
        if ClassCodexDB.showBisTooltip ~= nil then
            ClassCodexDB.showWowheadBisTooltip = ClassCodexDB.showBisTooltip
            ClassCodexDB.showBisTooltip = nil
        end
        -- Migrate old tab keys to new merged tabs
        local TAB_MIGRATION = { enchants = "enhancements", consumables = "enhancements", gear = "bis", crafts = "crafting" }
        if ClassCodexDB.compendiumTab then
            ClassCodexDB.compendiumTab = TAB_MIGRATION[ClassCodexDB.compendiumTab] or ClassCodexDB.compendiumTab
        end
        -- Loadout Dock position: was per-character on ClassCodexCharDB.loadoutDock
        -- during the preview, now account-wide on ClassCodexDB.dockLoadoutPosition.
        -- Migrate the first character's saved position so users don't lose it.
        if ClassCodexCharDB and ClassCodexCharDB.loadoutDock then
            local old = ClassCodexCharDB.loadoutDock
            if old.point and old.x and old.y and not ClassCodexDB.dockLoadoutPosition then
                ClassCodexDB.dockLoadoutPosition = {
                    point = old.point,
                    relativePoint = old.relativePoint,
                    x = old.x,
                    y = old.y,
                }
            end
            ClassCodexCharDB.loadoutDock = nil
        end
        -- Migrate the early two-checkbox tooltip-footer scheme into the
        -- consolidated tooltipFooterMode dropdown so users who tried the
        -- preview keep their preference.
        if ClassCodexDB.showTooltipPriorityFooter ~= nil and ClassCodexDB.tooltipFooterMode == nil then
            if ClassCodexDB.showTooltipPriorityFooter then
                ClassCodexDB.tooltipFooterMode = ClassCodexDB.tooltipFooterOnlyWhenDifferent and 2 or 1
            else
                ClassCodexDB.tooltipFooterMode = 0
            end
        end
        ClassCodexDB.showTooltipPriorityFooter = nil
        ClassCodexDB.tooltipFooterOnlyWhenDifferent = nil
        -- #618 migration: a user who had Crafts toggled off explicitly meant
        -- "hide the whole Crafting tab content". Inherit that intent for the
        -- new Embellishments toggle on first run so it doesn't appear out of
        -- nowhere after upgrade. Must run BEFORE the dbDefaults fill-in
        -- (which would otherwise overwrite the nil with true).
        if ClassCodexDB.dockShowCrafts == false and ClassCodexDB.dockShowEmbellishments == nil then
            ClassCodexDB.dockShowEmbellishments = false
        end
        if ClassCodexDB.floatShowCrafts == false and ClassCodexDB.floatShowEmbellishments == nil then
            ClassCodexDB.floatShowEmbellishments = false
        end
        -- #644 migration: the bisCurrentClassOnly checkbox is replaced by a
        -- 4-option scope dropdown. A user who had it ticked wanted only
        -- their own class — map to "self". Untouched users map to the
        -- default "all" via the dbDefaults fill-in below.
        if ClassCodexDB.bisCurrentClassOnly ~= nil and ClassCodexDB.tooltipBisScope == nil then
            ClassCodexDB.tooltipBisScope = ClassCodexDB.bisCurrentClassOnly and "self" or "all"
            ClassCodexDB.bisCurrentClassOnly = nil
        end
        for k, v in pairs(dbDefaults) do if ClassCodexDB[k] == nil then ClassCodexDB[k] = v end end
        -- Guardrail: if a mode has every content toggle disabled, recover to guide defaults.
        local function EnsureAtLeastOneVisibleTab(modePrefix)
            local hasGuide = ClassCodexDB[modePrefix .. "Stats"] ~= false
                or ClassCodexDB[modePrefix .. "Talents"] ~= false
                or ClassCodexDB[modePrefix .. "Rotation"] ~= false
            local hasGearing = ClassCodexDB[modePrefix .. "Enchants"] ~= false
                or ClassCodexDB[modePrefix .. "Gems"] ~= false
                or ClassCodexDB[modePrefix .. "Consumables"] ~= false
                or ClassCodexDB[modePrefix .. "Trinkets"] ~= false
                or ClassCodexDB[modePrefix .. "Crafts"] ~= false
                or ClassCodexDB[modePrefix .. "Embellishments"] ~= false
                or ClassCodexDB[modePrefix .. "BisGear"] ~= false
            if not hasGuide and not hasGearing then
                ClassCodexDB[modePrefix .. "Stats"] = true
                ClassCodexDB[modePrefix .. "Talents"] = true
                ClassCodexDB[modePrefix .. "Rotation"] = true
            end
        end
        EnsureAtLeastOneVisibleTab("dockShow")
        EnsureAtLeastOneVisibleTab("floatShow")
        if type(ClassCodexDB.minimap) ~= "table" then ClassCodexDB.minimap = { hide = false } end
        -- Reconcile minimap visibility (showMinimapButton drives minimap.hide)
        ClassCodexDB.minimap.hide = not ClassCodexDB.showMinimapButton
        if not ClassCodexCharDB then ClassCodexCharDB = {} end
        for k, v in pairs(charDefaults) do if ClassCodexCharDB[k] == nil then ClassCodexCharDB[k] = v end end
        if ClassCodexCharDB.activeTab then
            ClassCodexCharDB.activeTab = TAB_MIGRATION[ClassCodexCharDB.activeTab] or ClassCodexCharDB.activeTab
        end

        playerClassToken = select(2, UnitClass("player"))
        ns.RegisterSettings()

        -- Minimap button (LibDBIcon)
        local LDB = LibStub("LibDataBroker-1.1", true)
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDB and LDBIcon then
            local dataObj = LDB:NewDataObject("ClassCodex", {
                type = "launcher",
                icon = "Interface\\AddOns\\ClassCodex\\icon",
                OnClick = function(_, button)
                    if button == "LeftButton" then
                        if ns.OpenCompendium then
                            ns:OpenCompendium()
                        end
                    elseif button == "RightButton" then
                        if ns.settingsCategory then
                            Settings.OpenToCategory(ns.settingsCategory:GetID())
                        end
                    end
                end,
                OnTooltipShow = function(tip)
                    local ver = C_AddOns.GetAddOnMetadata(addonName, "Version") or ""
                    tip:AddLine("Class Codex v" .. ver, 1, 1, 1)
                    tip:AddLine("Left-click to open Compendium", 0.7, 0.7, 0.7)
                    tip:AddLine("Right-click to open Settings", 0.7, 0.7, 0.7)
                end,
            })
            LDBIcon:Register("ClassCodex", dataObj, ClassCodexDB.minimap)
            ns.LDBIcon = LDBIcon
        end

        if ClassCodexCharDB.floating then FloatPanel() end

        isMinimized = ClassCodexCharDB.minimized or false
        if isMinimized then
            minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-ExpandButton-Up")
        end

        if ClassCodexCharDB.activeTab then
            ns.setActiveTab(ClassCodexCharDB.activeTab)
        end

        -- Setup widget if PaperDollFrame already exists, otherwise wait
        if PaperDollFrame then
            SetupWidgetButton()
        end

    elseif event == "ADDON_LOADED" and PaperDollFrame and not widgetContainer then
        SetupWidgetButton()

    elseif event == "PLAYER_ENTERING_WORLD" then
        if PaperDollFrame and not widgetContainer then
            SetupWidgetButton()
        end
        -- Auto-register known UI suites as dock hosts so users get the right
        -- anchor without those addons needing to call ns.RegisterDockHost first.
        -- (GW2_UI replaces the character window with GwCharacterWindow.)
        if _G.GwCharacterWindow then
            ns.RegisterDockHost(_G.GwCharacterWindow, { priority = 50 })
        end
        -- Another addon may also register /cc; whichever is hashed last wins, so
        -- ours can be shadowed. Detect that first so every message below can fall
        -- back to /classcodex, then point the user at it explicitly.
        ns.ccContested = false
        for name in pairs(SlashCmdList) do
            if name ~= "CLASSCODEX" then
                local i = 1
                local s = _G["SLASH_" .. name .. i]
                while s do
                    if type(s) == "string" and s:upper() == "/CC" then ns.ccContested = true; break end
                    i = i + 1
                    s = _G["SLASH_" .. name .. i]
                end
            end
            if ns.ccContested then break end
        end
        if ClassCodexDB and ClassCodexDB.showLoginMessage then
            local ver = C_AddOns.GetAddOnMetadata(addonName, "Version") or ""
            print("|cff00ccffClass Codex|r v" .. ver .. " " .. ns.FixSlash(L["chat.loaded"]))
        end
        if ns.ccContested then
            print("|cff00ccffClass Codex:|r " .. L["chat.slash_conflict"])
        end
        -- Restore floating panel if it was open before logout
        if isFloating and ClassCodexCharDB and ClassCodexCharDB.panelOpen then
            ns:UpdatePanel()
            panel:Show()
        end
        -- Re-render the docked panel's Talents tab when zone/encounter
        -- flips the effective Archon source. Talent pane and Compendium
        -- handle this themselves; the docked panel needs the same.
        if ns.RegisterArchonContextCallback then
            ns.RegisterArchonContextCallback(function()
                if panel:IsShown() and ns.getActiveTab and ns.getActiveTab() == "talents" then
                    ns:UpdatePanel()
                end
            end)
        end
        eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if widgetContainer then
            eventFrame:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 == "player" then
        local perSpec = GetPerSpecState()
        if perSpec then
            local oldHero = perSpec.heroTalent
            perSpec.heroTalent = nil
            local newHero = GetActiveHeroTalentName()
            if oldHero and oldHero ~= newHero then
                print("|cff00ccffClass Codex:|r " .. L["chat.switched_to"]:format(newHero or "auto-detect"))
            end
        end
        currentHeroTalent = nil
        cachedRanks = nil
        if panel:IsShown() then ns:UpdatePanel() end

    elseif event == "TRAIT_CONFIG_UPDATED" then
        local perSpec = GetPerSpecState()
        if perSpec then perSpec.heroTalent = nil end
        currentHeroTalent = nil
        cachedRanks = nil
        if panel:IsShown() then ns:UpdatePanel() end

    elseif event == "COMBAT_RATING_UPDATE" or event == "UNIT_STATS" then
        -- Cheap path: only re-render when the Stats tab is visible. Other
        -- tabs don't display live ratings so they don't need to repaint.
        if panel:IsShown() and activeTab == "stats" then
            ns:UpdatePanel()
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "BAG_UPDATE_DELAYED" then
        -- Stats tab needs equipment-driven rating updates; BiS and
        -- Trinkets tabs need their "owned" row tint refreshed when
        -- bags/equipped slots change. Other tabs don't reflect either.
        if panel:IsShown() and (activeTab == "stats" or activeTab == "bis" or activeTab == "trinkets" or activeTab == "crafting") then
            ns:UpdatePanel()
        end

    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
        if panel:IsShown() and activeTab == "stats" then
            ns:UpdatePanel()
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Only the "group" scope depends on the live roster; other
        -- scopes' caches stay valid through group churn. ResolveBisScope
        -- builds the fingerprint, so this just nudges the next lookup
        -- to re-derive it.
        if ClassCodexDB and ClassCodexDB.tooltipBisScope == "group" then
            ns.InvalidateTooltipCache()
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash Commands
-------------------------------------------------------------------------------

SLASH_CLASSCODEX1 = "/cc"
SLASH_CLASSCODEX2 = "/classcodex"
SlashCmdList["CLASSCODEX"] = function(msg)
    msg = msg:lower():trim()
    if msg == "toggle" or msg == "" then
        if isFloating then
            if panel:IsShown() then
                panel:Hide(); ClassCodexCharDB.panelOpen = false
            else
                ns:UpdatePanel(); FadeIn(panel); ClassCodexCharDB.panelOpen = true
            end
        elseif CharacterFrame:IsShown() then
            if panel:IsShown() then
                panel:Hide(); ClassCodexCharDB.panelOpen = false
            else
                ns:UpdatePanel(); FadeIn(panel); ClassCodexCharDB.panelOpen = true
            end
        else
            ToggleCharacter("PaperDollFrame"); ClassCodexCharDB.panelOpen = true
        end
    elseif msg == "float" then
        if isFloating then DockPanel(); print("|cff00ccffClass Codex:|r " .. L["chat.mode_docked"])
        else FloatPanel(); print("|cff00ccffClass Codex:|r " .. L["chat.mode_floating"]) end
        if panel:IsShown() then ns:UpdatePanel() end
    elseif msg == "settings" then
        if ns.settingsCategory then Settings.OpenToCategory(ns.settingsCategory:GetID()) end
    elseif msg == "reset" then
        ClassCodexCharDB.floating = false
        ClassCodexCharDB.floatX = nil
        ClassCodexCharDB.floatY = nil
        ClassCodexCharDB.minimized = false
        isFloating = false; isMinimized = false
        DockPanel()
        minimizeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-CollapseButton-Up")
        print("|cff00ccffClass Codex:|r " .. L["chat.mode_reset"])
        if panel:IsShown() then ns:UpdatePanel() end
    elseif msg == "compendium" then
        if ns.OpenCompendium then ns:OpenCompendium()
        else print("|cff00ccffClass Codex:|r " .. L["chat.compendium_not_available"]) end
    elseif msg == "dock" then
        if ClassCodexDB then
            ClassCodexDB.dockLoadoutEnabled = not ClassCodexDB.dockLoadoutEnabled
        end
        if ns.UpdateLoadoutDockVisibility then ns.UpdateLoadoutDockVisibility() end
    elseif msg == "minimap" then
        if ns.LDBIcon then
            local db = ClassCodexDB.minimap
            if db.hide then
                db.hide = false
                ClassCodexDB.showMinimapButton = true
                ns.LDBIcon:Show("ClassCodex")
                print("|cff00ccffClass Codex:|r " .. L["chat.minimap_shown"])
            else
                db.hide = true
                ClassCodexDB.showMinimapButton = false
                ns.LDBIcon:Hide("ClassCodex")
                print("|cff00ccffClass Codex:|r " .. L["chat.minimap_hidden"])
            end
        else
            print("|cff00ccffClass Codex:|r " .. L["chat.minimap_not_available"])
        end
    elseif msg == "inspectdump" then
        if ns.DumpInspectState then
            ns.DumpInspectState()
        else
            print("|cff00ccffClass Codex:|r inspect dump unavailable.")
        end
    elseif msg == "help" then
        local sc = ns.FixSlash("/cc")
        print("|cff00ccffClass Codex|r commands:")
        print("  " .. sc .. " - Toggle panel")
        print("  " .. sc .. " float - Toggle float/dock")
        print("  " .. sc .. " compendium - Open compendium")
        print("  " .. sc .. " settings - Open settings")
        print("  " .. sc .. " minimap - Toggle minimap button")
        print("  " .. sc .. " reset - Reset position")
        print("  " .. sc .. " inspectdump - Print inspect-mode diagnostics")
    else
        print("|cff00ccffClass Codex:|r " .. ns.FixSlash(L["chat.unknown_command"]))
    end
end
