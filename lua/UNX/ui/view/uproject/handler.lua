-- lua/UNX/ui/view/uproject/handler.lua
local unl_open = require("UNL.buf.open")
local unl_finder = require("UNL.finder")
local unx_vcs = require("UNX.vcs")
local ctx_uproject = require("UNX.context.uproject")
local cache = require("UNX.cache")
local file_actions = require("UNX.ui.view.action.files")
local diff_action = require("UNX.ui.view.action.diff")
local filter_action = require("UNX.ui.view.action.filter")
local preview_mod = require("UNX.ui.view.uproject.preview")
local history_mod = require("UNX.ui.view.uproject.history")
local logger = require("UNX.logger")

local PendingView = require("UNX.ui.view.uproject.pending")
local FavoritesView = require("UNX.ui.view.uproject.favorites")
local favorite_actions = require("UNX.ui.view.action.favorites")

local M = {}

M.TREE_STATE_CACHE_ID = "uproject_tree_state"

function M.setup_autocmds(view_mod, schedule_render_fn)
    vim.api.nvim_create_autocmd({ "VimLeave" }, {
        callback = function()
            local tree = view_mod.get_active_tree()
            local exp_state = view_mod.get_expanded_state()
            if tree and vim.api.nvim_buf_is_valid(tree.bufnr) then
                local ctx = ctx_uproject.get()
                if ctx.project_root then
                    cache.write(M.TREE_STATE_CACHE_ID, ctx.project_root, exp_state)
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "FocusGained", "DirChanged" }, {
        callback = function()
            local explorer_ui = require("UNX.ui.explorer")
            if not explorer_ui.is_open() then return end
            
            local tree = view_mod.get_active_tree()
            if not tree or not vim.api.nvim_buf_is_valid(tree.bufnr) then return end

            local current_project_root = unl_finder.project.find_project_root(vim.loop.cwd())
            if not current_project_root then return end

            unx_vcs.refresh(current_project_root, function()
                vim.schedule(function()
                    if explorer_ui.is_open() and tree and vim.api.nvim_buf_is_valid(tree.bufnr) then     
                        view_mod.refresh(tree)
                    end
                end)
            end)
        end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufModifiedSet", "WinResized", "VimResized" }, {     
        callback = function()
            if view_mod.get_active_tree() then schedule_render_fn() end
        end
    })
end

function M.apply_keymaps(bufnr, active_tree, conf)
    local map_opts = { buffer = bufnr, noremap = true, silent = true }
    local keys = conf.keymaps or {}

    local mappings = {
        action_add = file_actions.add,
        action_add_directory = file_actions.add_directory,
        action_delete = file_actions.delete,
        action_move = file_actions.move,
        action_rename = file_actions.rename,
        action_toggle_favorite = file_actions.toggle_favorite,
        action_add_favorite_folder = favorite_actions.add_folder,
        action_move_favorite = favorite_actions.move_item,
        action_move_favorite_another = favorite_actions.move_item,
        action_rename_favorite_folder = favorite_actions.rename_folder,
        action_remove_favorite_folder = favorite_actions.remove_folder,
        action_find_files = file_actions.find_files_recursive,
        action_force_refresh = file_actions.refresh,
        action_diff = diff_action.diff,
        action_open_in_ide = file_actions.open_in_ide,
    }

    for key_id, fn in pairs(mappings) do
        if keys[key_id] then
            vim.keymap.set("n", keys[key_id], function() fn(active_tree) end, map_opts)
        end
    end

    vim.keymap.set("n", "/", function() filter_action.start_filter(active_tree) end, map_opts)

    -- プレビュー: p キーでトグル、auto モードでは CursorMoved で自動表示
    if keys.action_preview_toggle then
        vim.keymap.set("n", keys.action_preview_toggle, function()
            local node = active_tree:get_node()
            if not node or not node.path then return end
            if node.type == "directory" then
                preview_mod.toggle_enabled()
                return
            end
            local anchor_win = vim.api.nvim_get_current_win()
            preview_mod.toggle(node.path, anchor_win)
        end, map_opts)
    end

    -- マルチセレクト: <Space> でトグル
    -- nowait = true でグローバルの <Space>X 系マッピング（treesitter等）との競合を防ぐ
    local select_map_opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }
    local view_uproject = require("UNX.ui.view.uproject")
    local multiselect_enabled = not conf.multiselect or conf.multiselect.enabled ~= false

    if multiselect_enabled and keys.action_select_toggle then
        vim.keymap.set("n", keys.action_select_toggle, function()
            local node = active_tree:get_node()
            if not node or not node.path or node.type == "directory" then return end
            local added = view_uproject.toggle_selected(node.path)
            local fname = vim.fn.fnamemodify(node.path, ":t")
            local sel_icon = (conf.icons and conf.icons.uproject and conf.icons.uproject.selected) or "●"
            local icon = added and sel_icon or "○"
            local n = view_uproject.selected_count()
            logger.get().info(icon .. " " .. fname .. (n > 0 and ("  [" .. n .. " selected]") or ""))
        end, select_map_opts)
    end

    -- 選択クリア: <Esc>（選択中のときのみ動作）
    if multiselect_enabled and keys.action_clear_selection then
        vim.keymap.set("n", keys.action_clear_selection, function()
            if view_uproject.selected_count() > 0 then
                view_uproject.clear_selected()
                logger.get().info("○ Selection cleared")
            end
        end, select_map_opts)
    end

    -- auto preview: CursorMoved でデバウンス表示
    if conf.preview and conf.preview.auto ~= false then
        vim.api.nvim_create_autocmd("CursorMoved", {
            buffer = bufnr,
            callback = function()
                -- 履歴に現在ノードを記録
                local node = active_tree:get_node()
                if node then history_mod.push(bufnr, node:get_id()) end

                if not preview_mod.is_enabled() then return end
                if not node or not node.path or node.type == "directory" then
                    preview_mod.close(); return
                end
                local anchor_win = vim.api.nvim_get_current_win()
                preview_mod.schedule_show(node.path, anchor_win)
            end,
        })
    end

    -- go back: <BS> で前のノードへ
    if keys.action_go_back then
        vim.keymap.set("n", keys.action_go_back, function()
            local current = active_tree:get_node()
            local current_id = current and current:get_id() or nil
            local prev_id = history_mod.pop(bufnr, current_id)
            if not prev_id then
                vim.notify("UNX: no navigation history.", vim.log.levels.INFO)
                return
            end
            -- ノードを検索してカーソルを移動
            local found_node = active_tree:get_node(prev_id)
            if found_node then
                active_tree:get_node(prev_id):select()
                active_tree:render()
            else
                vim.notify("UNX: previous node is no longer visible.", vim.log.levels.INFO)
            end
        end, map_opts)
    end

    -- UNX ウィンドウを離れたら常にプレビューを閉じる
    -- BufLeave は同一バッファへの移動では発火しないため WinLeave を使用
    -- auto モードの有無・手動 p トグルに関わらず登録する
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = bufnr,
        callback = function()
            preview_mod.close()
        end,
    })

    if keys.custom then
        for key, func in pairs(keys.custom) do
            vim.keymap.set("n", key, function()
                if type(func) == "function" then func(active_tree)
                elseif type(func) == "string" then vim.cmd(func) end
            end, map_opts)
        end
    end
end

function M.on_node_action(tree_instance, builder_mod, expanded_state, save_state_fn, open_cmd)
    local node = tree_instance:get_node()
    if not node then return end

    local node_id = node:get_id()

    if node:has_children() or node._has_children or node.type == "directory" then
        if node:is_expanded() then
            node:collapse()
            expanded_state[node_id] = false
        else
            if not node:has_children() then builder_mod.lazy_load_children(tree_instance, node) end
            node:expand()
            expanded_state[node_id] = true
            
            -- 子ノードの展開状態を復元
            local children = tree_instance:get_nodes(node_id)
            if children then
                M.restore_expansion(tree_instance, expanded_state, builder_mod, children)
            end
        end

        -- Contextへの同期
        local uep_type = node.extra and node.extra.uep_type
        local ctx = ctx_uproject.get()
        local is_exp = node:is_expanded()

        if uep_type == PendingView.ROOT_TYPE_PENDING or uep_type == PendingView.ROOT_TYPE_UNPUSHED then
            if not ctx.pending_states then ctx.pending_states = {} end
            ctx.pending_states[uep_type] = is_exp
            ctx_uproject.set(ctx)
        elseif uep_type == FavoritesView.ROOT_TYPE then
            ctx.is_favorites_expanded = is_exp
            ctx_uproject.set(ctx)
        end

        tree_instance:render()
        save_state_fn()
    else
        if node.path then
            unl_open.safe({ file_path = node.path, open_cmd = open_cmd or "edit", plugin_name = "UNX", split_cmd = "vertical botright split" })
        end
    end
end

function M.restore_expansion(tree, expanded_ids, builder_mod, nodes_list)
    local roots = nodes_list or tree:get_nodes()
    
    for _, node in ipairs(roots) do
        local is_folder = node:has_children() or node._has_children or node.type == "directory"
        if is_folder then
            local node_id = node:get_id()
            if expanded_ids[node_id] then
                -- 展開
                if not node:has_children() then 
                    builder_mod.lazy_load_children(tree, node) 
                end
                node:expand()
                
                local children = tree:get_nodes(node_id)
                if children and #children > 0 then
                    M.restore_expansion(tree, expanded_ids, builder_mod, children)
                end
            else
                -- キャッシュで明示的に閉じられている、または未踏の場合は閉じる
                node:collapse()
            end
        end
    end
end

return M
