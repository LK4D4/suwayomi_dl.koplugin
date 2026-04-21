local SuwayomiAPI = {}

function SuwayomiAPI._buildSourcesQuery()
    return '{"query": "query getSources { sources { id name } }"}'
end

return SuwayomiAPI
