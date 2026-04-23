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

function Downloader:startChapterDownload(credentials, download_directory, manga, chapter)
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

    return {
        ok = true,
        path = chapter_path,
        total = #page_result.pages,
        job = {
            credentials = credentials,
            pages = page_result.pages,
            writer = writer,
            chapter_path = chapter_path,
            current = 0,
        },
    }
end

function Downloader:downloadNextPage(job)
    if not job or not job.pages then
        return { ok = false, error = "Invalid chapter download job." }
    end

    if job.current >= #job.pages then
        if job.writer then
            job.writer:close()
            job.writer = nil
        end
        return {
            ok = true,
            done = true,
            current = job.current,
            total = #job.pages,
            path = job.chapter_path,
        }
    end

    local next_index = job.current + 1
    local binary = SuwayomiAPI.downloadBinary(job.credentials, job.pages[next_index])
    if not binary.ok then
        return self:failAndCleanup(binary.error, job.chapter_path, job.writer)
    end

    local ext = binary.content_type == "image/webp" and "webp"
        or binary.content_type == "image/png" and "png"
        or "jpg"

    local entry_name = string.format("%04d.%s", next_index, ext)
    if not job.writer:addFileFromMemory(entry_name, binary.body) then
        return self:failAndCleanup(job.writer.err or "Could not write chapter archive.", job.chapter_path, job.writer)
    end

    job.current = next_index
    local done = job.current == #job.pages
    if done then
        job.writer:close()
        job.writer = nil
    end

    return {
        ok = true,
        done = done,
        current = job.current,
        total = #job.pages,
        path = job.chapter_path,
    }
end

function Downloader:downloadChapter(credentials, download_directory, manga, chapter)
    local start_result = self:startChapterDownload(credentials, download_directory, manga, chapter)
    if not start_result.ok or start_result.skipped then
        return start_result
    end

    local result
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok then
            return result
        end
    until result.done

    return { ok = true, path = start_result.path }
end

return Downloader
