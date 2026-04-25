-- lua/UNX/ui/view/uproject/preview.lua
-- フローティングプレビューウィンドウ管理

local M = {}

local state = {
    win     = nil,
    buf     = nil,
    timer   = nil,
    enabled = nil, -- nil = config に従う
}

-- --------------------------------------------------------------------------
-- internal helpers
-- --------------------------------------------------------------------------

local function cleanup_timer()
    if state.timer then
        state.timer:stop()
        if not state.timer:is_closing() then state.timer:close() end
        state.timer = nil
    end
end

local function get_conf()
    return require("UNX.config").get()
end

local function get_or_create_buf()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        return state.buf
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile  = false
    vim.bo[buf].buftype   = "nofile"
    state.buf = buf
    return buf
end

--- explorer ウィンドウの右側にフロートを配置するオプションを計算する。
--- 右にスペースが足りない場合は nil を返す。
local function calc_float_opts(anchor_win)
    local ok, pos = pcall(vim.api.nvim_win_get_position, anchor_win)
    if not ok then return nil end

    local anchor_col = pos[2]
    local anchor_w   = vim.api.nvim_win_get_width(anchor_win)

    local editor_w = vim.o.columns
    -- ステータスライン・コマンドラインを除いた実効高さ
    local editor_h = vim.o.lines - vim.o.cmdheight - 1

    local conf       = get_conf()
    local prev_conf  = conf.preview or {}
    local width_pct  = prev_conf.width_pct  or 0.45
    local height_pct = prev_conf.height_pct or 0.80
    local min_width  = prev_conf.min_width  or 20
    local min_height = prev_conf.min_height or 5

    -- 横: UNX 右端から画面右端までが利用可能領域
    local area_col_start = anchor_col + anchor_w + 2
    local available_w    = editor_w - area_col_start - 1

    local float_w     = math.floor(available_w * width_pct)
    -- 左右均等オフセット（余白を両端に振り分ける）
    local h_offset    = math.floor((available_w - float_w) / 2)
    local float_col   = area_col_start + h_offset

    -- 縦: Neovim 全体の実効高さを基準に中央配置
    local float_h     = math.floor(editor_h * height_pct)
    local float_row   = math.floor((editor_h - float_h) / 2)

    if float_w < min_width or area_col_start >= editor_w - 5 then
        return nil
    end

    return {
        relative  = "editor",
        row       = float_row,
        col       = float_col,
        width     = float_w,
        height    = math.max(float_h, min_height),
        style     = "minimal",
        border    = "rounded",
        focusable = false,
        zindex    = 45,
    }
end

-- --------------------------------------------------------------------------
-- public API
-- --------------------------------------------------------------------------

function M.is_open()
    return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- auto フラグの現在値を返す（user override → config のフォールバック順）
function M.is_enabled()
    if state.enabled ~= nil then return state.enabled end
    local conf = get_conf()
    if conf.preview then
        return conf.preview.auto ~= false
    end
    return true
end

--- `p` キーで auto フラグをトグルする
function M.toggle_enabled()
    state.enabled = not M.is_enabled()
    if not state.enabled then M.close() end
    return state.enabled
end

function M.close()
    cleanup_timer()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
end

--- 指定パスの内容をフローティングウィンドウに即時表示する
function M.show(path, anchor_win)
    if not path or not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
        M.close(); return
    end

    -- ディレクトリはスキップ
    local stat = vim.uv and vim.uv.fs_stat(path) or vim.loop.fs_stat(path)
    if not stat or stat.type == "directory" then M.close(); return end

    -- 大きすぎるファイルはスキップ
    local conf = get_conf()
    local max_kb = (conf.preview and conf.preview.max_file_size_kb) or 512
    if stat.size > max_kb * 1024 then M.close(); return end

    -- ファイル内容の読み込み（最大 500 行）
    local ok, lines = pcall(vim.fn.readfile, path, "", 500)
    if not ok then M.close(); return end

    local buf = get_or_create_buf()

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified   = false

    -- ファイルタイプを設定してシンタックスハイライト
    local ft = ""
    if vim.filetype and vim.filetype.match then
        ft = vim.filetype.match({ filename = path }) or ""
    end
    if ft ~= "" and vim.bo[buf].filetype ~= ft then
        vim.bo[buf].filetype = ft
    end

    local float_opts = calc_float_opts(anchor_win)
    if not float_opts then M.close(); return end

    local fname      = vim.fn.fnamemodify(path, ":t")
    local title_opts = vim.tbl_extend("force", float_opts, {
        title     = " " .. fname .. " ",
        title_pos = "center",
    })

    if M.is_open() then
        -- 既存ウィンドウを更新
        pcall(vim.api.nvim_win_set_config, state.win, title_opts)
        pcall(vim.api.nvim_win_set_buf, state.win, buf)
    else
        local win = vim.api.nvim_open_win(buf, false, title_opts)
        if not win or not vim.api.nvim_win_is_valid(win) then return end
        state.win = win
        vim.wo[win].wrap          = false
        vim.wo[win].number        = true
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn    = "no"
        vim.wo[win].foldcolumn    = "0"
        vim.wo[win].cursorline    = true
        vim.wo[win].winhl         = "Normal:Normal,FloatBorder:FloatBorder"
    end
end

--- デバウンス付き show（CursorMoved で使用）
function M.schedule_show(path, anchor_win)
    cleanup_timer()
    local conf    = get_conf()
    local debounce = (conf.preview and conf.preview.debounce_ms) or 150
    state.timer = vim.loop.new_timer()
    state.timer:start(debounce, 0, vim.schedule_wrap(function()
        cleanup_timer()
        M.show(path, anchor_win)
    end))
end

--- `p` キー: open / close をトグルする（auto フラグとは独立）
function M.toggle(path, anchor_win)
    if M.is_open() then
        M.close()
    else
        M.show(path, anchor_win)
    end
end

return M
