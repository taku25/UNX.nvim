-- lua/UNX/ui/view/action/commit_diff.lua
-- VCS tab: show diff between the file at a specific commit vs the local working copy
local M = {}
local vcs = require("UNX.vcs")
local unl_open = require("UNL.buf.open")
local unl_path = require("UNL.path")
local logger = require("UNX.logger")

--- Open a diff between the file content at a commit and the current working copy.
--- Expects the node to have:
---   node.type == "file"
---   node.data.commit  -- the parent commit object (hash, vcs, _root, ...)
---   node.data.full_rel_path / node.data.path  -- path relative to vcs root
---   node.data.depot_path  -- (P4 only) full depot path
--- @param tree table nui.tree instance
function M.diff(tree)
    if not tree then return end
    local node = tree:get_node()
    if not node then return end

    if node.type ~= "file" then
        logger.get().warn("D: select a file node inside an expanded commit")
        return
    end

    local commit = node.data and node.data.commit
    if not commit or not commit.hash then
        logger.get().warn("D: no commit info on node. Expand a commit first.")
        return
    end

    -- Resolve absolute path to the local working copy
    local rel_path = node.data.full_rel_path or node.data.path or node.text
    local local_path
    if commit._root and commit._root ~= "" then
        local_path = unl_path.join(commit._root, rel_path)
    else
        local ctx = require("UNX.context.uproject").get()
        local_path = unl_path.join(ctx.project_root or vim.fn.getcwd(), rel_path)
    end

    local filename = vim.fn.fnamemodify(rel_path, ":t")
    local hash_short = commit.hash:sub(1, 8)
    local ctx = require("UNX.context.uproject").get()
    local cwd = ctx.project_root or vim.fn.getcwd()

    vcs.get_file_at_commit(cwd, commit, node.data, function(content)
        if not content then
            logger.get().warn("Could not retrieve file at " .. hash_short .. " — VCS command failed")
            return
        end

        vim.schedule(function()
            -- Open (or focus) the local working copy on the right
            local exists = vim.fn.filereadable(local_path) == 1
            if exists then
                unl_open.safe({
                    file_path = local_path,
                    open_cmd = "edit",
                    plugin_name = "UNX",
                })
            else
                -- File may have been deleted; open a scratch buffer instead
                vim.cmd("enew")
                vim.bo.buftype = "nofile"
                vim.bo.bufhidden = "wipe"
                vim.bo.swapfile = false
                vim.api.nvim_buf_set_name(0, "Working copy: " .. filename .. " (deleted)")
            end

            vim.cmd("diffthis")

            -- Open the historical content in a vertical split on the left
            vim.cmd("leftabove vnew")
            local buf = vim.api.nvim_get_current_buf()

            -- Normalise CRLF from VCS output
            content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
            local lines = vim.split(content, "\n", { plain = true })
            -- Remove trailing empty line that results from trailing newline
            if lines[#lines] == "" then table.remove(lines) end

            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.bo[buf].buftype = "nofile"
            vim.bo[buf].bufhidden = "wipe"
            vim.bo[buf].swapfile = false
            vim.bo[buf].modifiable = false

            local ft = vim.filetype.match({ filename = filename })
            if ft then vim.bo[buf].filetype = ft end

            vim.api.nvim_buf_set_name(buf, filename .. "@" .. hash_short)

            vim.cmd("diffthis")
            -- Leave focus on the historical (left) pane so user can navigate
        end)
    end)
end

return M
