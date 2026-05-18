-- lua/UNX/util/fuzzy.lua
-- Multi-token substring search.
-- Spaces in the query act as AND separators: each whitespace-delimited token
-- must appear as a contiguous substring (case-insensitive) in the target.
-- Example: "ap room" matches "APRoomManager" because both "ap" and "room"
-- are contiguous substrings of "aproommanager".

local M = {}

--- Returns true when every whitespace-separated token in `query` is found as
--- a contiguous substring of `str` (case-insensitive). Empty query always matches.
---@param str string
---@param query string
---@return boolean
function M.match(str, query)
    if query == "" then return true end
    str = str:lower()
    query = query:lower()
    for token in query:gmatch("%S+") do
        if not str:find(token, 1, true) then
            return false
        end
    end
    return true
end

--- Build a SQLite LIKE pattern for a single fuzzy token: "acm" -> "%a%c%m%".
--- Used for the broad initial DB fetch; Lua-side M.match does the precise filter.
---@param query string
---@return string
function M.like_pattern(query)
    local parts = {}
    for i = 1, #query do
        parts[i] = query:sub(i, i)
    end
    return "%" .. table.concat(parts, "%") .. "%"
end

return M
