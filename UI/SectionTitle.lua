local _, ns = ...

-------------------------------------------------------------------------------
-- SectionTitle: plain non-collapsible header used by panel-side sections.
-- Matches the About-page title style — gold text, fixed height
-- (ns.SECTION_HEADER_HEIGHT), anchored at the top of the section frame.
--
-- Returned frame is the header itself; callers anchor section content
-- below it (typically via "TOPLEFT", title, "BOTTOMLEFT").
-------------------------------------------------------------------------------

function ns.CreateSectionTitle(parent, label)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(ns.SECTION_HEADER_HEIGHT)
    hdr:SetPoint("TOPLEFT", 0, 0)
    hdr:SetPoint("RIGHT", 0, 0)
    local title = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 2, 0)
    title:SetText(label)
    title:SetTextColor(1, 0.82, 0)
    return hdr
end
