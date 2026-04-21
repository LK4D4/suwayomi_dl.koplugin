package.path = "?.lua;" .. package.path

describe("suwayomi plugin", function()
    local registered_actions
    local registered_menu_plugin

    local function reset_plugin_environment()
        registered_actions = {}
        registered_menu_plugin = nil

        package.loaded.main = nil
        package.loaded.dispatcher = nil
        package.loaded.gettext = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["ui/widget/infomessage"] = nil
        package.loaded["ui/widget/container/widgetcontainer"] = nil
        package.loaded.suwayomi_ui = nil

        package.preload.dispatcher = function()
            return {
                registerAction = function(_, name, definition)
                    table.insert(registered_actions, {
                        name = name,
                        definition = definition,
                    })
                end,
            }
        end

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function() end,
            }
        end

        package.preload["ui/widget/infomessage"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/container/widgetcontainer"] = function()
            local WidgetContainer = {}

            function WidgetContainer:extend(definition)
                definition.__index = definition
                return setmetatable(definition, {
                    __index = self,
                    __call = function(class, instance)
                        instance = instance or {}
                        setmetatable(instance, class)
                        return instance
                    end,
                })
            end

            return WidgetContainer
        end

        package.preload.suwayomi_ui = function()
            return {
                showDirectoryChooser = function() end,
            }
        end
    end

    before_each(reset_plugin_environment)

    after_each(function()
        package.preload.dispatcher = nil
        package.preload.gettext = nil
        package.preload["ui/uimanager"] = nil
        package.preload["ui/widget/infomessage"] = nil
        package.preload["ui/widget/container/widgetcontainer"] = nil
        package.preload.suwayomi_ui = nil
    end)

    it("registers a dispatcher action and main-menu entry on init", function()
        local plugin_class = require("main")
        local plugin = plugin_class{
            ui = {
                menu = {
                    registerToMainMenu = function(_, instance)
                        registered_menu_plugin = instance
                    end,
                },
            },
        }

        plugin:init()

        assert.are.equal(plugin, registered_menu_plugin)
        assert.are.equal(1, #registered_actions)
        assert.are.equal("suwayomi_action", registered_actions[1].name)
        assert.are.equal("Suwayomi", registered_actions[1].definition.title)
    end)

    it("adds the plugin under the search menu section", function()
        local plugin_class = require("main")
        local menu_items = {}

        plugin_class:addToMainMenu(menu_items)

        assert.is_table(menu_items.suwayomi_dl)
        assert.are.equal("Suwayomi", menu_items.suwayomi_dl.text)
        assert.are.equal("search", menu_items.suwayomi_dl.sorting_hint)
        assert.are.equal(3, #menu_items.suwayomi_dl.sub_item_table)
    end)
end)
