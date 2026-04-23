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

function SuwayomiPlugin:getChapterProgressPath(manga, chapter, download_directory)
    local key = self:getChapterDownloadKey(manga, chapter):gsub("[^%w%-_%.]", "_")
    return (download_directory or ""):gsub("/+$", "") .. "/.suwayomi_dl_progress_" .. key .. ".txt"
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

    if status.state == "skipped" then
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

function SuwayomiPlugin:readChapterProgress(progress_path)
    local handle = io.open(progress_path, "r")
    if not handle then
        return nil
    end

    local status = {}
    for line in handle:lines() do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            status[key] = value
        end
    end
    handle:close()

    if status.current then
        status.current = tonumber(status.current)
    end
    if status.total then
        status.total = tonumber(status.total)
    end

    return status
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
    queued.progress_path = self:getChapterProgressPath(queued.manga, queued.chapter, queued.download_directory)
    os.remove(queued.progress_path)

    local FFIUtil = require("ffi/util")
    local pid, err = FFIUtil.runInSubProcess(function()
        local function writeProgress(state, current, total, path, error_message)
            if queued.downloader.writeProgress then
                queued.downloader:writeProgress(queued.progress_path, state, current, total, path, error_message)
                return
            end

            local handle = io.open(queued.progress_path, "w")
            if not handle then
                return
            end
            handle:write("state=", tostring(state or ""), "\n")
            handle:write("current=", tostring(current or 0), "\n")
            handle:write("total=", tostring(total or 0), "\n")
            handle:write("path=", tostring(path or ""), "\n")
            if error_message then
                handle:write("error=", tostring(error_message), "\n")
            end
            handle:close()
        end

        if queued.downloader.downloadChapterWithProgress then
            queued.downloader:downloadChapterWithProgress(
                queued.credentials,
                queued.download_directory,
                queued.manga,
                queued.chapter,
                queued.progress_path
            )
            return
        end

        local result = queued.downloader:startChapterDownload(queued.credentials, queued.download_directory, queued.manga, queued.chapter)
        if not result.ok or result.skipped then
            writeProgress(
                result.skipped and "skipped" or (result.ok and "downloaded" or "failed"),
                result.ok and 1 or 0,
                result.ok and 1 or 0,
                result.path,
                result.error
            )
            return
        end

        repeat
            result = queued.downloader:downloadNextPage(result.job)
            writeProgress(
                result.ok and (result.done and "downloaded" or "downloading") or "failed",
                result.current,
                result.total,
                result.path,
                result.error
            )
        until not result.ok or result.done
    end)

    if not pid then
        self.chapter_download_active = false
        self:setChapterDownloadStatus(queued.manga, queued.chapter, { state = "failed" })
        self:showMessage(T(_("Could not start chapter download: %1"), err or _("unknown error")))
        self:refreshChapterMenu()
        UIManager:scheduleIn(0, function()
            self:processChapterDownloadQueue()
        end)
        return
    end

    queued.pid = pid
    self:setChapterDownloadStatus(queued.manga, queued.chapter, {
        state = "downloading",
        current = 0,
        total = 0,
    })
    self:refreshChapterMenu()
    UIManager:scheduleIn(0.5, function()
        self:pollChapterDownload()
    end)
end

function SuwayomiPlugin:pollChapterDownload()
    local active = self.chapter_download_active
    if not active then
        return
    end

    local progress = self:readChapterProgress(active.progress_path)
    if progress and progress.state then
        self:setChapterDownloadStatus(active.manga, active.chapter, {
            state = progress.state,
            current = progress.current,
            total = progress.total,
        })
        self:refreshChapterMenu()
    end

    local FFIUtil = require("ffi/util")
    local done = FFIUtil.isSubProcessDone(active.pid)
    local terminal = progress and (progress.state == "downloaded" or progress.state == "skipped" or progress.state == "failed")

    if terminal or done then
        self.chapter_download_active = false
        os.remove(active.progress_path)
        if progress and (progress.state == "downloaded" or progress.state == "skipped") then
            -- The chapter row now carries the success state; avoid an extra popup.
        elseif progress and progress.state == "failed" then
            self:showMessage(_(progress.error or _("Chapter download failed.")))
        else
            self:setChapterDownloadStatus(active.manga, active.chapter, { state = "failed" })
            self:refreshChapterMenu()
            self:showMessage(_("Chapter download failed."))
        end
        UIManager:scheduleIn(0, function()
            self:processChapterDownloadQueue()
        end)
        return
    end

    UIManager:scheduleIn(0.5, function()
        self:pollChapterDownload()
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
