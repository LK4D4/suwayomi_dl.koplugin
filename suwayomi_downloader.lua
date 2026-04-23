local lfs = require("lfs")
local Archiver = require("ffi/archiver")
local FFIUtil = require("ffi/util")
local SuwayomiAPI = require("suwayomi_api")

local Downloader = {}

function Downloader:sanitizePathSegment(name)
    local sanitized = tostring(name or ""):gsub("[\\/:*?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
    if sanitized == "" or sanitized == "." or sanitized == ".." then
        return "untitled"
    end
    return sanitized
end

function Downloader:getTargetPath(download_directory, manga, chapter)
    local manga_dir = FFIUtil.joinPath(download_directory, self:sanitizePathSegment(manga.title))
    local chapter_path = FFIUtil.joinPath(manga_dir, self:sanitizePathSegment(chapter.name) .. ".cbz")
    return manga_dir, chapter_path
end

function Downloader:chapterExists(chapter_path)
    return lfs.attributes(chapter_path, "mode") == "file"
end

function Downloader:ensureDirectory(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    if lfs.mkdir(path) then
        return true
    end

    return false, "Could not create manga folder."
end

function Downloader:cleanupPartialFile(path)
    if path and path ~= "" then
        os.remove(path)
    end
end

function Downloader:failAndCleanup(message, chapter_path, writer)
    if writer then
        writer:close()
    end
    self:cleanupPartialFile(chapter_path)
    return {
        ok = false,
        error = message,
    }
end

function Downloader:downloadChapter(credentials, download_directory, manga, chapter)
    if not download_directory or download_directory == "" then
        return { ok = false, error = "Set up a download directory first." }
    end

    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    if self:chapterExists(chapter_path) then
        return { ok = true, skipped = true, path = chapter_path }
    end

    local page_result = SuwayomiAPI.fetchChapterPages(credentials, chapter.id)
    if not page_result.ok then
        return { ok = false, error = page_result.error }
    end
    if #page_result.pages == 0 then
        return { ok = false, error = "Suwayomi server did not return chapter pages." }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error }
    end

    local writer = Archiver.Writer:new()
    if not writer:open(chapter_path, "zip") then
        return { ok = false, error = writer.err or "Could not create chapter archive." }
    end

    for index, page_url in ipairs(page_result.pages) do
        local binary = SuwayomiAPI.downloadBinary(credentials, page_url)
        if not binary.ok then
            return self:failAndCleanup(binary.error, chapter_path, writer)
        end

        local ext = binary.content_type == "image/webp" and "webp"
            or binary.content_type == "image/png" and "png"
            or "jpg"

        local entry_name = string.format("%04d.%s", index, ext)
        if not writer:addFileFromMemory(entry_name, binary.body) then
            return self:failAndCleanup(writer.err or "Could not write chapter archive.", chapter_path, writer)
        end
    end

    writer:close()
    return { ok = true, path = chapter_path }
end

return Downloader
