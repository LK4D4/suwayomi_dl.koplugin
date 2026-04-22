package.path = "?.lua;" .. package.path

describe("suwayomi plugin", function()
    local registered_actions
    local registered_menu_plugin
    local login_dialog_options
    local language_menu_options
    local shown_messages
    local shown_sources
    local directory_chooser_callback
    local saved_download_directory
    local trapper_wrapped
    local trapper_subprocess_calls

    local function reset_plugin_environment()
        registered_actions = {}
        registered_menu_plugin = nil
        login_dialog_options = nil
        language_menu_options = nil
        shown_messages = {}
        shown_sources = nil
        directory_chooser_callback = nil
        saved_download_directory = nil
        trapper_wrapped = 0
        trapper_subprocess_calls = {}

        package.loaded.main = nil
        package.loaded.dispatcher = nil
        package.loaded["ffi/util"] = nil
        package.loaded.gettext = nil
        package.loaded["ui/trapper"] = nil
        package.loaded["ui/uimanager"] = nil
        package.loaded["ui/widget/infomessage"] = nil
        package.loaded["ui/widget/container/widgetcontainer"] = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

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

        package.preload["ffi/util"] = function()
            return {
                template = function(template_string, ...)
                    local result = template_string
                    local values = {...}
                    for index, value in ipairs(values) do
                        result = result:gsub("%%" .. index, tostring(value))
                    end
                    return result
                end,
            }
        end

        package.preload["ui/uimanager"] = function()
            return {
                show = function(_, widget)
                    table.insert(shown_messages, widget.text)
                end,
                nextTick = function(_, callback)
                    callback()
                end,
            }
        end

        package.preload["ui/trapper"] = function()
            return {
                wrap = function(_, callback)
                    trapper_wrapped = trapper_wrapped + 1
                    return callback()
                end,
                dismissableRunInSubprocess = function(_, callback, message)
                    table.insert(trapper_subprocess_calls, message)
                    return true, callback()
                end,
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

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return {
                        ok = true,
                        sources = {
                            { id = "1", name = "MangaDex (EN)", lang = "en" },
                            { id = "2", name = "MangaDex (RU)", lang = "ru" },
                            { id = "3", name = "ComicK (DE)", lang = "de" },
                            { id = "4", name = "Local source", lang = "localsourcelang" },
                        },
                    }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showDirectoryChooser = function(callback)
                    directory_chooser_callback = callback
                end,
                showLoginDialog = function(options)
                    login_dialog_options = options
                end,
                showLanguageMenu = function(options)
                    language_menu_options = options
                end,
                showSourcesMenu = function(sources)
                    shown_sources = sources
                end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return {
                        server_url = "https://suwayomi.example",
                        username = "alice",
                        password = "secret",
                        auth_method = "basic_auth",
                        source_languages = { "en", "ru" },
                    }
                end,
                save = function(_, credentials)
                    login_dialog_options.saved_credentials = credentials
                    return credentials
                end,
                loadSourceLanguages = function()
                    return { "en", "ru" }
                end,
                saveSourceLanguages = function(_, languages)
                    return languages
                end,
                loadDownloadDirectory = function()
                    return ""
                end,
                saveDownloadDirectory = function(_, path)
                    saved_download_directory = path
                    return path
                end,
            }
        end
    end

    before_each(reset_plugin_environment)

    after_each(function()
        package.preload.dispatcher = nil
        package.preload["ffi/util"] = nil
        package.preload.gettext = nil
        package.preload["ui/trapper"] = nil
        package.preload["ui/uimanager"] = nil
        package.preload["ui/widget/infomessage"] = nil
        package.preload["ui/widget/container/widgetcontainer"] = nil
        package.preload.suwayomi_api = nil
        package.preload.suwayomi_downloader = nil
        package.preload.suwayomi_ui = nil
        package.preload.suwayomi_settings = nil
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
        assert.are.equal(4, #menu_items.suwayomi_dl.sub_item_table)
    end)

    it("opens the login dialog with persisted credentials", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[2].callback()

        assert.is_table(login_dialog_options)
        assert.are.equal("https://suwayomi.example", login_dialog_options.credentials.server_url)
        assert.are.equal("alice", login_dialog_options.credentials.username)
        assert.are.equal("secret", login_dialog_options.credentials.password)
        assert.are.equal("basic_auth", login_dialog_options.credentials.auth_method)
    end)

    it("formats the saved login message without crashing", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[2].callback()

        login_dialog_options.onSave({
            server_url = "https://suwayomi.example",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.are.equal("Suwayomi login settings saved for https://suwayomi.example.", shown_messages[#shown_messages])
    end)

    it("loads sources and opens the sources menu when browse succeeds", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[1].callback()

        assert.are.same({
            { id = "1", name = "MangaDex (EN)", lang = "en" },
            { id = "2", name = "MangaDex (RU)", lang = "ru" },
            { id = "4", name = "Local source", lang = "localsourcelang" },
        }, shown_sources)
    end)

    it("downloads a selected chapter and shows the saved path", function()
        local downloader_called

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function(_, source_id)
                    assert.are.equal("s1", source_id)
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function(_, manga_id)
                    assert.are.equal("m1", manga_id)
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                downloadChapter = function(_, credentials, download_directory, manga, chapter)
                    downloader_called = {
                        credentials = credentials,
                        download_directory = download_directory,
                        manga = manga,
                        chapter = chapter,
                    }
                    return { ok = true, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(chapters, onSelect)
                    onSelect(chapters[1])
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()

        assert.are.equal(1, trapper_wrapped)
        assert.are.equal("Downloading chapter… (tap to cancel)", trapper_subprocess_calls[1])
        assert.are.equal("/books", downloader_called.download_directory)
        assert.are.equal("Sousou no Frieren", downloader_called.manga.title)
        assert.are.equal("Official_Vol. 1 Ch. 1", downloader_called.chapter.name)
        assert.are.equal("Downloaded chapter to /books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", shown_messages[#shown_messages])
    end)

    it("shows the downloader error when chapter download fails", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function(_, source_id)
                    assert.are.equal("s1", source_id)
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function(_, manga_id)
                    assert.are.equal("m1", manga_id)
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                downloadChapter = function()
                    return { ok = false, error = "Set up a download directory first." }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(chapters, onSelect)
                    onSelect(chapters[1])
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()

        assert.are.equal("Set up a download directory first.", shown_messages[#shown_messages])
    end)

    it("shows an interruption message when the subprocess is cancelled", function()
        package.preload["ui/trapper"] = function()
            return {
                wrap = function(_, callback)
                    trapper_wrapped = trapper_wrapped + 1
                    return callback()
                end,
                dismissableRunInSubprocess = function(_, _, message)
                    table.insert(trapper_subprocess_calls, message)
                    return false
                end,
            }
        end

        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return { ok = true, sources = { { id = "s1", name = "MangaDex", lang = "en" } } }
                end,
                fetchMangaForSource = function()
                    return { ok = true, manga = { { id = "m1", title = "Sousou no Frieren" } } }
                end,
                fetchChaptersForManga = function()
                    return { ok = true, chapters = { { id = "398", name = "Official_Vol. 1 Ch. 1" } } }
                end,
            }
        end

        package.preload.suwayomi_downloader = function()
            return {
                downloadChapter = function()
                    return { ok = true, path = "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" }
                end,
            }
        end

        package.preload.suwayomi_ui = function()
            return {
                showSourcesMenu = function(sources, onSelect)
                    onSelect(sources[1])
                end,
                showMangaMenu = function(manga, onSelect)
                    onSelect(manga[1])
                end,
                showChapterMenu = function(chapters, onSelect)
                    onSelect(chapters[1])
                end,
                showDirectoryChooser = function() end,
                showLoginDialog = function() end,
                showLanguageMenu = function() end,
            }
        end

        package.preload.suwayomi_settings = function()
            return {
                load = function()
                    return { server_url = "https://suwayomi.example", username = "alice", password = "secret", auth_method = "basic_auth" }
                end,
                loadSourceLanguages = function() return { "en" } end,
                loadDownloadDirectory = function() return "/books" end,
                saveDownloadDirectory = function(_, path) return path end,
                save = function(_, value) return value end,
                saveSourceLanguages = function(_, value) return value end,
            }
        end

        package.loaded.main = nil
        package.loaded["ui/trapper"] = nil
        package.loaded.suwayomi_api = nil
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_ui = nil
        package.loaded.suwayomi_settings = nil

        local plugin_class = require("main")
        local plugin = plugin_class{}

        plugin:browseSuwayomi()

        assert.are.equal("Chapter download interrupted.", shown_messages[#shown_messages])
    end)

    it("shows a message when browse fails", function()
        package.preload.suwayomi_api = function()
            return {
                fetchSources = function()
                    return {
                        ok = false,
                        error = "Authentication failed.",
                    }
                end,
            }
        end
        package.loaded.main = nil
        package.loaded.suwayomi_api = nil

        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[1].callback()

        assert.are.equal("Authentication failed.", shown_messages[#shown_messages])
    end)

    it("opens the language setup menu with the configured languages checked", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[3].callback()

        assert.is_table(language_menu_options)
        assert.are.equal("en", language_menu_options.languages[1].code)
        assert.are.equal("EN", language_menu_options.languages[1].label)
        assert.are.equal(true, language_menu_options.languages[1].enabled)
        assert.are.equal(true, language_menu_options.languages[2].enabled)
        assert.are.equal(false, language_menu_options.languages[3].enabled)
    end)

    it("saves the chosen download directory and shows a confirmation", function()
        local plugin_class = require("main")
        local menu_items = {}
        local plugin = plugin_class{}

        plugin:addToMainMenu(menu_items)
        menu_items.suwayomi_dl.sub_item_table[4].callback()

        directory_chooser_callback("/storage/emulated/0/Books/Manga")

        assert.are.equal("/storage/emulated/0/Books/Manga", saved_download_directory)
        assert.are.equal("Suwayomi download directory saved: /storage/emulated/0/Books/Manga", shown_messages[#shown_messages])
    end)
end)
