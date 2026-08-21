local _, ns = ...

-------------------------------------------------------------------------------
-- StatTargets: empirical stat rating targets from Archon (PvE M+/Raid).
--
-- Data lives in per-class files:
--   Data/{Class}/archon-stats.lua  -> ClassCodexArchonStats[CLASS][spec][context]
--
-- This module exposes:
--   ns.GetStatTargets(classToken, specKey, context) -> snapshot or nil
--   ns.GetPlayerStatRating(statKey) -> integer rating
--   ns.GetPlayerStatPercent(statKey) -> number (percent, e.g. 22.4)
--   ns.STAT_KEYS / ns.STAT_LABELS / ns.UNIVERSAL_DR
-------------------------------------------------------------------------------

-- Stat keys shared across scraper + addon.
ns.STAT_KEYS = { "crit", "haste", "mastery", "versatility" }

-- Canonical display labels (match Wowhead priority entries exactly).
ns.STAT_LABELS = {
    crit = "Critical Strike",
    haste = "Haste",
    mastery = "Mastery",
    versatility = "Versatility",
}

-- Reverse lookup: display label -> stat key.
ns.STAT_KEY_FROM_LABEL = {}
for key, label in pairs(ns.STAT_LABELS) do
    ns.STAT_KEY_FROM_LABEL[label] = key
end

-- Universal diminishing-returns rating thresholds in The War Within.
-- Above these ratings, each point of rating is less effective.
-- Documented on Wowhead's "Secondary Stats and Diminishing Returns" guide.
ns.UNIVERSAL_DR = {
    crit = 1380,
    haste = 1320,
    mastery = 1380,
    versatility = 1620,
}

-- DR brackets by stat percentage (post-DR character-sheet value). Once a
-- secondary stat % crosses a bracket boundary, every additional rating
-- point converts at the bracket's multiplier. The values match the
-- well-published TWW formula used by True Stat Values / Bagnon Stat etc.
ns.DR_BRACKETS = {
    { pct = 30, mult = 1.00 },
    { pct = 39, mult = 0.90 },
    { pct = 47, mult = 0.80 },
    { pct = 54, mult = 0.70 },
    { pct = 66, mult = 0.60 },
    { pct = math.huge, mult = 0.50 },
}

-- Returns the marginal effectiveness multiplier (0..1) for the player's
-- next rating point given their current stat % — i.e. "the next rating
-- point gives X% of its linear value."
function ns.GetMarginalDR(currentPct)
    if not currentPct or currentPct <= 0 then return 1 end
    for _, b in ipairs(ns.DR_BRACKETS) do
        if currentPct < b.pct then return b.mult end
    end
    return 0.5
end

-------------------------------------------------------------------------------
-- Data lookup (Archon PvE).
-------------------------------------------------------------------------------

-- Canonicalise a context string to the keys used in data files.
-- Accepts common aliases so callers don't need to worry about exact spelling.
local function NormalizeContext(ctx)
    if not ctx then return nil end
    local lc = ctx:lower()
    if lc:find("raid") then return "Raid" end
    if lc:find("mythic+") or lc:find("m+") or lc:find("dungeon") then
        return "Mythic+"
    end
    return nil
end

-- Returns the stat-target snapshot for the given (class, spec, context), or nil.
-- Snapshot shape: { targets = { crit, haste, mastery, versatility } }
-- (the Archon source URL lives in the consolidated ClassCodexSources.)
function ns.GetStatTargets(classToken, specKey, context)
    if not classToken or not specKey then return nil end
    local normalized = NormalizeContext(context)
    if not normalized then return nil end

    local root = _G.ClassCodexArchonStats
    if not root then return nil end

    local classData = root[classToken]
    if not classData then return nil end
    local specData = classData[specKey]
    if not specData then return nil end
    return specData[normalized]
end

-------------------------------------------------------------------------------
-- Live player stats (WoW API accessors).
-------------------------------------------------------------------------------

local function safeNum(v)
    if type(v) == "number" then return v end
    return 0
end

-- Rating is the integer "X Haste rating" number shown in the character sheet.
function ns.GetPlayerStatRating(statKey)
    if statKey == "crit" then
        return safeNum(GetCombatRating(CR_CRIT_MELEE)) -- all three (melee/ranged/spell) match
    elseif statKey == "haste" then
        return safeNum(GetCombatRating(CR_HASTE_MELEE))
    elseif statKey == "mastery" then
        return safeNum(GetCombatRating(CR_MASTERY))
    elseif statKey == "versatility" then
        return safeNum(GetCombatRating(CR_VERSATILITY_DAMAGE_DONE))
    end
    return 0
end

-- Effective percent visible on the character sheet (includes base + talents + buffs).
function ns.GetPlayerStatPercent(statKey)
    if statKey == "crit" then
        return safeNum(GetCritChance())
    elseif statKey == "haste" then
        return safeNum(GetHaste())
    elseif statKey == "mastery" then
        return safeNum(GetMasteryEffect())
    elseif statKey == "versatility" then
        -- Damage-done bonus from rating only. The earlier double-source
        -- accumulator (rating + GetVersatilityBonus) double-counted on
        -- some specs because GetVersatilityBonus' result already
        -- includes the rating contribution; we now match what
        -- GetCombatRatingBonus reports for the other secondaries.
        return safeNum(GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE))
    end
    return 0
end

-------------------------------------------------------------------------------
-- Delta classification: how does the player compare to the target?
-- Returns "above" | "at" | "below" along with the percent difference.
-------------------------------------------------------------------------------

function ns.ClassifyStatDelta(currentRating, targetRating)
    if not targetRating or targetRating <= 0 then return nil, 0 end
    local diff = currentRating - targetRating
    local pct = (diff / targetRating) * 100
    if math.abs(pct) < 5 then
        return "at", pct
    elseif pct > 0 then
        return "above", pct
    else
        return "below", pct
    end
end

-------------------------------------------------------------------------------
-- Shared tooltip builder — appends target / status lines for a single
-- secondary stat to a GameTooltip. Used by the Stat Targets row hover.
-------------------------------------------------------------------------------

local STATE_COLORS = {
    above = { 0.40, 0.70, 1.00 }, -- blue
    at    = { 0.40, 1.00, 0.45 }, -- green
    below = { 1.00, 0.40, 0.40 }, -- red
}

function ns.AppendStatExtrasToTooltip(tooltip, statKey, snapshot, opts)
    if not tooltip or not statKey then return end
    opts = opts or {}
    local label = ns.STAT_LABELS[statKey] or statKey
    local current = ns.GetPlayerStatRating(statKey) or 0
    local livePct = ns.GetPlayerStatPercent(statKey) or 0
    local target = snapshot and snapshot.targets and snapshot.targets[statKey]

    if opts.includeTitle then
        tooltip:AddLine(label, 1, 0.82, 0)
        tooltip:AddDoubleLine(
            string.format("%.1f%%", livePct),
            string.format("%d rating", current),
            1, 1, 1, 0.75, 0.75, 0.75)
    end

    if not opts.omitTarget and target and target > 0 then
        if opts.includeTitle then tooltip:AddLine(" ") end
        tooltip:AddDoubleLine("Target", string.format("%d", target),
            0.7, 0.7, 0.7, 1, 1, 1)
        local kind = ns.ClassifyStatDelta(current, target) or "below"
        local diff = current - target
        local sign = (diff >= 0) and "+" or "−"
        local stateLabels = {
            above = "Above target",
            at    = "At target",
            below = "Below target",
        }
        local c = STATE_COLORS[kind]
        tooltip:AddDoubleLine(stateLabels[kind], string.format("%s%d", sign, math.abs(diff)),
            c[1], c[2], c[3], c[1], c[2], c[3])
    end
end

-------------------------------------------------------------------------------
-- Context-aware ranking (drives tooltip # badges).
--
-- Produces { [statLabel] = tier } from a snapshot. Stats within `tolerance`
-- fraction of each other are tied into the same tier, walking sorted (highest
-- rating first). Default tolerance 0.15 means "within 15%".
--
-- Chain-tolerance: if A and B are within tolerance, and B and C are within
-- tolerance of each other, all three share a tier even if A and C exceed the
-- tolerance. Intentional — "close stats share a rank" feels right when the
-- whole cluster is in the same ballpark.
-------------------------------------------------------------------------------

function ns.DeriveSecondaryRanks(snapshot, tolerance)
    if not snapshot or not snapshot.targets then return nil end
    tolerance = tolerance or 0.15

    local entries = {}
    for key, label in pairs(ns.STAT_LABELS) do
        local val = snapshot.targets[key]
        if val ~= nil then
            entries[#entries + 1] = { label = label, value = val }
        end
    end
    if #entries == 0 then return nil end

    table.sort(entries, function(a, b) return a.value > b.value end)

    local ranks = {}
    local tier = 1
    ranks[entries[1].label] = tier
    for i = 2, #entries do
        local prev = entries[i - 1].value
        local cur = entries[i].value
        local gap = (prev > 0) and ((prev - cur) / prev) or 1
        if gap > tolerance then
            tier = tier + 1
        end
        ranks[entries[i].label] = tier
    end
    return ranks
end
