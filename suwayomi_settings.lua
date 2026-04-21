local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SuwayomiSettings = {
    settings_file = DataStorage:getSettingsDir() .. "/suwayomi_dl.lua",
    settings = nil,
}

local DEFAULT_CREDENTIALS = {
    server_url = "",
    username = "",
    password = "",
    auth_method = "basic_auth",
}

local DEFAULT_SOURCE_LANGUAGES = { "en" }

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

function SuwayomiSettings:open()
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_file)
    end
    return self.settings
end

function SuwayomiSettings:normalizeServerURL(server_url)
    if not server_url or server_url == "" then
        return ""
    end

    if server_url:match("^%a+://") then
        return server_url
    end

    return "http://" .. server_url
end

function SuwayomiSettings:load()
    local credentials = self:open():readSetting("credentials", copyTable(DEFAULT_CREDENTIALS))
    if credentials.auth_method == nil or credentials.auth_method == "" then
        credentials.auth_method = DEFAULT_CREDENTIALS.auth_method
    end
    return credentials
end

function SuwayomiSettings:save(credentials)
    local normalized = {
        server_url = self:normalizeServerURL(credentials.server_url),
        username = credentials.username or "",
        password = credentials.password or "",
        auth_method = credentials.auth_method or DEFAULT_CREDENTIALS.auth_method,
    }

    self:open():saveSetting("credentials", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadSourceLanguages()
    return self:open():readSetting("source_languages", copyTable(DEFAULT_SOURCE_LANGUAGES))
end

function SuwayomiSettings:saveSourceLanguages(source_languages)
    local normalized = {}
    for _, lang in ipairs(source_languages or {}) do
        table.insert(normalized, lang)
    end

    self:open():saveSetting("source_languages", normalized):flush()
    return normalized
end

return SuwayomiSettings
