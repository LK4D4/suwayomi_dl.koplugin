local SuwayomiAPI = {}
local json = require("dkjson")

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEBUG_LOG_PATH = "/storage/emulated/0/koreader/settings/suwayomi_debug.log"

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
    return '{"query": "query getSources { sources { nodes { id name displayName lang } } }"}'
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

function SuwayomiAPI.fetchSources(credentials)
    local ltn12 = require("ltn12")

    if not credentials or credentials.server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

    local client
    if credentials.server_url:match("^https://") then
        client = require("ssl.https")
    else
        client = require("socket.http")
    end

    local response_chunks = {}
    local request_body = SuwayomiAPI._buildSourcesQuery()
    local headers = SuwayomiAPI.buildRequestHeaders(credentials)
    headers["Content-Length"] = tostring(#request_body)

    local ok, code = client.request{
        url = SuwayomiAPI.buildGraphQLEndpoint(credentials.server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
    }

    appendDebugLog(string.format("fetchSources url=%s ok=%s code=%s code_type=%s", credentials.server_url, tostring(ok), tostring(code), type(code)))

    local response_body = table.concat(response_chunks)
    if code == 200 then
        appendDebugLog("fetchSources received HTTP 200")
        local sources, parse_error = SuwayomiAPI.parseSourcesResponse(response_body)
        if not sources then
            appendDebugLog("fetchSources parse error: " .. tostring(parse_error))
            appendDebugLog("fetchSources success body: " .. tostring(response_body))
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

    if not ok then
        appendDebugLog("fetchSources transport failure: " .. tostring(code))
        return {
            ok = false,
            error = "Could not reach the Suwayomi server: " .. tostring(code),
        }
    end

    if type(code) ~= "number" then
        appendDebugLog("fetchSources non-numeric status: " .. tostring(code))
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

    appendDebugLog("fetchSources HTTP status: " .. tostring(code))
    appendDebugLog("fetchSources response body: " .. tostring(response_body))
    return {
        ok = false,
        error = error_message[code] or "Could not reach the Suwayomi server.",
    }
end

return SuwayomiAPI
