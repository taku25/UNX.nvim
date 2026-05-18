-- lua/UNX/config/defaults.lua
local M = {}

M.defaults = {
    -- ウィンドウ設定
    window = {
        position = "left",
        size = {
            width = 35,
        },
    },
    cache = { dirname = "UNX" },
    logging = {
        level = "debug",
        echo = { level = "warn" },
        notify = { level = "error", prefix = "[UNX]" },
        file = { enable = true, max_kb = 512, rotate = 3, filename = "unx.log" },
        perf = { enabled = false, patterns = { "^refresh" }, level = "trace" },
        debug = { enable = true, },

    },
    highlights = {
        UNXDirectoryIcon = { link = "Directory" },
        UNXFileIcon      = { link = "Comment" },
        UNXFileName      = { link = "Normal" },
        UNXCurrentFile   = { link = "CursorLineNr" },
        UNXIndentMarker  = { link = "NonText" },
        UNXModifiedIcon  = { link = "Special" },

        UNXTabActive     = { link = "UNXVCSAdded" },
        UNXTabInactive   = { link = "Normal" },
        UNXTabSeparator  = { link = "NonText" },

        UNXVCSModified   = { link = "Special" },
        UNXVCSAdded      = { link = "String" },
        UNXVCSDeleted    = { link = "Error" },
        UNXVCSRenamed    = { link = "Title" },
        UNXVCSConflict   = { link = "ErrorMsg" },
        UNXVCSUntracked  = { link = "Function" },
        UNXVCSIgnored    = { link = "Comment" },

        UNXVCSFunction      = { link = "Function" },
        UNXSelected         = { link = "DiagnosticOk" },
        UNXInsightsGroupIcon = { link = "UNXDirectoryIcon" },
        UNXInsightsLeafIcon  = { link = "Function" },
    },
    icons = {
        uproject = {
            expander_open   = "",
            expander_closed = "",
            folder_closed   = "",
            folder_open     = "",
            default_file    = "",
            modified        = "[+]",
            recent          = "󱋡 ",
            favorites       = " ",
            selected        = "●",
        },
        insights = {
            group_icon_open = "",
            group_icon_closed = "",
            leaf_icon = "󰊕", 
        },
        vcs = {
            Modified  = "",
            Added     = "✚",
            Deleted   = "",
            Renamed   = "➜",
            Conflict  = "",
            Untracked = "★",
            Ignored   = "◌",
        },
    },
    preview = {
        auto             = true,   -- カーソル移動で自動プレビュー
        debounce_ms      = 150,
        max_file_size_kb = 512,
        -- フロートウィンドウのサイズをエディタ全体に対する割合で指定
        width_pct        = 0.90,
        height_pct       = 0.80,
        min_width        = 20,     -- 最小幅（列数）
        min_height       = 5,      -- 最小高さ（行数）
    },
    multiselect = {
        enabled = true,
    },
    uproject = {
        show_hidden = false,
        show_recent = true,
        recent_max  = 15,
        ui = {
            right_components = {
                "vcs_status",
                "modified_buffer",
            },
        },
    },
    safe_open = {
        prevent_in_buftypes = {
            "nofile", "quickfix", "help", "terminal", "prompt",
        },
        prevent_in_filetypes = {
            "neo-tree", "NvimTree", "TelescopePrompt", "fugitive", "lazy", "unx-explorer",
        },
    },
    vcs = {
        git = { enabled = true },
        p4 = { enabled = true, auto_checkout = true },
        svn = { enabled = true },
        my_commits_limit = 10,
        repo_commits_limit = 10,
    },
    symbols = {
        expand_groups = true, -- Functions, Propertiesなどを最初から展開する
    },
    keymaps = {
        close = { "q" },
        open = { "<CR>", "o" },
        vsplit = "s",
        split = "i",

        action_add = "a",
        action_new_file = "N",
        action_add_directory = "A",
        action_delete = "d",
        action_move = "m",
        action_rename = "r",

        action_toggle_favorite = "b",
        action_add_favorite_folder = "N",
        action_move_favorite = "m",
        action_move_favorite_another = "M",
        action_rename_favorite_folder = "<C-r>",
        action_remove_favorite_folder = "<C-d>",
        action_find_files = "f",
        action_preview_toggle  = "p",
        action_select_toggle   = "<Space>",
        action_clear_selection = "<Esc>",
        action_force_refresh = "R",
        action_diff = "D",
        action_commit_diff = "D",
        action_help = "g?",
        action_open_in_ide = "<C-o>",
        action_copy_path = "yy",
        action_goto_pair = "gh",
        action_go_back = "<BS>",
        action_toggle_hierarchy = "H",
        custom = {},
    },
}

return M.defaults
