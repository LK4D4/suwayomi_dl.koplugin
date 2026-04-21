package.path = "?.lua;" .. package.path
local downloader = require("suwayomi_downloader")

describe("suwayomi_downloader", function()
    it("should add items to queue", function()
        downloader:init()
        downloader:enqueue({url = "http://test", dest = "/tmp/test.jpg"})
        assert.are.equal(1, downloader:getQueueLength())
    end)
end)
