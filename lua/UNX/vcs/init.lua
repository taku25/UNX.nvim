-- lua/UNX/vcs/init.lua
local M = {}
local unl_vcs = require("UNL.vcs")

-- VCSプロバイダーの定義 (UNX ラッパーを使用)
local providers = {
    { name = "p4",  module = require("UNX.vcs.p4") },
    { name = "git", module = require("UNX.vcs.git") },
    { name = "svn", module = require("UNX.vcs.svn") },
}

--- 設定を取得するヘルパー
local function get_config()
    local conf = require("UNL.config").get("UNX")
    return conf.vcs or {}
end

--- VCSの状態を更新する
function M.refresh(root_path, on_complete)
    local conf = get_config()
    local pending = 0

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false then
            pending = pending + 1
        end
    end

    if pending == 0 then
        if on_complete then on_complete() end
        return
    end

    local function check_done()
        pending = pending - 1
        if pending <= 0 and on_complete then
            on_complete()
        end
    end

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.refresh) == "function" then
            provider.module.refresh(root_path, check_done, "UNX")
        else
            -- refresh未実装のプロバイダーはスキップ
            if cfg and cfg.enabled ~= false then
                check_done()
            end
        end
    end
end

--- 全てのVCS変更ファイルをマージして返す (Local Changes)
function M.get_aggregated_changes()
    local conf = get_config()
    local combined = {}
    local seen = {}

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_changes) == "function" then
            local changes = provider.module.get_changes()
            
            for _, item in ipairs(changes) do
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

--- 全ての未プッシュファイルをマージして返す (Remote Diff)
function M.get_aggregated_unpushed()
    local conf = get_config()
    local combined = {}
    local seen = {}

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_unpushed) == "function" then
            local changes = provider.module.get_unpushed()
            
            for _, item in ipairs(changes) do
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

--- パスのVCSステータスを取得する
function M.get_status(path)
    local conf = get_config()

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_status) == "function" then
            local status = provider.module.get_status(path)
            if status then
                return status
            end
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
    local conf = get_config()
    local index = 1
    
    local function try_next()
        if index > #providers then
            on_success(nil)
            return
        end
        
        local provider = providers[index]
        index = index + 1
        local cfg = conf[provider.name]
        
        if cfg and cfg.enabled ~= false and type(provider.module.get_file_content) == "function" then
            provider.module.get_file_content(path, function(content)
                if content then
                    on_success(content)
                else
                    try_next()
                end
            end)
        else
            try_next()
        end
    end
    
    try_next()
end

--- 有効なVCSプロバイダーからユーザー名を取得する
--- @param cwd string プロジェクトルート
--- @param callback function(name: string|nil, provider_name: string|nil)
function M.get_user_name(cwd, callback)
    local conf = get_config()
    local index = 1

    local function try_next()
        if index > #providers then
            return callback(nil, nil)
        end

        local provider = providers[index]
        index = index + 1
        local cfg = conf[provider.name]

        if cfg and cfg.enabled ~= false and type(provider.module.get_user_name) == "function" then
            provider.module.get_user_name(cwd, function(name)
                if name then
                    callback(name, provider.name)
                else
                    try_next()
                end
            end)
        else
            try_next()
        end
    end

    try_next()
end

--- 有効な全VCSプロバイダーからコミット履歴を集約する
--- @param cwd string プロジェクトルート
--- @param limit number 最大取得件数
--- @param author string|nil 著者フィルタ (nilの場合は全コミット)
--- @param callback function(commits: table[]) 結果コミットリスト
function M.get_log(cwd, limit, author, callback)
    local conf = get_config()
    local all_commits = {}
    local pending = 0

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_log) == "function" then
            pending = pending + 1
        end
    end

    if pending == 0 then
        return callback({})
    end

    local function check_done()
        pending = pending - 1
        if pending <= 0 then
            callback(all_commits)
        end
    end

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false and type(provider.module.get_log) == "function" then
            provider.module.get_log(cwd, limit, author, function(commits)
                if commits then
                    for _, c in ipairs(commits) do
                        c.vcs = c.vcs or provider.name
                        table.insert(all_commits, c)
                    end
                end
                check_done()
            end)
        end
    end
end

--- 各VCSプロバイダーが自身のユーザー名を使って「自分のコミット」を取得する
--- @param cwd string プロジェクトルート
--- @param limit number 最大取得件数
--- @param callback function(commits: table[]) 結果コミットリスト
function M.get_my_log(cwd, limit, callback)
    local conf = get_config()
    local all_commits = {}
    local pending = 0

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false
           and type(provider.module.get_log) == "function"
           and type(provider.module.get_user_name) == "function" then
            pending = pending + 1
        end
    end

    if pending == 0 then
        return callback({})
    end

    local function check_done()
        pending = pending - 1
        if pending <= 0 then
            callback(all_commits)
        end
    end

    for _, provider in ipairs(providers) do
        local cfg = conf[provider.name]
        if cfg and cfg.enabled ~= false
           and type(provider.module.get_log) == "function"
           and type(provider.module.get_user_name) == "function" then
            -- Each provider resolves its own user name
            provider.module.get_user_name(cwd, function(user_name)
                if not user_name then
                    check_done()
                    return
                end
                provider.module.get_log(cwd, limit, user_name, function(commits)
                    if commits then
                        for _, c in ipairs(commits) do
                            c.vcs = c.vcs or provider.name
                            table.insert(all_commits, c)
                        end
                    end
                    check_done()
                end)
            end)
        end
    end
end

--- コミット時点のファイル内容を取得する
--- @param cwd string プロジェクトルート
--- @param commit table コミットオブジェクト（hash, vcs フィールド必須）
--- @param file_data table ファイルデータ（full_rel_path, depot_path フィールド）
--- @param callback function(content: string|nil)
function M.get_file_at_commit(cwd, commit, file_data, callback)
    local conf = get_config()
    local vcs_name = commit.vcs

    for _, provider in ipairs(providers) do
        if provider.name == vcs_name then
            local cfg = conf[provider.name]
            if cfg and cfg.enabled ~= false and type(provider.module.get_file_at_commit) == "function" then
                -- P4 は depot_path、Git は full_rel_path（git root 相対）を渡す
                local path_arg = (vcs_name == "p4")
                    and (file_data.depot_path or file_data.full_rel_path or file_data.path)
                    or  (file_data.full_rel_path or file_data.path or "")
                provider.module.get_file_at_commit(cwd, commit.hash, path_arg, callback)
                return
            end
        end
    end

    callback(nil)
end

--- コミットの変更ファイルリストを取得する
--- @param cwd string プロジェクトルート
--- @param commit table コミットオブジェクト（hashとvcsフィールド必須）
--- @param callback function(files: string[]|nil)
function M.get_commit_files(cwd, commit, callback)
    local conf = get_config()
    local vcs_name = commit.vcs

    for _, provider in ipairs(providers) do
        if provider.name == vcs_name then
            local cfg = conf[provider.name]
            if cfg and cfg.enabled ~= false and type(provider.module.get_commit_files) == "function" then
                provider.module.get_commit_files(cwd, commit.hash, callback)
                return
            end
        end
    end

    callback(nil)
end

return M