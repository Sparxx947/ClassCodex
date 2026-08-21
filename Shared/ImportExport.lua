local addonName, ns = ...

-------------------------------------------------------------------------------
-- ImportExport: Parse and apply Blizzard talent export strings
--
-- V2 parser + C_Traits staging + CommitConfig to a dedicated loadout slot.
-- Directly based on TalentLoadoutManager's proven approach.
-------------------------------------------------------------------------------

if not ExportUtil or not C_Traits or not C_ClassTalents then
    function ns.ApplyTalentExportString()
        return nil, "Required talent APIs not available"
    end
    return
end

-------------------------------------------------------------------------------
-- Constants (match Blizzard's V2 serialization format)
-------------------------------------------------------------------------------

local BIT_WIDTH_HEADER_VERSION = 8
local BIT_WIDTH_SPEC_ID = 16
local BIT_WIDTH_RANKS_PURCHASED = 6

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

local function Msg(text)
    print("|cff00ccffClass Codex:|r " .. text)
end

local function GetSpecID()
    local specIndex = GetSpecialization()
    if not specIndex then return nil end
    return (GetSpecializationInfo(specIndex))
end

local function GetTreeID()
    local configInfo = C_Traits.GetConfigInfo(C_ClassTalents.GetActiveConfigID())
    return configInfo and configInfo.treeIDs and configInfo.treeIDs[1]
end

-------------------------------------------------------------------------------
-- V2 Parser (copied from TalentLoadoutManager/ImportExportV2.lua)
-------------------------------------------------------------------------------

local function ReadLoadoutHeader(importStream)
    local headerBitWidth = BIT_WIDTH_HEADER_VERSION + BIT_WIDTH_SPEC_ID + 128
    if importStream:GetNumberOfBits() < headerBitWidth then
        return false, 0, 0
    end
    local serializationVersion = importStream:ExtractValue(BIT_WIDTH_HEADER_VERSION)
    local specID = importStream:ExtractValue(BIT_WIDTH_SPEC_ID)
    -- treeHash: 128 bits, 16 x 8-bit values
    local treeHash = {}
    for i = 1, 16 do
        treeHash[i] = importStream:ExtractValue(8)
    end
    return true, serializationVersion, specID, treeHash
end

local function ReadLoadoutContent(importStream, treeID)
    local results = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)
    for i, nodeID in ipairs(treeNodes) do
        local isNodeSelected = importStream:ExtractValue(1) == 1
        local isNodePurchased = false
        local isPartiallyRanked = false
        local partialRanksPurchased = 0
        local isChoiceNode = false
        local choiceNodeSelection = 0

        if isNodeSelected then
            isNodePurchased = importStream:ExtractValue(1) == 1
            if isNodePurchased then
                isPartiallyRanked = importStream:ExtractValue(1) == 1
                if isPartiallyRanked then
                    partialRanksPurchased = importStream:ExtractValue(BIT_WIDTH_RANKS_PURCHASED)
                end
                isChoiceNode = importStream:ExtractValue(1) == 1
                if isChoiceNode then
                    choiceNodeSelection = importStream:ExtractValue(2)
                end
            end
        end

        results[i] = {
            nodeID = nodeID,
            isNodeSelected = isNodeSelected,
            isNodeGranted = isNodeSelected and not isNodePurchased,
            isNodePurchased = isNodePurchased,
            isPartiallyRanked = isPartiallyRanked,
            partialRanksPurchased = partialRanksPurchased,
            isChoiceNode = isChoiceNode,
            choiceNodeSelection = choiceNodeSelection + 1, -- zero-indexed → lua
        }
    end
    return results
end

local function ConvertToEntryInfo(configID, treeID, loadoutContent)
    local results = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)
    for i, treeNodeID in ipairs(treeNodes) do
        local indexInfo = loadoutContent[i]
        if indexInfo and indexInfo.isNodePurchased then
            local nodeInfo = C_Traits.GetNodeInfo(configID, treeNodeID)
            if nodeInfo and nodeInfo.ID ~= 0 then
                local isChoice = nodeInfo.type == Enum.TraitNodeType.Selection
                              or nodeInfo.type == Enum.TraitNodeType.SubTreeSelection
                local choiceIdx = indexInfo.isChoiceNode and indexInfo.choiceNodeSelection or nil
                if isChoice ~= indexInfo.isChoiceNode then
                    choiceIdx = 1 -- corrupt string fallback
                end
                local selectionEntryID
                if isChoice and choiceIdx and nodeInfo.entryIDs then
                    selectionEntryID = nodeInfo.entryIDs[choiceIdx]
                elseif nodeInfo.activeEntry then
                    selectionEntryID = nodeInfo.activeEntry.entryID
                end

                local ranks = nodeInfo.maxRanks or 1
                if indexInfo.isPartiallyRanked then
                    ranks = indexInfo.partialRanksPurchased
                end

                results[treeNodeID] = {
                    nodeID = treeNodeID,
                    ranksPurchased = ranks,
                    selectionEntryID = selectionEntryID,
                    isChoiceNode = isChoice,
                }
            end
        end
    end
    return results
end

-- ParseExportString
--
-- `expectedSpecID` and `configID` are optional overrides — when present
-- they replace the player's current spec / configID resolution, which
-- is what the inspect-mode hover-diff path needs. Without them this
-- behaves exactly as before (apply path).
local function ParseExportString(exportString, treeID, expectedSpecID, configID)
    local ok, importStream = pcall(ExportUtil.MakeImportDataStream, exportString)
    if not ok or not importStream then
        return nil, "Failed to decode export string"
    end

    local headerValid, version, specID = ReadLoadoutHeader(importStream)
    if not headerValid then
        return nil, "Invalid export string"
    end
    if version ~= C_Traits.GetLoadoutSerializationVersion() then
        return nil, "Serialization version mismatch"
    end

    local checkAgainst = expectedSpecID or GetSpecID()
    if specID ~= checkAgainst then
        return nil, format("Export is for specID %d, active is %d", specID, checkAgainst)
    end

    local loadoutContent = ReadLoadoutContent(importStream, treeID)
    local effectiveConfigID = configID or C_ClassTalents.GetActiveConfigID()
    local entryInfo = ConvertToEntryInfo(effectiveConfigID, treeID, loadoutContent)

    return entryInfo
end

-------------------------------------------------------------------------------
-- ns.ParseLoadoutNodes(exportString) -> { [nodeID] = { ranksPurchased,
--   selectionEntryID, isChoiceNode } } or nil, err
--
-- Parse-only path (no staging, no commit). Used by the talent-pane frame's
-- hover-diff to decode a build's export string against the player's active
-- tree without applying anything.
-------------------------------------------------------------------------------
function ns.ParseLoadoutNodes(exportString)
    if not exportString or exportString == "" then
        return nil, "Empty export string"
    end
    local treeID, configID, expectedSpecID
    -- Inspect mode: resolve tree, configID and expected spec from the
    -- talent frame's current state, not the local player. The export
    -- string's specID won't match the local player's when classes
    -- differ, and the tree/configID need to be the inspected target's
    -- for ConvertToEntryInfo to look up node info correctly.
    if ns._talentPaneInspect then
        local tf = PlayerSpellsFrame and PlayerSpellsFrame.TalentsFrame
        if tf and tf.GetConfigID then
            local ok, id = pcall(tf.GetConfigID, tf)
            if ok then configID = id end
        end
        if not configID then
            configID = (Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID) or -1
        end
        local info = C_Traits.GetConfigInfo(configID)
        treeID = info and info.treeIDs and info.treeIDs[1]
        expectedSpecID = ns._talentPaneInspect.specID
    else
        treeID = GetTreeID()
    end
    if not treeID then return nil, "Cannot determine talent tree" end
    return ParseExportString(exportString, treeID, expectedSpecID, configID)
end

-------------------------------------------------------------------------------
-- Purchase entries (multi-pass, deferred across frames — based on TLM
-- PurchaseOrderedEntries but batched so the UI doesn't freeze for ~1s
-- on a full reset+purchase. Processes BATCH_SIZE nodes per frame; multi-
-- pass semantics preserved (re-runs until no progress is made). Calls
-- onComplete when finished.
--
-- An applyToken guards against overlapping calls: each invocation gets
-- a unique token and aborts early if a newer call has been started.
-------------------------------------------------------------------------------

local BATCH_SIZE = 100 -- effectively process the whole tree in one batch; the suppression flag keeps the freeze short, async only kicks in for trees larger than this
local applyToken = 0

local function ResetAndPurchaseDeferred(configID, treeID, entryInfo, onComplete)
    applyToken = applyToken + 1
    local myToken = applyToken

    C_Traits.ResetTree(configID, treeID)

    local orderedNodes = C_Traits.GetTreeNodes(treeID)
    table.sort(orderedNodes, function(a, b)
        local aI = C_Traits.GetNodeInfo(configID, a)
        local bI = C_Traits.GetNodeInfo(configID, b)
        if aI.posY ~= bI.posY then return aI.posY < bI.posY end
        return aI.posX < bI.posX
    end)

    local i = 1
    local passProgress = 0

    local function step()
        if myToken ~= applyToken then return end -- superseded by a newer apply
        local processed = 0
        while i <= #orderedNodes and processed < BATCH_SIZE do
            local nodeID = orderedNodes[i]
            local entry = entryInfo[nodeID]
            if entry then
                local success = false
                if entry.isChoiceNode then
                    success = C_Traits.SetSelection(configID, entry.nodeID, entry.selectionEntryID)
                elseif entry.ranksPurchased then
                    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                    for _ = 1, (entry.ranksPurchased - (nodeInfo and nodeInfo.ranksPurchased or 0)) do
                        success = C_Traits.PurchaseRank(configID, entry.nodeID)
                    end
                end
                if success then
                    passProgress = passProgress + 1
                    entryInfo[nodeID] = nil
                end
            end
            i = i + 1
            processed = processed + 1
        end

        if i <= #orderedNodes then
            -- More nodes in this pass; continue next frame.
            C_Timer.After(0, step)
        elseif passProgress > 0 then
            -- Pass made progress; start another pass.
            i = 1
            passProgress = 0
            C_Timer.After(0, step)
        else
            -- Done.
            if onComplete then onComplete() end
        end
    end

    step()
end

-------------------------------------------------------------------------------
-- Dedicated "Class Codex" loadout slot (configID stored in CharDB per spec)
-------------------------------------------------------------------------------

local CC_NAME = "Class Codex"
local pendingApply = nil
local pendingApplySeq = 0

-- pendingApply stays set across the ENTIRE async lifecycle so the spam-
-- click guard at the top of ApplyTalentExportString blocks any user
-- re-entry between phases. Intermediate event handlers don't nil it —
-- only the terminal success/failure points do, via ClearPendingApply.
--
-- Legitimate continuations (handlers calling ApplyTalentExportString
-- via RunNextFrame) bypass the guard with _isContinuation=true.
--
-- The watchdog is a defence against Blizzard silently dropping an
-- expected TRAIT_CONFIG_* event: if the flag stays set past the
-- window, the watchdog auto-clears it so the player can apply again
-- without /reload. Sequence counter invalidates stale timers when
-- pendingApply is replaced or cleared mid-flight.
local PENDING_APPLY_WATCHDOG_SECS = 10
local function SetPendingApply(pa)
    pendingApplySeq = pendingApplySeq + 1
    local mySeq = pendingApplySeq
    pendingApply = pa
    C_Timer.After(PENDING_APPLY_WATCHDOG_SECS, function()
        if pendingApplySeq == mySeq then
            pendingApply = nil
        end
    end)
end

local function ClearPendingApply()
    pendingApplySeq = pendingApplySeq + 1 -- invalidate any in-flight watchdog
    pendingApply = nil
end

local function ClearStoredConfigID(specID)
    if not ClassCodexCharDB or not ClassCodexCharDB.ccLoadout then return end
    if specID then ClassCodexCharDB.ccLoadout[specID] = nil end
end

local function GetStoredConfigID()
    local specID = GetSpecID()
    if not specID or not ClassCodexCharDB then return nil end
    local stored = ClassCodexCharDB.ccLoadout and ClassCodexCharDB.ccLoadout[specID]
    if not stored then return nil end

    -- Validate against the live loadout list — GetConfigInfo can still return
    -- a stale table for a deleted configID, which would later make
    -- LoadConfig fail with Enum.LoadConfigResult.Error.
    if C_ClassTalents.GetConfigIDsBySpecID then
        local validIDs = C_ClassTalents.GetConfigIDsBySpecID(specID)
        if validIDs then
            for _, id in ipairs(validIDs) do
                if id == stored then return stored end
            end
            ClearStoredConfigID(specID)
            return nil
        end
    end

    local ok, info = pcall(C_Traits.GetConfigInfo, stored)
    if ok and info then return stored end
    ClearStoredConfigID(specID)
    return nil
end

local function StoreConfigID(configID)
    local specID = GetSpecID()
    if not specID or not ClassCodexCharDB then return end
    if not ClassCodexCharDB.ccLoadout then ClassCodexCharDB.ccLoadout = {} end
    ClassCodexCharDB.ccLoadout[specID] = configID
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "TRAIT_CONFIG_CREATED" then
        if type(arg1) ~= "table" then return end
        if not pendingApply then return end
        if arg1.type ~= Enum.TraitConfigType.Combat then return end
        if arg1.name ~= CC_NAME then return end
        self:UnregisterEvent("TRAIT_CONFIG_CREATED")
        StoreConfigID(arg1.ID)
        -- pendingApply intentionally kept set — the spam-click guard
        -- needs it across the brief window between this handler and
        -- the next-frame re-apply. The re-apply bypasses the guard
        -- via _isContinuation; its own SetPendingApply at the
        -- LoadConfig site overwrites this slot's data with phase-2
        -- data.
        local pa = pendingApply
        RunNextFrame(function()
            ns.ApplyTalentExportString(pa.exportString, pa.buildLabel, true)
        end)
    elseif event == "TRAIT_CONFIG_UPDATED" then
        if arg1 ~= C_ClassTalents.GetActiveConfigID() then return end
        if not pendingApply then return end
        self:UnregisterEvent("TRAIT_CONFIG_UPDATED")
        local pa = pendingApply
        if pa.renameOnly then
            -- Terminal success: commit cast finished, rename + notify.
            local ccConfigID = GetStoredConfigID()
            if ccConfigID then
                local loadoutName = CC_NAME .. ": " .. (pa.buildLabel or "Build")
                C_ClassTalents.RenameConfig(ccConfigID, loadoutName)
            end
            Msg("Talents applied: " .. (pa.buildLabel or "build"))
            ClearPendingApply()
            -- Defer the flag clear by one frame so any TRAIT_*_UPDATED
            -- events still pending in this dispatch cycle remain
            -- suppressed. Then explicitly refresh the talent dropdown
            -- so the (active) tag updates and the glow re-computes
            -- against the new active state (will be empty since the
            -- build matches).
            RunNextFrame(function()
                ns._talentApplyInProgress = false
                if ns._refreshTalentDiff then ns._refreshTalentDiff() end
            end)
        else
            -- LoadConfig cast finished — continuation to stage + commit.
            -- Same as the TRAIT_CONFIG_CREATED branch: keep pendingApply
            -- set across the next-frame window, let the re-apply
            -- overwrite via its own SetPendingApply.
            RunNextFrame(function()
                ns.ApplyTalentExportString(pa.exportString, pa.buildLabel, true)
            end)
        end
    end
end)

-------------------------------------------------------------------------------
-- ns.ApplyTalentExportString(exportString, buildLabel)
-------------------------------------------------------------------------------

-- Terminal-failure helper: every bail-out path runs through here so a
-- continuation that hits a precondition error never leaves
-- pendingApply set (which would otherwise lock the next user click
-- behind the spam-click guard until the watchdog expires).
local function Fail(msg)
    ClearPendingApply()
    return nil, msg
end

-- _isContinuation is true only when the function is re-entered from a
-- TRAIT_CONFIG_* handler's RunNextFrame to continue an in-flight apply.
-- User-initiated calls always omit it (or pass nil/false), which makes
-- the guard fire if a previous apply is still mid-flight.
function ns.ApplyTalentExportString(exportString, buildLabel, _isContinuation)
    if not exportString or exportString == "" then
        return Fail("Empty export string")
    end

    -- Spam-click guard: block any new user-initiated apply while a
    -- previous one is still mid-flight. pendingApply stays set across
    -- the entire async lifecycle (RequestNewConfig → LoadConfig cast
    -- → stage/commit cast → rename) so the guard catches clicks at
    -- every intermediate step, not just within a single phase.
    if pendingApply and not _isContinuation then
        return nil, "Apply already in progress — wait for it to finish."
    end

    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    if not activeConfigID then return Fail("No active talent configuration") end

    -- Combat is the only failure cause we can't recover from — staging
    -- and CommitConfig are both protected from combat lockdown. Check
    -- explicitly so the user gets a clear message instead of a mid-
    -- stage failure that looks like a bug.
    if InCombatLockdown and InCombatLockdown() then
        return Fail("Cannot change talents in combat.")
    end

    -- Unsaved talent changes (player clicked talents in the tree but
    -- didn't apply) cause LoadConfig to error in the create-fresh-slot
    -- path, which leaves the user puzzled when their build doesn't
    -- come through. Surface it before we do anything destructive so
    -- they know to apply or discard their manual edits first. Skip on
    -- continuation calls — staging legitimately stages changes on the
    -- scratch, and re-checking mid-flight would always trip.
    if not _isContinuation and C_Traits.ConfigHasStagedChanges
        and C_Traits.ConfigHasStagedChanges(activeConfigID)
    then
        return Fail("You have unsaved talent changes. Open the talents pane and click Apply Changes (or right-click the loadout name to discard) before applying a Class Codex build.")
    end

    -- We deliberately don't pre-flight C_ClassTalents.CanChangeTalents()
    -- here: it returns false whenever the tree has unspent currency,
    -- which would lock levelling players out of the apply path entirely.
    -- ResetAndPurchaseDeferred starts with ResetTree (refunds the whole
    -- tree) and then stages purchases until the player's currency is
    -- consumed — so unspent vs spent at entry doesn't matter, and the
    -- post-stage partial-apply warning surfaces if the build exceeds
    -- the player's budget. Other CanChangeTalents=false reasons (talent
    -- UI not loaded, PvP-zone restrictions, etc.) fall through to the
    -- existing CommitConfig branch which prints "Commit failed. Open
    -- talent frame and click Apply Changes."

    -- Fast path: if the CC loadout already has these exact talents AND
    -- it's the spec's currently-selected saved loadout, just rename it.
    -- Skips the full stage/commit cycle when two recommendations share
    -- the same build (e.g. "All Dungeons" and "Maisara Caverns") but the
    -- user wants the dock/loadout to read the more specific encounter
    -- name. The persistent ccConfigID is what we want to rename, NOT
    -- the in-memory scratch returned by GetActiveConfigID.
    if ns.ExtractTalentBits and ns.GetActiveTalentSignature
        and C_ClassTalents.RenameConfig and C_ClassTalents.GetLastSelectedSavedConfigID
    then
        local ccConfigID = GetStoredConfigID()
        local specID = GetSpecID()
        local lastSelected = specID and C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        if ccConfigID and lastSelected == ccConfigID then
            local activeBits = ns.GetActiveTalentSignature()
            local newBits = ns.ExtractTalentBits(exportString)
            if activeBits and newBits and activeBits == newBits then
                C_ClassTalents.RenameConfig(ccConfigID, CC_NAME .. ": " .. (buildLabel or "Build"))
                Msg("Renamed loadout to " .. (buildLabel or "Build"))
                ClearPendingApply()
                return true
            end
        end
    end

    local treeID = GetTreeID()
    if not treeID then return Fail("Cannot determine talent tree") end

    -- Parse
    local entryInfo, parseErr = ParseExportString(exportString, treeID)
    if not entryInfo then return Fail(parseErr) end

    -- Ensure we have a dedicated loadout slot
    local ccConfigID = GetStoredConfigID()
    if not ccConfigID then
        if C_ClassTalents.CanCreateNewConfig and not C_ClassTalents.CanCreateNewConfig() then
            return Fail("No free loadout slots — delete one to use Class Codex builds")
        end
        C_ClassTalents.RequestNewConfig(CC_NAME)
        SetPendingApply({ exportString = exportString, buildLabel = buildLabel })
        eventFrame:RegisterEvent("TRAIT_CONFIG_CREATED")
        Msg("Creating loadout slot...")
        return true
    end

    -- Switch to CC loadout if not on it (TLM does this before staging)
    local specID = GetSpecID()
    local currentLoadoutID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
    if currentLoadoutID ~= ccConfigID then
        local result = C_ClassTalents.LoadConfig(ccConfigID, true)
        if result == Enum.LoadConfigResult.LoadInProgress then
            SetPendingApply({ exportString = exportString, buildLabel = buildLabel })
            eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
            return true
        elseif result == Enum.LoadConfigResult.Error then
            -- LoadConfig failed even though GetStoredConfigID validated the
            -- ID against GetConfigIDsBySpecID up the stack. Clear the
            -- stored ID so a subsequent click runs the fresh path
            -- (RequestNewConfig branch), then surface the error. Do NOT
            -- recurse: a persistent LoadConfig failure (talent UI in a
            -- transient state, pending unstaged changes) would otherwise
            -- drive an unbounded create-slot / LoadConfig-fail loop and
            -- exhaust the player's loadout slots.
            ClearStoredConfigID(specID)
            return Fail("Could not load Class Codex loadout. Open the talents pane and click Apply Changes, then try again.")
        end
    end

    -- Re-fetch activeConfigID after LoadConfig may have changed it
    activeConfigID = C_ClassTalents.GetActiveConfigID()

    -- Snapshot for the partial-apply path (B): ResetAndPurchaseDeferred
    -- nils out entries from entryInfo as it successfully purchases
    -- them, so the leftover count after staging tells us how many
    -- nodes we couldn't afford at the player's current level.
    local originalNodeCount = 0
    for _ in pairs(entryInfo) do originalNodeCount = originalNodeCount + 1 end

    -- Reset + purchase: deferred across frames so the UI doesn't
    -- freeze on a ~50-node tree. Commit happens in the onComplete
    -- callback once all nodes are staged.
    --
    -- Set a global flag covering the WHOLE apply: deferred purchase
    -- loop AND the commit cast that follows. Observers (e.g. our own
    -- talent dropdown's TRAIT_TREE_CURRENCY_INFO_UPDATED handler) skip
    -- their per-event re-renders while the flag is set, so the diff
    -- glow doesn't flicker as the staged state shifts node-by-node
    -- and during the commit cast the player is watching.
    --
    -- Cleared on failure inside the onComplete callback; on success
    -- the flag stays true until the commit cast completes
    -- (TRAIT_CONFIG_UPDATED in renameOnly branch).
    ns._talentApplyInProgress = true
    ResetAndPurchaseDeferred(activeConfigID, treeID, entryInfo, function()
        if not C_Traits.ConfigHasStagedChanges(activeConfigID) then
            ns._talentApplyInProgress = false
            -- No staged changes means the CC loadout's talents already
            -- match. The user clicked a build by a different name
            -- (e.g. "Maisara Caverns" vs "All Dungeons") — rename so
            -- the loadout label reflects what they picked.
            if C_ClassTalents.RenameConfig and ccConfigID then
                C_ClassTalents.RenameConfig(ccConfigID, CC_NAME .. ": " .. (buildLabel or "Build"))
                Msg("Renamed loadout to " .. (buildLabel or "Build"))
            else
                Msg("Already using this build.")
            end
            ClearPendingApply()
            return
        end

        -- (B) Partial-apply warning. The staging loop is already
        -- robust to "ran out of currency" — failed PurchaseRank calls
        -- leave the node in entryInfo and a pass that makes zero
        -- progress terminates the loop. So if any nodes remain in
        -- entryInfo, it's because the player's current level couldn't
        -- afford or unlock them (typical levelling-vs-max-level-build
        -- case). Surface that as a single info line before committing
        -- so the user knows why their loadout looks shorter than the
        -- build description. We still call CommitConfig normally —
        -- if Blizzard rejects the partial state (e.g. leftover
        -- currency from multi-point nodes) the existing commit-fail
        -- branch directs them to the talent UI.
        local remainingNodes = 0
        for _ in pairs(entryInfo) do remainingNodes = remainingNodes + 1 end
        if remainingNodes > 0 then
            local applied = originalNodeCount - remainingNodes
            Msg(string.format(
                "Applying %d of %d nodes — your current level can't fit the rest. Level up and re-apply to fill in the remaining %d.",
                applied, originalNodeCount, remainingNodes))
        end

        if not C_ClassTalents.CommitConfig(ccConfigID) then
            ns._talentApplyInProgress = false
            Msg("|cffff0000Commit failed.|r Open talent frame and click Apply Changes.")
            ClearPendingApply()
            return
        end

        -- CommitConfig triggers a cast bar — defer rename to after cast.
        -- The apply-in-progress flag stays true until that fires.
        SetPendingApply({ buildLabel = buildLabel, renameOnly = true })
        eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")

        if C_ClassTalents.UpdateLastSelectedSavedConfigID then
            C_ClassTalents.UpdateLastSelectedSavedConfigID(specID, ccConfigID)
        end
    end)

    return true
end
