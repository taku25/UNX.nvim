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
    
    elseif node.kind == "Constructor" then icon = " "; icon_hl = "Special"
    elseif node.kind == "UProperty" then icon = "UP "; icon_hl = "UNXDirectoryIcon"
    elseif node.kind == "Field" then icon = " "; icon_hl = "Identifier"
    elseif node.kind == "Access" then icon = " "; icon_hl = "Special"; text_hl = "Special"
    elseif node.kind == "GroupFields" then icon = " "; icon_hl = "Special"; text_hl = "Title"
    elseif node.kind == "GroupMethods" then icon = "󰊕 "; icon_hl = "Special"; text_hl = "Title"
    elseif node.kind == "BaseClass" then icon = "󰜮 "; icon_hl = "UNXVCSRenamed"; text_hl = "Comment"
    elseif node.kind == "Implementation" then icon = " "; icon_hl = "Comment"; text_hl = "Comment"
    elseif node.kind == "Info" then icon = " "; icon_hl = "Comment"
    end
    
    local text = tostring(node.text or "Unknown"):gsub("[\r\n]+", " ")
    local detail = ""
    if node.detail and node.detail ~= vim.NIL then
        detail = tostring(node.detail):gsub("[\r\n]+", " ")
    end
    
    line:append(tostring(icon or " "), icon_hl or "Normal")
    line:append(text, text_hl or "Normal")
    
    if detail ~= "" then
        line:append(" " .. detail, "Comment") -- 前にスペースを追加して見やすく
    end

    -- ★修正: 属性情報の表示 (Accessグループノード以外では表示しない、またはEnumを考慮)
    -- node.kind が "Access" の場合は、そのノード自体が public/private などを表す
    if node.kind == "Access" then
        -- Accessノード自体のテキスト（public等）にハイライトを適用
        -- prepare_nodeの冒頭で既にappendされているため、ここでは追加の装飾のみ
    end

    return line
end

function M.setup() end

-- ★追加: トグル機能
function M.toggle_parents()
    local state = ctx_symbols.get()
    state.show_parents = not state.show_parents
    ctx_symbols.set(state)
    
    local msg = state.show_parents and "Parents: ON (Detailed/Slow)" or "Parents: OFF (Fast)"
    -- vim.notify (msg, vim.log.levels.INFO)
    logger.get().info(msg)
    
    -- 強制リフレッシュ
    if runtime_state.tree_ref then
        M.update(runtime_state.tree_ref, nil, { force = true })
    end
end

function M.create(bufnr)
    -- ★修正: 設定からキーを取得して割り当て
    local conf = require("UNX.config").get()
    local toggle_key = conf.keymaps.action_toggle_parents or "p"

    local map_opts = { buffer = bufnr, noremap = true, silent = true }
    
    if toggle_key and toggle_key ~= "" then
        vim.keymap.set("n", toggle_key, function() M.toggle_parents() end, map_opts)
    end

    return Tree({ bufnr = bufnr, nodes = {}, prepare_node = prepare_node })
end

function M.update(tree_instance, target_winid, opts)
    if not tree_instance then return end
    opts = opts or {}
    
    -- タイマー開始前の即時チェックでも、Symbolsビュー自体なら弾かないように修正
    local current_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[current_buf].filetype
    
    -- 除外リスト（unx-explorer はここでは弾かず、内部で処理する）
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

        -- ★修正: Symbolsビューにフォーカスがある場合、前回のバッファをターゲットにする
        if ft_delayed == "unx-explorer" then
            local state = ctx_symbols.get()
            if state.last_bufnr and vim.api.nvim_buf_is_valid(state.last_bufnr) then
                current_buf_delayed = state.last_bufnr
                ft_delayed = vim.bo[current_buf_delayed].filetype
            else
                -- 前回のバッファが見つからなければ何もしない
                return 
            end
        end

        -- 改めて除外ファイルのチェック
        if ft_delayed == "neo-tree" or ft_delayed == "TelescopePrompt" or ft_delayed == "qf" then return end

        local buf_name_delayed = vim.api.nvim_buf_get_name(current_buf_delayed)
        if buf_name_delayed == "" then return end
        
        local filename = vim.fn.fnamemodify(buf_name_delayed, ":t:r")
        if not filename or filename == "" then return end
        
        local current_tick = vim.api.nvim_buf_get_changedtick(current_buf_delayed)
        local state = ctx_symbols.get()
        local last_class_name = state.class_name
        local last_bufnr = state.last_bufnr

        -- 強制更新フラグ(force)がある場合はチェックをスキップ
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
                 
                 -- WinBarの更新 (target_winid が指定されている場合のみ)
                 if target_winid and vim.api.nvim_win_is_valid(target_winid) then
                     local icon = "󰌗"
                     if ft_delayed == "cpp" then icon = "" elseif ft_delayed == "c" then icon = "" end
                     
                     local mode_icon = state.show_parents and "" or ""
                     local bar_text = string.format("%%#UNXVCSFunction# %s %s %s", icon, filename, mode_icon)
                     
                     pcall(vim.api.nvim_win_set_option, target_winid, "winbar", bar_text)
                 end
                 
                 if ctx_symbols.get().class_name == filename then
                     runtime_state.cancel_func = nil
                 end
             end)
        end

        if state.show_parents then
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
                 
                 -- ★非同期に変更
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
