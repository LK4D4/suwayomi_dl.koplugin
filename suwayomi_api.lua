local SuwayomiAPI = {}
local json = require("dkjson")

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEBUG_LOG_PATH = "/storage/emulated/0/koreader/settings/suwayomi_debug.log"
local performGraphQLRequest

local function appendDebugLog(message)
    local handle = io.open(DEBUG_LOG_PATH, "a")
    if not handle then
        return
    end
    handle:write(message, "\n")
    handle:close()
end

local function base64Encode(input)
    local result = {}
    local index = 1

    while index <= #input do
        local a = input:byte(index) or 0
        local b = input:byte(index + 1) or 0
        local c = input:byte(index + 2) or 0
        local chunk_length = math.min(3, #input - index + 1)
        local value = a * 65536 + b * 256 + c

        local char1 = math.floor(value / 262144) % 64 + 1
        local char2 = math.floor(value / 4096) % 64 + 1
        local char3 = math.floor(value / 64) % 64 + 1
        local char4 = value % 64 + 1

        table.insert(result, BASE64_ALPHABET:sub(char1, char1))
        table.insert(result, BASE64_ALPHABET:sub(char2, char2))
        table.insert(result, chunk_length < 2 and "=" or BASE64_ALPHABET:sub(char3, char3))
        table.insert(result, chunk_length < 3 and "=" or BASE64_ALPHABET:sub(char4, char4))

        index = index + 3
    end

    return table.concat(result)
end

function SuwayomiAPI._buildSourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang } } }",
    })
end

function SuwayomiAPI.buildBasicAuthHeader(username, password)
    return "Basic " .. base64Encode(string.format("%s:%s", username or "", password or ""))
end

function SuwayomiAPI.buildRequestHeaders(credentials)
    local headers = {
        ["Content-Type"] = "application/json",
    }

    if credentials and credentials.auth_method == "basic_auth" then
        headers.Authorization = SuwayomiAPI.buildBasicAuthHeader(credentials.username, credentials.password)
    end

    return headers
end

function SuwayomiAPI.buildGraphQLEndpoint(server_url)
    return (server_url or ""):gsub("/+$", "") .. "/api/graphql"
end

function SuwayomiAPI.parseSourcesResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local sources = payload
        and payload.data
        and payload.data.sources
        and payload.data.sources.nodes

    if type(sources) ~= "table" then
        return nil, "Suwayomi server did not return a sources list."
    end

    local parsed_sources = {}
    for _, source in ipairs(sources) do
        table.insert(parsed_sources, {
            id = tostring(source.id),
            name = source.displayName or ((source.name or tostring(source.id)) .. (source.lang and source.lang ~= "" and source.lang ~= "localsourcelang" and (" (" .. string.upper(source.lang) .. ")") or "")),
            raw_name = source.name,
            lang = source.lang,
        })
    end

    return parsed_sources
end

function SuwayomiAPI._buildMangaQuery(source_id)
    return json.encode({
        query = "mutation GET_SOURCE_MANGAS_FETCH($input: FetchSourceMangaInput!) { fetchSourceManga(input: $input) { hasNextPage mangas { id title } } }",
        variables = {
            input = {
                source = tostring(source_id),
                page = 1,
                type = "POPULAR",
            },
        },
    })
end

function SuwayomiAPI.parseMangaResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local manga_nodes = payload
        and payload.data
        and payload.data.fetchSourceManga
        and payload.data.fetchSourceManga.mangas

    if type(manga_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a manga list."
    end

    local manga = {}
    for _, entry in ipairs(manga_nodes) do
        table.insert(manga, {
            id = tostring(entry.id),
            title = entry.title or tostring(entry.id),
        })
    end

    return manga
end

function SuwayomiAPI._buildChapterQuery(manga_id)
    return json.encode({
        query = "mutation GET_MANGA_CHAPTERS_FETCH($input: FetchChaptersInput!) { fetchChapters(input: $input) { chapters { id name chapterNumber sourceOrder scanlator } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function SuwayomiAPI.parseChapterResponse(response_body)
    local payload, _, err = json.decode(response_body, 1, nil)
    if err then
        return nil, "Invalid response from Suwayomi server."
    end

    local chapter_nodes = payload
        and payload.data
        and payload.data.fetchChapters
        and payload.data.fetchChapters.chapters

    if type(chapter_nodes) ~= "table" then
        local graph_error = payload and payload.errors and payload.errors[1] and payload.errors[1].message
        return nil, graph_error or "Suwayomi server did not return a chapter list."
    end

    local chapters = {}
    for _, entry in ipairs(chapter_nodes) do
        local chapter_name = entry.name
        if not chapter_name or chapter_name == "" then
            chapter_name = entry.chapterNumber and ("Chapter " .. tostring(entry.chapterNumber)) or tostring(entry.id)
        end

        table.insert(chapters, {
            id = tostring(entry.id),
            name = chapter_name,
        })
    end

    return chapters
end

performGraphQLRequest = function(credentials, request_body, operation_name)
    local ltn12 = require("ltn12")
    local server_url = credentials and credentials.server_url

    if not server_url or server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

    local client
    if server_url:match("^https://") then
        client = require("ssl.https")
    else
        client = require("socket.http")
    end

    local response_chunks = {}
    local headers = SuwayomiAPI.buildRequestHeaders(credentials)
    headers["Content-Length"] = tostring(#request_body)

    local ok, code = client.request{
        url = SuwayomiAPI.buildGraphQLEndpoint(server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
    }

    appendDebugLog(string.format("%s url=%s ok=%s code=%s code_type=%s", operation_name, server_url, tostring(ok), tostring(code), type(code)))

    local response_body = table.concat(response_chunks)
    if code == 200 then
        appendDebugLog(operation_name .. " received HTTP 200")
        return {
            ok = true,
            response_body = response_body,
        }
    end

    if not ok then
        appendDebugLog(operation_name .. " transport failure: " .. tostring(code))
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    if type(code) ~= "number" then
        appendDebugLog(operation_name .. " non-numeric status: " .. tostring(code))
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    local error_message = {
        [401] = "Authentication failed.",
        [403] = "Authentication failed.",
        [404] = "Suwayomi GraphQL endpoint not found.",
    }

    appendDebugLog(operation_name .. " HTTP status: " .. tostring(code))
    appendDebugLog(operation_name .. " response body: " .. tostring(response_body))
    return {
        ok = false,
        error = error_message[code] or "Could not reach the Suwayomi server.",
    }
end

function SuwayomiAPI.fetchSources(credentials)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildSourcesQuery(), "fetchSources")
    if not result.ok then
        return result
    end

    local sources, parse_error = SuwayomiAPI.parseSourcesResponse(result.response_body)
    if not sources then
        appendDebugLog("fetchSources parse error: " .. tostring(parse_error))
        appendDebugLog("fetchSources success body: " .. tostring(result.response_body))
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        sources = sources,
    }
end

function SuwayomiAPI.fetchMangaForSource(credentials, source_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildMangaQuery(source_id), "fetchMangaForSource")
    if not result.ok then
        return result
    end

    local manga, parse_error = SuwayomiAPI.parseMangaResponse(result.response_body)
    if not manga then
        appendDebugLog("fetchMangaForSource parse error: " .. tostring(parse_error))
        appendDebugLog("fetchMangaForSource success body: " .. tostring(result.response_body))
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        manga = manga,
    }
end

function SuwayomiAPI.fetchChaptersForManga(credentials, manga_id)
    local result = performGraphQLRequest(credentials, SuwayomiAPI._buildChapterQuery(manga_id), "fetchChaptersForManga")
    if not result.ok then
        return result
    end

    local chapters, parse_error = SuwayomiAPI.parseChapterResponse(result.response_body)
    if not chapters then
        appendDebugLog("fetchChaptersForManga parse error: " .. tostring(parse_error))
        appendDebugLog("fetchChaptersForManga success body: " .. tostring(result.response_body))
        return {
            ok = false,
            error = parse_error,
        }
    end

    return {
        ok = true,
        chapters = chapters,
    }
end

return SuwayomiAPI
