local addonName, ns = ...

-------------------------------------------------------------------------------
-- ReduceTaint: Prevent INTERFACE_ACTION_BLOCKED after programmatic loadout
--
-- When Class Codex applies a talent build via C_Traits, it can taint
-- variables that Blizzard's talent frame later reads. This module cleans
-- up the most common taint vectors so the Blizzard UI keeps working.
--
-- Adapted from NumyAddon/TalentLoadoutManager (MIT)
-------------------------------------------------------------------------------

-- Guard: only needed on retail with the player spells frame
if not PlayerSpellsFrame and not C_ClassTalents then return end

-------------------------------------------------------------------------------
-- Core utility: nil a key from secure code without spreading taint
-- Uses TextureLoadingGroupMixin.RemoveTexture which calls table[key] = nil
-- from secure (Blizzard-signed) code.
-------------------------------------------------------------------------------

local secureSetNil
do
    local mixin = TextureLoadingGroupMixin
    if mixin and mixin.RemoveTexture then
        function secureSetNil(tbl, key)
            mixin.RemoveTexture({ textures = tbl }, key)
        end
    else
        -- Fallback: direct nil (still causes taint but better than nothing)
        function secureSetNil(tbl, key)
            tbl[key] = nil
        end
    end
end

ns.secureSetNil = secureSetNil

-------------------------------------------------------------------------------
-- Fix 1: Tainted configID on the talent frame
--
-- After ImportLoadout/LoadConfig, PlayerSpellsFrame.TalentsFrame.configID
-- becomes tainted. The Share/Export button reads it, causing
-- ADDON_ACTION_BLOCKED. We detect taint via issecurevariable and clean it.
-------------------------------------------------------------------------------

local function FixTalentFrameConfigID()
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talentsFrame then return end

    -- Hook the Share button's click if it exists
    local shareBtn = talentsFrame.SearchBox and talentsFrame.SearchBox.ShareButton
                  or talentsFrame.ShareButton
    if shareBtn and not shareBtn._classCodexHooked then
        shareBtn:HookScript("PreClick", function()
            if not issecurevariable(talentsFrame, "configID") then
                local configID = C_ClassTalents.GetActiveConfigID()
                if configID then
                    secureSetNil(talentsFrame, "configID")
                    talentsFrame.configID = configID
                end
            end
        end)
        shareBtn._classCodexHooked = true
    end
end

-------------------------------------------------------------------------------
-- Fix 2: Frame OnHide taint
--
-- PlayerSpellsFrame.OnHide reads inspectUnit/inspectString/lockInspect
-- which can become tainted. Clean them before hide runs.
-------------------------------------------------------------------------------

local function FixOnHideTaint()
    local frame = PlayerSpellsFrame
    if not frame or frame._classCodexOnHideHooked then return end

    frame:HookScript("OnHide", function(self)
        for _, key in ipairs({ "inspectUnit", "inspectString", "lockInspect" }) do
            if not issecurevariable(self, key) then
                secureSetNil(self, key)
            end
        end
    end)
    frame._classCodexOnHideHooked = true
end

-------------------------------------------------------------------------------
-- Fix 3: PlayerSpellsFrame OnHide var cleanup
--
-- We intentionally do NOT wrap PlayerSpellsFrame.OnShow's environment.
-- TLM's original setfenv approach replaced MultiActionBar_ShowAllGrids
-- and UpdateMicroButtons with no-ops to avoid spreading taint to action
-- bar buttons, but the side effect was that hidden action bar grids never
-- auto-showed when the spellbook opened. The other taint cleanups
-- (configID, OnHide vars, MicroButton flags, the hook below) prevent
-- ADDON_ACTION_BLOCKED without that trade-off.
-------------------------------------------------------------------------------

local function FixMultiActionBarTaint()
    local frame = PlayerSpellsFrame
    if not frame or frame._classCodexOnShowHooked then return end

    -- Clean tainted lockInspect/inspectUnit/inspectString before OnHide
    hooksecurefunc(FrameUtil, "UnregisterFrameForEvents", function(f)
        if f ~= frame then return end
        for _, key in ipairs({ "lockInspect", "inspectUnit", "inspectString" }) do
            if not issecurevariable(frame, key) then
                if not frame[key] then
                    secureSetNil(frame, key)
                end
            end
        end
    end)

    frame._classCodexOnShowHooked = true
end

-------------------------------------------------------------------------------
-- Fix 4: MicroButton taint
--
-- After talent operations, canUseTalentUI / canUseTalentSpecUI on the
-- TalentMicroButton can be left tainted, causing errors when the micro
-- menu bar updates. Clean them after each TRAIT_CONFIG_UPDATED.
-------------------------------------------------------------------------------

local function FixMicroButtonTaint()
    local btn = TalentMicroButton
    if not btn or btn._classCodexTaintHooked then return end

    local cleanupFrame = CreateFrame("Frame")
    cleanupFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    cleanupFrame:SetScript("OnEvent", function()
        if btn and not issecurevariable(btn, "canUseTalentUI") then
            secureSetNil(btn, "canUseTalentUI")
        end
        if btn and not issecurevariable(btn, "canUseTalentSpecUI") then
            secureSetNil(btn, "canUseTalentSpecUI")
        end
    end)
    btn._classCodexTaintHooked = true
end

-------------------------------------------------------------------------------
-- Fix 5: Castbar taint (from TLM)
--
-- enableCommitCastBar on the talent frame can become tainted after
-- programmatic commits. Nil it out to prevent taint spreading.
-------------------------------------------------------------------------------

local function FixCastbarTaint()
    local talentsFrame = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
    if not talentsFrame or talentsFrame._classCodexCastbarFixed then return end
    secureSetNil(talentsFrame, "enableCommitCastBar")
    talentsFrame._classCodexCastbarFixed = true
end

-------------------------------------------------------------------------------
-- Initialize: apply fixes when the talent frame loads
-------------------------------------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_PlayerSpells" then
        FixTalentFrameConfigID()
        FixOnHideTaint()
        FixMultiActionBarTaint()
        FixMicroButtonTaint()
        FixCastbarTaint()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Blizzard_PlayerSpells may already be loaded
        if PlayerSpellsFrame then
            FixTalentFrameConfigID()
            FixOnHideTaint()
            FixMultiActionBarTaint()
            FixMicroButtonTaint()
            self:UnregisterEvent("ADDON_LOADED")
        end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)
