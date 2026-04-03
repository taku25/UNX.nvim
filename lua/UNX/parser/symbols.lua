-- lua/UNX/parser/symbols.lua
local IDRegistry = require("UNX.common.id_registry")
local Tree = require("nui.tree")
local unl_api = require("UNL.api")
local unx_config = require("UNX.config")
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

-- 同じ名前のクラスデータをマージする
local function merge_symbols(symbols)
    local merged = {}
    local map = {}

    for _, item in ipairs(symbols) do
        local key = item.name
        if not map[key] then
            -- クローンを作成してマージのベースにする
            local clone = vim.deepcopy(item)
            map[key] = clone
            table.insert(merged, clone)
        else
            local base = map[key]
            -- fields のマージ
            if item.fields then
                base.fields = base.fields or {}
                for access, list in pairs(item.fields) do
                    base.fields[access] = base.fields[access] or {}
                    for _, f in ipairs(list) do table.insert(base.fields[access], f) end
                end
            end
            -- methods のマージ
            if item.methods then
                base.methods = base.methods or {}
                for access, list in pairs(item.methods) do
                    base.methods[access] = base.methods[access] or {}
                    for _, m in ipairs(list) do table.insert(base.methods[access], m) end
                end
            end
            -- enum_values のマージ
            if item.enum_values then
                base.enum_values = base.enum_values or {}
                for _, v in ipairs(item.enum_values) do table.insert(base.enum_values, v) end
            end
            -- 行番号はより小さい方（定義側）を優先
            if item.line and (not base.line or item.line < base.line) then
                base.line = item.line
                base.file_path = item.file_path
            end
        end
    end
    return merged
end

local function build_class_node(class_data, registry, render_seen_ids, is_current_class)
    local children = {}
    local file_hash = IDRegistry.get_file_hash(class_data.file_path)
    local class_base_id = string.format("%s_%s_%d", file_hash, class_data.name, class_data.line or 0)

    local conf = unx_config.get()
    local should_expand = conf.symbols and conf.symbols.expand_groups

    local function make_group_id(suffix)
        local raw = registry:get(class_base_id .. suffix)
        return safe_node_id(raw, render_seen_ids)
    end

    local function make_item_node(item)
        local kind = item.kind
        if item.access == "impl" then kind = "Implementation" end

        local item_file_hash = IDRegistry.get_file_hash(item.file_path or class_data.file_path)
        local raw = string.format("%s_%s_%d", item_file_hash, item.name, item.line or 0)
        local unique = safe_node_id(registry:get(raw), render_seen_ids)
        return Tree.Node({
            text = item.name,
            detail = item.detail,
            return_type = item.return_type,
            kind = kind,
            access = item.access,
            line = item.line,
            file_path = item.file_path or class_data.file_path,
            id = unique
        })
    end

    -- 1. Properties
    local prop_groups = {}
    for _, access in ipairs({"public", "protected", "private", "impl"}) do
        if class_data.fields and class_data.fields[access] and #class_data.fields[access] > 0 then
            local access_children = {}
            for _, f in ipairs(class_data.fields[access]) do
                table.insert(access_children, make_item_node(f))
            end
            table.sort(access_children, function(a, b) return (a.line or 0) < (b.line or 0) end)
            
            local group_node = Tree.Node({
                text = access,
                kind = "Access",
                id = make_group_id("_prop_group_" .. access),
                _has_children = true,
                loaded = true
            }, access_children)
            group_node:expand()
            table.insert(prop_groups, group_node)
        end
    end

    if #prop_groups > 0 then
        local node = Tree.Node({ 
            text = "Properties", 
            kind = "GroupFields", 
            id = make_group_id("_props"),
            _has_children = true,
            loaded = true
        }, prop_groups)
        if should_expand then node:expand() end
        table.insert(children, node)
    end

    -- 2. Functions
    local function_subgroups = {}

    -- 2a. definitions
    local def_groups = {}
    for _, access in ipairs({"public", "protected", "private"}) do
        if class_data.methods and class_data.methods[access] and #class_data.methods[access] > 0 then
            local access_children = {}
            local seen_names = {}
            for _, m in ipairs(class_data.methods[access]) do
                if not seen_names[m.name] then
                    table.insert(access_children, make_item_node(m))
                    seen_names[m.name] = true
                end
            end
            table.sort(access_children, function(a, b) return (a.line or 0) < (b.line or 0) end)

            local group_node = Tree.Node({
                text = access,
                kind = "Access",
                id = make_group_id("_func_group_" .. access),
                _has_children = true,
                loaded = true
            }, access_children)
            group_node:expand()
            table.insert(def_groups, group_node)
        end
    end

    if #def_groups > 0 then
        local def_node = Tree.Node({
            text = "definitions",
            kind = "GroupMethods",
            id = make_group_id("_func_defs"),
            _has_children = true,
            loaded = true
        }, def_groups)
        def_node:expand()
        table.insert(function_subgroups, def_node)
    end

    -- 2b. implementations
    local impl_items = {}
    if class_data.methods and class_data.methods["impl"] and #class_data.methods["impl"] > 0 then
        for _, m in ipairs(class_data.methods["impl"]) do
            table.insert(impl_items, make_item_node(m))
        end
        table.sort(impl_items, function(a, b) return (a.line or 0) < (b.line or 0) end)
        
        local impl_node = Tree.Node({
            text = "implementations",
            kind = "GroupMethods",
            id = make_group_id("_func_impls"),
            _has_children = true,
            loaded = true
        }, impl_items)
        impl_node:expand()
        table.insert(function_subgroups, impl_node)
    end

    if #function_subgroups > 0 then
        local node = Tree.Node({ 
            text = "Functions", 
            kind = "GroupMethods", 
            id = make_group_id("_funcs"),
            _has_children = true,
            loaded = true
        }, function_subgroups)
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
        loaded = true
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
            symbols = merge_symbols(symbols) -- ★追加: シンボルをマージ
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
    unl_api.provider.request("ucm.get_file_symbols", {
        file_path = file_path
    }, function(ok, symbols)
        local function process(data)
            if type(data) ~= "table" then data = {} end
            data = merge_symbols(data) -- ★追加: シンボルをマージ

            local registry = IDRegistry.new()
            local seen_ids = {}
            local nodes = {}

            for _, item in ipairs(data) do
                local k = (item.kind or ""):lower()
                if k:find("class") or k:find("struct") or k:find("enum") then
                    local node = build_class_node(item, registry, seen_ids, true)
                    table.insert(nodes, node)
                else
                    local id = safe_node_id(registry:get(item.name .. (item.line or 0)), seen_ids)
                    table.insert(nodes, Tree.Node({
                        text = item.name,
                        detail = item.detail,
                        return_type = item.return_type,
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
    unl_api.provider.request("ucm.get_file_symbols", { file_path = file_path }, function(ok, symbols)
        if ok and symbols and type(symbols) == "table" then
            symbols = merge_symbols(symbols) -- ★追加: シンボルをマージ
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
