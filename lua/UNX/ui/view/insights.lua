-- lua/UNX/ui/view/insights.lua
local Tree = require("nui.tree")
local Line = require("nui.line")

-- ★追加: コンテキスト
local ctx_insights = require("UNX.context.insights")

local M = {}

-- ★変更: 状態管理の分離
-- Runtime State (再起動で消えてよい、または巨大すぎて保存に適さないデータ)
local runtime_state = {
    active_tree = nil,      -- Treeインスタンス
    trace_handle = nil,     -- ハンドルオブジェクト (関数などを含む可能性があるため保存しない)
    frame_events = nil,     -- イベントツリー (巨大なテーブルなので保存しない)
    frame_data_full = nil,  -- フルデータ
    is_expanded = {},       -- 展開状態 (UIの一時的な状態)
}

local function prepare_node(node)
    local conf = require("UNX.config").get() -- ★修正: 設定を動的に取得
    local line = Line()
    line:append(string.rep("  ", node:get_depth() - 1))
    
    -- 子を持つかどうか
    local has_children = node:has_children() or (node.children and #node.children > 0)
    
    local ui_config = conf.icons or {}
    local icon_config = ui_config.insights or {}
    
    local default_open = ""      
    local default_closed = ""    
    local default_group_hl = "UNXInsightsGroupIcon"
    local default_leaf_icon = "󰊕"
    local default_leaf_hl = "UNXInsightsLeafIcon"
    
    local icon = default_leaf_icon
    local icon_hl = default_leaf_hl
    local text_hl = default_leaf_hl

    if node.kind == "Frame" then
        -- Frameノード
        icon = "󰔐"
        icon_hl = "Title"
        text_hl = "Title"
    elseif has_children then
        -- グループノード
        icon_hl = default_group_hl
        text_hl = icon_hl
        
        if node:is_expanded() then
            icon = icon_config.group_icon_open or default_open
        else
            icon = icon_config.group_icon_closed or default_closed
        end
    else
        -- リーフノード
        icon = icon_config.leaf_icon or default_leaf_icon
        icon_hl = default_leaf_hl
        text_hl = icon_hl
    end
    
    line:append(icon .. " ", icon_hl)
    line:append(node.text, text_hl)

    if node.detail then
        line:append(" (" .. node.detail .. ")", "Comment")
    end

    return line
end

-- ULGのイベントツリーをNui Treeノードに変換
local function convert_events_to_nodes(events, parent_id)
    local nodes = {}
    
    for i, event in ipairs(events) do
        local duration_ms = (event.e - event.s) * 1000
        local base_id = string.format("%s_ev%d", parent_id, i)

        local children_nodes = nil
        local has_children = event.children and #event.children > 0
        
        if has_children then
            children_nodes = convert_events_to_nodes(event.children, base_id)
        end
        
        local kind = "Stat"
        if event.name and event.name:match("::Tick") then kind = "Frame" end
        
        local node = Tree.Node({
            text = event.name or "Unknown Event",
            kind = kind,
            detail = string.format("%.3fms", duration_ms),
            id = base_id
        }, children_nodes)
        
        -- 展開状態の復元
        if has_children and runtime_state.is_expanded[base_id] then
             node:expand()
        end
        
        table.insert(nodes, node)
    end
    
    return nodes
end

function M.setup()
end

function M.create(bufnr)
    local tree = Tree({
        bufnr = bufnr,
        nodes = {}, 
        prepare_node = prepare_node,
    })
    runtime_state.active_tree = tree
    return tree
end

function M.set_data(trace_handle, frame_data)
    -- ★変更: Runtime Stateの更新
    runtime_state.trace_handle = trace_handle
    runtime_state.frame_data_full = frame_data
    runtime_state.frame_events = frame_data.events_tree
    
    -- ★変更: Context (永続データ) の更新
    -- ここでは「今どのフレームを見ているか」の情報だけ保存する
    local ctx = ctx_insights.get()
    ctx.trace_handle_id = (type(trace_handle) == "table" and trace_handle.id) or nil
    ctx.frame_number = frame_data.frame_number
    ctx.frame_summary = {
        duration_ms = frame_data.duration_ms,
        frame_start_time = frame_data.frame_start_time
    }
    ctx_insights.set(ctx)
    
    -- 再描画
    if runtime_state.active_tree then
        M.render(runtime_state.active_tree)
    end
end

function M.render(tree_instance)
    if tree_instance and runtime_state.frame_data_full and runtime_state.frame_events then
        local root_id = string.format("frame_%d", runtime_state.frame_data_full.frame_number)
        
        -- ULGイベントツリーをNui Treeノードに変換
        local nodes = convert_events_to_nodes(runtime_state.frame_events, root_id)
        
        -- ルートノード
        local root_text = string.format("Frame %d: %.3fms", runtime_state.frame_data_full.frame_number, runtime_state.frame_data_full.duration_ms)
        local frame_node = Tree.Node({
            text = root_text,
            kind = "Frame",
            detail = string.format("Start: %.3fs", runtime_state.frame_data_full.frame_start_time),
            id = root_id
        }, nodes)
        
        frame_node:expand()
        
        tree_instance:set_nodes({ frame_node })
        tree_instance:render()
    end
end

function M.on_node_action(tree_instance, split_instance, other_split_instance)
    local node = tree_instance:get_node()
    if not node then return end
    
    if node:has_children() then
        if node:is_expanded() then node:collapse() else node:expand() end
        
        -- 展開状態を Runtime State に保存
        runtime_state.is_expanded[node.id] = node:is_expanded()
        
        tree_instance:render()
    elseif node.kind ~= "Frame" then
        -- ジャンプ処理 (将来実装)
    end
end

return M
