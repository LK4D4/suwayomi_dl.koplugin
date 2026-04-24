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
        self:handleChapterTap(manga, chapter)
    end, function(chapter)
        self:toggleChapterSelection(manga, chapter)
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

function SuwayomiPlugin:getChapterSelectionKey(manga, chapter)
    return tostring(manga.id or manga.title or "") .. ":" .. tostring(chapter.id or chapter.name or "")
end

function SuwayomiPlugin:isChapterSelected(manga, chapter)
    local manga_id = type(manga) == "table" and (manga.id or manga.title) or manga
    local chapter_id = type(chapter) == "table" and (chapter.id or chapter.name) or chapter
    local key = tostring(manga_id or "") .. ":" .. tostring(chapter_id or "")
    return self.selected_chapters and self.selected_chapters[key] == true
end

function SuwayomiPlugin:getSelectedChapterCount()
    local count = 0
    for _, selected in pairs(self.selected_chapters or {}) do
        if selected then
            count = count + 1
        end
    end
    return count
end

function SuwayomiPlugin:toggleChapterSelection(manga, chapter)
    self.selected_chapters = self.selected_chapters or {}
    local key = self:getChapterSelectionKey(manga, chapter)
    if self.selected_chapters[key] then
        self.selected_chapters[key] = nil
    else
        self.selected_chapters[key] = true
    end
    self.selection_mode = self:getSelectedChapterCount() > 0
    self:refreshChapterMenu()
end

function SuwayomiPlugin:handleChapterTap(manga, chapter)
    if self.selection_mode then
        self:toggleChapterSelection(manga, chapter)
        return
    end

    self:showChapterActions(manga, chapter)
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
        local ledger_read_is_pending = entry and entry.read == true and entry.pending_read_sync == true
        local is_read = suwayomi_is_read or ledger_read_is_pending
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
        elseif entry and entry.read == true then
            if entry.path then
                entry.read = nil
                entry.pending_read_sync = nil
                ledger[key] = entry
            else
                ledger[key] = nil
            end
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

function SuwayomiPlugin:ensureDirectory(path)
    if not path or path == "" then
        return false
    end

    local ok, lfs = pcall(require, "lfs")
    if not ok or not lfs then
        return false
    end

    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        self:ensureDirectory(parent)
    end

    return lfs.mkdir(path) or lfs.attributes(path, "mode") == "directory"
end

function SuwayomiPlugin:loadKoreaderMetadataTable(chapter_path)
    local metadata_path = self:getKoreaderMetadataPathForDocument(chapter_path)
    local metadata = {
        doc_path = chapter_path,
    }
    local handle = metadata_path and io.open(metadata_path, "r")
    if not handle then
        return metadata, metadata_path
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return metadata, metadata_path
    end

    setfenv(loader, {})
    local ok, parsed = pcall(loader)
    if ok and type(parsed) == "table" then
        parsed.doc_path = parsed.doc_path or chapter_path
        return parsed, metadata_path
    end

    return metadata, metadata_path
end

local function sortLuaKeys(left, right)
    local left_type = type(left)
    local right_type = type(right)
    if left_type == right_type then
        return tostring(left) < tostring(right)
    end
    return left_type < right_type
end

function SuwayomiPlugin:serializeLuaValue(value, indent)
    indent = indent or 0
    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    if value_type ~= "table" then
        return "nil"
    end

    local next_indent = indent + 4
    local current_padding = string.rep(" ", indent)
    local next_padding = string.rep(" ", next_indent)
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, sortLuaKeys)

    local lines = { "{" }
    for _, key in ipairs(keys) do
        local item = value[key]
        if item ~= nil then
            table.insert(lines, next_padding
                .. "["
                .. self:serializeLuaValue(key, 0)
                .. "] = "
                .. self:serializeLuaValue(item, next_indent)
                .. ",")
        end
    end
    table.insert(lines, current_padding .. "}")
    return table.concat(lines, "\n")
end

function SuwayomiPlugin:saveKoreaderMetadataTable(metadata_path, metadata)
    if not metadata_path then
        return false
    end

    local metadata_dir = metadata_path:match("^(.*)/[^/]+$")
    if metadata_dir and not self:ensureDirectory(metadata_dir) then
        return false
    end

    local handle = io.open(metadata_path, "w")
    if not handle then
        return false
    end

    handle:write("return ", self:serializeLuaValue(metadata, 0), "\n")
    handle:close()
    return true
end

function SuwayomiPlugin:setKoreaderChapterReadState(chapter_path, is_read)
    if not chapter_path or chapter_path == "" then
        return false
    end

    local metadata, metadata_path = self:loadKoreaderMetadataTable(chapter_path)
    metadata.doc_path = metadata.doc_path or chapter_path
    metadata.summary = type(metadata.summary) == "table" and metadata.summary or {}

    if is_read then
        metadata.percent_finished = 1
        metadata.summary.status = "complete"
    else
        metadata.percent_finished = 0
        metadata.summary.status = nil
    end

    return self:saveKoreaderMetadataTable(metadata_path, metadata)
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

function SuwayomiPlugin:getKoreaderHistoryPath()
    if not SuwayomiSettings.getSettingsDir then
        return nil
    end

    local settings_dir = SuwayomiSettings:getSettingsDir()
    if not settings_dir or settings_dir == "" then
        return nil
    end

    return settings_dir .. "/history.lua"
end

function SuwayomiPlugin:loadKoreaderHistoryPaths()
    local history_path = self:getKoreaderHistoryPath()
    local handle = history_path and io.open(history_path, "r")
    if not handle then
        return {}
    end

    local content = handle:read("*a") or ""
    handle:close()

    local loader = loadstring(content)
    if not loader then
        return {}
    end

    setfenv(loader, {})
    local ok, history = pcall(loader)
    if not ok or type(history) ~= "table" then
        return {}
    end

    local paths = {}
    for _, entry in pairs(history) do
        if type(entry) == "table" and type(entry.file) == "string" and entry.file ~= "" then
            paths[entry.file] = true
        end
    end
    return paths
end

function SuwayomiPlugin:buildChapterMenuItems(manga, chapters)
    local SuwayomiDownloader = require("suwayomi_downloader")
    local download_directory = SuwayomiSettings:loadDownloadDirectory()
    local history_paths = self:loadKoreaderHistoryPaths()
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
            local history_read = chapter_exists and history_paths[chapter_path] == true
            if metadata_finished or history_read then
                item.is_read = true
                if item._suwayomi_is_read ~= true then
                    item.pending_read_sync = true
                end
            end
            if chapter_exists and item.is_read == true and not metadata_finished then
                self:setKoreaderChapterReadState(chapter_path, true)
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
        if self.selection_mode then
            if self:isChapterSelected(manga, item) then
                item.menu_text = "[x] " .. item.menu_text
            else
                item.menu_text = "[ ] " .. item.menu_text
            end
        end

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

    if chapter.is_read == true then
        table.insert(actions, { id = "mark_unread", text = _("Mark as unread") })
    else
        table.insert(actions, { id = "mark_read", text = _("Mark as read") })
    end
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
    if downloaded and chapter_path then
        self:setKoreaderChapterReadState(chapter_path, true)
    end
    self:upsertChapterLedgerEntry(manga, chapter, {
        path = chapter_path,
        read = true,
        pending_read_sync = true,
    })

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = true
                break
            end
        end
    end
    self:refreshChapterMenu()
    self:schedulePendingReadSync()
    return true
end

function SuwayomiPlugin:markChapterUnread(manga, chapter)
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    if downloaded and chapter_path then
        self:setKoreaderChapterReadState(chapter_path, false)
    end
    local ledger = self:loadChapterLedger()
    local key = self:getChapterLedgerKey(manga, chapter)
    local entry = ledger[key]

    if entry then
        entry.read = nil
        entry.pending_read_sync = nil
        entry.path = entry.path or chapter_path
        if not entry.path then
            ledger[key] = nil
        else
            ledger[key] = entry
        end
        self:saveChapterLedger(ledger)
    end

    if self.current_chapter_context and self.current_chapter_context.chapters then
        for _, current in ipairs(self.current_chapter_context.chapters) do
            if tostring(current.id or "") == tostring(chapter.id or "") then
                current.is_read = false
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
    if action_id == "mark_unread" then
        return self:markChapterUnread(manga, chapter)
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

    self:schedulePendingReadSync()
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

function SuwayomiPlugin:schedulePendingReadSync()
    if self.pending_read_sync_scheduled then
        return
    end

    self.pending_read_sync_scheduled = true
    UIManager:scheduleIn(0, function()
        self.pending_read_sync_scheduled = false
        self:syncPendingReadMarks()
    end)
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
            self:handleChapterTap(self.current_chapter_context.manga, chapter)
        end, function(chapter)
            self:toggleChapterSelection(self.current_chapter_context.manga, chapter)
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
