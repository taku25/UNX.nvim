-- lua/UNX/ui/view/uproject/renderer.lua
local Line = require("nui.line")
local unl_path = require("UNL.path")
local unx_vcs = require("UNX.vcs")
local utils = require("UNX.common.utils")
local PendingView = require("UNX.ui.view.uproject.pending")
local FavoritesView = require("UNX.ui.view.uproject.favorites")
local RecentView = require("UNX.ui.view.uproject.recent")

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local M = {}

-- 現在開いているバッファの正規化パス（nil = 追跡なし）
local current_buf_path = nil

-- 選択中のパス集合 { [normalized_path] = true }
local selected_paths = {}

function M.set_current_path(path)
    current_buf_path = path
end

function M.set_selected_paths(paths)
    selected_paths = paths or {}
end

local function get_platform_icon(name)
    local lower = name:lower()
    if lower:find("windows") then return " " end
    if lower:find("mac") or lower:find("ios") or lower:find("tvos") or lower:find("apple") then return " " end
    if lower:find("android") then return " " end
    if lower:find("linux") or lower:find("unix") then return " " end
    if lower:find("default") then return " " end
    return " " 
end

function M.prepare_node(node)
    local conf = require("UNX.config").get()
    local line = Line()
    line:append(string.rep("  ", node:get_depth() - 1))
    
    local has_children = node:has_children() or node._has_children
    local icon = "  "
    if has_children then
        icon = node:is_expanded() and " " or " "
    end
    line:append(icon, "UNXIndentMarker")

    local icon_text = " "
    local icon_hl = "UNXFileIcon"
    local uep_type = node.extra and node.extra.uep_type
    local is_special_folder = (uep_type == "root_game_fs")
        or (uep_type == "root_engine_fs")
        or (uep_type == FavoritesView.ROOT_TYPE)
        or (uep_type == RecentView.ROOT_TYPE)
        or (uep_type == PendingView.ROOT_TYPE_PENDING)
        or (uep_type == PendingView.ROOT_TYPE_UNPUSHED)

    if node.type == "directory" or is_special_folder then
        if uep_type == "root_game_fs" or uep_type == "root_engine_fs" then
            icon_text = "󰚝 "
            icon_hl = "UNXDirectoryIcon"
        elseif uep_type == FavoritesView.ROOT_TYPE then
            icon_text = (conf.uproject and conf.uproject.icon and conf.uproject.icon.favorites) or " "
            icon_hl = "Special"
        elseif uep_type == RecentView.ROOT_TYPE then
            icon_text = (conf.uproject and conf.uproject.icon and conf.uproject.icon.recent) or " "
            icon_hl = "Special"
        elseif uep_type == PendingView.ROOT_TYPE_PENDING then
            icon_text = " "
            icon_hl = "Special"
        elseif uep_type == PendingView.ROOT_TYPE_UNPUSHED then
            icon_text = " "
            icon_hl = "Special"
        else
            icon_text = node:is_expanded() and " " or " "
            icon_hl = "UNXDirectoryIcon"
        end
    elseif has_devicons then
        local ext = ""
        if node.path then
            ext = node.path:match("^.+%.(.+)$") or ""
        end
        local d_icon, d_hl = devicons.get_icon(node.text, ext, { default = true })
        icon_text = (d_icon or " ") .. " "
        icon_hl = d_hl or icon_hl
    end
    line:append(icon_text, icon_hl)

    local path = node.path or node.id
    local norm_path = unl_path.normalize(path)
    local vcs_stat = unx_vcs.get_status(norm_path)
    local name_hl = "UNXFileName"
    if vcs_stat then
        local _, vcs_hl = utils.get_vcs_icon_and_hl(vcs_stat, conf)
        name_hl = vcs_hl or name_hl
    end

    if node.extra and node.extra.vcs_status_override == "Unpushed" then
        name_hl = "UNXVCSAdded"
    end

    -- 現在開いているバッファと一致するノードを強調表示
    if node.path and current_buf_path and norm_path == current_buf_path then
        name_hl = "UNXCurrentFile"
    end

    -- マルチセレクト: 選択中はファイル名の前にマーカーを置き、名前も選択色に
    local is_selected = node.path and node.type == "file"
        and selected_paths[unl_path.normalize(node.path)]

    if is_selected then
        line:append("● ", "UNXSelected")
        line:append(node.text, "UNXSelected")
    else
        line:append(node.text, name_hl)
    end

    return line
end

return M
