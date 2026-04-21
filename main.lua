local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SuwayomiPlugin = WidgetContainer:extend{
    name = "suwayomi_dl",
    is_doc_only = false,
}

function SuwayomiPlugin:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function SuwayomiPlugin:addToMainMenu(menu_items)
    menu_items.search:append({
        text = _("Suwayomi"),
        sub_item_table = {
            {
                text = _("Browse Suwayomi"),
                callback = function()
                    -- TODO: Launch UI
                end
            },
            {
                text = _("Setup login information"),
                callback = function()
                    -- TODO: Login Dialog
                end
            },
            {
                text = _("Setup download directory"),
                callback = function()
                    -- TODO: Directory Chooser
                end
            }
        }
    })
end

return SuwayomiPlugin
