local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local SuwayomiAPI = require("suwayomi_api")
local SuwayomiDownloadQueue = require("suwayomi_download_queue")
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

function SuwayomiPlugin:createDownloadQueue()
    return SuwayomiDownloadQueue:new{
        settings = SuwayomiSettings,
        downloader = require("suwayomi_downloader"),
        ui_manager = UIManager,
        ffi_util = require("ffi/util"),
        getCredentials = function()
            return SuwayomiSettings:load()
        end,
        onStatusChanged = function()
            self:refreshChapterMenu()
        end,
        onMessage = function(message)
            self:showMessage(message)
        end,
    }
end

function SuwayomiPlugin:getDownloadQueue()
    if not self.download_queue then
        self.download_queue = self:createDownloadQueue()
    end
    return self.download_queue
end

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
    self:getDownloadQueue():recover()
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
    local language_menu

    local function buildLanguages()
        local languages = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            table.insert(languages, {
                code = language.code,
                label = language.label,
                enabled = selected[language.code] == true,
            })
        end
        return languages
    end

    local function saveSelectedLanguages()
        local saved_languages = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            if selected[language.code] then
                table.insert(saved_languages, language.code)
            end
        end
        SuwayomiSettings:saveSourceLanguages(saved_languages)
    end

    local function showSavedSummary()
        local labels = {}
        for _, language in ipairs(SOURCE_LANGUAGE_OPTIONS) do
            if selected[language.code] then
                table.insert(labels, language.label)
            end
        end
        local summary = #labels > 0 and table.concat(labels, ", ") or _("none")
        self:showMessage(T(_("Suwayomi source languages saved: %1"), summary))
    end

    local function onToggle(code, enabled)
        if enabled then
            selected[code] = true
        else
            selected[code] = nil
        end

        saveSelectedLanguages()
        if SuwayomiUI.updateLanguageMenu then
            SuwayomiUI.updateLanguageMenu(language_menu, {
                languages = buildLanguages(),
                onClose = showSavedSummary,
            }, onToggle)
        end
    end

    language_menu = SuwayomiUI.showLanguageMenu({
        languages = buildLanguages(),
        onToggle = onToggle,
        onClose = showSavedSummary,
    })
end

function SuwayomiPlugin:browseSuwayomi()
    local credentials = SuwayomiSettings:load()
    if credentials.server_url == "" then
        self:showMessage(_("Set up your Suwayomi server login first."))
        return
    end

    self:syncPendingReadMarks(credentials)

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

    local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
    self.current_chapter_context = {
        manga = manga,
        chapters = chapters,
    }

    self.current_chapter_options = {
        title = manga.title,
        chapters = self:buildChapterMenuItems(manga, chapters),
    }
    self.current_chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:showChapterActions(manga, chapter)
    end)
end

function SuwayomiPlugin:getChapterDownloadKey(manga, chapter)
    return self:getDownloadQueue():getKey(manga, chapter)
end

function SuwayomiPlugin:getChapterProgressPath(manga, chapter, download_directory)
    return self:getDownloadQueue():buildProgressPath(manga, chapter, download_directory)
end

function SuwayomiPlugin:getChapterDownloadStatus(manga, chapter)
    return self:getDownloadQueue():getStatus(manga, chapter)
end

function SuwayomiPlugin:setChapterDownloadStatus(manga, chapter, status)
    self:getDownloadQueue():setStatus(manga, chapter, status)
end

function SuwayomiPlugin:formatChapterMenuText(chapter, status)
    return self:getDownloadQueue():formatChapterMenuText(chapter, status)
end

function SuwayomiPlugin:loadChapterLedger()
    if not SuwayomiSettings.loadChapterLedger then
        return {}
    end
    return SuwayomiSettings:loadChapterLedger() or {}
end

function SuwayomiPlugin:saveChapterLedger(ledger)
    if not SuwayomiSettings.saveChapterLedger then
        return ledger or {}
    end
    return SuwayomiSettings:saveChapterLedger(ledger or {})
end

function SuwayomiPlugin:upsertChapterLedgerEntry(manga, chapter, updates)
    local ledger = self:loadChapterLedger()
    local key = self:getChapterLedgerKey(manga, chapter)
    local existing = ledger[key] or {}

    local entry = {
        manga_id = tostring(manga.id or existing.manga_id or ""),
        manga_title = manga.title or existing.manga_title,
        chapter_id = tostring(chapter.id or existing.chapter_id or ""),
        chapter_name = chapter.name or existing.chapter_name,
        read = existing.read == true,
        path = existing.path,
        pending_read_sync = existing.pending_read_sync == true or nil,
    }

    for update_key, value in pairs(updates or {}) do
        entry[update_key] = value
    end

    ledger[key] = entry
    self:saveChapterLedger(ledger)
    return entry
end

function SuwayomiPlugin:getChapterLedgerKey(manga, chapter)
    return self:getChapterDownloadKey(manga, chapter)
end

function SuwayomiPlugin:mergeChaptersWithReadLedger(manga, chapters)
    local ledger = self:loadChapterLedger()
    local changed = false
    local merged = {}

    for _, chapter in ipairs(chapters or {}) do
        local item = {}
        for key, value in pairs(chapter) do
            item[key] = value
        end

        local key = self:getChapterLedgerKey(manga, item)
        local entry = ledger[key]
        local suwayomi_is_read = item.is_read == true
        local is_read = suwayomi_is_read or (entry and entry.read == true)
        item._suwayomi_is_read = suwayomi_is_read
        item.is_read = is_read

        if is_read then
            ledger[key] = {
                manga_id = tostring(manga.id or ""),
                manga_title = manga.title,
                chapter_id = tostring(item.id or ""),
                chapter_name = item.name,
                read = true,
                path = entry and entry.path or nil,
                pending_read_sync = suwayomi_is_read and nil or (entry and entry.pending_read_sync == true or nil),
            }
            changed = true
        end

        table.insert(merged, item)
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return merged
end

function SuwayomiPlugin:getKoreaderMetadataPathForDocument(document_path)
    if not document_path or document_path == "" then
        return nil
    end

    local base_path, extension = document_path:match("^(.*)%.([^%.%/]+)$")
    if not base_path or not extension then
        return nil
    end

    return base_path .. ".sdr/metadata." .. extension .. ".lua"
end

function SuwayomiPlugin:isKoreaderMetadataFinished(metadata_path)
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return false
    end

    local content = handle:read("*a") or ""
    handle:close()

    local status = content:match('%["status"%]%s*=%s*"([^"]+)"')
    if status == "complete" or status == "completed" or status == "finished" then
        return true
    end

    local percent_finished = tonumber(content:match('%["percent_finished"%]%s*=%s*([%d%.]+)'))
    return percent_finished ~= nil and percent_finished >= 1
end

function SuwayomiPlugin:isChapterPathFinishedInKoreader(chapter_path)
    return self:isKoreaderMetadataFinished(self:getKoreaderMetadataPathForDocument(chapter_path))
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

        local chapter_exists = false
        local chapter_path
        if download_directory and download_directory ~= "" then
            _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, item)
            chapter_exists = SuwayomiDownloader:chapterExists(chapter_path)
            local metadata_finished = chapter_exists and self:isChapterPathFinishedInKoreader(chapter_path)
            if metadata_finished then
                item.is_read = true
                if item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                end
            end
        end

        local status = self:getChapterDownloadStatus(manga, item)
        if not status then
            if chapter_exists then
                status = { state = "downloaded" }
            elseif item.is_read then
                status = { state = "read" }
            end
        end
        item.menu_text = self:formatChapterMenuText(item, status)

        if chapter_exists then
            self:upsertChapterLedgerEntry(manga, item, {
                path = chapter_path,
                read = item.is_read == true,
                pending_read_sync = item.pending_read_sync == true or nil,
            })
        end

        table.insert(items, item)
    end

    return items
end

function SuwayomiPlugin:getChapterPath(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    if not download_directory or download_directory == "" then
        return nil
    end

    local SuwayomiDownloader = require("suwayomi_downloader")
    local _, chapter_path = SuwayomiDownloader:getTargetPath(download_directory, manga, chapter)
    return chapter_path
end

function SuwayomiPlugin:isChapterDownloaded(manga, chapter)
    local chapter_path = self:getChapterPath(manga, chapter)
    if not chapter_path then
        return false, nil
    end

    local SuwayomiDownloader = require("suwayomi_downloader")
    return SuwayomiDownloader:chapterExists(chapter_path), chapter_path
end

function SuwayomiPlugin:getChapterActions(manga, chapter)
    local downloaded = self:isChapterDownloaded(manga, chapter)
    local actions = {}

    if downloaded then
        table.insert(actions, { id = "open", text = _("Open") })
        table.insert(actions, { id = "delete", text = _("Delete from device") })
    else
        table.insert(actions, { id = "download", text = _("Download") })
    end

    table.insert(actions, { id = "mark_read", text = _("Mark as read") })
    return actions
end

function SuwayomiPlugin:openChapter(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        self:showMessage(_("Download the chapter first."))
        return false
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(chapter_path)
    elseif ReaderUI.showReader then
        ReaderUI:showReader(chapter_path)
    else
        self:showMessage(_("KOReader could not open this chapter right now."))
        return false
    end

    return true
end

function SuwayomiPlugin:deleteChapterFromDevice(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if not downloaded or not chapter_path then
        self:showMessage(_("This chapter is not downloaded."))
        return false
    end

    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    os.remove(chapter_path)
    if metadata_path then
        os.remove(metadata_path)
        os.remove(metadata_path .. ".old")
        local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
        if metadata_dir then
            os.remove(metadata_dir)
        end
    end

    local ledger = self:loadChapterLedger()
    local key = self:getChapterLedgerKey(manga, chapter)
    local entry = ledger[key]
    if entry then
        entry.path = nil
        if entry.read ~= true and entry.pending_read_sync ~= true then
            ledger[key] = nil
        else
            ledger[key] = entry
        end
        self:saveChapterLedger(ledger)
    end

    self:refreshChapterMenu()
    return true
end

function SuwayomiPlugin:markChapterRead(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local entry = self:upsertChapterLedgerEntry(manga, chapter, {
        path = chapter_path,
        read = true,
        pending_read_sync = true,
    })

    local credentials = SuwayomiSettings:load()
    if credentials.server_url ~= "" and SuwayomiAPI.markChapterRead then
        local result = SuwayomiAPI.markChapterRead(credentials, entry.chapter_id)
        if result.ok then
            self:upsertChapterLedgerEntry(manga, chapter, {
                path = chapter_path,
                read = true,
                pending_read_sync = nil,
            })
        else
            self:showMessage(_(result.error))
        end
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = true
                break
            end
        end
    end
    self:refreshChapterMenu()
    return true
end

function SuwayomiPlugin:performChapterAction(manga, chapter, action_id)
    if action_id == "open" then
        return self:openChapter(manga, chapter)
    end
    if action_id == "download" then
        self:enqueueChapterDownload(manga, chapter)
        return true
    end
    if action_id == "delete" then
        return self:deleteChapterFromDevice(manga, chapter)
    end
    if action_id == "mark_read" then
        return self:markChapterRead(manga, chapter)
    end
    return false
end

function SuwayomiPlugin:showChapterActions(manga, chapter)
    if not SuwayomiUI.showChapterActionsMenu then
        self:enqueueChapterDownload(manga, chapter)
        return
    end

    local options = {
        title = chapter.name,
        actions = self:getChapterActions(manga, chapter),
    }

    SuwayomiUI.showChapterActionsMenu(options, function(action)
        self:performChapterAction(manga, chapter, action.id)
    end)
end

function SuwayomiPlugin:getCurrentDocumentPath()
    if not self.ui then
        return nil
    end

    local document = self.ui.document
    return self.ui.document_path
        or self.ui.document_pathname
        or (document and (document.file or document.filename or document.path))
end

function SuwayomiPlugin:isCurrentDocumentFinished()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings or not doc_settings.readSetting then
        return false
    end

    local summary = doc_settings:readSetting("summary")
    local status = summary and summary.status
    return status == "finished" or status == "complete" or status == "completed"
end

function SuwayomiPlugin:markLedgerEntryRead(entry)
    if not entry or entry.read == true then
        return false
    end

    local ledger = self:loadChapterLedger()
    local key = tostring(entry.manga_id or "") .. ":" .. tostring(entry.chapter_id or "")
    if not ledger[key] then
        return false
    end

    ledger[key].read = true
    ledger[key].pending_read_sync = true
    self:saveChapterLedger(ledger)

    local credentials = SuwayomiSettings:load()
    if credentials.server_url ~= "" and SuwayomiAPI.markChapterRead then
        local result = SuwayomiAPI.markChapterRead(credentials, entry.chapter_id)
        if result.ok then
            ledger = self:loadChapterLedger()
            if ledger[key] then
                ledger[key].pending_read_sync = nil
                self:saveChapterLedger(ledger)
            end
        else
            self:showMessage(_(result.error))
        end
    end

    return true
end

function SuwayomiPlugin:syncPendingReadMarks(credentials)
    if not SuwayomiAPI.markChapterRead then
        return 0
    end

    credentials = credentials or SuwayomiSettings:load()
    if not credentials or credentials.server_url == "" then
        return 0
    end

    local ledger = self:loadChapterLedger()
    local synced = 0
    local changed = false

    for key, entry in pairs(ledger) do
        if entry.read == true and entry.pending_read_sync == true and entry.chapter_id then
            local result = SuwayomiAPI.markChapterRead(credentials, entry.chapter_id)
            if result.ok then
                ledger[key].pending_read_sync = nil
                synced = synced + 1
                changed = true
            end
        end
    end

    if changed then
        self:saveChapterLedger(ledger)
    end

    return synced
end

function SuwayomiPlugin:onCloseDocument()
    local document_path = self:getCurrentDocumentPath()
    if not document_path or not self:isCurrentDocumentFinished() then
        return
    end

    local ledger = self:loadChapterLedger()
    for _, entry in pairs(ledger) do
        if entry.path == document_path then
            self:markLedgerEntryRead(entry)
            return
        end
    end
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
            self:showChapterActions(self.current_chapter_context.manga, chapter)
        end)
    elseif self.current_chapter_menu and self.current_chapter_menu.updateItems then
        self.current_chapter_menu:updateItems(nil, true)
    end
end

function SuwayomiPlugin:enqueueChapterDownload(manga, chapter)
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
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

    self:getDownloadQueue():enqueue(manga, chapter, download_directory)
    self:refreshChapterMenu()
end

function SuwayomiPlugin:processChapterDownloadQueue()
    self:getDownloadQueue():process()
end

function SuwayomiPlugin:pollChapterDownload()
    self:getDownloadQueue():poll()
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
