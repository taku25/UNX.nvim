-- lua/UNX/ui/view/action/favorites.lua
local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local favorites_cache = require("UNX.cache.favorites")
local ctx_uproject = require("UNX.context.uproject")

local unl_picker = require("UNL.picker")
local unx_config = require("UNX.config")

local M = {}

function M.add_folder(tree)
    local node = tree:get_node()
    local parent_folder = nil
    if node and node.extra and node.extra.is_favorite_folder then
        parent_folder = node.text
    end

    local ctx = ctx_uproject.get()
    local project_root = ctx.project_root
    if not project_root then return end

    local title = parent_folder and ("[ New Folder under " .. parent_folder .. " ]") or "[ New Favorite Folder ]"

    local input = Input({
        position = "50%",
        size = { width = 40 },
        border = { style = "rounded", text = { top = title, top_align = "center" } },
        win_options = { winblend = 10, winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
    }, {
        prompt = " Name: ",
        default_value = "",
        on_close = function() end,
        on_submit = function(value)
            if value and value ~= "" then
                local success, err = favorites_cache.add_folder(value, project_root, parent_folder)
                if success then
                    vim.notify(string.format("Created favorite folder: %s", value), vim.log.levels.INFO)
                    -- ツリーをリフレッシュ
                    local explorer_ui = require("UNX.ui.explorer")
                    explorer_ui.refresh()
                else
                    vim.notify(err or "Failed to create folder", vim.log.levels.ERROR)
                end
            end
        end,
    })

    input:mount()
    input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
end

function M.move_item(tree)
    local ctx = ctx_uproject.get()
    local project_root = ctx.project_root
    if not project_root then return end

    local view_uproject = require("UNX.ui.view.uproject")
    local selected = view_uproject.get_selected_list()

    -- マルチセレクト: 選択中のアイテムをまとめて移動
    if #selected > 0 then
        local folders = favorites_cache.get_folders(project_root)
        local items = {}
        for _, f in ipairs(folders) do
            table.insert(items, { label = f, value = f })
        end

        unl_picker.open({
            kind = "unx_favorites_move",
            title = string.format("Move %d item(s) to folder", #selected),
            items = items,
            conf = unx_config.get(),
            preview_enabled = false,
            on_submit = function(selection)
                if selection then
                    local parts = vim.split(selection, "/", { plain = true })
                    local choice = parts[#parts]
                    for _, path in ipairs(selected) do
                        favorites_cache.move_to_folder(path, choice, project_root, false)
                    end
                    vim.notify(string.format("Moved %d item(s) to %s", #selected, choice), vim.log.levels.INFO)
                    view_uproject.clear_selected()
                    local explorer_ui = require("UNX.ui.explorer")
                    explorer_ui.refresh()
                end
            end,
        })
        return
    end

    -- シングル（既存ロジック）
    local node = tree:get_node()
    if not node or not node.extra or (not node.extra.is_favorite_item and not node.extra.is_favorite_folder) then
        return vim.notify("Select a favorite item or folder to move", vim.log.levels.WARN)
    end

    local folders = favorites_cache.get_folders(project_root)
    local items = {}
    for _, f in ipairs(folders) do
        -- 自分自身（フォルダの場合）には移動できない
        if not (node.extra.is_favorite_folder and f == node.text) then
            table.insert(items, { label = f, value = f })
        end
    end

    unl_picker.open({
        kind = "unx_favorites_move",
        title = string.format("Move '%s' to folder", node.text),
        items = items,
        conf = unx_config.get(),
        preview_enabled = false,
        on_submit = function(selection)
            if selection then
                local choice_path = selection
                local parts = vim.split(choice_path, "/", { plain = true })
                local choice = parts[#parts] -- 最後の名前を取得

                local target_id = node.extra.is_favorite_folder and node.text or node.path
                favorites_cache.move_to_folder(target_id, choice, project_root, node.extra.is_favorite_folder)
                vim.notify(string.format("Moved %s to %s", node.text, choice_path), vim.log.levels.INFO)
                local explorer_ui = require("UNX.ui.explorer")
                explorer_ui.refresh()
            end
        end,
    })
end

function M.remove_folder(tree)
    local node = tree:get_node()
    if not node or not node.extra or not node.extra.is_favorite_folder then
        return vim.notify("Select a favorite folder to remove", vim.log.levels.WARN)
    end

    local ctx = ctx_uproject.get()
    local project_root = ctx.project_root
    if not project_root then return end

    vim.ui.select({ "Yes", "No" }, {
        prompt = string.format("Remove folder '%s'? (Items will be moved to Default)", node.text),
    }, function(choice)
        if choice == "Yes" then
            favorites_cache.remove_folder(node.text, project_root)
            local explorer_ui = require("UNX.ui.explorer")
            explorer_ui.refresh()
        end
    end)
end

function M.rename_folder(tree)
    local node = tree:get_node()
    if not node or not node.extra or not node.extra.is_favorite_folder then
        return vim.notify("Select a favorite folder to rename", vim.log.levels.WARN)
    end
    if node.text == "Default" then
        return vim.notify("Cannot rename the Default folder", vim.log.levels.WARN)
    end

    local ctx = ctx_uproject.get()
    local project_root = ctx.project_root
    if not project_root then return end

    local input = Input({
        position = "50%",
        size = { width = 40 },
        border = { style = "rounded", text = { top = "[ Rename Favorite Folder ]", top_align = "center" } },
        win_options = { winblend = 10, winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
    }, {
        prompt = " New Name: ",
        default_value = node.text,
        on_close = function() end,
        on_submit = function(value)
            if value and value ~= "" and value ~= node.text then
                local success = favorites_cache.rename_folder(node.text, value, project_root)
                if success then
                    vim.notify(string.format("Renamed favorite folder: %s -> %s", node.text, value), vim.log.levels.INFO)
                    local explorer_ui = require("UNX.ui.explorer")
                    explorer_ui.refresh()
                end
            end
        end,
    })

    input:mount()
    input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
end

return M
