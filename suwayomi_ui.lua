local Menu = require("ui/widget/menu")
local FileChooser = require("ui/widget/filechooser")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local SuwayomiUI = {}

function SuwayomiUI.showDirectoryChooser(callback)
    local chooser
    chooser = FileChooser:new{
        title = _("Select download directory"),
        onConfirm = function(path)
            if callback then callback(path) end
            if chooser then
                chooser:onClose()
            end
        end,
    }
    -- Show UI
    local UIManager = require("ui/uimanager")
    UIManager:show(chooser)
end

function SuwayomiUI.showSourcesMenu(sources, onSelectCallback)
    local menu_table = {}
    for _, source in ipairs(sources) do
        table.insert(menu_table, {
            text = source.name,
            callback = function()
                if onSelectCallback then onSelectCallback(source) end
            end
        })
    end

    local menu = Menu:new{
        title = _("Suwayomi Sources"),
        item_table = menu_table,
    }
    local UIManager = require("ui/uimanager")
    UIManager:show(menu)
end

return SuwayomiUI
