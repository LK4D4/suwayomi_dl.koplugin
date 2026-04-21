local Downloader = {
    queue = {}
}

function Downloader:init()
    self.queue = {}
end

function Downloader:enqueue(item)
    table.insert(self.queue, item)
end

function Downloader:getQueueLength()
    return #self.queue
end

return Downloader
