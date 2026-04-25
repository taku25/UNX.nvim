-- lua/UNX/vcs/p4.lua
local unl_p4 = require("UNL.vcs.p4")
local M = {}

-- Proxy calls to UNL.vcs.p4
setmetatable(M, { __index = unl_p4 })

local function spawn_p4(args, cwd, on_success)
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)
    local output_data = ""

    local handle, pid
    handle, pid = vim.loop.spawn("p4", {
        args = args,
        cwd = cwd,
        stdio = { nil, stdout, stderr }
    }, function(code, signal)
        stdout:read_stop()
        stderr:read_stop()
        stdout:close()
        stderr:close()
        handle:close()

        vim.schedule(function()
            if code == 0 then
                on_success(output_data)
            else
                on_success(nil)
            end
        end)
    end)

    if handle then
        vim.loop.read_start(stdout, function(err, data)
            if data then output_data = output_data .. data end
        end)
        vim.loop.read_start(stderr, function(err, data) end)
    else
        vim.schedule(function() on_success(nil) end)
    end
end

--- Check if P4 workspace is valid for this directory
local function check_workspace(cwd, callback)
    spawn_p4({ "where", "." }, cwd, function(output)
        if not output or output == "" or output:match("not on client") or output:match("not under") then
            callback(false)
        else
            callback(true)
        end
    end)
end

--- Override refresh to verify workspace before fetching P4 status.
--- UNL.vcs.p4 caches availability per-path, but may have stale data from
--- a previous P4-managed project. Always re-check with "p4 where" here.
--- @param start_path string Project root
--- @param on_complete function|nil
--- @param logger_name string|nil
function M.refresh(start_path, on_complete, logger_name)
    check_workspace(start_path, function(available)
        if not available then
            -- Clear any stale P4 cache so get_changes() returns nothing
            unl_p4.clear()
            if on_complete then on_complete() end
            return
        end
        unl_p4.refresh(start_path, on_complete, logger_name)
    end)
end

--- Get current P4 user name
--- @param cwd string
--- @param callback function(name: string|nil)
function M.get_user_name(cwd, callback)
    check_workspace(cwd, function(available)
        if not available then return callback(nil) end
        spawn_p4({ "user", "-o" }, cwd, function(output)
            if not output then return callback(nil) end
            local user = output:match("User:%s+(%S+)")
            callback(user)
        end)
    end)
end

--- Get P4 changelist log
--- @param cwd string Root directory
--- @param limit number Max count
--- @param author string|nil User filter (optional)
--- @param callback function(commits: table[]|nil)
function M.get_log(cwd, limit, author, callback)
    check_workspace(cwd, function(available)
        if not available then return callback(nil) end

        -- Use "..." (relative to cwd) instead of "//..." (all depots)
        local args = { "-ztag", "changes", "-m", tostring(limit), "-l", "-s", "submitted" }
        if author then
            table.insert(args, "-u")
            table.insert(args, author)
        end
        table.insert(args, "...")

        spawn_p4(args, cwd, function(output)
            if not output then return callback(nil) end

            local commits = {}
            local current = {}
            for line in output:gmatch("[^\r\n]+") do
                local key, value = line:match("^%.%.%.%s+(%S+)%s+(.+)$")
                if key then
                    if key == "change" then
                        if current.hash then
                            table.insert(commits, current)
                        end
                        current = { hash = value, vcs = "p4" }
                    elseif key == "user" then
                        current.author = value
                    elseif key == "desc" then
                        current.message = vim.fn.trim(value)
                    elseif key == "time" then
                        local ts = tonumber(value)
                        if ts then
                            local diff = os.time() - ts
                            if diff < 3600 then
                                current.date = math.floor(diff / 60) .. " minutes ago"
                            elseif diff < 86400 then
                                current.date = math.floor(diff / 3600) .. " hours ago"
                            else
                                current.date = math.floor(diff / 86400) .. " days ago"
                            end
                        end
                    end
                end
            end
            if current.hash then
                table.insert(commits, current)
            end

            for _, c in ipairs(commits) do
                c.message = c.message or "(no description)"
                c.author = c.author or ""
                c.date = c.date or ""
                c.display = string.format("%s %s (%s)", c.hash, c.message, c.date)
            end

            callback(commits)
        end)
    end)
end

--- Get changed files for a P4 changelist
--- @param cwd string Root directory
--- @param changelist string Changelist number
--- @param callback function(files: string[]|nil)
function M.get_commit_files(cwd, changelist, callback)
    spawn_p4({ "describe", "-s", changelist }, cwd, function(output)
        if not output then return callback(nil) end

        local files = {}
        local in_affected = false
        for line in output:gmatch("[^\r\n]+") do
            if line:match("^Affected files") then
                in_affected = true
            elseif in_affected then
                local depot_path = line:match("^%.%.%.%s+(//[^#]+)")
                if depot_path then
                    local short = depot_path:match("//[^/]+/(.+)$") or depot_path
                    table.insert(files, short)
                end
            end
        end

        callback(files)
    end)
end

return M
