local unl_path = require("UNL.path")
local M = {}


-- 開いているバッファの変更状態を取得
function M.get_opened_buffers_status()
    local opened_buffers = {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.buflisted(buffer) ~= 0 then
            local name = vim.api.nvim_buf_get_name(buffer)
            if name == "" then name = "[No Name]#" .. buffer end
            local norm_name = unl_path.normalize(name)
            if norm_name then
                opened_buffers[norm_name] = { modified = vim.bo[buffer].modified }
            end
        end
    end
    return opened_buffers
end

-- Gitステータスのアイコンとハイライトを取得
function M.get_vcs_icon_and_hl(status_code, config)
    local uproj_conf = config.icons or {}

    -- ★変更: vcs_icons を優先し、なければ git_icons を見る (後方互換)
    local icons = uproj_conf.vcs or {}

    if status_code == "M" then return icons.Modified or "", "UNXVCSModified" end
    if status_code == "A" then return icons.Added or "✚", "UNXVCSAdded" end
    if status_code == "D" then return icons.Deleted or "✖", "UNXVCSDeleted" end
    if status_code == "R" then return icons.Renamed or "➜", "UNXVCSRenamed" end
    if status_code == "C" then return icons.Conflict or "", "UNXVCSConflict" end
    if status_code == "??" then return icons.Untracked or "★", "UNXVCSUntracked" end
    if status_code == "!!" then return icons.Ignored or "◌", "UNXVCSIgnored" end
    

    return "", "UNXFileName"
end

return M
