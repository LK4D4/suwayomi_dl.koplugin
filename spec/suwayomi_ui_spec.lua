package.path = "?.lua;" .. package.path

describe("suwayomi_ui", function()
    local shown_dialog
    local closed_dialog
    local events

    before_each(function()
        shown_dialog = nil
        closed_dialog = nil
        events = {}

        package.loaded.suwayomi_ui = nil
        package.loaded.gettext = nil
        package.loaded["ui/widget/menu"] = nil
        package.loaded["ui/widget/filechooser"] = nil
        package.loaded["ui/widget/multiinputdialog"] = nil
        package.loaded["ui/uimanager"] = nil

        package.preload.gettext = function()
            return function(text)
                return text
            end
        end

        package.preload["ui/widget/menu"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/filechooser"] = function()
            return {
                new = function(_, options)
                    return options
                end,
            }
        end

        package.preload["ui/widget/multiinputdialog"] = function()
            return {
                new = function(_, options)
                    options.getFields = function()
                        return {
                            "https://suwayomi.example",
                            "alice",
                            "secret",
                        }
                    end
                    options.onShowKeyboard = function() end
                    return options
                end,
            }
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    shown_dialog = widget
                end,
                close = function(_, widget)
                    closed_dialog = widget
                    table.insert(events, "close")
                end,
            }
        end
    end)

    after_each(function()
        package.preload.gettext = nil
        package.preload["ui/widget/menu"] = nil
        package.preload["ui/widget/filechooser"] = nil
        package.preload["ui/widget/multiinputdialog"] = nil
        package.preload["ui/uimanager"] = nil
    end)

    it("closes the dialog before running the save callback", function()
        local ui = require("suwayomi_ui")

        ui.showLoginDialog({
            onSave = function(credentials)
                table.insert(events, "save")
                assert.are.equal("https://suwayomi.example", credentials.server_url)
                assert.are.equal("alice", credentials.username)
                assert.are.equal("secret", credentials.password)
                assert.are.equal("basic_auth", credentials.auth_method)
            end,
        })

        shown_dialog.buttons[1][2].callback()

        assert.are.same({"close", "save"}, events)
        assert.are.equal(shown_dialog, closed_dialog)
    end)
end)
