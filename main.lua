local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local SuwayomiAPI = require("suwayomi_api")
local SuwayomiSettings = require("suwayomi_settings")
local SuwayomiUI = require("suwayomi_ui")
local _ = require("gettext")
local T = require("ffi/util").template

local SOURCE_LANGUAGE_OPTIONS = {
    { code = "en", label = "EN" },
    { code = "ru", label = "RU" },
    { code = "de", label = "DE" },
    { code = "es", label = "ES" },
    { code = "fr", label = "FR" },
}

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
    self.chapter_download_status = {}
    self.chapter_download_queue = {}
    self.chapter_download_active = false
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
            UIManager:nextTick(function()
                self:showMessage(T(_("Suwayomi login settings saved for %1."), saved_credentials.server_url))
            end)
        end,
    })
end

function SuwayomiPlugin:buildSourceLanguageSet(source_languages)
    local selected = {}
    for _, lang in ipairs(source_languages or {}) do
        selected[lang] = true
    end
    return selected
end

function SuwayomiPlugin:filterSourcesByLanguage(sources)
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())
    local filtered = {}

    for _, source in ipairs(sources or {}) do
        if source.lang == "localsourcelang" or selected[source.lang] then
            table.insert(filtered, source)
        end
    end

    return filtered
end

function SuwayomiPlugin:showSourceLanguageDialog()
    local selected = self:buildSourceLanguageSet(SuwayomiSettings:loadSourceLanguages())

    SuwayomiUI.showLanguageMenu({
        languages = (function()
            local languages = {}
            for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
                table.insert(languages, {
                    code = language.code,
                    label = language.label,
                    enabled = selected[language.code] == true,
                })
            end
            return languages
        end)(),
        onToggle = function(code, enabled)
            if enabled then
                selected[code] = true
            else
                selected[code] = nil
            end

            local saved_languages = {}
            for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
                if selected[language.code] then
                    table.insert(saved_languages, language.code)
                end
            end

            SuwayomiSettings:saveSourceLanguages(saved_languages)
            self:showSourceLanguageDialog()
        end,
        onClose = function()
            local saved_languages = SuwayomiSettings:loadSourceLanguages()
            local labels = {}
            local selected_lookup = self:buildSourceLanguageSet(saved_languages)
            for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
                if selected_lookup[language.code] then
                    table.insert(labels, language.label)
                end
            end
            local summary = #labels > 0 and table.concat(labels, ", ") or _("none")
            self:showMessage(T(_("Suwayomi source languages saved: %1"), summary))
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

    local filtered_sources = self:filterSourcesByLanguage(result.sources)
    if #filtered_sources == 0 then
        self:showMessage(_("No Suwayomi sources match the selected languages."))
        return
    end

    SuwayomiUI.showSourcesMenu(filtered_sources, function(source)
        self:showMangaForSource(source)
    end)
end

function SuwayomiPlugin:showMangaForSource(source)
    local credentials = SuwayomiSettings:load()
    local result = SuwayomiAPI.fetchMangaForSource(credentials, source.id)
    if not result.ok then
        self:showMessage(_(result.error))
        return
    end

    if not result.manga or #result.manga == 0 then
        self:showMessage(_("This source has no manga."))
        return
    end

    SuwayomiUI.showMangaMenu(result.manga, function(manga)
        self:showChaptersForManga(manga)
    end)
end

function SuwayomiPlugin:showChaptersForManga(manga)
    local credentials = SuwayomiSettings:load()
    local result = SuwayomiAPI.fetchChaptersForManga(credentials, manga.id)
    if not result.ok then
        self:showMessage(_(result.error))
        return
    end

    if not result.chapters or #result.chapters == 0 then
        self:showMessage(_("This manga has no chapters."))
        return
    end

    self.current_chapter_context = {
        manga = manga,
        chapters = result.chapters,
    }

    local chapters = self:buildChapterMenuItems(manga, result.chapters)
    self.current_chapter_options = {
        title = manga.title,
        chapters = chapters,
    }
    self.current_chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:enqueueChapterDownload(manga, chapter)
    end)
end

function SuwayomiPlugin:getChapterDownloadKey(manga, chapter)
    return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
end

function SuwayomiPlugin:getChapterDownloadStatus(manga, chapter)
    self.chapter_download_status = self.chapter_download_status or {}
    return self.chapter_download_status[self:getChapterDownloadKey(manga, chapter)]
end

function SuwayomiPlugin:setChapterDownloadStatus(manga, chapter, status)
    self.chapter_download_status = self.chapter_download_status or {}
    self.chapter_download_status[self:getChapterDownloadKey(manga, chapter)] = status
end

function SuwayomiPlugin:formatChapterMenuText(chapter, status)
    if not status then
        return chapter.name
    end

    if status.state == "queued" then
        return chapter.name .. " [queued]"
    end

    if status.state == "downloading" then
        if status.total and status.total > 0 and status.current then
            return T(_("%1 [downloading %2/%3]"), chapter.name, status.current, status.total)
        end
        return chapter.name .. " [downloading]"
    end

    if status.state == "downloaded" then
        return chapter.name .. " [downloaded]"
    end

    if status.state == "failed" then
        return chapter.name .. " [failed]"
    end

    return chapter.name
end

function SuwayomiPlugin:buildChapterMenuItems(manga, chapters)
    local SuwayomiDownloader = require("suwayomi_downloader")
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    local items = {}

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        item.menu_text = self:formatChapterMenuText(item, self:getChapterDownloadStatus(manga, item))
        if download_directory and download_directory ~= "" then
            local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, item)
            if not self:getChapterDownloadStatus(manga, item) and SuwayomiDownloader:chapterExists(chapter_path) then
                item.menu_text = item.name .. " [downloaded]"
            end
        end

        table.insert(items, item)
    end

    return items
end

function SuwayomiPlugin:refreshChapterMenu()
    if not self.current_chapter_context then
        return
    end

    local options = {
        title = self.current_chapter_context.manga.title,
        chapters = self:buildChapterMenuItems(self.current_chapter_context.manga, self.current_chapter_context.chapters),
    }
    self.current_chapter_options = self.current_chapter_options or {}
    self.current_chapter_options.title = options.title
    self.current_chapter_options.chapters = options.chapters

    if SuwayomiUI.updateChapterMenu then
        SuwayomiUI.updateChapterMenu(self.current_chapter_menu, options, function(chapter)
            self:enqueueChapterDownload(self.current_chapter_context.manga, chapter)
        end)
    elseif self.current_chapter_menu and self.current_chapter_menu.updateItems then
        self.current_chapter_menu:updateItems(nil, true)
    end
end

function SuwayomiPlugin:formatDownloadMessage(result)
    local filename = result.path and result.path:match("([^/]+)$") or nil
    local directory = result.path and result.path:match("^(.*)/[^/]+$") or nil

    if result.skipped then
        return T(_("Already downloaded: %1"), filename or _("chapter"))
    end

    if filename and directory then
        return T(_("Saved %1 in %2"), filename, directory)
    end

    return T(_("Downloaded chapter to %1"), result.path or "")
end

function SuwayomiPlugin:enqueueChapterDownload(manga, chapter)
    local SuwayomiDownloader = require("suwayomi_downloader")
    local credentials = SuwayomiSettings:load()
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    self.chapter_download_queue = self.chapter_download_queue or {}
    if not download_directory or download_directory == "" then
        SuwayomiUI.showDirectoryChooser(function(path)
            local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
            self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
            UIManager:nextTick(function()
                self:enqueueChapterDownload(manga, chapter)
            end)
        end)
        return
    end

    local status = self:getChapterDownloadStatus(manga, chapter)
    if status and (status.state == "queued" or status.state == "downloading") then
        self:showMessage(_("Chapter download is already in progress."))
        return
    end

    self:setChapterDownloadStatus(manga, chapter, { state = "queued" })
    table.insert(self.chapter_download_queue, {
        credentials = credentials,
        download_directory = download_directory,
        manga = manga,
        chapter = chapter,
        downloader = SuwayomiDownloader,
    })
    self:refreshChapterMenu()
    UIManager:scheduleIn(0, function()
        self:processChapterDownloadQueue()
    end)
end

function SuwayomiPlugin:processChapterDownloadQueue()
    if self.chapter_download_active then
        return
    end

    local queued = table.remove(self.chapter_download_queue, 1)
    if not queued then
        return
    end

    self.chapter_download_active = queued
    local start_result = queued.downloader:startChapterDownload(queued.credentials, queued.download_directory, queued.manga, queued.chapter)
    if not start_result.ok or start_result.skipped then
        self.chapter_download_active = false
        if start_result.ok then
            self:setChapterDownloadStatus(queued.manga, queued.chapter, { state = "downloaded" })
            self:showMessage(self:formatDownloadMessage(start_result))
        else
            self:setChapterDownloadStatus(queued.manga, queued.chapter, { state = "failed" })
            self:showMessage(_(start_result.error))
        end
        self:refreshChapterMenu()
        UIManager:scheduleIn(0, function()
            self:processChapterDownloadQueue()
        end)
        return
    end

    queued.step_job = start_result.job
    queued.path = start_result.path
    self:setChapterDownloadStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = start_result.total,
    })
    self:refreshChapterMenu()
    UIManager:scheduleIn(0, function()
        self:processChapterDownloadStep()
    end)
end

function SuwayomiPlugin:processChapterDownloadStep()
    local active = self.chapter_download_active
    if not active then
        return
    end

    local result = active.downloader:downloadNextPage(active.step_job)
    if not result.ok then
        self:setChapterDownloadStatus(active.manga, active.chapter, { state = "failed" })
        self.chapter_download_active = false
        self:refreshChapterMenu()
        self:showMessage(_(result.error))
        UIManager:scheduleIn(0, function()
            self:processChapterDownloadQueue()
        end)
        return
    end

    self:setChapterDownloadStatus(active.manga, active.chapter, {
        state = result.done and "downloaded" or "downloading",
        current = result.current,
        total = result.total,
    })
    self:refreshChapterMenu()

    if result.done then
        self.chapter_download_active = false
        self:showMessage(self:formatDownloadMessage(result))
        UIManager:scheduleIn(0, function()
            self:processChapterDownloadQueue()
        end)
        return
    end

    UIManager:scheduleIn(0, function()
        self:processChapterDownloadStep()
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
                text = _("Setup source languages"),
                callback = function()
                    self:showSourceLanguageDialog()
                end
            },
            {
                text = _("Setup download directory"),
                callback = function()
                    SuwayomiUI.showDirectoryChooser(function(path)
                        local saved_path = SuwayomiSettings:saveDownloadDirectory(path)
                        self:showMessage(T(_("Suwayomi download directory saved: %1"), saved_path))
                    end)
                end
            }
        }
    }
end

return SuwayomiPlugin
