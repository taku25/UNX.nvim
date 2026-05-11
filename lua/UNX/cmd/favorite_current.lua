-- lua/UNX/cmd/favorite_current.lua
local favorites_cache = require("UNX.cache.favorites")
local unl_path = require("UNL.path")
local unl_finder = require("UNL.finder")
local unl_picker = require("UNL.picker")
local unx_config = require("UNX.config")

local M = {}

function M.execute()
    local buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(buf)
    
    if not path or path == "" then
        vim.notify("[UNX] Cannot add this buffer (no name) to Favorites.", vim.log.levels.WARN)
        return
    end
    
    path = unl_path.normalize(path)

    -- ファイルの実在チェック
    if vim.fn.filereadable(path) == 0 then
         vim.notify("[UNX] File does not exist on disk. Please save it first.", vim.log.levels.WARN)
         return
    end

    local ctx = require("UNX.context.uproject").get()
    local project_root = ctx.project_root or unl_finder.project.find_project_root(path)
    
    -- Check if already a favorite (for direct removal)
    local favorites = favorites_cache.load(project_root)
    local is_already_fav = false
    local norm_path = unl_path.normalize(path)
    for _, item in ipairs(favorites) do
        if not item.is_folder and unl_path.normalize(item.path) == norm_path then
            is_already_fav = true
            break
        end
    end

    local function refresh_ui()
        local ok_exp, explorer = pcall(require, "UNX.ui.explorer")
        if ok_exp and explorer.is_open() then
            explorer.refresh()
        end
    end

    if is_already_fav then
        local _, msg = favorites_cache.toggle(path, project_root)
        vim.notify(string.format("[UNX] ☆ %s: %s", msg, vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)
        refresh_ui()
        return
    end

    -- Adding new favorite: check for folders
    local folders = favorites_cache.get_folders(project_root)
    if #folders <= 1 then
        -- Only "Default" exists, add directly
        local added, msg = favorites_cache.toggle(path, project_root, "Default")
        local icon = added and "★ " or "☆ "
        vim.notify(string.format("[UNX] %s%s: %s", icon, msg, vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)
        refresh_ui()
    else
        -- Use UNL picker to select folder
        local picker_items = {}
        for _, f in ipairs(folders) do
            table.insert(picker_items, { label = f, value = f })
        end

        unl_picker.open({
            kind = "unx_favorites_add_current_to_folder",
            title = "Add to Favorites folder",
            items = picker_items,
            conf = unx_config.get(),
            preview_enabled = false,
            on_submit = function(selection)
                if selection then
                    -- selection is the full folder path (e.g. "Root/B/A" or "Default")
                    local added, msg = favorites_cache.toggle(path, project_root, selection)
                    local icon = added and "★ " or "☆ "
                    vim.notify(string.format("[UNX] %s%s (%s): %s", icon, msg, selection, vim.fn.fnamemodify(path, ":t")), vim.log.levels.INFO)
                    refresh_ui()
                end
            end,
        })
    end
end

return M
