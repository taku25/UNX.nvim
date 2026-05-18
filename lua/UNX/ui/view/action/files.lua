-- lua/UNX/ui/view/action/files.lua
local unl_api = require("UNL.api")
local fs = require("vim.fs")
local favorites_cache = require("UNX.cache.favorites")
local unl_picker = require("UNL.picker")
local unx_config = require("UNX.config")
local unl_path = require("UNL.path")
local unl_buf_open = require("UNL.buf.open")
local logger = require("UNX.logger") -- ★使用

local M = {}

local function sanitize_path(path)
    if not path or path == "" then return nil end
    local abs_path = vim.fn.fnamemodify(path, ":p")
    if abs_path:len() > 3 and (abs_path:sub(-1) == "/" or abs_path:sub(-1) == "\\") then
        abs_path = abs_path:sub(1, -2)
    end
    return abs_path:gsub("\\", "/")
end

function M.add(tree)
    local node = tree:get_node()
    if not node then return end
    
    local raw_target = node.path
    if node.type == "file" then
        raw_target = vim.fn.fnamemodify(node.path, ":h")
    end

    local target_dir = sanitize_path(raw_target)
    if not target_dir or vim.fn.isdirectory(target_dir) == 0 then 
        -- ★修正
        logger.get().error("Invalid target directory.")
        return 
    end

    unl_api.provider.request("ucm.class.new", {
        target_dir = target_dir,
        logger_name = "UNX",
    })
end

function M.add_file(tree)
    local node = tree:get_node()
    if not node then return end
    
    local raw_target = node.path
    if node.type == "file" then
        raw_target = vim.fn.fnamemodify(node.path, ":h")
    end
    
    local target_dir = sanitize_path(raw_target)
    if not target_dir then return end

    vim.ui.input({ prompt = "New File Name: " }, function(input)
        if not input or input == "" then return end
        
        local new_file_path = vim.fs.joinpath(target_dir, input)
        
        if vim.loop.fs_stat(new_file_path) then
             logger.get().error("File already exists: " .. new_file_path)
             return
        end

        local ok, err = pcall(vim.fn.writefile, {}, new_file_path)
        if ok then
            logger.get().info("File created: " .. new_file_path)
            local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
            local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
            if unl_events_ok and unl_types_ok then
                 local mod_info = unl_api.find_module(new_file_path)
                 if mod_info and mod_info.name then
                     unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, {
                        status = "success",
                        type = "add",
                        module = { name = mod_info.name }
                     })
                 end
            end
             
             -- Open the new file
            unl_buf_open.safe({
                file_path = new_file_path,
                open_cmd = "edit",
                plugin_name = "UNX",
            })
        else
            logger.get().error("Failed to create file: " .. tostring(err))
        end
    end)
end

function M.add_directory(tree)
    local node = tree:get_node()
    if not node then return end
    
    local raw_target = node.path
    if node.type == "file" then
        raw_target = vim.fn.fnamemodify(node.path, ":h")
    end
    
    local target_dir = sanitize_path(raw_target)
    if not target_dir then return end

    vim.ui.input({ prompt = "New Directory Name: " }, function(input)
        if not input or input == "" then return end
        
        local new_dir_path = vim.fs.joinpath(target_dir, input)
        
        local ok, err = pcall(vim.fn.mkdir, new_dir_path, "p")
        if ok then
            -- ★修正
            logger.get().info("Directory created: " .. new_dir_path)
            local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
            local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
            if unl_events_ok and unl_types_ok then
                 local mod_info = unl_api.find_module(new_dir_path)
                 if mod_info and mod_info.name then
                     unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, {
                        status = "success",
                        type = "add",
                        module = { name = mod_info.name }
                     })
                 end
            end
        else
            -- ★修正
            logger.get().error("Failed to create directory: " .. tostring(err))
        end
    end)
end

function M.delete(tree)
    local view_uproject = require("UNX.ui.view.uproject")
    local selected = view_uproject.get_selected_list()

    -- マルチセレクト: 選択中ファイルを一括削除
    if #selected > 0 then
        local choice = vim.fn.confirm(
            string.format("Delete %d selected file(s)?", #selected), "&Yes\n&No", 2)
        if choice ~= 1 then return end
        for _, path in ipairs(selected) do
            local stat = vim.uv and vim.uv.fs_stat(path) or vim.loop.fs_stat(path)
            if stat and stat.type == "file" then
                unl_api.provider.request("ucm.class.delete", {
                    file_path = path,
                    logger_name = "UNX",
                })
            end
        end
        view_uproject.clear_selected()
        return
    end

    -- シングル削除（既存ロジック）
    local node = tree:get_node()
    if not node then return end
    
    local path = sanitize_path(node.path)
    if not path then return end

    if node.type == "file" then
        unl_api.provider.request("ucm.class.delete", {
            file_path = path,
            logger_name = "UNX",
        })
    elseif node.type == "directory" then
        local choice = vim.fn.confirm("Delete directory '" .. node.text .. "' and ALL its contents?", "&Yes\n&No", 2)
        if choice == 1 then
            local parent_dir = vim.fn.fnamemodify(path, ":h")
            local mod_info = unl_api.find_module(parent_dir)

            local ok = vim.fn.delete(path, "rf")
            if ok == 0 then 
                logger.get().info("Directory deleted: " .. path)
                
                local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
                local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
                if unl_events_ok and unl_types_ok and mod_info and mod_info.name then
                     unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, {
                        status = "success",
                        type = "delete",
                        module = { name = mod_info.name }
                     })
                end
            else
                logger.get().error("Failed to delete directory. Error code: " .. tostring(ok))
            end
        end
    end
end

function M.move(tree)
    local node = tree:get_node()
    if not node then return end
    
    local path = sanitize_path(node.path)
    if not path then return end

    if node.type == "file" then
        unl_api.provider.request("ucm.class.move", {
            file_path = path,
            logger_name = "UNX",
        })
    elseif node.type == "directory" then
        vim.ui.input({ prompt = "Move directory to (absolute path): ", default = path, completion = "dir" }, function(new_path)
            if not new_path or new_path == "" or new_path == path then return end
            
            local parent_dir = vim.fn.fnamemodify(new_path, ":h")
            if vim.fn.isdirectory(parent_dir) == 0 then
                local create_choice = vim.fn.confirm("Parent directory does not exist. Create it?\n" .. parent_dir, "&Yes\n&No", 1)
                if create_choice == 1 then
                    local ok, err = pcall(vim.fn.mkdir, parent_dir, "p")
                    if not ok then
                         -- ★修正
                         logger.get().error("Failed to create parent directory: " .. tostring(err))
                         return
                    end
                else
                    return
                end
            end
            
            local choice = vim.fn.confirm("Move directory to '" .. new_path .. "'?", "&Yes\n&No", 2)
            if choice == 1 then
                local mod_info_old = unl_api.find_module(vim.fn.fnamemodify(path, ":h"))

                local success, err = vim.loop.fs_rename(path, new_path)
                
                if success then
                    -- ★修正
                    logger.get().info("Directory moved.")
                    
                    local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
                    local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
                    if unl_events_ok and unl_types_ok then
                         local mod_info_new = unl_api.find_module(new_path)
                         if mod_info_old and mod_info_old.name then
                             unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, { status="success", type="move", module={name=mod_info_old.name} })
                         end
                         if mod_info_new and mod_info_new.name and (not mod_info_old or mod_info_new.name ~= mod_info_old.name) then
                             unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, { status="success", type="move", module={name=mod_info_new.name} })
                         end
                    end
                else
                    -- ★修正
                    logger.get().error("Failed to move directory: " .. tostring(err))
                end
            end
        end)
    end
end

function M.rename(tree)
    local node = tree:get_node()
    if not node then return end
    
    local path = sanitize_path(node.path)
    if not path then return end

    if node.type == "file" then
        unl_api.provider.request("ucm.class.rename", {
            file_path = path,
            logger_name = "UNX",
        })
    elseif node.type == "directory" then
        local old_name = node.text
        vim.ui.input({ prompt = "Rename directory: ", default = old_name }, function(new_name)
            if not new_name or new_name == "" or new_name == old_name then return end
            
            local parent_dir = vim.fn.fnamemodify(path, ":h")
            local new_path = vim.fs.joinpath(parent_dir, new_name)
            
            local success, err = vim.loop.fs_rename(path, new_path)
            if success then
                -- ★修正
                logger.get().info("Directory renamed.")
                
                local unl_events_ok, unl_events = pcall(require, "UNL.event.events")
                local unl_types_ok, unl_event_types = pcall(require, "UNL.event.types")
                if unl_events_ok and unl_types_ok then
                     local mod_info = unl_api.find_module(new_path)
                     if mod_info and mod_info.name then
                         unl_events.publish(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, {
                            status = "success",
                            type = "rename",
                            module = { name = mod_info.name }
                         })
                     end
                end
            else
                -- ★修正
                logger.get().error("Failed to rename directory: " .. tostring(err))
            end
        end)
    end
end

-- 共通: パス群を指定フォルダに追加（重複スキップ）。追加件数を返す
local function add_paths_to_folder(paths, folder, project_root)
    local added_count = 0
    for _, path in ipairs(paths) do
        local norm = unl_path.normalize(path)
        local favs = favorites_cache.load(project_root)
        local already = false
        for _, item in ipairs(favs) do
            if not item.is_folder and unl_path.normalize(item.path) == norm then
                already = true; break
            end
        end
        if not already then
            favorites_cache.toggle(path, project_root, folder)
            added_count = added_count + 1
        end
    end
    return added_count
end

-- 共通: フォルダが複数あるときpickerを出してフォルダを選択し、paths を追加する。
-- on_done(folder_name, added_count) が選択後に呼ばれる。
local function pick_folder_and_add(paths, project_root, on_done)
    local folders = favorites_cache.get_folders(project_root)
    if #folders <= 1 then
        local count = add_paths_to_folder(paths, "Default", project_root)
        on_done("Default", count)
        return
    end

    local picker_items = {}
    for _, f in ipairs(folders) do
        table.insert(picker_items, { label = f, value = f })
    end
    unl_picker.open({
        kind = "unx_favorites_add_to_folder",
        title = "Add to Favorites folder",
        items = picker_items,
        conf = unx_config.get(),
        preview_enabled = false,
        on_submit = function(selection)
            if not selection then return end
            local parts = vim.split(selection, "/", { plain = true })
            local folder = parts[#parts]
            local count = add_paths_to_folder(paths, folder, project_root)
            on_done(folder, count)
        end,
    })
end

function M.toggle_favorite(tree)
    local view_uproject = require("UNX.ui.view.uproject")
    local selected = view_uproject.get_selected_list()
    local ctx = require("UNX.context.uproject").get()
    local project_root = ctx.project_root or require("UNL.finder").project.find_project_root(vim.loop.cwd())

    -- マルチセレクト: 既登録→削除 / 未登録→フォルダpicker経由で追加
    if #selected > 0 then
        local favs = favorites_cache.load(project_root)
        local fav_set = {}
        for _, item in ipairs(favs) do
            if not item.is_folder then
                fav_set[unl_path.normalize(item.path)] = true
            end
        end

        local to_remove, to_add = {}, {}
        for _, path in ipairs(selected) do
            if fav_set[unl_path.normalize(path)] then
                table.insert(to_remove, path)
            else
                table.insert(to_add, path)
            end
        end

        -- 既登録分を一括削除
        local removed_count = 0
        for _, path in ipairs(to_remove) do
            favorites_cache.toggle(path, project_root)
            removed_count = removed_count + 1
        end
        if removed_count > 0 then
            logger.get().info(string.format("☆ Removed %d file(s) from Favorites", removed_count))
        end

        -- 未登録分はフォルダpicker経由で追加
        if #to_add > 0 then
            pick_folder_and_add(to_add, project_root, function(folder, count)
                if count > 0 then
                    logger.get().info(string.format("★ Added %d file(s) to '%s'", count, folder))
                end
                view_uproject.clear_selected()
                view_uproject.refresh(tree)
            end)
        else
            view_uproject.clear_selected()
            view_uproject.refresh(tree)
        end
        return
    end

    -- シングル
    local node = tree:get_node()
    if not node then return end

    local path = sanitize_path(node.path)
    if not path then return end

    -- 既にお気に入り登録済みなら削除
    local favorites = favorites_cache.load(project_root)
    local norm_path = unl_path.normalize(path)
    for _, item in ipairs(favorites) do
        if not item.is_folder and unl_path.normalize(item.path) == norm_path then
            local _, msg = favorites_cache.toggle(path, project_root)
            logger.get().info("☆ " .. msg .. ": " .. vim.fn.fnamemodify(path, ":t"))
            require("UNX.ui.view.uproject").refresh(tree)
            return
        end
    end

    -- 新規追加: フォルダ選択経由（シングルもマルチも同じパス）
    local fname = vim.fn.fnamemodify(path, ":t")
    pick_folder_and_add({ path }, project_root, function(folder, _)
        logger.get().info(string.format("★ Added '%s' to '%s'", fname, folder))
        require("UNX.ui.view.uproject").refresh(tree)
    end)
end

function M.find_files_recursive(tree)
    local node = tree:get_node()
    if not node then return end
    
    local target_dir = node.path
    if node.type == "file" then
        target_dir = vim.fn.fnamemodify(node.path, ":h")
    end
    target_dir = sanitize_path(target_dir)
    
    if not target_dir then return end

    local dir_name = vim.fn.fnamemodify(target_dir, ":t")
    -- ★修正
    logger.get().info("Fetching files under: " .. dir_name)

    local prefix = unl_path.normalize(target_dir)
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end

    -- Use UNL API instead of UEP provider
    require("UNL.api").db.search_files_by_path_part(dir_name, function(items)
        if not items then
            return logger.get().error("Failed to get file list from UNL Server.")
        end

        local filtered_items = {}
        for _, item in ipairs(items or {}) do
            local item_path = unl_path.normalize(item.path)
            -- Verify it's actually under the target directory
            if item_path:find(prefix, 1, true) == 1 then
                table.insert(filtered_items, {
                    display = item.filename or vim.fn.fnamemodify(item.path, ":t"),
                    value = item.path,
                    filename = item.path,
                })
            end
        end

        if #filtered_items == 0 then
            return logger.get().warn("No files found under " .. dir_name)
        end

        table.sort(filtered_items, function(a, b) return a.display < b.display end)

        unl_picker.open({
            kind = "unx_find_files_recursive",
            title = " Find in: " .. dir_name,
            items = filtered_items,
            conf = unx_config.get(),
            preview_enabled = true,
            devicons_enabled = true,
            on_submit = function(selection)
                if selection then
                    unl_buf_open.safe({ file_path = selection, open_cmd = "edit", plugin_name = "UNX" })
                end
            end,
        })
    end)
end

function M.copy_path(tree)
    local node = tree:get_node()
    if not node then return end

    local path = sanitize_path(node.path)
    if not path then return end

    -- forward slash 統一・連続スラッシュ正規化 (先頭 // UNC は保持)
    local abs = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
    abs = abs:gsub("(.)//+", "%1/")
    -- 末尾スラッシュ除去 (ディレクトリノードへの対応)
    if abs:len() > 3 and abs:sub(-1) == "/" then abs = abs:sub(1, -2) end

    vim.fn.setreg("+", abs)
    vim.fn.setreg('"', abs)
    logger.get().info("Copied path: " .. abs)
end

function M.open_in_ide(tree)
    local node = tree:get_node()
    if not node then return end
    
    local path = sanitize_path(node.path)
    if not path then return end
    
    -- ファイル以外のノード（ディレクトリなど）の場合、Unreal Editorで開けるかはUEPの実装依存
    -- とりあえずパスを渡してUEP側に任せる
    logger.get().info("Opening in Unreal Editor: " .. vim.fn.fnamemodify(path, ":t"))
    
    unl_api.provider.request("uep.open_in_ide", {
        file_path = path
    })
end

function M.refresh(tree)
    require("UNX.ui.view.uproject").refresh(tree)
end

return M

