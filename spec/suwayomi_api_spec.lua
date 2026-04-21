package.path = "?.lua;" .. package.path
local api = require("suwayomi_api")

describe("suwayomi_api", function()
    it("should build correct GraphQL query for sources", function()
        local query = api._buildSourcesQuery()
        assert.truthy(query:match("query getSources"))
        assert.truthy(query:match("sources { id name }"))
    end)
end)
