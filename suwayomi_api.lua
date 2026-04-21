local SuwayomiAPI = {}
local json = require("dkjson")

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(input)
    local result = {}
    local padding = (3 - (#input % 3)) % 3
    input = input .. string.rep("\0", padding)

    for index = 1, #input, 3 do
        local a = input:byte(index)
        local b = input:byte(index + 1)
        local c = input:byte(index + 2)
        local value = a * 65536 + b * 256 + c

        local char1 = math.floor(value / 262144) % 64 + 1
        local char2 = math.floor(value / 4096) % 64 + 1
        local char3 = math.floor(value / 64) % 64 + 1
        local char4 = value % 64 + 1

        table.insert(result, BASE64_ALPHABET:sub(char1, char1))
        table.insert(result, BASE64_ALPHABET:sub(char2, char2))
        table.insert(result, padding >= 2 and "=" or BASE64_ALPHABET:sub(char3, char3))
        table.insert(result, padding >= 1 and "=" or BASE64_ALPHABET:sub(char4, char4))
    end

    return table.concat(result)
end

function SuwayomiAPI._buildSourcesQuery()
    return '{"query": "query getSources { sources { id name } }"}'
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

    if type(sources) ~= "table" then
        return nil, "Suwayomi server did not return a sources list."
    end

    local parsed_sources = {}
    for _, source in ipairs(sources) do
        table.insert(parsed_sources, {
            id = tostring(source.id),
            name = source.name or tostring(source.id),
        })
    end

    return parsed_sources
end

function SuwayomiAPI.fetchSources(credentials)
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    if not credentials or credentials.server_url == "" then
        return {
            ok = false,
            error = "Missing Suwayomi server URL.",
        }
    end

    local response_chunks = {}
    local request_body = SuwayomiAPI._buildSourcesQuery()
    local headers = SuwayomiAPI.buildRequestHeaders(credentials)
    headers["Content-Length"] = tostring(#request_body)

    local _, code = http.request{
        url = SuwayomiAPI.buildGraphQLEndpoint(credentials.server_url),
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_chunks),
    }

    local response_body = table.concat(response_chunks)
    if code == 200 then
        local sources, parse_error = SuwayomiAPI.parseSourcesResponse(response_body)
        if not sources then
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

    local error_message = {
        [401] = "Authentication failed.",
        [403] = "Authentication failed.",
        [404] = "Suwayomi GraphQL endpoint not found.",
    }

    return {
        ok = false,
        error = error_message[code] or "Could not reach the Suwayomi server.",
    }
end

return SuwayomiAPI
