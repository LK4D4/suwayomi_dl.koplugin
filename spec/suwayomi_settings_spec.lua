package.path = "?.lua;" .. package.path

describe("suwayomi_settings", function()
    local flushed
    local stored_data

    before_each(function()
        flushed = false
        stored_data = {}

        package.loaded.suwayomi_settings = nil
        package.loaded.datastorage = nil
        package.loaded.luasettings = nil

        package.preload.datastorage = function()
            return {
                getSettingsDir = function()
                    return "/mock/settings"
                end,
            }
        end

        package.preload.luasettings = function()
            return {
                open = function(_, path)
                    return {
                        file = path,
                        data = stored_data,
                        readSetting = function(self, key, default)
                            if self.data[key] == nil and default ~= nil then
                                self.data[key] = default
                            end
                            return self.data[key]
                        end,
                        saveSetting = function(self, key, value)
                            self.data[key] = value
                            return self
                        end,
                        flush = function()
                            flushed = true
                        end,
                    }
                end,
            }
        end
    end)

    after_each(function()
        package.preload.datastorage = nil
        package.preload.luasettings = nil
    end)

    it("loads persisted credentials from the KOReader settings directory", function()
        stored_data.credentials = {
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        }

        local settings = require("suwayomi_settings")
        local credentials = settings:load()

        assert.are.equal("/mock/settings/suwayomi_dl.lua", settings.settings_file)
        assert.are.same(stored_data.credentials, credentials)
    end)

    it("saves credentials and flushes the settings file", function()
        local settings = require("suwayomi_settings")
        settings:save({
            server_url = "suwayomi.local:4567",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(flushed)
        assert.are.equal("http://suwayomi.local:4567", stored_data.credentials.server_url)
        assert.are.equal("alice", stored_data.credentials.username)
        assert.are.equal("secret", stored_data.credentials.password)
        assert.are.equal("basic_auth", stored_data.credentials.auth_method)
    end)
end)
