package.path = "?.lua;" .. package.path

describe("suwayomi_downloader", function()
    after_each(function()
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_api = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil

        package.preload.suwayomi_api = nil
        package.preload.lfs = nil
        package.preload["ffi/archiver"] = nil
        package.preload["ffi/util"] = nil
    end)

    it("skips downloading when the target cbz already exists", function()
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_api = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload.suwayomi_api = function()
            return {
                fetchChapterPages = function()
                    error("should not fetch pages for an existing file")
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function(path, attribute)
                    if path == "/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz" and attribute == "mode" then
                        return "file"
                    end
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi_downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_true(result.ok)
        assert.is_true(result.skipped)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", result.path)
    end)

    it("builds a cbz from fetched page bytes", function()
        local added_files = {}

        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_api = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload.suwayomi_api = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = {
                            "/api/v1/manga/85/chapter/1/page/0",
                            "/api/v1/manga/85/chapter/1/page/1",
                        },
                    }
                end,
                downloadBinary = function(_, page_url)
                    return {
                        ok = true,
                        body = page_url:match("/0$") and "page-one" or "page-two",
                        content_type = "image/jpeg",
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function(path)
                    assert.are.equal("/books/Sousou no Frieren", path)
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function(_, path, format)
                                assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", path)
                                assert.are.equal("zip", format)
                                return true
                            end,
                            addFileFromMemory = function(_, entry_path, content)
                                table.insert(added_files, { path = entry_path, content = content })
                                return true
                            end,
                            close = function() end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi_downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_true(result.ok)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", result.path)
        assert.are.same({
            { path = "0001.jpg", content = "page-one" },
            { path = "0002.jpg", content = "page-two" },
        }, added_files)
    end)

    it("removes a partial cbz when a page download fails", function()
        local removed_path

        package.preload.suwayomi_api = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0", "/page/1" },
                    }
                end,
                downloadBinary = function(_, page_url)
                    if page_url == "/page/0" then
                        return { ok = true, body = "page-one", content_type = "image/jpeg" }
                    end
                    return { ok = false, error = "Could not download chapter page." }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function() return true end,
                            addFileFromMemory = function() return true end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi_downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", removed_path)
    end)

    it("removes a partial cbz when archive writing fails", function()
        local removed_path

        package.preload.suwayomi_api = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
                downloadBinary = function()
                    return { ok = true, body = "page-one", content_type = "image/jpeg" }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return true
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            err = "Could not write chapter archive.",
                            open = function() return true end,
                            addFileFromMemory = function() return false end,
                            close = function() end,
                        }
                    end,
                }
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local original_remove = os.remove
        os.remove = function(path)
            removed_path = path
            return true
        end

        local downloader = require("suwayomi_downloader")
        local result = downloader:downloadChapter({ server_url = "https://suwayomi.example" }, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        os.remove = original_remove

        assert.is_false(result.ok)
        assert.are.equal("Could not write chapter archive.", result.error)
        assert.are.equal("/books/Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz", removed_path)
    end)

    it("reports a manga directory creation failure before opening the archive", function()
        package.preload.suwayomi_api = function()
            return {
                fetchChapterPages = function()
                    return {
                        ok = true,
                        chapter = { id = "398", name = "Official_Vol. 1 Ch. 1", manga_title = "Sousou no Frieren" },
                        pages = { "/page/0" },
                    }
                end,
            }
        end
        package.preload.lfs = function()
            return {
                attributes = function()
                    return nil
                end,
                mkdir = function()
                    return nil
                end,
            }
        end
        package.preload["ffi/archiver"] = function()
            return {
                Writer = {
                    new = function()
                        return {
                            open = function()
                                error("archive should not open when mkdir fails")
                            end,
                        }
                    end,
                },
            }
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end

        local downloader = require("suwayomi_downloader")
        local result = downloader:downloadChapter({}, "/books", { title = "Sousou no Frieren" }, { id = "398", name = "Official_Vol. 1 Ch. 1" })

        assert.is_false(result.ok)
        assert.are.equal("Could not create manga folder.", result.error)
    end)

    it("neutralizes traversal-only manga and chapter names", function()
        package.loaded.suwayomi_downloader = nil
        package.loaded.suwayomi_api = nil
        package.loaded.lfs = nil
        package.loaded["ffi/archiver"] = nil
        package.loaded["ffi/util"] = nil
        package.preload.lfs = function()
            return {}
        end
        package.preload["ffi/archiver"] = function()
            return {}
        end
        package.preload["ffi/util"] = function()
            return {
                joinPath = function(base, segment)
                    if base:sub(-1) == "/" then
                        return base .. segment
                    end
                    return base .. "/" .. segment
                end,
            }
        end
        package.preload.suwayomi_api = function()
            return {}
        end

        local downloader = require("suwayomi_downloader")
        local manga_dir, chapter_path = downloader:getTargetPath("/books", { title = ".." }, { name = ".." })

        assert.are.equal("/books/untitled", manga_dir)
        assert.are.equal("/books/untitled/untitled.cbz", chapter_path)
    end)
end)
