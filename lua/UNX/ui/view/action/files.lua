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
                -- ★修正
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
                -- ★修正
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

function M.toggle_favorite(tree)
    local node = tree:get_node()
    if not node then return end
    
    local path = sanitize_path(node.path)
    if not path then return end
    
    local ctx = require("UNX.context.uproject").get()
    local project_root = ctx.project_root or require("UNL.finder").project.find_project_root(vim.loop.cwd())
    
    -- Check if already a favorite (for direct removal)
    local favorites = favorites_cache.load(project_root)
    local is_already_fav = false
    local norm_path = unl_path.normalize(path)
    for _, item in ipairs(favorites) do
        if not item.is_folder and unl_path.normalize(item.path) == norm_path then
            is_already_fav = true
            break
        end
    end

    if is_already_fav then
        local _, msg = favorites_cache.toggle(path, project_root)
        logger.get().info("☆ " .. msg .. ": " .. vim.fn.fnamemodify(path, ":t"))
        require("UNX.ui.view.uproject").refresh(tree)
        return
    end

    -- Adding new favorite: check for folders
    local folders = favorites_cache.get_folders(project_root)
    if #folders <= 1 then
        -- Only "Default" exists, add directly
        local added, msg = favorites_cache.toggle(path, project_root, "Default")
        local icon = added and "★ " or "☆ "
        logger.get().info(icon .. msg .. ": " .. vim.fn.fnamemodify(path, ":t"))
        require("UNX.ui.view.uproject").refresh(tree)
    else
        -- Use UNL picker to select folder
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
                if selection then
                    local choice_path = selection
                    local parts = vim.split(choice_path, "/", { plain = true })
                    local choice = parts[#parts] -- 最後の名前を取得

                    local added, msg = favorites_cache.toggle(path, project_root, choice)
                    local icon = added and "★ " or "☆ "
                    logger.get().info(icon .. msg .. " (" .. choice_path .. "): " .. vim.fn.fnamemodify(path, ":t"))
                    require("UNX.ui.view.uproject").refresh(tree)
                end
            end,
        })
    end
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
                    unl_buf_open.safe({ file_path = selection.value, open_cmd = "edit", plugin_name = "UNX" })
                end
            end,
        })
    end)
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

