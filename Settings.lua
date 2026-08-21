local _, ns = ...
local L = ns.L

-------------------------------------------------------------------------------
-- Settings panel registration (WoW Settings API)
--
-- Extracted from ClassCodex.lua. Inline panel-refresh callbacks of the form
-- `function() if panel:IsShown() then ns:UpdatePanel() end end` are now
-- one-liners around ns.UpdatePanelIfVisible(mode) so we don't have to capture
-- the panel frame and isFloating flag from ClassCodex.lua's scope. Same for
-- ns.InvalidateTooltipCache.
-------------------------------------------------------------------------------

-- Widget offset slider bounds. Mirror the constants used in ClassCodex.lua
-- where the actual application logic lives (ApplyWidgetPosition etc.). The
-- defaults are duplicated rather than threaded through ns because they're
-- compile-time constants and the slider needs them at panel-build time.
local WIDGET_DEFAULT_OFFSET_X = -1
local WIDGET_DEFAULT_OFFSET_Y = -148
local WIDGET_OFFSET_MIN = -500
local WIDGET_OFFSET_MAX = 500

function ns.RegisterSettings()
    local ok, err = pcall(function()
        local category, layout = Settings.RegisterVerticalLayoutCategory("Class Codex")

        local function AddHeader(label)
            local init = CreateSettingsListSectionHeaderInitializer(label)
            layout:AddInitializer(init)
        end

        local function AddCheckbox(variable, name, tooltip, defaultValue, onChange)
            local setting = Settings.RegisterAddOnSetting(category, variable, variable, ClassCodexDB, type(defaultValue), name, defaultValue)
            if onChange then
                Settings.SetOnValueChangedCallback(variable, function()
                    onChange(ClassCodexDB[variable])
                end)
            end
            Settings.CreateCheckbox(category, setting, tooltip)
        end

        local function AddDropdown(variable, name, tooltip, defaultValue, options, onChange)
            local setting = Settings.RegisterAddOnSetting(category, variable, variable, ClassCodexDB, "number", name, defaultValue)
            if onChange then
                Settings.SetOnValueChangedCallback(variable, function()
                    onChange(ClassCodexDB[variable])
                end)
            end
            Settings.CreateDropdown(category, setting, function()
                local container = Settings.CreateControlTextContainer()
                for _, opt in ipairs(options) do container:Add(opt.value, opt.label) end
                return container:GetData()
            end, tooltip)
        end

        -- 1. General
        AddHeader(L["settings.header.general"])
        AddCheckbox("showMinimapButton", L["settings.label.minimap_button"],
            L["settings.tooltip.minimap_button"], true,
            function(val)
                if ns.LDBIcon then
                    ClassCodexDB.minimap.hide = not val
                    if val then
                        ns.LDBIcon:Show("ClassCodex")
                    else
                        ns.LDBIcon:Hide("ClassCodex")
                    end
                end
            end)

        AddCheckbox("showLoginMessage", L["settings.label.login_message"],
            L["settings.tooltip.login_message"], false, nil)

        -- 2. Character Pane Button. Reset is available in-game via Shift+Right-click
        -- on the gear icon, so we don't add a Settings reset button (the
        -- CreateSettingsButtonInitializer signature varies across client
        -- versions and was tripping a Blizzard assertion).
        local sectionOk, sectionErr = pcall(function()
            AddHeader(L["settings.header.character_pane_button"])
            AddCheckbox("widgetLocked", L["settings.label.lock_button_position"],
                L["settings.tooltip.lock_button_position"], false,
                function() if ns.RefreshWidgetTooltip then ns.RefreshWidgetTooltip() end end)

            local function AddOffsetSlider(variable, label, tooltip, defaultValue)
                local setting = Settings.RegisterAddOnSetting(category, variable, variable, ClassCodexDB,
                    Settings.VarType.Number, label, defaultValue)
                Settings.SetOnValueChangedCallback(variable, function()
                    if ns.ApplyWidgetPosition then ns.ApplyWidgetPosition() end
                end)
                local sliderOptions = Settings.CreateSliderOptions(WIDGET_OFFSET_MIN, WIDGET_OFFSET_MAX, 1)
                sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                    return tostring(value)
                end)
                Settings.CreateSlider(category, setting, sliderOptions, tooltip)
            end

            AddOffsetSlider("widgetOffsetX", L["settings.label.horizontal_offset"],
                L["settings.tooltip.horizontal_offset"], WIDGET_DEFAULT_OFFSET_X)
            AddOffsetSlider("widgetOffsetY", L["settings.label.vertical_offset"],
                L["settings.tooltip.vertical_offset"], WIDGET_DEFAULT_OFFSET_Y)
        end)
        if not sectionOk then
            print("|cffff0000Class Codex:|r Character Pane Button section failed: " .. tostring(sectionErr))
        end

        -- 3. Tooltips
        AddHeader(L["settings.header.tooltips"])
        AddCheckbox("showTooltipBadges", L["settings.label.stat_priority_ranks"],
            L["settings.tooltip.stat_priority_ranks"], true, nil)

        AddDropdown("tooltipFooterMode", L["settings.label.stat_priority_source_line"],
            L["settings.tooltip.bis_source"],
            0,
            {
                { value = 0, label = L["settings.value.off"] },
                { value = 1, label = L["settings.value.always"] },
                { value = 2, label = L["settings.value.only_when_different"] },
            }, nil)

        AddCheckbox("showWowheadBisTooltip", L["settings.label.wowhead_bis"],
            L["settings.tooltip.wowhead_bis"], true, ns.InvalidateTooltipCache)

        AddCheckbox("showIcyVeinsBisTooltip", L["settings.label.icy_veins_bis"],
            L["settings.tooltip.icy_veins_bis"], true, ns.InvalidateTooltipCache)

        AddCheckbox("showTrinketTooltip", L["settings.label.trinket_tier"],
            L["settings.tooltip.trinket_tier"], true, ns.InvalidateTooltipCache)

        do
            local variable = "tooltipBisScope"
            local defaultValue = "all"
            local function GetOptions()
                local container = Settings.CreateControlTextContainer()
                container:Add("all", L["settings.value.bis_scope_all"])
                container:Add("group", L["settings.value.bis_scope_group"])
                container:Add("self", L["settings.value.bis_scope_self"])
                container:Add("off", L["settings.value.off"])
                return container:GetData()
            end
            local setting = Settings.RegisterAddOnSetting(category, variable, variable, ClassCodexDB,
                type(defaultValue), L["settings.label.bis_scope"], defaultValue)
            Settings.SetOnValueChangedCallback(variable, function() ns.InvalidateTooltipCache() end)
            Settings.CreateDropdown(category, setting, GetOptions, L["settings.tooltip.bis_scope"])
        end

        do
            local variable = "tooltipSourceStyle"
            local defaultValue = 1
            local function GetOptions()
                local container = Settings.CreateControlTextContainer()
                container:Add(1, L["settings.value.icons"])
                container:Add(2, L["settings.value.labels"])
                container:Add(3, L["settings.value.both"])
                return container:GetData()
            end
            local setting = Settings.RegisterAddOnSetting(category, variable, variable, ClassCodexDB, type(defaultValue), L["settings.label.source_display"], defaultValue)
            Settings.SetOnValueChangedCallback(variable, function() ns.InvalidateTooltipCache() end)
            Settings.CreateDropdown(category, setting, GetOptions, L["settings.tooltip.source_display"])
        end

        -- 4. Crafting
        AddHeader(L["settings.header.crafting"])
        AddCheckbox("craftingTopPicksOnly", L["settings.label.crafting_top_picks_only"],
            L["settings.tooltip.crafting_top_picks_only"], true,
            function()
                if ns.UpdatePanel then ns:UpdatePanel() end
                if ns.UpdateCompendium then ns:UpdateCompendium() end
            end)

        -- 5. Loadout Dock
        AddHeader(L["settings.header.loadout_dock"])
        AddCheckbox("dockLoadoutEnabled", L["settings.label.show_loadout_dock"],
            L["settings.tooltip.show_loadout_dock"], false,
            function() if ns.UpdateLoadoutDockVisibility then ns.UpdateLoadoutDockVisibility() end end)
        AddCheckbox("dockLoadoutHideInCombat", L["settings.label.dock_hide_in_combat"],
            L["settings.tooltip.dock_hide_in_combat"], true,
            function() if ns.UpdateLoadoutDockVisibility then ns.UpdateLoadoutDockVisibility() end end)
        AddCheckbox("dockLoadoutLocked", L["settings.label.dock_lock_position"],
            L["settings.tooltip.dock_lock_position"], false, nil)
        AddCheckbox("dockLoadoutShowSpecIcon", L["settings.label.dock_show_spec_icon"],
            L["settings.tooltip.dock_show_spec_icon"], true,
            function() if ns.RefreshLoadoutDock then ns.RefreshLoadoutDock() end end)
        AddCheckbox("dockLoadoutShowHeroIcon", L["settings.label.dock_show_hero_icon"],
            L["settings.tooltip.dock_show_hero_icon"], true,
            function() if ns.RefreshLoadoutDock then ns.RefreshLoadoutDock() end end)
        AddCheckbox("dockLoadoutShowSaved", L["settings.label.dock_show_saved"],
            L["settings.tooltip.dock_show_saved"], true, nil)
        AddCheckbox("dockLoadoutShowWowhead", L["settings.label.dock_show_wowhead"],
            L["settings.tooltip.dock_show_wowhead"], true, nil)
        AddCheckbox("dockLoadoutShowArchon", L["settings.label.dock_show_archon"],
            L["settings.tooltip.dock_show_archon"], true, nil)
        AddCheckbox("dockLoadoutShowIcyVeins", L["settings.label.dock_show_icyveins"],
            L["settings.tooltip.dock_show_icyveins"], true,
            function() if ns.RefreshLoadoutDock then ns.RefreshLoadoutDock() end end)

        do
            local setting = Settings.RegisterAddOnSetting(category, "dockLoadoutOpacity", "dockLoadoutOpacity", ClassCodexDB,
                Settings.VarType.Number, L["settings.label.dock_opacity"], 95)
            Settings.SetOnValueChangedCallback("dockLoadoutOpacity", function()
                if ns.ApplyLoadoutDockOpacity then ns.ApplyLoadoutDockOpacity() end
            end)
            local sliderOptions = Settings.CreateSliderOptions(0, 100, 5)
            sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return v .. "%" end)
            Settings.CreateSlider(category, setting, sliderOptions,
                L["settings.tooltip.dock_opacity"])
        end

        AddCheckbox("dockLoadoutAutoWidth", L["settings.label.dock_auto_width"],
            L["settings.tooltip.dock_auto_width"], false,
            function() if ns.RefreshLoadoutDock then ns.RefreshLoadoutDock() end end)

        do
            local setting = Settings.RegisterAddOnSetting(category, "dockLoadoutWidth", "dockLoadoutWidth", ClassCodexDB,
                Settings.VarType.Number, L["settings.label.dock_width"], 200)
            Settings.SetOnValueChangedCallback("dockLoadoutWidth", function()
                if ns.ApplyLoadoutDockWidth then ns.ApplyLoadoutDockWidth() end
            end)
            local sliderOptions = Settings.CreateSliderOptions(120, 400, 10)
            sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return v .. "px" end)
            Settings.CreateSlider(category, setting, sliderOptions,
                L["settings.tooltip.dock_width"])
        end

        do
            local setting = Settings.RegisterAddOnSetting(category, "dockLoadoutScale", "dockLoadoutScale", ClassCodexDB,
                Settings.VarType.Number, L["settings.label.dock_scale"], 100)
            Settings.SetOnValueChangedCallback("dockLoadoutScale", function()
                if ns.ApplyLoadoutDockScale then ns.ApplyLoadoutDockScale() end
            end)
            local sliderOptions = Settings.CreateSliderOptions(50, 200, 5)
            sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return v .. "%" end)
            Settings.CreateSlider(category, setting, sliderOptions,
                L["settings.tooltip.dock_scale"])
        end

        do
            local setting = Settings.RegisterAddOnSetting(category, "dockLoadoutAlignment", "dockLoadoutAlignment", ClassCodexDB,
                Settings.VarType.String, L["settings.label.dock_alignment"], "LEFT")
            Settings.SetOnValueChangedCallback("dockLoadoutAlignment", function()
                if ns.RefreshLoadoutDock then ns.RefreshLoadoutDock() end
            end)
            Settings.CreateDropdown(category, setting, function()
                local container = Settings.CreateControlTextContainer()
                container:Add("LEFT", L["settings.value.left"])
                container:Add("CENTER", L["settings.value.center"])
                container:Add("RIGHT", L["settings.value.right"])
                return container:GetData()
            end, L["settings.tooltip.dock_alignment"])
        end

        AddCheckbox("dockLoadoutShowBorder", L["settings.label.dock_show_border"],
            L["settings.tooltip.dock_show_border"], true,
            function() if ns.ApplyLoadoutDockBorder then ns.ApplyLoadoutDockBorder() end end)

        -- 5. Talent Pane integration
        AddHeader(L["settings.header.talent_pane"])
        AddCheckbox("talentPaneEnabled", L["settings.label.talent_pane_show"],
            L["settings.tooltip.talent_pane_show"], true,
            function(val)
                if ns.SetTalentPaneEnabled then ns.SetTalentPaneEnabled(val) end
            end)

        -- 5b. Unit menu integration
        AddHeader(L["settings.header.unit_menus"])
        AddCheckbox("unitMenuEnabled", L["settings.label.unit_menu_enabled"],
            L["settings.tooltip.unit_menu_enabled"], true)

        -- 5. Panel (settings shared between docked and floating modes)
        AddHeader(L["settings.header.panel"])
        AddCheckbox("highlightOwnedGear", L["settings.label.highlight_owned"],
            L["settings.tooltip.highlight_owned"], true,
            function() ns.UpdatePanelIfVisible() end)

        do
            local setting = Settings.RegisterAddOnSetting(category, "panelWidth", "panelWidth", ClassCodexDB,
                Settings.VarType.Number, L["settings.label.panel_width"], 312)
            Settings.SetOnValueChangedCallback("panelWidth", function()
                ns.UpdatePanelIfVisible()
            end)
            local sliderOptions = Settings.CreateSliderOptions(260, 500, 10)
            sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
                return v .. "px"
            end)
            Settings.CreateSlider(category, setting, sliderOptions, L["settings.tooltip.panel_width"])
        end

        -- 6. Docked Panel
        AddHeader(L["settings.header.docked_panel"])
        AddCheckbox("dockShowStats", L["settings.label.show_stat_priority"],
            L["settings.tooltip.dock_show_stat_priority"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowStatTargets", L["settings.label.show_stat_targets"],
            L["settings.tooltip.dock_show_stat_targets"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowTalents", L["settings.label.show_talents"],
            L["settings.tooltip.dock_show_talents"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowRotation", L["settings.label.show_rotation"],
            L["settings.tooltip.dock_show_rotation"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowEnchants", L["settings.label.show_enchants"],
            L["settings.tooltip.dock_show_enchants"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowGems", L["settings.label.show_gems"],
            L["settings.tooltip.dock_show_gems"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowConsumables", L["settings.label.show_consumables"],
            L["settings.tooltip.dock_show_consumables"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowTrinkets", L["settings.label.show_trinkets"],
            L["settings.tooltip.dock_show_trinkets"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowCrafts", L["settings.label.show_crafts"],
            L["settings.tooltip.dock_show_crafts"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowEmbellishments", L["settings.label.show_embellishments"],
            L["settings.tooltip.dock_show_embellishments"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        AddCheckbox("dockShowBisGear", L["settings.label.show_bis_gear"],
            L["settings.tooltip.dock_show_bis_gear"], true,
            function() ns.UpdatePanelIfVisible("docked") end)

        -- 6. Floating Panel
        AddHeader(L["settings.header.floating_panel"])
        AddCheckbox("floatShowStats", L["settings.label.show_stat_priority"],
            L["settings.tooltip.float_show_stat_priority"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowStatTargets", L["settings.label.show_stat_targets"],
            L["settings.tooltip.float_show_stat_targets"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowTalents", L["settings.label.show_talents"],
            L["settings.tooltip.float_show_talents"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowRotation", L["settings.label.show_rotation"],
            L["settings.tooltip.float_show_rotation"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowEnchants", L["settings.label.show_enchants"],
            L["settings.tooltip.float_show_enchants"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowGems", L["settings.label.show_gems"],
            L["settings.tooltip.float_show_gems"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowConsumables", L["settings.label.show_consumables"],
            L["settings.tooltip.float_show_consumables"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowTrinkets", L["settings.label.show_trinkets"],
            L["settings.tooltip.float_show_trinkets"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowCrafts", L["settings.label.show_crafts"],
            L["settings.tooltip.float_show_crafts"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowEmbellishments", L["settings.label.show_embellishments"],
            L["settings.tooltip.float_show_embellishments"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        AddCheckbox("floatShowBisGear", L["settings.label.show_bis_gear"],
            L["settings.tooltip.float_show_bis_gear"], true,
            function() ns.UpdatePanelIfVisible("floating") end)

        Settings.RegisterAddOnCategory(category)
        ns.settingsCategory = category
    end)
    -- Public helper used by the dock right-click menu and slash commands
    -- so callers don't need to know about the category internals.
    function ns.OpenSettings()
        if Settings and Settings.OpenToCategory and ns.settingsCategory then
            Settings.OpenToCategory(ns.settingsCategory:GetID())
        end
    end
    if not ok then
        print("|cffff0000Class Codex:|r " .. L["chat.settings_registration_failed"]:format(tostring(err)))
    end
end
