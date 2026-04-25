-- lua/UNX/ui/view/uproject/recent.lua

local Tree = require("nui.tree")
local unl_path = require("UNL.path")

local M = {}

M.ROOT_TYPE = "recent_files_root"

--- v:oldfiles からプロジェクト配下の既存ファイルを最大 max_count 件返す
function M.create_children_nodes(project_root, max_count)
    local norm_root = unl_path.normalize(project_root):lower()
    local oldfiles = vim.v.oldfiles or {}
    local nodes = {}
    local seen = {}

    for _, path in ipairs(oldfiles) do
        if #nodes >= max_count then break end

        local norm_path = unl_path.normalize(path)
        local norm_lower = norm_path:lower()

        if vim.startswith(norm_lower, norm_root .. "/")
            and not seen[norm_path]
            and vim.fn.filereadable(path) == 1 then

            seen[norm_path] = true
            table.insert(nodes, Tree.Node({
                text     = vim.fn.fnamemodify(path, ":t"),
                id       = "recent_item_" .. norm_path,
                path     = path,
                type     = "file",
                _has_children = false,
                extra    = { uep_type = "fs", is_recent_item = true, project_root = project_root },
            }))
        end
    end

    return nodes
end

--- プロジェクト配下に v:oldfiles のファイルが 1 件以上あるか確認
local function has_any_recent(project_root)
    local norm_root = unl_path.normalize(project_root):lower()
    for _, path in ipairs(vim.v.oldfiles or {}) do
        local norm_lower = unl_path.normalize(path):lower()
        if vim.startswith(norm_lower, norm_root .. "/") and vim.fn.filereadable(path) == 1 then
            return true
        end
    end
    return false
end

function M.create_root_node(is_expanded, project_root, max_count)
    local children = nil
    if is_expanded then
        children = M.create_children_nodes(project_root, max_count)
        if #children == 0 then return nil end
    else
        if not has_any_recent(project_root) then return nil end
    end

    local node = Tree.Node({
        text = "Recent",
        id   = "root_recent_files",
        type = "directory",
        _has_children = true,
        extra = { uep_type = M.ROOT_TYPE, project_root = project_root, max_count = max_count },
    }, children)

    if is_expanded then node:expand() end
    return node
end

return M
