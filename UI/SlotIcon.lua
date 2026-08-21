local _, ns = ...

-------------------------------------------------------------------------------
-- SlotIcon: polished slot-style item icon with corner markers.
--
-- Renders an item icon inside a chunky Blizzard "UI-Quickslot2" bevel
-- frame, layered the way KeystoneLoot's icon button does it:
--
--   layer       sublvl   what                                  visible role
--   ARTWORK     -1       auctionhouse-itemicon-empty (alpha)   empty/loading
--   ARTWORK     0        item icon texture                     the item art
--   ARTWORK     1        UI-Quickslot2, sized ~1.8x the icon   the chunky bevel
--   OVERLAY     1        corner markers (BiS, owned, etc.)     status badges
--
-- Why this shape: a bare 40x40 texture with a same-size slot frame ends
-- up looking ungrounded — the Blizzard frame's outer corners barely
-- extend past the icon edge, so the bevel reads as a thin line. KL's
-- icon button sizes the frame texture ~1.8x the icon, drops the
-- TexCoord crop, and the chunky corners pop. We replicate that here so
-- every section that needs a "real" item slot can call into one helper
-- and get identical visuals.
--
-- Future tabs (Gear/Trinkets/Enhancements card variants) can adopt this
-- helper by calling ns.CreateSlotIcon(parent, { size = N }) and setting
-- markers via ns.SlotIconMarkers presets — no per-tab divergence.
-------------------------------------------------------------------------------

local DEFAULT_ICON_SIZE   = 32
local DEFAULT_SLOT_RATIO  = 1.8125 -- KL reminder ratio (58/32); 52/28 ≈ 1.857
local DEFAULT_ICON_TRIM   = 0.08   -- matches KL's TexCoord crop
local DEFAULT_MARKER_SIZE = 20
local DEFAULT_MARKER_INSET = 7     -- corners sit this far outside the icon
local EMPTY_ATLAS         = "auctionhouse-itemicon-empty"
local SLOT_TEXTURE        = "Interface\\Buttons\\UI-Quickslot2"

-- C_Texture.GetAtlasInfo returns nil for atlases that don't exist on
-- the current client. We use it before SetAtlas so a marker spec with
-- an atlas + texture pair gracefully falls back when the atlas is
-- missing (older client, Classic, etc.).
local function AtlasExists(name)
    if not name then return false end
    if not C_Texture or not C_Texture.GetAtlasInfo then return false end
    return C_Texture.GetAtlasInfo(name) ~= nil
end

local CORNER_LAYOUT = {
    topleft     = { point = "TOPLEFT",     dx = -1, dy =  1 },
    topright    = { point = "TOPRIGHT",    dx =  1, dy =  1 },
    bottomleft  = { point = "BOTTOMLEFT",  dx = -1, dy = -1 },
    bottomright = { point = "BOTTOMRIGHT", dx =  1, dy = -1 },
}

-- ns.SlotIconMarkers: preset registry. Each section that needs a marker
-- adds its preset here so other sections render the same marker the
-- same way. corner picks one of the four CORNER_LAYOUT keys; spec is
-- the texture/atlas + sizing handed to SetMarker. Keep TOPLEFT for
-- primary recommendation (BiS, Must-have), TOPRIGHT for ownership/
-- state, and the bottom row for secondary signals (catalyst, warning,
-- etc.).
--
-- Each spec supports both `atlas` and `texture` — atlas is preferred
-- (modern polished aesthetic, matches KL's custom tier ribbons) and
-- falls back to the texture when the atlas isn't present on the
-- client.
ns.SlotIconMarkers = {
    bis = {
        -- Wowhead "W" mark — Crafting BiS designations originate on
        -- Wowhead (Archon surfaces them via a BadgeLabel that links
        -- to the Wowhead BiS guide; see parse-archon-crafts.ts:113).
        -- Same wowhead.tga asset reused across the addon for any
        -- Wowhead-sourced attribution.
        --
        -- All three source-attribution markers (bis, popular_archon,
        -- popular_murlok) live at top-left. BiS stays anchored to the
        -- corner; PaintCardIcon shifts the popular mark DOWN when both
        -- are shown so they stack vertically (bis on top) at the same
        -- corner without overlap.
        corner = "topleft",
        spec = {
            texture = "Interface\\AddOns\\ClassCodex\\Textures\\wowhead",
            size = 13,
        },
    },
    popular_archon = {
        -- "Most-played" marker attributed to Archon — used in PvE
        -- contexts (raid + Mythic+) where the popularity signal comes
        -- from Archon's top-player gear page.
        corner = "topleft",
        spec = {
            texture = "Interface\\AddOns\\ClassCodex\\Textures\\archon",
            size = 13,
        },
    },
    popular_murlok = {
        -- "Most-played" marker attributed to Murlok — used in the PvP
        -- context where popularity is sourced from Murlok's per-spec
        -- pickrates. Mutually exclusive with popular_archon (the
        -- active context picks one).
        corner = "topleft",
        spec = {
            texture = "Interface\\AddOns\\ClassCodex\\Textures\\murlok",
            size = 13,
        },
    },
    owned = {
        corner = "topright",
        spec = {
            -- Clean modern checkmark from the common UI atlas (used by
            -- the friends list, communities, etc.). Falls back to the
            -- classic CheckBox-Check for older clients.
            atlas = "common-icon-checkmark",
            texture = "Interface\\Buttons\\UI-CheckBox-Check",
            size = 16,
        },
    },
}

-------------------------------------------------------------------------------
-- Marker plumbing
-------------------------------------------------------------------------------

local function CreateMarkerTexture(icon, corner, offsetX, offsetY)
    local layout = CORNER_LAYOUT[corner]
    if not layout then return nil end
    local tex = icon:CreateTexture(nil, "OVERLAY", nil, 1)
    tex:SetSize(icon._opts.markerSize, icon._opts.markerSize)
    tex:SetPoint(
        layout.point, icon, layout.point,
        layout.dx * icon._opts.markerInset + (offsetX or 0),
        layout.dy * icon._opts.markerInset + (offsetY or 0)
    )
    tex:Hide()
    return tex
end

-- Re-anchor an existing marker texture. Used when callers shift a
-- marker at runtime (e.g. shifting `bis` right when `popular` is also
-- shown so the two sit side-by-side at top-left).
local function RepositionMarker(icon, tex, corner, offsetX, offsetY)
    local layout = CORNER_LAYOUT[corner]
    if not layout then return end
    tex:ClearAllPoints()
    tex:SetPoint(
        layout.point, icon, layout.point,
        layout.dx * icon._opts.markerInset + (offsetX or 0),
        layout.dy * icon._opts.markerInset + (offsetY or 0)
    )
end

local function ApplySpec(tex, spec)
    if not spec then tex:Hide(); return end
    local applied = false
    if AtlasExists(spec.atlas) then
        tex:SetAtlas(spec.atlas)
        applied = true
    elseif spec.texture then
        tex:SetTexture(spec.texture)
        applied = true
    end
    if not applied then tex:Hide(); return end
    if spec.size then tex:SetSize(spec.size, spec.size) end
    tex:SetAlpha(spec.alpha or 1)
    if spec.vertexColor then
        tex:SetVertexColor(spec.vertexColor[1], spec.vertexColor[2], spec.vertexColor[3], spec.vertexColor[4] or 1)
    else
        tex:SetVertexColor(1, 1, 1, 1)
    end
    tex:Show()
end

-------------------------------------------------------------------------------
-- Instance API (mixed into the returned Frame)
-------------------------------------------------------------------------------

local SlotIconAPI = {}

-- Resolve an icon texture for itemId via the cached APIs. C_Item path
-- is preferred (no localisation/quality round-trip); GetItemInfo path
-- covers older clients + items still loading from the server.
local function ResolveIconTexture(itemId)
    if not itemId or itemId == 0 then return nil end
    if C_Item and C_Item.GetItemIconByID then
        local i = C_Item.GetItemIconByID(itemId)
        if i then return i end
    end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
    return icon
end

function SlotIconAPI:SetItem(itemId)
    self._itemId = itemId
    local tex = ResolveIconTexture(itemId)
    if tex then
        self.tex:SetTexture(tex)
        self.tex:Show()
        self.empty:Hide()
    else
        -- Either no itemId or the item hasn't been cached yet. Either
        -- way, fall back to the auctionhouse-itemicon-empty atlas so the
        -- frame doesn't render a QuestionMark placeholder for a few ms.
        self.tex:Hide()
        self.empty:Show()
        if itemId and itemId ~= 0 and C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemId)
        end
    end
end

-- Markers are keyed by NAME (not corner) so multiple markers can share
-- a corner — e.g. `bis` and `popular` both at top-left, side-by-side.
-- The corner + offset come from the registered preset
-- (ns.SlotIconMarkers[name]) plus any runtime offset set via
-- SetMarkerOffset.
local function ResolveMarker(icon, name)
    local preset = ns.SlotIconMarkers[name]
    if not preset then return nil end
    local offset = icon._markerOffsets[name]
    return preset, offset
end

function SlotIconAPI:SetMarkerOffset(name, offsetX, offsetY)
    self._markerOffsets[name] = { x = offsetX or 0, y = offsetY or 0 }
    local tex = self.markers[name]
    local preset = ns.SlotIconMarkers[name]
    if tex and preset then
        RepositionMarker(self, tex, preset.corner, offsetX, offsetY)
    end
end

function SlotIconAPI:SetMarkerByName(name)
    local preset, offset = ResolveMarker(self, name)
    if not preset then return end
    local tex = self.markers[name]
    if not tex then
        tex = CreateMarkerTexture(
            self, preset.corner,
            offset and offset.x or 0,
            offset and offset.y or 0
        )
        self.markers[name] = tex
    end
    ApplySpec(tex, preset.spec)
end

function SlotIconAPI:ClearMarkerByName(name)
    local tex = self.markers[name]
    if tex then tex:Hide() end
end

function SlotIconAPI:ClearAllMarkers()
    for _, tex in pairs(self.markers) do tex:Hide() end
end

-- Toggle a registered marker on/off in one call (typical hot-path use).
function SlotIconAPI:ToggleMarker(name, shown)
    if shown then self:SetMarkerByName(name) else self:ClearMarkerByName(name) end
end

function SlotIconAPI:SetDesaturated(flag)
    self.tex:SetDesaturated(flag and true or false)
end

-------------------------------------------------------------------------------
-- Public factory
-------------------------------------------------------------------------------

-- ns.CreateSlotIcon(parent, opts) -> Frame
-- opts (all optional):
--   size         icon edge length (defaults DEFAULT_ICON_SIZE)
--   slotSize     explicit slot frame edge length (defaults size * slotRatio)
--   slotRatio    multiplier vs size when slotSize is not provided
--   iconTrim     TexCoord crop applied to the icon (built-in Blizzard
--                icons have a ~7-8% margin; trimming it lets the icon
--                sit flush inside the slot bevel)
--   markerSize   default size for corner markers
--   markerInset  how far outside the icon corner each marker sits
function ns.CreateSlotIcon(parent, opts)
    opts = opts or {}
    local size       = opts.size       or DEFAULT_ICON_SIZE
    local slotSize   = opts.slotSize   or math.floor(size * (opts.slotRatio or DEFAULT_SLOT_RATIO) + 0.5)
    local iconTrim   = opts.iconTrim   or DEFAULT_ICON_TRIM
    local markerSize = opts.markerSize or DEFAULT_MARKER_SIZE
    local markerInset = opts.markerInset or DEFAULT_MARKER_INSET

    local btn = CreateFrame("Frame", nil, parent)
    btn:SetSize(size, size)
    btn._opts = {
        size = size,
        slotSize = slotSize,
        markerSize = markerSize,
        markerInset = markerInset,
    }
    btn.markers = {}
    btn._markerOffsets = {}

    -- ARTWORK -1: empty-slot placeholder (loading/no-icon fallback).
    local empty = btn:CreateTexture(nil, "ARTWORK", nil, -1)
    empty:SetAtlas(EMPTY_ATLAS)
    empty:SetAllPoints()
    empty:SetAlpha(0.7)
    btn.empty = empty

    -- ARTWORK 0: the item icon itself.
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(iconTrim, 1 - iconTrim, iconTrim, 1 - iconTrim)
    btn.tex = tex

    -- ARTWORK 1: chunky Quickslot2 bevel. No TexCoord crop — the full
    -- texture is what gives the frame its weight.
    local slot = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    slot:SetTexture(SLOT_TEXTURE)
    slot:SetSize(slotSize, slotSize)
    slot:SetPoint("CENTER", btn, "CENTER")
    btn.slot = slot

    for k, v in pairs(SlotIconAPI) do btn[k] = v end

    return btn
end

-- The slot frame extends slightly past the icon edges; callers laying
-- out cards need to know the actual visual half-extent so the icon
-- doesn't clip into card edges. half = max(size, slotSize) / 2.
function ns.SlotIconHalfExtent(opts)
    opts = opts or {}
    local size = opts.size or DEFAULT_ICON_SIZE
    local slot = opts.slotSize or math.floor(size * (opts.slotRatio or DEFAULT_SLOT_RATIO) + 0.5)
    return math.max(size, slot) / 2
end
