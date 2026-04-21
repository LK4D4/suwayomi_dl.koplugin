local Menu = require("ui/widget/menu")
local FileChooser = require("ui/widget/filechooser")
local MultiInputDialog = require("ui/widget/multiinputdialog")
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

function SuwayomiUI.showLanguageMenu(options)
    local UIManager = require("ui/uimanager")
    local menu_table = {}

    for _, language in ipairs(options.languages or {}) do
        table.insert(menu_table, {
            text = string.format("%s %s", language.enabled and "[x]" or "[ ]", language.label),
            callback = function()
                if options.onToggle then
                    options.onToggle(language.code, not language.enabled)
                end
            end,
        })
    end

    table.insert(menu_table, {
        text = _("Done"),
        callback = function()
            if options.onClose then
                options.onClose()
            end
        end,
    })

    local menu = Menu:new{
        title = _("Suwayomi source languages"),
        item_table = menu_table,
    }
    UIManager:show(menu)
end

function SuwayomiUI.showLoginDialog(options)
    local credentials = options.credentials or {}
    local UIManager = require("ui/uimanager")
    local dialog

    dialog = MultiInputDialog:new{
        title = _("Suwayomi login"),
        fields = {
            {
                hint = _("Server URL"),
                text = credentials.server_url or "",
            },
            {
                hint = _("Username"),
                text = credentials.username or "",
            },
            {
                hint = _("Password"),
                text = credentials.password or "",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        if options.onSave then
                            options.onSave({
                                server_url = fields[1],
                                username = fields[2],
                                password = fields[3],
                                auth_method = "basic_auth",
                            })
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return SuwayomiUI
