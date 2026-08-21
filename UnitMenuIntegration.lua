local _, ns = ...
local L = ns.L

-- Player-context unit popup tags that carry a usable contextData.unit.
-- BN-friend / chat-roster / similar tags carry name+server only and would
-- silently fail the gate below, so we skip them.
local TAGS = {
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_FRIEND",
    "MENU_UNIT_GUILD",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_ARENAENEMY",
    "MENU_UNIT_ENEMY_PLAYER",
}

-- Default-on. nil means default.
local function IsEnabled()
    if ClassCodexDB == nil then return true end
    if ClassCodexDB.unitMenuEnabled == nil then return true end
    return ClassCodexDB.unitMenuEnabled and true or false
end

local function CanShow(unit)
    if not unit or not UnitExists(unit) then return false end
    if not UnitIsPlayer(unit) then return false end
    if UnitIsUnit(unit, "player") then return false end
    -- Pass `false` so the call is silent on out-of-range / opposite-faction
    -- — we just hide the entry rather than letting the menu show then error.
    return CanInspect(unit, false)
end

local function LoadPlayerSpellsFrame()
    if not PlayerSpellsFrame and PlayerSpellsFrame_LoadUI then
        PlayerSpellsFrame_LoadUI()
    end
    return PlayerSpellsFrame
end

local function ResolveUnit(originalUnit, guid)
    -- The unit token may have stale state by the time we open (user
    -- re-targeted, etc.). UnitTokenFromGUID resolves the current token for
    -- the GUID — works for any unit Blizzard currently has frames for.
    if originalUnit and UnitExists(originalUnit) and UnitGUID(originalUnit) == guid then
        return originalUnit
    end
    return UnitTokenFromGUID and UnitTokenFromGUID(guid) or nil
end

-- Pending inspects keyed by GUID. INSPECT_READY fires globally per addon
-- that calls NotifyInspect, so we filter by GUID to only react to ours.
local pending = {}

local function StartInspect(unit)
    if not unit or not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    pending[guid] = { unit = unit, name = UnitName(unit) }
    NotifyInspect(unit)
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("INSPECT_READY")
listener:SetScript("OnEvent", function(_, _, guid)
    local info = pending[guid]
    if not info then return end
    pending[guid] = nil

    -- C_Traits.GenerateInspectImportString can return empty even after
    -- INSPECT_READY (the trait data lags slightly behind the equipment
    -- inspect). Poll until non-empty, with a 10s cap. Cf. TalentTreeTweaks'
    -- modules/exportInspectedBuild.lua.
    local startTime = GetTime()
    local ticker
    ticker = C_Timer.NewTicker(0, function()
        local unit = ResolveUnit(info.unit, guid)
        if not unit or (GetTime() - startTime) > 10 then
            ticker:Cancel()
            return
        end
        local exportString = C_Traits.GenerateInspectImportString(unit)
        if not exportString or exportString == "" then return end
        ticker:Cancel()

        local frame = LoadPlayerSpellsFrame()
        if not frame or not frame.SetInspectString then return end
        local level = (UnitLevel and UnitLevel(unit)) or 80
        frame:SetInspectString(exportString, level)
        if not frame:IsShown() then
            ShowUIPanel(frame)
        end
    end)
end)

local function Callback(_, rootDescription, contextData)
    -- Early-return before any rootDescription:Create* call when disabled.
    -- Per Stanzilla/WoWUIBugs#826, the menu's secure context is tainted by
    -- the Create calls themselves — skipping them keeps the menu clean.
    if not IsEnabled() then return end
    -- Skip entirely in combat: the Create* taint can block protected
    -- functions Blizzard calls from the same menu (SetRaidTarget, etc.).
    -- Inspecting talents mid-fight isn't useful anyway.
    if InCombatLockdown and InCombatLockdown() then return end
    if not contextData or not CanShow(contextData.unit) then return end
    local unit = contextData.unit
    rootDescription:CreateDivider()
    rootDescription:CreateTitle("Class Codex")
    rootDescription:CreateButton(L["talent_pane.view_talents"], function()
        StartInspect(unit)
    end)
end

if Menu and Menu.ModifyMenu then
    for _, tag in ipairs(TAGS) do
        Menu.ModifyMenu(tag, Callback)
    end
end

-- Forbidden-action notice. Post-12.0, modifying a MENU_UNIT_* menu via
-- Menu.ModifyMenu can taint protected functions Blizzard itself calls from
-- the same menu (SetRaidTarget, FollowUnit, etc.). Blizzard-side bug; no
-- addon can fix it. We point the user at the toggle so they don't blame us.
local notified = false
local notice = CreateFrame("Frame")
notice:RegisterEvent("ADDON_ACTION_FORBIDDEN")
notice:SetScript("OnEvent", function(_, _, addonName, funcName)
    if notified or addonName ~= "ClassCodex" then return end
    notified = true
    print(string.format(L["chat.blizzard_bug_notice"], funcName or "?"))
end)
