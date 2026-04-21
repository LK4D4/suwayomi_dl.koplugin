package.path = "?.lua;" .. package.path

describe("suwayomi_api", function()
    local api

    before_each(function()
        package.loaded.suwayomi_api = nil
        package.loaded["socket.http"] = nil
        package.loaded["ssl.https"] = nil
        package.loaded.ltn12 = nil
        api = require("suwayomi_api")
    end)

    it("should build correct GraphQL query for sources", function()
        local query = api._buildSourcesQuery()
        assert.truthy(query:match("query getSources"))
        assert.truthy(query:match("sources { nodes { id name displayName lang } }"))
    end)

    it("builds a basic auth header from credentials", function()
        local header = api.buildBasicAuthHeader("alice", "s3cret")
        assert.are.equal("Basic YWxpY2U6czNjcmV0", header)
    end)

    it("builds a basic auth header for longer credentials", function()
        local header = api.buildBasicAuthHeader("suwayomi", "EfQDeSAHD8NktUWX6nb9")
        assert.are.equal("Basic c3V3YXlvbWk6RWZRRGVTQUhEOE5rdFVXWDZuYjk=", header)
    end)

    it("builds request headers for basic auth settings", function()
        local headers = api.buildRequestHeaders({
            username = "alice",
            password = "s3cret",
            auth_method = "basic_auth",
        })

        assert.are.equal("application/json", headers["Content-Type"])
        assert.are.equal("Basic YWxpY2U6czNjcmV0", headers.Authorization)
    end)

    it("parses sources from a GraphQL response body", function()
        local response = [[
            {
                "data": {
                    "sources": {
                        "nodes": [
                            {"id": "1", "name": "MangaDex", "displayName": "MangaDex (EN)", "lang": "en"},
                            {"id": "2", "name": "ComicK", "lang": "fr"}
                        ]
                    }
                }
            }
        ]]

        local sources = api.parseSourcesResponse(response)

        assert.are.same({
            { id = "1", name = "MangaDex (EN)", raw_name = "MangaDex", lang = "en" },
            { id = "2", name = "ComicK (FR)", raw_name = "ComicK", lang = "fr" },
        }, sources)
    end)

    it("uses ssl.https for https servers", function()
        local requested_url

        package.preload["ssl.https"] = function()
            return {
                request = function(options)
                    requested_url = options.url
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(chunk)
                            table.insert(target, [[{"data":{"sources":{"nodes":[]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(result.ok)
        assert.are.equal("https://suwayomi.example/api/graphql", requested_url)
    end)

    it("uses socket.http for http servers", function()
        local requested_url

        package.preload["socket.http"] = function()
            return {
                request = function(options)
                    requested_url = options.url
                    options.sink("ignored")
                    return 1, 200
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(target)
                        return function(chunk)
                            table.insert(target, [[{"data":{"sources":{"nodes":[]}}}]])
                        end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "http://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_true(result.ok)
        assert.are.equal("http://suwayomi.example/api/graphql", requested_url)
    end)

    it("surfaces transport errors from the HTTP client", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(_)
                    return nil, "certificate verify failed"
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(_target)
                        return function(_chunk) end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Could not reach the Suwayomi server: certificate verify failed", result.error)
    end)

    it("surfaces non-http status strings from the HTTP client", function()
        package.preload["ssl.https"] = function()
            return {
                request = function(_)
                    return 1, "closed"
                end,
            }
        end

        package.preload.ltn12 = function()
            return {
                source = {
                    string = function(value)
                        return value
                    end,
                },
                sink = {
                    table = function(_target)
                        return function(_chunk) end
                    end,
                },
            }
        end

        local result = api.fetchSources({
            server_url = "https://suwayomi.example/",
            username = "alice",
            password = "secret",
            auth_method = "basic_auth",
        })

        assert.is_false(result.ok)
        assert.are.equal("Could not reach the Suwayomi server: closed", result.error)
    end)
end)
