-- lua/UNX/ui/view/uproject.lua
local Tree = require("nui.tree")
local builder = require("UNX.ui.view.uproject.builder")
local renderer = require("UNX.ui.view.uproject.renderer")
local handler = require("UNX.ui.view.uproject.handler")
local ctx_uproject = require("UNX.context.uproject")
local cache = require("UNX.cache")
local unl_path = require("UNL.path")
local unl_finder = require("UNL.finder")
local PendingView = require("UNX.ui.view.uproject.pending")
local FavoritesView = require("UNX.ui.view.uproject.favorites")

local M = {}

local active_tree = nil
local render_timer = nil
local save_timer = nil
local expanded_state = {}
local selected_paths = {}  -- マルチセレクト: { [normalized_path] = true }

--- 選択操作専用: デバウンスなしで即時同期レンダリング
local function render_sync()
    if not active_tree or not vim.api.nvim_buf_is_valid(active_tree.bufnr) then return end
    vim.api.nvim_buf_set_option(active_tree.bufnr, "modifiable", true)
    active_tree:render()
    vim.api.nvim_buf_set_option(active_tree.bufnr, "modifiable", false)
end

local function schedule_render()
    if not active_tree or not vim.api.nvim_buf_is_valid(active_tree.bufnr) then return end
    if render_timer then render_timer:stop(); if not render_timer:is_closing() then render_timer:close() end render_timer = nil end
    render_timer = vim.loop.new_timer()
    render_timer:start(200, 0, vim.schedule_wrap(function()
        if render_timer then if not render_timer:is_closing() then render_timer:close() end render_timer = nil end
        if active_tree and vim.api.nvim_buf_is_valid(active_tree.bufnr) then
            vim.api.nvim_buf_set_option(active_tree.bufnr, "modifiable", true)
            active_tree:render()
            vim.api.nvim_buf_set_option(active_tree.bufnr, "modifiable", false)
        end
    end))
end

local function save_tree_state()
    if save_timer then save_timer:stop(); if not save_timer:is_closing() then save_timer:close() end end
    save_timer = vim.loop.new_timer()
    save_timer:start(500, 0, vim.schedule_wrap(function()
        if save_timer then if not save_timer:is_closing() then save_timer:close() end save_timer = nil end
        if active_tree and vim.api.nvim_buf_is_valid(active_tree.bufnr) then
            local ctx = ctx_uproject.get()
            if ctx.project_root then cache.write(handler.TREE_STATE_CACHE_ID, ctx.project_root, expanded_state) end
        end
    end))
end

function M.setup()
    handler.setup_autocmds(M, schedule_render)
end

function M.get_active_tree() return active_tree end
function M.get_expanded_state() return expanded_state end

-- --------------------------------------------------------------------------
-- マルチセレクト API
-- --------------------------------------------------------------------------

function M.get_selected_paths() return selected_paths end

function M.get_selected_list()
    local list = {}
    for path in pairs(selected_paths) do table.insert(list, path) end
    return list
end

function M.selected_count()
    local n = 0
    for _ in pairs(selected_paths) do n = n + 1 end
    return n
end

--- 指定パスの選択状態をトグルし、再描画する。追加なら true を返す。
function M.toggle_selected(path)
    if not path then return false end
    local norm = unl_path.normalize(path)
    if selected_paths[norm] then
        selected_paths[norm] = nil
    else
        selected_paths[norm] = true
    end
    renderer.set_selected_paths(selected_paths)
    render_sync()
    return selected_paths[norm] == true
end

--- 選択をすべて解除し、再描画する。
function M.clear_selected()
    for k in pairs(selected_paths) do selected_paths[k] = nil end
    renderer.set_selected_paths(selected_paths)
    render_sync()
end

function M.restore_expansion_explicit(tree)
    if tree and not vim.tbl_isempty(expanded_state) then
        handler.restore_expansion(tree, expanded_state, builder)
    end
end

function M.create(bufnr, winid)
    local ctx = ctx_uproject.get()
    
    -- 状態をクリア (プロジェクト切り替え時のため)
    for k in pairs(expanded_state) do expanded_state[k] = nil end
    for k in pairs(selected_paths) do selected_paths[k] = nil end
    renderer.set_selected_paths(selected_paths)
    
    -- 0. プロジェクトルートの検出とコンテキスト更新
    local project_info = unl_finder.project.find_project(vim.loop.cwd())
    if project_info then
        ctx.project_root = project_info.root
        ctx_uproject.set(ctx)
    end

    -- 1. キャッシュ読み込み
    if ctx.project_root then
        local loaded_state = cache.read(handler.TREE_STATE_CACHE_ID, ctx.project_root)
        if loaded_state then 
            for k, v in pairs(loaded_state) do expanded_state[k] = v end
        end
        -- デフォルトの開閉状態をセット (キャッシュがない場合のみ)
        local game_id = unl_path.normalize(ctx.project_root)
        if expanded_state[game_id] == nil then expanded_state[game_id] = true end
        if expanded_state["root_pending_changes"] == nil then expanded_state["root_pending_changes"] = true end
        if expanded_state["root_favorites"] == nil then expanded_state["root_favorites"] = true end
        if expanded_state["root_recent_files"] == nil then expanded_state["root_recent_files"] = true end
    end

    -- 2. ツリー作成 ( builder.fetch_root_data は同期的にノードを返す)
    active_tree = Tree({
        bufnr = bufnr,
        nodes = builder.fetch_root_data(nil, expanded_state),
        prepare_node = renderer.prepare_node,
    })

    -- 3. 確実に展開処理を実行
    M.restore_expansion_explicit(active_tree)
    active_tree:render()

    handler.apply_keymaps(bufnr, active_tree, require("UNX.config").get())
    return active_tree
end

function M.refresh(tree_instance)
    if not tree_instance or not vim.api.nvim_buf_is_valid(tree_instance.bufnr) then return end
    local new_nodes = builder.fetch_root_data(tree_instance, expanded_state)
    
    vim.api.nvim_buf_set_option(tree_instance.bufnr, "modifiable", true)
    tree_instance:set_nodes(new_nodes)
    M.restore_expansion_explicit(tree_instance)
    tree_instance:render()
    vim.api.nvim_buf_set_option(tree_instance.bufnr, "modifiable", false)
    
    active_tree = tree_instance
end

function M.on_node_action(tree_instance)
    handler.on_node_action(tree_instance, builder, expanded_state, save_tree_state)
end

function M.ensure_children_loaded(tree, node)
    if not node:has_children() then builder.lazy_load_children(tree, node) end
end

function M.set_expanded_state(node_id, is_expanded)
    expanded_state[node_id] = is_expanded and true or false
end

function M.cancel_async_tasks()
    if render_timer then render_timer:stop(); if not render_timer:is_closing() then render_timer:close() end render_timer = nil end
    if save_timer then save_timer:stop(); if not save_timer:is_closing() then save_timer:close() end save_timer = nil end
end

--- 現在開いているバッファのパスをレンダラーに伝える
function M.set_current_buf_path(path)
    renderer.set_current_path(path)
end

--- デバウンス付き再レンダリングをスケジュール（バッファ変更時の呼び出し用）
function M.request_render()
    schedule_render()
end

return M