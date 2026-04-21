local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi_api")
local SuwayomiSettings = require("suwayomi_settings")
local SuwayomiUI = require("suwayomi_ui")
local _ = require("gettext")

local SuwayomiPlugin = WidgetContainer:extend{
    name = "suwayomi_dl",
    is_doc_only = false,
}

function SuwayomiPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("suwayomi_action", {
        category = "none",
        event = "SuwayomiAction",
        title = _("Suwayomi"),
        general = true,
    })
end

function SuwayomiPlugin:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function SuwayomiPlugin:showNotImplemented(message)
    self:showMessage(message)
end

function SuwayomiPlugin:showMessage(message)
    UIManager:show(InfoMessage:new{
        text = message,
    })
end

function SuwayomiPlugin:onSuwayomiAction()
    self:showNotImplemented(_("Open Search > Suwayomi to access the plugin menu."))
end

function SuwayomiPlugin:showLoginDialog()
    SuwayomiUI.showLoginDialog({
        credentials = SuwayomiSettings:load(),
        onSave = function(credentials)
            local saved_credentials = SuwayomiSettings:save(credentials)
            self:showMessage(_("Suwayomi login settings saved for %1."):format(saved_credentials.server_url))
        end,
    })
end

function SuwayomiPlugin:browseSuwayomi()
    local credentials = SuwayomiSettings:load()
    if credentials.server_url == "" then
        self:showMessage(_("Set up your Suwayomi server login first."))
        return
    end

    local result = SuwayomiAPI.fetchSources(credentials)
    if not result.ok then
        self:showMessage(_(result.error))
        return
    end

    SuwayomiUI.showSourcesMenu(result.sources, function(source)
        self:showNotImplemented(_("Source selected: %1"):format(source.name))
    end)
end

function SuwayomiPlugin:addToMainMenu(menu_items)
    menu_items.suwayomi_dl = {
        text = _("Suwayomi"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Browse Suwayomi"),
                callback = function()
                    self:browseSuwayomi()
                end
            },
            {
                text = _("Setup login information"),
                callback = function()
                    self:showLoginDialog()
                end
            },
            {
                text = _("Setup download directory"),
                callback = function()
                    SuwayomiUI.showDirectoryChooser(function(path)
                        self:showNotImplemented(_("Selected download directory: %1"):format(path))
                    end)
                end
            }
        }
    }
end

return SuwayomiPlugin
