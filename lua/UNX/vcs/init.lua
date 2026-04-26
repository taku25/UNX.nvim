-- lua/UNX/vcs/init.lua
-- UNX の VCS アグリゲーター。
-- ファイル監視・ステータス系は UNX 設定の enabled フラグで制御する。
-- 履歴系 (get_log / get_my_log / get_commit_files / get_file_at_commit / get_user_name) は
-- UNL.vcs に委譲する（UNL 側でプロバイダーを持つ）。
local M = {}
local unl_vcs = require("UNL.vcs")

-- UNX 設定フィルタ付きプロバイダー (ステータス・リフレッシュ系に使用)
-- UNL.vcs のプロバイダーを直接参照する
local providers = {
    { name = "p4",  module = require("UNL.vcs.p4") },
    { name = "git", module = require("UNL.vcs.git") },
    { name = "svn", module = require("UNL.vcs.svn") },
}

--- 設定を取得するヘルパー
local function get_config()
    local conf = require("UNL.config").get("UNX")
    return conf.vcs or {}
end

--- VCS ステータスを更新する (UNX 設定の enabled フラグで制御)
function M.refresh(root_path, on_complete)
    local conf = get_config()
    local pending = 0

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false then pending = pending + 1 end
    end

    if pending == 0 then
        if on_complete then on_complete() end
        return
    end

    local function check_done()
        pending = pending - 1
        if pending <= 0 and on_complete then on_complete() end
    end

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false then
            if type(provider.module.refresh) == "function" then
                provider.module.refresh(root_path, check_done, "UNX")
            else
                check_done()
            end
        end
    end
end

--- 全 VCS 変更ファイルをマージして返す (Local Changes)
function M.get_aggregated_changes()
    local conf = get_config()
    local combined = {}
    local seen = {}
    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_changes) == "function" then
            for _, item in ipairs(provider.module.get_changes()) do
                if not seen[item.path] then
                    seen[item.path] = true
                    table.insert(combined, item)
                end
            end
        end
    end
    table.sort(combined, function(a, b) return a.path < b.path end)
    return combined
end

--- 全 VCS 未プッシュファイルをマージして返す (Remote Diff)
function M.get_aggregated_unpushed()
    local conf = get_config()
    local combined = {}
    local seen = {}
    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_unpushed) == "function" then
            for _, item in ipairs(provider.module.get_unpushed()) do
                if not seen[item.path] then
                    seen[item.path] = true
                    table.insert(combined, item)
                end
            end
        end
    end
    table.sort(combined, function(a, b) return a.path < b.path end)
    return combined
end

--- パスの VCS ステータスを取得する
function M.get_status(path)
    local conf = get_config()
    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_status) == "function" then
            local status = provider.module.get_status(path)
            if status then return status end
        end
    end
    return nil
end

--- 全プロバイダーのキャッシュをクリア
function M.clear()
    unl_vcs.clear()
end

function M.is_p4_managed(path)
    local conf = get_config()
    if not conf.p4 or conf.p4.enabled == false then return false end
    return unl_vcs.is_p4_managed(path)
end

function M.p4_edit(path)
    return unl_vcs.p4_edit(path, "UNX")
end

function M.p4_revert(path)
    return unl_vcs.p4_revert(path, "UNX")
end

function M.get_file_content(path, on_success)
    return unl_vcs.get_file_content(path, on_success)
end

-- ──────────────────────────────────────────────────────
-- 履歴系: UNL.vcs に委譲 (プロバイダーの enabled 制御なし)
-- 将来的に他プラグインからも同じ UNL.vcs を呼べる
-- ──────────────────────────────────────────────────────

function M.get_user_name(cwd, callback)
    return unl_vcs.get_user_name(cwd, callback)
end

function M.get_log(cwd, limit, author, callback)
    return unl_vcs.get_log(cwd, limit, author, callback)
end

function M.get_my_log(cwd, limit, callback)
    return unl_vcs.get_my_log(cwd, limit, callback)
end

function M.get_commit_files(cwd, commit, callback)
    return unl_vcs.get_commit_files(cwd, commit, callback)
end

function M.get_file_at_commit(cwd, commit, file_data, callback)
    return unl_vcs.get_file_at_commit(cwd, commit, file_data, callback)
end

return M