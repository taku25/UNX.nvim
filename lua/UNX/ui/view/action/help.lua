-- lua/UNX/ui/view/action/help.lua
-- UNX キーマップヘルプをフローティングウィンドウで表示する

local M = {}

local KEY_DEFS = {
    { section = "Navigation" },
    { key_conf = "open",                  fallback = "<CR> / o",  desc = "Open file" },
    { key_conf = "vsplit",                fallback = "s",         desc = "Open in vertical split" },
    { key_conf = "split",                 fallback = "i",         desc = "Open in horizontal split" },
    { key_conf = "close",                 fallback = "q",         desc = "Close explorer" },
    { key_literal = "<Tab>",                                          desc = "Switch tab" },
    { key_literal = "/",                                              desc = "Filter files" },
    { key_conf = "action_help",           fallback = "g?",           desc = "Show this help" },

    { section = "File Operations" },
    { key_conf = "action_add",            fallback = "a",         desc = "New class (UCM)" },
    { key_conf = "action_add_directory",  fallback = "A",         desc = "New directory" },
    { key_conf = "action_delete",         fallback = "d",         desc = "Delete file/directory" },
    { key_conf = "action_rename",         fallback = "r",         desc = "Rename" },
    { key_conf = "action_move",           fallback = "m",         desc = "Move" },
    { key_conf = "action_find_files",     fallback = "f",         desc = "Find files (recursive)" },
    { key_conf = "action_open_in_ide",    fallback = "<C-o>",     desc = "Open in IDE" },

    { section = "Selection & Favorites" },
    { key_conf = "action_select_toggle",  fallback = "<Space>",   desc = "Multi-select toggle" },
    { key_conf = "action_clear_selection",fallback = "<Esc>",     desc = "Clear selection" },
    { key_conf = "action_toggle_favorite",fallback = "b",         desc = "Toggle favorite" },
    { key_conf = "action_add_favorite_folder", fallback = "N",    desc = "New favorite folder" },
    { key_conf = "action_move_favorite",  fallback = "m",         desc = "Move favorite item" },
    { key_conf = "action_remove_favorite_folder", fallback = "<C-d>", desc = "Remove favorite folder" },

    { section = "View & VCS" },
    { key_conf = "action_preview_toggle", fallback = "p",         desc = "Toggle preview" },
    { key_conf = "action_force_refresh",  fallback = "R",         desc = "Force refresh" },
    { key_conf = "action_diff",           fallback = "D",         desc = "Diff file vs VCS (uproject tab)" },
    { key_conf = "action_commit_diff",    fallback = "D",         desc = "Diff file at commit (VCS tab)" },
}

local function key_str(def, keys)
    if def.key_literal then
        return def.key_literal
    elseif def.key_conf then
        local v = keys[def.key_conf]
        if type(v) == "table" then
            return table.concat(v, " / ")
        elseif v then
            return tostring(v)
        end
    end
    return def.fallback or ""
end

function M.show()
    local conf = require("UNX.config").get()
    local keys = conf.keymaps or {}

    -- Build lines
    local lines = {}
    local max_key_w = 0
    local items = {}  -- { key_s, desc } or { section }

    for _, def in ipairs(KEY_DEFS) do
        if def.section then
            table.insert(items, { section = def.section })
        else
            local ks = key_str(def, keys)
            if #ks > max_key_w then max_key_w = #ks end
            table.insert(items, { key_s = ks, desc = def.desc })
        end
    end

    local col_w = math.max(max_key_w, 6)
    local border_inner = col_w + 3 + 30  -- key + " → " + desc
    local width = math.max(border_inner + 4, 52)

    table.insert(lines, "")
    for _, item in ipairs(items) do
        if item.section then
            table.insert(lines, "  ── " .. item.section .. " " .. string.rep("─", math.max(0, width - #item.section - 9)))
        else
            local pad = string.rep(" ", col_w - #item.key_s)
            table.insert(lines, string.format("  %s%s  →  %s", item.key_s, pad, item.desc))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "  Press q / <Esc> / g? to close")
    table.insert(lines, "")

    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "unx-help"

    local win = vim.api.nvim_open_win(buf, true, {
        relative  = "editor",
        row       = row,
        col       = col,
        width     = width,
        height    = height,
        style     = "minimal",
        border    = "rounded",
        title     = " UNX.nvim Keymaps ",
        title_pos = "center",
        focusable = true,
        zindex    = 60,
    })

    vim.wo[win].wrap         = false
    vim.wo[win].cursorline   = false
    vim.wo[win].number       = false
    vim.wo[win].signcolumn   = "no"

    local function close_win()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end

    local help_key = keys.action_help or "g?"
    for _, k in ipairs({ "q", "<Esc>", help_key, "<CR>" }) do
        vim.keymap.set("n", k, close_win, { buffer = buf, noremap = true, silent = true })
    end

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer   = buf,
        once     = true,
        callback = function() vim.schedule(close_win) end,
    })
end

return M
