-- lua/UNX/parser/symbols.lua
local IDRegistry = require("UNX.common.id_registry")
local Tree = require("nui.tree")
local unl_api = require("UNL.api")
local unx_config = require("UNX.config") -- ★追加: 設定読み込み
local M = {}

local function safe_node_id(id, seen_ids)
    if not id then return "unknown_" .. vim.loop.hrtime() end
    if not seen_ids[id] then
        seen_ids[id] = true
        return id
    else
        local count = 1
        local new_id = id .. "_dup" .. count
        while seen_ids[new_id] do
            count = count + 1
            new_id = id .. "_dup" .. count
        end
        seen_ids[new_id] = true
        return new_id
    end
end

local function build_class_node(class_data, registry, render_seen_ids, is_current_class)
    local children = {}
    local file_hash = IDRegistry.get_file_hash(class_data.file_path)
    local class_base_id = string.format("%s_%s_%d", file_hash, class_data.name, class_data.line)

    -- ★設定を取得
    local conf = unx_config.get()
    local should_expand = conf.symbols and conf.symbols.expand_groups

    local function make_group_id(suffix)
        local raw = registry:get(class_base_id .. suffix)
        return safe_node_id(raw, render_seen_ids)
    end

    local function make_item_node(item)
        local kind = item.kind
        -- 'impl' accessレベルの場合、種類を 'Implementation' に変更して見た目を分ける
        if item.access == "impl" then
            kind = "Implementation"
        end

        local raw = string.format("%s_%s_%d", file_hash, item.name, item.line)
        local unique = safe_node_id(registry:get(raw), render_seen_ids)
        return Tree.Node({
            text = item.name,
            detail = item.detail,
            kind = kind,
            line = item.line,
            file_path = item.file_path,
            id = unique
        })
    end

    -- 1. Properties (メンバー)
    local prop_children = {}
    for _, access in ipairs({"public", "protected", "private", "impl"}) do
        if class_data.fields and class_data.fields[access] then
            for _, f in ipairs(class_data.fields[access]) do
                table.insert(prop_children, make_item_node(f))
            end
        end
    end
    if #prop_children > 0 then
        table.sort(prop_children, function(a, b) return (a.line or 0) < (b.line or 0) end)
        local node = Tree.Node({ 
            text = "Properties", 
            kind = "GroupFields", 
            id = make_group_id("_props"),
            _has_children = true,
            loaded = true
        }, prop_children)
        if should_expand then node:expand() end
        table.insert(children, node)
    end

    -- 2. Functions (メソッド定義)
    local func_children = {}
    for _, access in ipairs({"public", "protected", "private"}) do
        if class_data.methods and class_data.methods[access] then
            for _, m in ipairs(class_data.methods[access]) do
                table.insert(func_children, make_item_node(m))
            end
        end
    end
    if #func_children > 0 then
        table.sort(func_children, function(a, b) return (a.line or 0) < (b.line or 0) end)
        local node = Tree.Node({ 
            text = "Functions", 
            kind = "GroupMethods", 
            id = make_group_id("_funcs"),
            _has_children = true,
            loaded = true
        }, func_children)
        if should_expand then node:expand() end
        table.insert(children, node)
    end

    -- 3. Implementations (メソッド実装)
    local impl_children = {}
    if class_data.methods and class_data.methods["impl"] then
        for _, m in ipairs(class_data.methods["impl"]) do
            table.insert(impl_children, make_item_node(m))
        end
    end
    if #impl_children > 0 then
        table.sort(impl_children, function(a, b) return (a.line or 0) < (b.line or 0) end)
        local node = Tree.Node({ 
            text = "Implementations", 
            kind = "GroupMethods", 
            id = make_group_id("_impls"),
            _has_children = true,
            loaded = true
        }, impl_children)
        if should_expand then node:expand() end
        table.insert(children, node)
    end

    local node_id_raw = registry:get(class_base_id)
    if not is_current_class then node_id_raw = "base_" .. node_id_raw end
    
    local node = Tree.Node({
        text = class_data.name,
        kind = is_current_class and class_data.kind or "BaseClass",
        line = class_data.line,
        file_path = class_data.file_path,
        id = safe_node_id(node_id_raw, render_seen_ids),
        _has_children = (#children > 0),
        loaded = true -- 子ノードを同期的に追加済み
    }, children)
    
    if is_current_class then
        node:expand()
    else
        node:collapse()
    end
    
    return node, children
end

function M.build_from_context(context, on_complete)
    local root_nodes = {}
    local registry = IDRegistry.new()
    local seen_ids = {}

    if context.parents then
        for i = #context.parents, 1, -1 do
            local p_info = context.parents[i]
            if p_info and p_info.header then
                local id = safe_node_id(registry:get("base_" .. p_info.name), seen_ids)
                local p_node = Tree.Node({
                    text = p_info.name,
                    kind = "BaseClass",
                    id = id,
                    file_path = p_info.header,
                    lazy_load = true,
                    _has_children = true 
                })
                p_node:collapse()
                table.insert(root_nodes, p_node)
            end
        end
    end

    local current_info = context.current
    
    local function process_symbols(symbols)
        if symbols then
            local found_main = false
            for _, item in ipairs(symbols) do
                if item.name == current_info.name then
                    local node = build_class_node(item, registry, seen_ids, true)
                    table.insert(root_nodes, node)
                    found_main = true
                end
            end
            
            if not found_main and #symbols > 0 then
                 for _, item in ipairs(symbols) do
                    local k = (item.kind or ""):lower()
                    if k:find("class") or k:find("struct") or k:find("enum") then
                        local node = build_class_node(item, registry, seen_ids, true)
                        table.insert(root_nodes, node)
                    end
                 end
            end
        end
        if on_complete then on_complete(root_nodes) end
    end

    local target_file = current_info and (current_info.header or current_info.cpp)
    if target_file then
        -- ★非同期に変更
        unl_api.provider.request("ucm.get_file_symbols", {
            file_path = target_file
        }, function(ok, res)
            if ok and res and type(res) == "table" then
                process_symbols(res)
            else
                if on_complete then on_complete(root_nodes) end
            end
        end)
    else
        if on_complete then on_complete(root_nodes) end
    end
end

function M.fetch_and_build(file_path, on_complete)
    -- ★非同期に変更
    unl_api.provider.request("ucm.get_file_symbols", {
        file_path = file_path
    }, function(ok, symbols)
        local function process(data)
            if type(data) ~= "table" then data = {} end

            local registry = IDRegistry.new()
            local seen_ids = {}
            local nodes = {}

            for _, item in ipairs(data) do
                local k = (item.kind or ""):lower()
                if k:find("class") or k:find("struct") or k:find("enum") then
                    local node = build_class_node(item, registry, seen_ids, true)
                    table.insert(nodes, node)
                else
                    local id = safe_node_id(registry:get(item.name .. item.line), seen_ids)
                    table.insert(nodes, Tree.Node({
                        text = item.name,
                        kind = item.kind,
                        line = item.line,
                        file_path = item.file_path,
                        id = id
                    }))
                end
            end
            if on_complete then on_complete(nodes) end
        end

        if ok and symbols and type(symbols) == "table" then
            process(symbols)
        else
            process({})
        end
    end)
end

function M.parse_and_get_children(file_path, class_name, on_complete)
    -- ★非同期に変更
    unl_api.provider.request("ucm.get_file_symbols", { file_path = file_path }, function(ok, symbols)
        if ok and symbols and type(symbols) == "table" then
            local registry = IDRegistry.new()
            local seen = {}
            
            for _, item in ipairs(symbols) do
                if item.name == class_name then
                    local _, children = build_class_node(item, registry, seen, true)
                    if on_complete then on_complete(children or {}) end
                    return
                end
            end
        end
        if on_complete then on_complete({}) end
    end)
end

return M
