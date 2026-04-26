-- lua/UNX/ui/explorer.lua
local Tree = require("nui.tree")
local Line = require("nui.line")
local ViewUproject = require("UNX.ui.view.uproject")
local ViewSymbols  = require("UNX.ui.view.symbols")
local ViewInsights = require("UNX.ui.view.insights")
local ViewConfig   = require("UNX.ui.view.config")
local ViewVCS      = require("UNX.ui.view.vcs")
local ViewHistory  = require("UNX.ui.view.vcs.history")
local ctx_explorer = require("UNX.context.explorer")
local logger_module = require("UNX.logger")

local M = {}

local TAB_CONFIG = {
    uproject = {
        order    = 1,
        display  = "uproject",
        view_mod = ViewUproject,
        sub_view = {
            view_mod = ViewSymbols,
        }
    },
    vcs = {
        order    = 2,
        display  = "vcs",
        view_mod = ViewVCS,
        sub_view = {
            view_mod = ViewHistory,
        }
    },
    config = {
        order    = 3,
        display  = "config",
        view_mod = ViewConfig,
    },
    insights = {
        order    = 4,
        display  = "insights",
        view_mod = ViewInsights,
    },
}

local TAB_ORDER = {}
for key, _ in pairs(TAB_CONFIG) do table.insert(TAB_ORDER, key) end
table.sort(TAB_ORDER, function(a, b) return TAB_CONFIG[a].order < TAB_CONFIG[b].order end)

local ui = {
    win_main = nil,
    win_sub  = nil,
    tabs = {},
}

for key, conf in pairs(TAB_CONFIG) do
    ui.tabs[key] = {
        buf = nil,
        tree = nil,
        sub = conf.sub_view and { buf = nil, tree = nil } or nil
    }
end

local ignore_win_close_event = false
local switch_layout
local handle_tab_switch_click

local function get_current_tab_key()
    local state = ctx_explorer.get()
    local key = state.current_tab
    if not key or not TAB_CONFIG[key] then return "uproject" end
    return key
end

local function set_current_tab_key(key)
    local state = ctx_explorer.get()
    state.current_tab = key
    ctx_explorer.set(state)
end

local function get_or_create_buffer(existing_buf, filetype)
    if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
        return existing_buf
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = filetype or "unx-explorer"
    vim.bo[buf].modifiable = false
    return buf
end

local function apply_window_options(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end
    local opts = {
        number = false, relativenumber = false, wrap = false,
        signcolumn = "no", foldcolumn = "0", list = false, spell = false, 
        winfixwidth = true
    }
    for k, v in pairs(opts) do vim.wo[winid][k] = v end
end

local function apply_buffer_keymaps(bufnr, tab_key, is_sub_view)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

    local opts = { noremap = true, silent = true, buffer = bufnr }

    vim.keymap.set("n", "<Tab>", function()
        local current = get_current_tab_key()
        local current_idx = 1
        for i, k in ipairs(TAB_ORDER) do
            if k == current then current_idx = i; break end
        end
        local next_idx = (current_idx % #TAB_ORDER) + 1
        switch_layout(TAB_ORDER[next_idx])
    end, opts)

    vim.keymap.set("n", "<LeftMouse>", function()
        local winid = vim.api.nvim_get_current_win()
        local mouse_line = vim.fn.getmousepos().line
        if mouse_line == 0 or mouse_line == 1 then
            handle_tab_switch_click(winid)
        end
    end, opts)
    
    local function do_action()
        local tab_state = ui.tabs[tab_key]
        if not tab_state then return end

        local target_tree = is_sub_view and (tab_state.sub and tab_state.sub.tree) or tab_state.tree
        local view_mod = is_sub_view and TAB_CONFIG[tab_key].sub_view.view_mod or TAB_CONFIG[tab_key].view_mod

        if view_mod and view_mod.on_node_action and target_tree then
            view_mod.on_node_action(target_tree, nil, nil)
        end
    end

    vim.keymap.set("n", "<2-LeftMouse>", function()
        local winid = vim.api.nvim_get_current_win()
        local mouse = vim.fn.getmousepos()
        if mouse.winid ~= winid or mouse.line <= 1 then return end
        vim.api.nvim_set_current_win(winid)
        pcall(vim.api.nvim_win_set_cursor, winid, {mouse.line, 0})
        do_action()
    end, opts)

    local conf = require("UNX.config").get()
    local keys = conf.keymaps.open or {"<CR>", "o"}
    for _, key in ipairs(keys) do
        vim.keymap.set("n", key, do_action, opts)
    end

    local close_keys = conf.keymaps.close or {"q"}
    for _, key in ipairs(close_keys) do
        vim.keymap.set("n", key, function() M.close() end, opts)
    end

    -- vsplit / split open
    local function make_split_action(split_fn_name)
        return function()
            local tab_state = ui.tabs[tab_key]
            if not tab_state then return end
            local target_tree = is_sub_view and (tab_state.sub and tab_state.sub.tree) or tab_state.tree
            local view_mod = is_sub_view and TAB_CONFIG[tab_key].sub_view and TAB_CONFIG[tab_key].sub_view.view_mod
                          or TAB_CONFIG[tab_key].view_mod
            if not view_mod or not target_tree then return end
            if type(view_mod[split_fn_name]) == "function" then
                view_mod[split_fn_name](target_tree)
            elseif type(view_mod.on_node_action) == "function" then
                view_mod.on_node_action(target_tree, nil, nil)
            end
        end
    end

    local vsplit_key = conf.keymaps.vsplit
    if vsplit_key then
        vim.keymap.set("n", vsplit_key, make_split_action("on_node_vsplit"), opts)
    end
    local split_key = conf.keymaps.split
    if split_key then
        vim.keymap.set("n", split_key, make_split_action("on_node_split"), opts)
    end

    -- g? ヘルプ
    local help_key = conf.keymaps.action_help or "g?"
    vim.keymap.set("n", help_key, function()
        require("UNX.ui.view.action.help").show()
    end, opts)

    -- VCS タブ専用: D でコミット diff
    if tab_key == "vcs" then
        local commit_diff_key = conf.keymaps.action_commit_diff or "D"
        vim.keymap.set("n", commit_diff_key, function()
            local tab_state = ui.tabs[tab_key]
            if not tab_state then return end
            local target_tree = is_sub_view and (tab_state.sub and tab_state.sub.tree) or tab_state.tree
            if target_tree then
                require("UNX.ui.view.action.commit_diff").diff(target_tree)
            end
        end, opts)
    end
end

local function update_winbars()
    local current_key = get_current_tab_key()
    local hl_active   = "%#UNXTabActive#"
    local hl_inactive = "%#UNXTabInactive#"
    local hl_sep      = "%#UNXTabSeparator#"
    local text_sep    = " | "

    if ui.win_main and vim.api.nvim_win_is_valid(ui.win_main) then
        local parts = {}
        for i, key in ipairs(TAB_ORDER) do
            local conf = TAB_CONFIG[key]
            local hl = (current_key == key) and hl_active or hl_inactive
            table.insert(parts, hl .. " " .. conf.display)
            if i < #TAB_ORDER then
                table.insert(parts, hl_sep .. text_sep)
            end
        end
        pcall(vim.api.nvim_win_set_option, ui.win_main, "winbar", table.concat(parts))
    end

    if ui.win_sub and vim.api.nvim_win_is_valid(ui.win_sub) then
        local current_key = get_current_tab_key()
        if current_key == "vcs" then
            local sym_bar = "%#UNXVCSFunction#  Repository History"
            pcall(vim.api.nvim_win_set_option, ui.win_sub, "winbar", sym_bar)
        else
            local buf = vim.api.nvim_win_get_buf(ui.win_sub)
            local buf_name = vim.api.nvim_buf_get_name(buf)
            local filename = vim.fn.fnamemodify(buf_name, ":t:r")
            if vim.bo[buf].filetype == "unx-explorer" then
                filename = "Symbols"
            end
            local sym_bar = "%#UNXVCSFunction# 󰌗 Class/Function " .. filename
            pcall(vim.api.nvim_win_set_option, ui.win_sub, "winbar", sym_bar)
        end
    end
end

switch_layout = function(target_key)
    local current = get_current_tab_key()
    if current ~= target_key then
        set_current_tab_key(target_key)
    end

    if not ui.win_main or not vim.api.nvim_win_is_valid(ui.win_main) then return end

    local conf = TAB_CONFIG[target_key]
    local state = ui.tabs[target_key]
    
    if not conf or not state then return end

    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_win_set_buf(ui.win_main, state.buf)
    end

    if conf.sub_view then
        if not ui.win_sub or not vim.api.nvim_win_is_valid(ui.win_sub) then
            local current_win = vim.api.nvim_get_current_win()
            vim.api.nvim_set_current_win(ui.win_main)
            vim.cmd("belowright split")
            local height = math.floor(vim.api.nvim_win_get_height(ui.win_main) * 0.4)
            if height < 1 then height = 1 end
            vim.cmd("resize " .. height)
            ui.win_sub = vim.api.nvim_get_current_win()
            apply_window_options(ui.win_sub)
            vim.api.nvim_set_current_win(ui.win_main)
        end

        if ui.win_sub and vim.api.nvim_win_is_valid(ui.win_sub) then
            if state.sub and state.sub.buf then
                vim.api.nvim_win_set_buf(ui.win_sub, state.sub.buf)
                if target_key == "uproject" and vim.bo.filetype:match("cpp") then
                     ViewSymbols.update(state.sub.tree, ui.win_sub, { force = true })
                end
                -- For VCS tab, use 50/50 split
                if target_key == "vcs" then
                    local total = vim.api.nvim_win_get_height(ui.win_main) + vim.api.nvim_win_get_height(ui.win_sub)
                    local half = math.floor(total / 2)
                    vim.api.nvim_win_set_height(ui.win_sub, half)
                end
            end
        end
    else
        if ui.win_sub and vim.api.nvim_win_is_valid(ui.win_sub) then
            ignore_win_close_event = true
            pcall(vim.api.nvim_win_close, ui.win_sub, true)
            ignore_win_close_event = false
            ui.win_sub = nil
        end
        if conf.view_mod and conf.view_mod.render and state.tree then
            conf.view_mod.render(state.tree)
        end
    end

    update_winbars()
end

handle_tab_switch_click = function(winid)
    if winid ~= ui.win_main then return end
    local mouse = vim.fn.getmousepos()
    local col = mouse.wincol
    if not col then return end

    local strwidth = vim.fn.strdisplaywidth
    local current_width = 0
    local sep_w = strwidth(" | ")
    
    for _, key in ipairs(TAB_ORDER) do
        local conf = TAB_CONFIG[key]
        local tab_w = strwidth(" " .. conf.display)
        local start_col = current_width
        local end_col = current_width + tab_w
        
        if col >= start_col and col <= end_col then
            switch_layout(key)
            return
        end
        current_width = end_col + sep_w
    end
end

function M.setup(opts)
    opts = opts or {}
    for _, conf in pairs(TAB_CONFIG) do
        if conf.view_mod and conf.view_mod.setup then conf.view_mod.setup() end
        if conf.sub_view and conf.sub_view.view_mod and conf.sub_view.view_mod.setup then
            conf.sub_view.view_mod.setup()
        end
    end

    local unl_api_ok, unl_api = pcall(require, "UNL.api")
    if unl_api_ok then
        local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
        if unl_types_ok then
            local events = require("UNL.event.events")
            events.subscribe(unl_event_types.ON_REQUEST_TRACE_CALLEES_VIEW, function(payload)
                if not M.is_open() then M.open() end
                switch_layout("insights")
                local state = ui.tabs.insights
                if state and state.tree and payload and payload.frame_data then
                    ViewInsights.set_data(payload.trace_handle, payload.frame_data)
                end
            end)
            events.subscribe(unl_event_types.ON_REQUEST_UPROJECT_TREE_VIEW, function(payload)
                if not M.is_open() then M.open() end
                if payload.scope and not payload.project_root then 
                    switch_layout("config")
                    local state = ui.tabs.config
                    if state and state.tree then ViewConfig.render(state.tree) end
                else
                    switch_layout("uproject")
                    local state = ui.tabs.uproject
                    if state and state.tree then ViewUproject.refresh(state.tree) end
                end
            end)
        end
    end
    
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
        callback = function(args)
            local ft = vim.bo.filetype
            if ft ~= "c" and ft ~= "cpp" then return end
            local current = get_current_tab_key()
            if current == "uproject" and ui.win_sub and vim.api.nvim_win_is_valid(ui.win_sub) then
                local state = ui.tabs.uproject
                if state and state.sub and state.sub.tree then
                    local is_force = (args.event == "BufWritePost")
                    ViewSymbols.update(state.sub.tree, ui.win_sub, { force = is_force })
                end
            end
        end,
    })

    -- 現在開いているバッファをエクスプローラーで強調表示する
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
        group = vim.api.nvim_create_augroup("UNX_CurrentBuffer", { clear = true }),
        callback = function()
            if not M.is_open() then return end
            -- エクスプローラー自身のバッファはスキップ
            local ft = vim.bo.filetype
            local bt = vim.bo.buftype
            if ft == "unx-explorer" or bt == "nofile" or bt == "terminal" then return end

            local path = vim.api.nvim_buf_get_name(0)
            if path == "" then return end

            local unl_path = require("UNL.path")
            ViewUproject.set_current_buf_path(unl_path.normalize(path))

            -- uproject タブが表示中なら再レンダリング
            local current_tab = get_current_tab_key()
            if current_tab == "uproject" then
                local state = ui.tabs.uproject
                if state and state.tree then
                    ViewUproject.request_render()
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = vim.api.nvim_create_augroup("UNX_AutoClose", { clear = true }),
        callback = function(args)
            if ignore_win_close_event then return end
            local closed_win = tonumber(args.match)
            if closed_win == ui.win_main or closed_win == ui.win_sub then
                M.close()
            end
        end
    })
end

function M.open()
    if ui.win_main and vim.api.nvim_win_is_valid(ui.win_main) then
        vim.api.nvim_set_current_win(ui.win_main)
        return
    end
    
    local conf = require("UNX.config").get()
    
    for key, tab_conf in pairs(TAB_CONFIG) do
        local state = ui.tabs[key]
        state.buf = get_or_create_buffer(state.buf, "unx-explorer")
        apply_buffer_keymaps(state.buf, key, false)
        if tab_conf.sub_view then
            state.sub.buf = get_or_create_buffer(state.sub.buf, "unx-explorer")
            apply_buffer_keymaps(state.sub.buf, key, true)
        end
    end
    
    local width = conf.window and conf.window.size and conf.window.size.width or 35
    local pos = conf.window and conf.window.position or "left"
    local modifier = (pos == "right" and "botright" or "topleft")
    
    vim.cmd(modifier .. " vsplit")
    ui.win_main = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(ui.win_main, width)
    apply_window_options(ui.win_main)

    for key, tab_conf in pairs(TAB_CONFIG) do
        local state = ui.tabs[key]
        if tab_conf.view_mod and tab_conf.view_mod.create then
            if not state.tree then
                if key == "uproject" then
                    state.tree = tab_conf.view_mod.create(state.buf, ui.win_main)
                else
                    state.tree = tab_conf.view_mod.create(state.buf)
                end
            end
        end
        if tab_conf.sub_view and tab_conf.sub_view.view_mod and tab_conf.sub_view.view_mod.create then
            if not state.sub.tree then
                state.sub.tree = tab_conf.sub_view.view_mod.create(state.sub.buf)
            end
        end
    end

    local saved_tab = get_current_tab_key()
    switch_layout(saved_tab)

    -- 開いているバッファを初期ハイライト対象としてセット
    local cur_path = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if cur_path ~= "" then
        local unl_path = require("UNL.path")
        ViewUproject.set_current_buf_path(unl_path.normalize(cur_path))
    end

    if ui.tabs.uproject and ui.tabs.uproject.tree then
        ViewUproject.refresh(ui.tabs.uproject.tree, ui.win_main)
    end
end

function M.close()
    ignore_win_close_event = true
    local wins = { ui.win_main, ui.win_sub }
    for _, winid in ipairs(wins) do
        if winid and vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end
    end
    ui.win_main = nil
    ui.win_sub = nil
    ignore_win_close_event = false
    ViewUproject.cancel_async_tasks()
end

function M.refresh()
    local current = get_current_tab_key()
    local conf = TAB_CONFIG[current]
    local state = ui.tabs[current]
    if state and state.tree and conf.view_mod then
        if conf.view_mod.refresh then
            conf.view_mod.refresh(state.tree)
        elseif conf.view_mod.render then
            conf.view_mod.render(state.tree)
        end
    end
end

function M.is_open()
    return ui.win_main and vim.api.nvim_win_is_valid(ui.win_main)
end

function M.focus(filepath)
    local logger = logger_module.get()

    if not M.is_open() then
        M.open()
    end

    -- Switch to the uproject tab where the file tree is
    switch_layout("uproject")
    vim.api.nvim_set_current_win(ui.win_main)

    local tree = ui.tabs.uproject.tree
    if not tree then return end

    local ctx = require("UNX.context.uproject").get()
    local project_root = ctx.project_root
    if not project_root then return end

    local unl_path = require("UNL.path")
    local norm_filepath = unl_path.normalize(filepath)
    
    -- Check if the file is within the project root
    if not norm_filepath:find(project_root, 1, true) then
        logger.warn("File is not inside the current project root.")
        return
    end

    local relative_path = norm_filepath:gsub(project_root, "", 1):match("^[/]*(.*)")
    local path_parts = vim.split(relative_path, "[\\/]")

    -- First, find the project root node in the tree
    local root_nodes = tree:get_nodes()
    local project_node = nil
    local project_node_id = unl_path.normalize(project_root)
    for _, node in ipairs(root_nodes) do
        if node.id == project_node_id then
            project_node = node
            break
        end
    end

    if not project_node then
        logger.warn("Project root node not found in the tree.")
        return
    end

    -- Ensure the project root node is expanded
    if not project_node:is_expanded() then
        ViewUproject.ensure_children_loaded(tree, project_node)
        project_node:expand()
        ViewUproject.set_expanded_state(project_node:get_id(), true)
    end

    local current_nodes = tree:get_nodes(project_node:get_id())
    local target_node = nil

    for i, part in ipairs(path_parts) do
        local found_node = nil
        if current_nodes then
            for _, node in ipairs(current_nodes) do
                if node.text:lower() == part:lower() then
                    found_node = node
                    break
                end
            end
        end

        if found_node then
            target_node = found_node
            if i < #path_parts then -- It's a directory, needs to be expanded
                if not found_node:is_expanded() then
                    ViewUproject.ensure_children_loaded(tree, found_node)
                    found_node:expand()
                    ViewUproject.set_expanded_state(found_node:get_id(), true)
                end
                current_nodes = tree:get_nodes(found_node:get_id())
                if not current_nodes or #current_nodes == 0 then
                    return -- Children not loaded yet, might be async
                end
            end
        else
            target_node = nil
            break
        end
    end

    if target_node then
        -- Just render the changes. Since we updated the expanded_state and 
        -- expanded the nodes in the loop, we don't need to full refresh.
        tree:render()

        local target_id = target_node.id
        -- We need the project root node's ID to find where the main tree starts
        local project_node_id = project_node.id

        vim.schedule(function()
            local count = vim.api.nvim_buf_line_count(tree.bufnr)
            local start_line = 1

            -- 1. Find the start line of the project root node to skip Favorites/Pending
            for i = 1, count do
                local node = tree:get_node(i)
                if node and node.id == project_node_id then
                    start_line = i
                    break
                end
            end

            -- 2. Search for the target file from the project root downwards
            for i = start_line, count do
                local node = tree:get_node(i)
                -- Compare normalized paths to avoid issues with separators or drive letters
                if node and node.path and unl_path.normalize(node.path) == norm_filepath then
                    vim.api.nvim_win_set_cursor(ui.win_main, { i, 0 })
                    return
                end
            end
        end)
    end
end

return M
