package.path = "?.lua;" .. package.path
local api = require("suwayomi_api")

describe("suwayomi_api", function()
    it("should build correct GraphQL query for sources", function()
        local query = api._buildSourcesQuery()
        assert.truthy(query:match("query getSources"))
        assert.truthy(query:match("sources { id name }"))
    end)

    it("builds a basic auth header from credentials", function()
        local header = api.buildBasicAuthHeader("alice", "s3cret")
        assert.are.equal("Basic YWxpY2U6czNjcmV0", header)
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
                    "sources": [
                        {"id": "1", "name": "MangaDex"},
                        {"id": "2", "name": "ComicK"}
                    ]
                }
            }
        ]]

        local sources = api.parseSourcesResponse(response)

        assert.are.same({
            { id = "1", name = "MangaDex" },
            { id = "2", name = "ComicK" },
        }, sources)
    end)
end)
