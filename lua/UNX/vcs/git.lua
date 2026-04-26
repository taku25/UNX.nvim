-- lua/UNX/vcs/git.lua
local unl_git = require("UNL.vcs.git")
local unl_path = require("UNL.path")
local M = {}

-- Proxy calls to UNL.vcs.git
setmetatable(M, { __index = unl_git })

-- Use ASCII Unit Separator to avoid conflicts with commit messages
local SEP = string.char(0x1f)

local function spawn_git(args, cwd, on_success)
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)
    local output_data = ""

    local handle, pid
    handle, pid = vim.loop.spawn("git", {
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

--- Find git root from a given directory
--- @param cwd string Starting directory
--- @param callback function(git_root: string|nil)
local function find_git_root(cwd, callback)
    spawn_git({"rev-parse", "--show-toplevel"}, cwd, function(output)
        if not output then return callback(nil) end
        local root = output:gsub("[\r\n]+", "")
        if root == "" then return callback(nil) end
        callback(unl_path.normalize(root))
    end)
end

--- Get current user name
--- @param cwd string
--- @param callback function(name: string|nil)
function M.get_user_name(cwd, callback)
    spawn_git({"config", "user.name"}, cwd, function(output)
        if not output then return callback(nil) end
        local name = output:gsub("[\r\n]+", "")
        if name == "" then return callback(nil) end
        callback(name)
    end)
end

--- Get git log (newest first)
--- @param cwd string Root directory
--- @param limit number Max count
--- @param author string|nil Author filter (optional)
--- @param callback function(commits: table[]|nil)
function M.get_log(cwd, limit, author, callback)
    find_git_root(cwd, function(git_root)
        if not git_root then return callback(nil) end

        local format = "%h" .. SEP .. "%s" .. SEP .. "%an" .. SEP .. "%ar"
        local args = { "log", "--first-parent", "--pretty=format:" .. format, "-n", tostring(limit) }
        if author then
            table.insert(args, "--author=" .. author)
        end

        spawn_git(args, git_root, function(output)
            if not output then return callback(nil) end

            local commits = {}
            for line in output:gmatch("[^\r\n]+") do
                local parts = vim.split(line, SEP)
                if #parts >= 4 then
                    table.insert(commits, {
                        hash = parts[1],
                        message = parts[2],
                        author = parts[3],
                        date = parts[4],
                        display = string.format("%s %s (%s)", parts[1], parts[2], parts[4]),
                        vcs = "git",
                        _root = git_root,
                    })
                end
            end
            callback(commits)
        end)
    end)
end

--- Get file content at a specific commit
--- @param cwd string Root directory
--- @param commit_hash string Commit hash
--- @param rel_path string Path relative to git root
--- @param callback function(content: string|nil)
function M.get_file_at_commit(cwd, commit_hash, rel_path, callback)
    find_git_root(cwd, function(git_root)
        if not git_root then return callback(nil) end
        -- Normalise to forward slashes (git requires them even on Windows)
        local fwd_path = rel_path:gsub("\\", "/")
        spawn_git({ "show", commit_hash .. ":" .. fwd_path }, git_root, function(content)
            callback(content)
        end)
    end)
end

--- Get changed files for a commit (structured for submodule grouping)
--- @param cwd string Root directory
--- @param commit_hash string Commit hash
--- @param callback function(items: table[]|nil)
function M.get_commit_files(cwd, commit_hash, callback)
    find_git_root(cwd, function(git_root)
        if not git_root then return callback(nil) end

        -- Use --raw to detect submodules (mode 160000)
        spawn_git({"show", "--raw", "--pretty=format:", commit_hash}, git_root, function(output)
            if not output then return callback(nil) end

            local items = {}
            local submodule_jobs = 0
            local is_iterating = true

            local function check_done()
                if not is_iterating and submodule_jobs == 0 then
                    -- Sort: submodules first, then normal files
                    table.sort(items, function(a, b)
                        if a.type ~= b.type then return a.type == "submodule" end
                        return a.path < b.path
                    end)
                    callback(items)
                end
            end

            for line in output:gmatch("[^\r\n]+") do
                local _, new_mode, old_hash, new_hash, _, path = line:match("^:(%d+) (%d+) (%x+) (%x+) (%u%d*)%s+(.+)$")
                
                if path then
                    if new_mode == "160000" then
                        -- Submodule detected
                        submodule_jobs = submodule_jobs + 1
                        local sub_abs_path = unl_path.join(git_root, path)
                        
                        spawn_git({"diff", "--name-only", old_hash, new_hash}, sub_abs_path, function(sub_output)
                            local sub_files = {}
                            if sub_output then
                                for sub_line in sub_output:gmatch("[^\r\n]+") do
                                    if sub_line ~= "" then
                                        table.insert(sub_files, {
                                            name = vim.fn.fnamemodify(sub_line, ":t"),
                                            rel_path = sub_line,
                                            full_rel_path = path .. "/" .. sub_line
                                        })
                                    end
                                end
                            end
                            
                            table.insert(items, {
                                type = "submodule",
                                path = path,
                                name = path, -- Submodule name is its path
                                files = sub_files
                            })
                            submodule_jobs = submodule_jobs - 1
                            check_done()
                        end)
                    else
                        -- Normal file
                        table.insert(items, {
                            type = "file",
                            path = path,
                            name = vim.fn.fnamemodify(path, ":t"),
                            full_rel_path = path
                        })
                    end
                end
            end
            
            is_iterating = false
            check_done()
        end)
    end)
end

return M
