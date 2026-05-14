-- lua/UNX/ui/view/symbols.lua
local Tree = require("nui.tree")
local Line = require("nui.line")
local IDRegistry = require("UNX.common.id_registry")
local logger = require("UNX.logger")
local unl_open = require("UNL.buf.open")
local unl_api = require("UNL.api")

local SymbolParser = require("UNX.parser.symbols")
local ctx_symbols = require("UNX.context.symbols")

local M = {}

local runtime_state = {
    ticks = {},
    tree_ref = nil,
    cancel_func = nil,
    ignore_next_update = false,
}

local debounce_timer = nil

-- (prepare_node 関数は変更なしのため省略...)
local function prepare_node(node)
    -- ... (前回のコードと同じ) ...
    local line = Line()
    line:append(string.rep("  ", node:get_depth() - 1))
    
    local icon, icon_hl, text_hl = " ", "Normal", "UNXFileName"
    
    if node.kind == "UClass" then icon = "UE "; icon_hl = "UNXVCSAdded"; text_hl = "Type"
    elseif node.kind == "UStruct" then icon = "US "; icon_hl = "UNXVCSAdded"; text_hl = "Type"
    elseif node.kind == "UEnum" then icon = "En "; icon_hl = "UNXVCSAdded"; text_hl = "Type"
    elseif node.kind == "Class" then icon = "󰌗 "; icon_hl = "Type"; text_hl = "Type"
    elseif node.kind == "Struct" then icon = "󰌗 "; icon_hl = "Type"; text_hl = "Type"
    
    elseif node.kind == "UFunction" then icon = "UF "; icon_hl = "UNXVCSModified"; text_hl = "UNXVCSFunction"
    elseif node.kind == "Function" then icon = "󰊕 "; icon_hl = "UNXVCSFunction"
    
    elseif node.kind == "Constructor" then icon = " "; icon_hl = "Special"
    elseif node.kind == "UProperty" then icon = "UP "; icon_hl = "UNXDirectoryIcon"
    elseif node.kind == "Field" then icon = " "; icon_hl = "Identifier"
    elseif node.kind == "Access" then icon = " "; icon_hl = "Special"; text_hl = "Special"
    elseif node.kind == "GroupFields" then icon = " "; icon_hl = "Special"; text_hl = "Title"
    elseif node.kind == "GroupMethods" then icon = "󰊕 "; icon_hl = "Special"; text_hl = "Title"
    elseif node.kind == "BaseClass" then icon = "󰜮 "; icon_hl = "UNXVCSRenamed"; text_hl = "Comment"
    elseif node.kind == "Implementation" then icon = " "; icon_hl = "Comment"; text_hl = "Comment"
    elseif node.kind == "Info" then icon = " "; icon_hl = "Comment"
    -- 階層ビュー専用 kinds
    elseif node.kind == "HierarchyRoot" then icon = "󰌗 "; icon_hl = "UNXVCSAdded"; text_hl = "Type"
    elseif node.kind == "HierarchyParent" then icon = "󰜮 "; icon_hl = "UNXVCSRenamed"; text_hl = "UNXVCSRenamed"
    elseif node.kind == "HierarchyChild" then icon = "󰍴 "; icon_hl = "UNXVCSAdded"; text_hl = "Normal"
    elseif node.kind == "HierarchySection" then icon = " "; icon_hl = "Comment"; text_hl = "Title"
    end
    
    local text = tostring(node.text or "Unknown"):gsub("[\r\n]+", " ")
    local detail = ""
    
    if node.kind == "Function" or node.kind == "UFunction" or node.kind == "Constructor" or node.kind == "Implementation" then
        -- 関数系: (パラメータ) : 戻り値
        if node.detail and node.detail ~= vim.NIL and node.detail ~= "" then
            detail = tostring(node.detail):gsub("[\r\n]+", " ")
        end
        if node.return_type and node.return_type ~= vim.NIL and node.return_type ~= "" then
            local rt_text = tostring(node.return_type):gsub("[\r\n]+", " ")
            if detail ~= "" then
                detail = detail .. ": " .. rt_text
            else
                detail = rt_text
            end
        end
    else
        -- プロパティ等: 型名のみ
        if node.return_type and node.return_type ~= vim.NIL and node.return_type ~= "" then
            detail = tostring(node.return_type):gsub("[\r\n]+", " ")
        elseif node.detail and node.detail ~= vim.NIL and node.detail ~= "" then
            detail = tostring(node.detail):gsub("[\r\n]+", " ")
        end
    end
    
    line:append(tostring(icon or " "), icon_hl or "Normal")
    line:append(text, text_hl or "Normal")
    
    if detail ~= "" then
        line:append("  " .. detail, "Comment")
    end

    if node.kind == "Access" then
        -- Accessノード自体のテキスト（public等）にハイライトを適用
    end

    return line
end

-- 階層ビューのノードを構築して返す
local UE_PREFIXES = { "U", "A", "I", "F", "T", "E", "S" }

--- ファイル名（接頭辞なし）からDBのクラス名（UE接頭辞付き）を解決する
local function resolve_class_name(filename, callback)
    -- まずそのままで親クラスを試す
    unl_api.db.get_inheritance_chain(filename, function(parents)
        if parents and #parents > 0 then
            callback(filename)
            return
        end
        -- 次に直接の子があるか試す
        local remote = require("UNL.db.remote")
        remote.find_derived_classes(filename, function(children)
            if children and #children > 0 then
                callback(filename)
                return
            end
            -- UEプレフィックスを順に試す
            local idx = 0
            local function try_next()
                idx = idx + 1
                if idx > #UE_PREFIXES then
                    callback(filename) -- 見つからなくてもオリジナルを返す
                    return
                end
                local candidate = UE_PREFIXES[idx] .. filename
                unl_api.db.get_inheritance_chain(candidate, function(p2)
                    if p2 and #p2 > 0 then
                        callback(candidate)
                    else
                        remote.find_derived_classes(candidate, function(r2)
                            if r2 and #r2 > 0 then
                                callback(candidate)
                            else
                                try_next()
                            end
                        end)
                    end
                end)
            end
            try_next()
        end)
    end)
end

local function build_hierarchy_nodes(class_name, callback)
    local Tree_node = require("nui.tree").Node

    -- クラス名を解決してからノード構築
    resolve_class_name(class_name, function(resolved_name)
        local root = Tree_node({ id = "hier_root", text = resolved_name, kind = "HierarchyRoot" })

        local pending = 2 -- 親チェーン + 子クラス の2クエリを待つ
        local parents_result = nil
        local children_result = nil

        local function try_finish()
            pending = pending - 1
            if pending > 0 then return end

            local all_nodes = { root }

            -- 親チェーンセクション
            if parents_result and #parents_result > 0 then
                local parent_nodes = {}
                for i, p in ipairs(parents_result) do
                    local n = Tree_node({
                        id = "hier_parent_" .. i,
                        text = p.name or p.class_name or p,
                        kind = "HierarchyParent",
                        file_path = p.path or p.file_path,
                        line = p.line or p.line_number,
                    })
                    table.insert(parent_nodes, n)
                end
                table.insert(all_nodes, Tree_node({ id = "hier_sec_parents", text = "Parents (" .. #parent_nodes .. ")", kind = "HierarchySection" }, parent_nodes))
            end

            -- 子クラスセクション
            if children_result then
                local child_nodes = {}
                for i, c in ipairs(children_result) do
                    local cname = c.name or c.class_name
                    if cname and cname ~= "Scanning..." then
                        local n = Tree_node({
                            id = "hier_child_" .. i,
                            text = cname,
                            kind = "HierarchyChild",
                            file_path = c.path or c.file_path,
                            line = c.line or c.line_number,
                            symbol_type = c.symbol_type,
                        })
                        table.insert(child_nodes, n)
                    end
                end
                local label = "Derived Classes (" .. #child_nodes .. ")"
                if #child_nodes > 0 then
                    table.insert(all_nodes, Tree_node({ id = "hier_sec_children", text = label, kind = "HierarchySection" }, child_nodes))
                else
                    table.insert(all_nodes, Tree_node({ id = "hier_sec_children_empty", text = "Derived Classes (0)", kind = "HierarchySection" }))
                end
            end

            callback(all_nodes)
        end

        -- 親クラスチェーンを取得
        unl_api.db.get_inheritance_chain(resolved_name, function(result)
            parents_result = result or {}
            try_finish()
        end)

        -- 派生クラスを取得（直接の子のみ = FindDerivedClasses）
        local remote = require("UNL.db.remote")
        remote.find_derived_classes(resolved_name, function(result)
            children_result = result or {}
            try_finish()
        end)
    end)
end

function M.setup() end

-- ★追加: トグル機能
function M.toggle_parents()
    local state = ctx_symbols.get()
    state.show_parents = not state.show_parents
    ctx_symbols.set(state)
    
    local msg = state.show_parents and "Parents: ON (Detailed/Slow)" or "Parents: OFF (Fast)"
    logger.get().info(msg)
    
    if runtime_state.tree_ref then
        M.update(runtime_state.tree_ref, nil, { force = true })
    end
end

-- ★追加: クラス階層ビュートグル
function M.toggle_hierarchy()
    local state = ctx_symbols.get()
    state.show_hierarchy = not state.show_hierarchy
    ctx_symbols.set(state)
    local msg = state.show_hierarchy and "Hierarchy: ON" or "Hierarchy: OFF (Symbols)"
    logger.get().info(msg)
    if runtime_state.tree_ref then
        M.update(runtime_state.tree_ref, nil, { force = true })
    end
end

function M.create(bufnr)
    local conf = require("UNX.config").get()
    local toggle_key = conf.keymaps.action_toggle_parents or "p"
    local hierarchy_key = conf.keymaps.action_toggle_hierarchy or "H"

    local map_opts = { buffer = bufnr, noremap = true, silent = true }
    
    if toggle_key and toggle_key ~= "" then
        vim.keymap.set("n", toggle_key, function() M.toggle_parents() end, map_opts)
    end
    if hierarchy_key and hierarchy_key ~= "" then
        vim.keymap.set("n", hierarchy_key, function() M.toggle_hierarchy() end, map_opts)
    end

    return Tree({ bufnr = bufnr, nodes = {}, prepare_node = prepare_node })
end

function M.update(tree_instance, target_winid, opts)
    if not tree_instance then return end
    opts = opts or {}
    
    local current_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[current_buf].filetype
    
    if ft == "neo-tree" or ft == "TelescopePrompt" or ft == "qf" then return end

    if debounce_timer then
        debounce_timer:stop()
        if not debounce_timer:is_closing() then debounce_timer:close() end
        debounce_timer = nil
    end

    debounce_timer = vim.loop.new_timer()
    debounce_timer:start(50, 0, vim.schedule_wrap(function()
        if debounce_timer then
            if not debounce_timer:is_closing() then debounce_timer:close() end
            debounce_timer = nil
        end
        
        local current_buf_delayed = vim.api.nvim_get_current_buf()
        local ft_delayed = vim.bo[current_buf_delayed].filetype

        if ft_delayed == "unx-explorer" then
            local state = ctx_symbols.get()
            if state.last_bufnr and vim.api.nvim_buf_is_valid(state.last_bufnr) then
                current_buf_delayed = state.last_bufnr
                ft_delayed = vim.bo[current_buf_delayed].filetype
            else
                return 
            end
        end

        if ft_delayed == "neo-tree" or ft_delayed == "TelescopePrompt" or ft_delayed == "qf" then return end

        local buf_name_delayed = vim.api.nvim_buf_get_name(current_buf_delayed)
        if buf_name_delayed == "" then return end
        
        local filename = vim.fn.fnamemodify(buf_name_delayed, ":t:r")
        if not filename or filename == "" then return end
        
        local current_tick = vim.api.nvim_buf_get_changedtick(current_buf_delayed)
        local state = ctx_symbols.get()
        local last_class_name = state.class_name
        local last_bufnr = state.last_bufnr

        if runtime_state.ignore_next_update then
            runtime_state.ignore_next_update = false
            state.last_bufnr = current_buf_delayed
            ctx_symbols.set(state)
            runtime_state.ticks[current_buf_delayed] = current_tick
            return
        end

        if last_class_name == filename and last_bufnr ~= current_buf_delayed and not opts.force then
            state.last_bufnr = current_buf_delayed
            ctx_symbols.set(state)
            runtime_state.ticks[current_buf_delayed] = current_tick
            return
        end

        if not opts.force and last_class_name == filename 
           and runtime_state.ticks[current_buf_delayed] == current_tick 
           and runtime_state.tree_ref == tree_instance then
            return
        end

        if runtime_state.cancel_func then
            runtime_state.cancel_func()
            runtime_state.cancel_func = nil
        end

        local is_cancelled = false
        runtime_state.cancel_func = function() is_cancelled = true end

        local function finish_update(nodes)
             if is_cancelled then return end
             
             if not nodes or #nodes == 0 then
                 logger.get().debug("No symbols generated.")
             end
             
             state.class_name = filename
             state.last_bufnr = current_buf_delayed
             ctx_symbols.set(state)
             
             runtime_state.tree_ref = tree_instance
             runtime_state.ticks[current_buf_delayed] = current_tick

             vim.schedule(function()
                 if is_cancelled then return end
                 if not tree_instance then return end
                 
                 tree_instance:set_nodes(nodes)
                 tree_instance:render()
                 
                 if target_winid and vim.api.nvim_win_is_valid(target_winid) then
                     local icon = "󰌗"
                     if ft_delayed == "cpp" then icon = "" elseif ft_delayed == "c" then icon = "" end
                     
                     local mode_icon
                     if state.show_hierarchy then
                         mode_icon = "󰀬"
                     elseif state.show_parents then
                         mode_icon = ""
                     else
                         mode_icon = ""
                     end
                     local bar_text = string.format("%%#UNXVCSFunction# %s %s %s", icon, filename, mode_icon)
                     
                     pcall(vim.api.nvim_win_set_option, target_winid, "winbar", bar_text)
                 end
                 
                 if ctx_symbols.get().class_name == filename then
                     runtime_state.cancel_func = nil
                 end
             end)
        end

        -- 階層ビューモード
        if state.show_hierarchy then
            logger.get().debug("Building class hierarchy: " .. filename)
            build_hierarchy_nodes(filename, finish_update)
        elseif state.show_parents then
            logger.get().debug("Parsing file symbols (Deep Context): " .. filename)
            unl_api.provider.request("uep.get_class_context", { 
                class_name = filename,
                on_complete = function(ctx_ok, context)
                    if is_cancelled then return end

                    if ctx_ok and context and context.current then
                        SymbolParser.build_from_context(context, finish_update)
                    else
                        SymbolParser.fetch_and_build(buf_name_delayed, finish_update)
                    end
                end
            })
        else
            logger.get().debug("Parsing file symbols (Fast): " .. filename)
            SymbolParser.fetch_and_build(buf_name_delayed, finish_update)
        end
    end))
end

function M.on_node_action(tree_instance, split_instance, other_split_instance)
    local node = tree_instance:get_node()
    if not node then return end
    
    -- 階層ビューのノード処理
    if node.kind == "HierarchySection" then
        if node:has_children() then
            if node:is_expanded() then node:collapse() else node:expand() end
            tree_instance:render()
        end
        return
    end

    if node.kind == "HierarchyRoot" then return end

    if (node.kind == "HierarchyParent" or node.kind == "HierarchyChild") and node.file_path then
        runtime_state.ignore_next_update = true
        unl_open.safe({
            file_path = node.file_path,
            open_cmd = "edit",
            plugin_name = "UNX",
            split_cmd = "vertical botright split",
        })
        if node.line and node.line > 0 then
            vim.api.nvim_win_set_cursor(0, { node.line, 0 })
            vim.cmd("normal! zz")
        end
        return
    end

    if node.kind == "Class" or node.kind == "UClass" or node.kind == "Struct" or node.kind == "UStruct" then
        return
    end

    if node.kind == "BaseClass" and node.lazy_load then
        if node:is_expanded() then
            node:collapse()
            tree_instance:render()
        else
            if not node:has_children() then
                 logger.get().debug("Lazy loading base class: " .. node.text)
                 
                 SymbolParser.parse_and_get_children(node.file_path, node.text, function(children)
                     if children and #children > 0 then
                         tree_instance:set_nodes(children, node:get_id())
                         node.lazy_load = false
                     else
                         logger.get().warn("No symbols found in base class.")
                     end
                     node:expand()
                     tree_instance:render()
                 end)
            else
                 node:expand()
                 tree_instance:render()
            end
        end
        return
    end

    if node:has_children() then
        if node:is_expanded() then node:collapse() else node:expand() end
        tree_instance:render()
    elseif node.line then
        if node.file_path then
             runtime_state.ignore_next_update = true
             unl_open.safe({
                file_path = node.file_path,
                open_cmd = "edit",
                plugin_name = "UNX",
                split_cmd = "vertical botright split",
            })
            vim.api.nvim_win_set_cursor(0, { node.line, 0 })
            vim.cmd("normal! zz")
        end
    end
end

return M
