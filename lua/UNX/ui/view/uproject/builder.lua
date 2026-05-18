-- lua/UNX/ui/view/uproject/builder.lua
local Tree = require("nui.tree")
local unl_api = require("UNL.api")
local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local unx_vcs = require("UNX.vcs")
local ctx_uproject = require("UNX.context.uproject")
local fuzzy = require("UNX.util.fuzzy")
local fs = require("vim.fs")

local PendingView = require("UNX.ui.view.uproject.pending")
local FavoritesView = require("UNX.ui.view.uproject.favorites")
local RecentView = require("UNX.ui.view.uproject.recent")

local M = {}

-- ======================================================
-- FS Scan Helpers
-- ======================================================

local IGNORED_DIRS = {
    [".git"] = true, [".vs"] = true, [".vscode"] = true, [".idea"] = true,
    ["Intermediate"] = true, ["Binaries"] = true, ["Saved"] = true,
    ["DerivedDataCache"] = true, ["Build"] = true,
}

local function is_ignored(name) return IGNORED_DIRS[name] == true end

local function directory_first_sorter(a, b)
    local at = a.type or ""
    local bt = b.type or ""
    if at == "directory" and bt ~= "directory" then return true
    elseif at ~= "directory" and bt == "directory" then return false
    else 
        local an = tostring(a.text or a.name or "")
        local bn = tostring(b.text or b.name or "")
        return an < bn
    end
end

function M.scan_directory(path, exclude_paths)
    if not path then return {} end
    exclude_paths = exclude_paths or {}
    local nodes = {}
    local handle = vim.loop.fs_scandir(path)
    if handle then
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            local full_path = fs.joinpath(path, name)
            local normalized = unl_path.normalize(full_path)
            if not name:match("^%.") and not is_ignored(name) and not exclude_paths[normalized] then
                local is_dir = (type == "directory")
                table.insert(nodes, Tree.Node({
                    text = name,
                    id = normalized,
                    path = full_path,
                    type = is_dir and "directory" or "file",
                    _has_children = is_dir,
                    extra = { uep_type = "fs" },
                }))
            end
        end
    end
    table.sort(nodes, directory_first_sorter)
    return nodes
end

-- ======================================================
-- Data Fetching
-- ======================================================

local function paths_to_tree_nodes(file_items, root_path)
    if not file_items or #file_items == 0 then return {} end
    local norm_root = unl_path.normalize(root_path)
    local root_len = #norm_root
    local dir_map = {}
    local root_nodes = {}

    local function get_or_create_dir(dir_path)
        local norm_dir = unl_path.normalize(dir_path)
        if norm_dir:lower() == norm_root:lower() or #norm_dir <= root_len then return nil end
        if dir_map[norm_dir] then return dir_map[norm_dir] end
        
        local parent_path = vim.fn.fnamemodify(dir_path, ":h")
        local dir_name = vim.fn.fnamemodify(dir_path, ":t")
        local node = Tree.Node({ text = dir_name, id = norm_dir, path = dir_path, type = "directory", _has_children = true })
        node:expand()
        local entry = { node = node, children = {} }
        dir_map[norm_dir] = entry
        local parent_entry = get_or_create_dir(parent_path)
        if parent_entry then table.insert(parent_entry.children, node) else table.insert(root_nodes, node) end
        return entry
    end

    for _, item in ipairs(file_items) do
        if item.type ~= "directory" then
            local path = item.path
            local norm_path = unl_path.normalize(path)
            local parent_path = vim.fn.fnamemodify(path, ":h")
            local parent_entry = get_or_create_dir(parent_path)
            local file_node = Tree.Node({ text = item.display or vim.fn.fnamemodify(path, ":t"), id = norm_path, path = path, type = "file", _has_children = false })
            if parent_entry then table.insert(parent_entry.children, file_node) else table.insert(root_nodes, file_node) end
        end
    end

    local function build_nui_hierarchy(nodes_list)
        local nui_list = {}
        table.sort(nodes_list, directory_first_sorter)
        for _, node_data in ipairs(nodes_list) do
            local children = nil
            if node_data.type == "directory" then
                -- node_data.id は正規化済みパスで dir_map のキーと一致する
                local entry = dir_map[node_data.id]
                if entry and #entry.children > 0 then children = build_nui_hierarchy(entry.children) end
            end
            local final_node = Tree.Node({ text = node_data.text, id = node_data.id, path = node_data.path, type = node_data.type, _has_children = (children ~= nil) }, children)
            if final_node:has_children() then final_node:expand() end
            table.insert(nui_list, final_node)
        end
        return nui_list
    end
    return build_nui_hierarchy(root_nodes)
end

function M.fetch_root_data(tree_instance, expanded_state, skip_vcs_refresh)
    local conf = require("UNX.config").get()
    local ctx = ctx_uproject.get()
    local project_info = unl_finder.project.find_project(vim.loop.cwd())
    if not project_info then return { Tree.Node({ text = "Not in an Unreal project.", kind = "Info", id = "error" }) } end

    -- コンテキスト更新
    ctx.project_root = project_info.root
    local engine_root = unl_finder.engine.find_engine_root(project_info.uproject, { engine_override_path = conf.engine_path })
    ctx.engine_root = engine_root
    ctx_uproject.set(ctx)

    -- Filtering view (Async)
    if ctx.filter_text and ctx.filter_text ~= "" then
        local filter = ctx.filter_text
        unl_api.db.search_files(filter, function(items)
            local nodes = {}
            table.insert(nodes, Tree.Node({ text = "Search: " .. ctx.filter_text .. " (Press / to clear)", id = "filter_header", type = "info" }))

            local fav_items = require("UNX.cache.favorites").load(project_info.root)
            local filtered_favs = {}
            for _, item in ipairs(fav_items) do
                if not item.is_folder and item.path then
                    -- ファイル名またはdisplay名のみでfuzzy match（フルパスは対象外）
                    local basename = vim.fn.fnamemodify(item.path, ":t")
                    local p_match = fuzzy.match(basename, filter)
                    local n_match = item.name and fuzzy.match(item.name, filter)
                    if p_match or n_match then table.insert(filtered_favs, item) end
                end
            end
            if #filtered_favs > 0 then
                local fav_children = {}
                for _, item in ipairs(filtered_favs) do
                    table.insert(fav_children, Tree.Node({ text = item.name or vim.fn.fnamemodify(item.path, ":t"), id = "fav_" .. unl_path.normalize(item.path), path = item.path, type = "file", extra = { uep_type = "fs", is_favorite_item = true, project_root = project_info.root } }))
                end
                local fav_root = Tree.Node({ text = "Favorites (Filtered)", id = "root_favorites", type = "directory", _has_children = true, extra = { uep_type = FavoritesView.ROOT_TYPE, project_root = project_info.root } }, fav_children)
                fav_root:expand(); table.insert(nodes, fav_root)
            end

            local changes = unx_vcs.get_aggregated_changes()
            local filtered_changes = {}
            -- ファイル名（basename）のみでfuzzy match（フルパスはディレクトリ名が誤マッチするため使用しない）
            for _, item in ipairs(changes) do
                if fuzzy.match(vim.fn.fnamemodify(item.path, ":t"), filter) then
                    table.insert(filtered_changes, item)
                end
            end
            if #filtered_changes > 0 then
                local change_children = {}
                for _, item in ipairs(filtered_changes) do
                    table.insert(change_children, Tree.Node({ text = vim.fn.fnamemodify(item.path, ":t"), id = "pending_vcs_" .. unl_path.normalize(item.path), path = item.path, type = "file", extra = { uep_type = "fs", is_pending_item = true } }))
                end
                local pend_root = Tree.Node({ text = "Pending Changes (Filtered)", id = "root_pending_changes", type = "directory", _has_children = true, extra = { uep_type = PendingView.ROOT_TYPE_PENDING } }, change_children)
                pend_root:expand(); table.insert(nodes, pend_root)
            end

            if items then
                local filtered_items = {}
                local norm_proj_root = unl_path.normalize(project_info.root):lower()
                for _, item in ipairs(items) do
                    -- プロジェクトルート配下かつfuzzyマッチのみ表示する
                    local norm_item_path = unl_path.normalize(item.path):lower()
                    if vim.startswith(norm_item_path, norm_proj_root .. "/")
                        and fuzzy.match(item.filename or "", filter)
                    then
                        table.insert(filtered_items, { path = item.path, display = item.filename, type = "file" })
                    end
                end
                if #filtered_items > 0 then
                    local hierarchy_nodes = paths_to_tree_nodes(filtered_items, project_info.root)
                    local norm_root = unl_path.normalize(project_info.root)
                    local proj_root = Tree.Node({ 
                        text = vim.fn.fnamemodify(project_info.root, ":t") .. " (Results)", 
                        id = "search_results_" .. norm_root, 
                        path = project_info.root, 
                        type = "directory", 
                        _has_children = true, 
                        extra = { uep_type = "fs" } 
                    }, hierarchy_nodes)
                    proj_root:expand(); table.insert(nodes, proj_root)
                else table.insert(nodes, Tree.Node({ text = "No matching files in project.", kind = "Info", id = "no_match_main" })) end
            else table.insert(nodes, Tree.Node({ text = "Failed to fetch file list from Server.", kind = "Info", id = "error" })) end
            
            vim.schedule(function()
                local tree = tree_instance or require("UNX.ui.view.uproject").get_active_tree()
                if tree and vim.api.nvim_buf_is_valid(tree.bufnr) then
                    vim.api.nvim_buf_set_option(tree.bufnr, "modifiable", true)
                    tree:set_nodes(nodes)
                    tree:render()
                    vim.api.nvim_buf_set_option(tree.bufnr, "modifiable", false)
                end
            end)
        end)
        return { Tree.Node({ text = "Searching: " .. ctx.filter_text .. "...", id = "loading", type = "info" }) }
    end

    -- Logical Tree view (Pure Local FS Mode - Sync!)
    local nodes = {}
    local tree_mod = require("UNX.ui.view.uproject")
    local current_tree = tree_instance or tree_mod.get_active_tree()

    -- 常に最新の状態を Context に同期 (既存ツリーがあればそちらを優先)
    local is_fav_exp = (expanded_state["root_favorites"] ~= false)
    if current_tree then
        local f_node = current_tree:get_node("root_favorites")
        if f_node then is_fav_exp = f_node:is_expanded() end
    end
    ctx.is_favorites_expanded = is_fav_exp

    local fav_node = FavoritesView.create_root_node(is_fav_exp, project_info.root)
    if fav_node then table.insert(nodes, fav_node) end

    -- Recent Files
    local is_recent_exp = (expanded_state["root_recent_files"] ~= false)
    if current_tree then
        local r_node = current_tree:get_node("root_recent_files")
        if r_node then is_recent_exp = r_node:is_expanded() end
    end
    if conf.uproject and conf.uproject.show_recent ~= false then
        local recent_max = (conf.uproject.recent_max or 15)
        local recent_node = RecentView.create_root_node(is_recent_exp, project_info.root, recent_max)
        if recent_node then table.insert(nodes, recent_node) end
    end
    
    if not ctx.pending_states then ctx.pending_states = {} end
    ctx.pending_states[PendingView.ROOT_TYPE_PENDING] = (expanded_state["root_pending_changes"] ~= false)
    ctx.pending_states[PendingView.ROOT_TYPE_UNPUSHED] = (expanded_state["root_unpushed_commits"] ~= false)
    if current_tree then
        local p_node = current_tree:get_node("root_pending_changes")
        if p_node then ctx.pending_states[PendingView.ROOT_TYPE_PENDING] = p_node:is_expanded() end
        local u_node = current_tree:get_node("root_unpushed_commits")
        if u_node then ctx.pending_states[PendingView.ROOT_TYPE_UNPUSHED] = u_node:is_expanded() end
    end
    ctx_uproject.set(ctx)

    local pending_nodes = PendingView.create_root_nodes(ctx.pending_states)
    for _, p in ipairs(pending_nodes) do table.insert(nodes, p) end

    -- Game Root
    table.insert(nodes, Tree.Node({ 
        text = vim.fn.fnamemodify(project_info.root, ":t"), 
        id = unl_path.normalize(project_info.root), 
        path = project_info.root, 
        type = "directory", 
        _has_children = true, 
        extra = { uep_type = "root_game_fs" }
    }))

    -- Engine Root
    local engine_root = unl_finder.engine.find_engine_root(project_info.uproject, { engine_override_path = conf.engine_path })
    if engine_root then
        table.insert(nodes, Tree.Node({ 
            text = "Engine", 
            id = unl_path.normalize(engine_root), 
            path = engine_root, 
            type = "directory", 
            _has_children = true, 
            extra = { uep_type = "root_engine_fs" }
        }))
    end

    -- VCSリフレッシュ（非同期）
    if not skip_vcs_refresh then
        unx_vcs.refresh(project_info.root, function()
            vim.schedule(function()
                local tree = tree_mod.get_active_tree()
                if tree and vim.api.nvim_buf_is_valid(tree.bufnr) then
                    local current_nodes = M.fetch_root_data(tree, tree_mod.get_expanded_state(), true)
                    
                    vim.api.nvim_buf_set_option(tree.bufnr, "modifiable", true)
                    tree:set_nodes(current_nodes)
                    tree_mod.restore_expansion_explicit(tree)
                    tree:render()
                    vim.api.nvim_buf_set_option(tree.bufnr, "modifiable", false)
                end
            end)
        end)
    end

    return nodes
end

function M.lazy_load_children(tree_instance, parent_node)
    if parent_node:has_children() then return end
    local extra = parent_node.extra or {}
    
    if extra.uep_type == PendingView.ROOT_TYPE_PENDING or extra.uep_type == PendingView.ROOT_TYPE_UNPUSHED then
        local nui_children = PendingView.create_children_nodes(parent_node)
        tree_instance:set_nodes(nui_children, parent_node:get_id()); return
    end

    if extra.uep_type == FavoritesView.ROOT_TYPE then
        local nui_children = FavoritesView.create_children_nodes(extra.project_root)
        tree_instance:set_nodes(nui_children, parent_node:get_id()); return
    end

    if extra.uep_type == RecentView.ROOT_TYPE then
        local conf = require("UNX.config").get()
        local max_count = extra.max_count or (conf.uproject and conf.uproject.recent_max) or 15
        local nui_children = RecentView.create_children_nodes(extra.project_root, max_count)
        tree_instance:set_nodes(nui_children, parent_node:get_id()); return
    end

    if extra.uep_type == "root_engine_fs" then
        local root = parent_node.path
        local target_root = fs.joinpath(root, "Engine")
        if vim.fn.isdirectory(target_root) == 0 then target_root = root end
        local children = M.scan_directory(target_root)
        tree_instance:set_nodes(children, parent_node:get_id()); return
    end

    if parent_node.path then
        local exclude = {}
        local ctx = ctx_uproject.get()
        if ctx.project_root and ctx.engine_root then
             local p_norm = unl_path.normalize(parent_node.path)
             local e_norm = unl_path.normalize(ctx.engine_root)
             if (p_norm == e_norm) or (vim.startswith(p_norm, e_norm .. "/")) then exclude[unl_path.normalize(ctx.project_root)] = true end
        end
        local children = M.scan_directory(parent_node.path, exclude)
        tree_instance:set_nodes(children, parent_node:get_id())
    end
end

return M
