-- lua/UNX/ui/view/action/favorites.lua
local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local favorites_cache = require("UNX.cache.favorites")
local ctx_uproject = require("UNX.context.uproject")

local unl_picker = require("UNL.picker")
local unx_config = require("UNX.config")

local M = {}

local function refresh()
  local explorer_ui = require("UNX.ui.explorer")
  explorer_ui.refresh()
end

function M.add_folder(tree)
  local node = tree:get_node()
  -- Use full path from extra; nil = root
  local parent_full_path = nil
  if node and node.extra and node.extra.is_favorite_folder then
    parent_full_path = node.extra.folder_full_path
  end

  local ctx = ctx_uproject.get()
  local project_root = ctx.project_root
  if not project_root then return end

  local title = parent_full_path and ("[ New Folder under " .. parent_full_path .. " ]") or "[ New Favorite Folder ]"

  local input = Input({
    position = "50%",
    size = { width = 40 },
    border = { style = "rounded", text = { top = title, top_align = "center" } },
    win_options = { winblend = 10, winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    prompt = " Name: ",
    default_value = "",
    on_close = function() end,
    on_submit = function(value)
      if value and value ~= "" then
        local success, err = favorites_cache.add_folder(value, project_root, parent_full_path)
        if success then
          vim.notify(string.format("Created favorite folder: %s", value), vim.log.levels.INFO)
          refresh()
        else
          vim.notify(err or "Failed to create folder", vim.log.levels.ERROR)
        end
      end
    end,
  })

  input:mount()
  input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
end

function M.move_item(tree)
  local ctx = ctx_uproject.get()
  local project_root = ctx.project_root
  if not project_root then return end

  local view_uproject = require("UNX.ui.view.uproject")
  local selected = view_uproject.get_selected_list()

  -- Multi-select: move all selected items to a chosen folder
  if #selected > 0 then
    local folders = favorites_cache.get_folders(project_root)
    local items = {}
    for _, f in ipairs(folders) do
      table.insert(items, { label = f, value = f })
    end

    unl_picker.open({
      kind = "unx_favorites_move",
      title = string.format("Move %d item(s) to folder", #selected),
      items = items,
      conf = unx_config.get(),
      preview_enabled = false,
      on_submit = function(selection)
        if selection then
          for _, path in ipairs(selected) do
            -- selected contains absolute file paths
            favorites_cache.move_to_folder(path, selection, project_root, false)
          end
          vim.notify(string.format("Moved %d item(s) to %s", #selected, selection), vim.log.levels.INFO)
          view_uproject.clear_selected()
          refresh()
        end
      end,
    })
    return
  end

  -- Single node
  local node = tree:get_node()
  if not node or not node.extra or (not node.extra.is_favorite_item and not node.extra.is_favorite_folder) then
    return vim.notify("Select a favorite item or folder to move", vim.log.levels.WARN)
  end

  local node_full_path = node.extra.folder_full_path  -- for folders
  local folders = favorites_cache.get_folders(project_root)
  local items = {}
  for _, f in ipairs(folders) do
    -- Cannot move a folder into itself
    if not (node.extra.is_favorite_folder and f == node_full_path) then
      table.insert(items, { label = f, value = f })
    end
  end

  unl_picker.open({
    kind = "unx_favorites_move",
    title = string.format("Move '%s' to folder", node.text),
    items = items,
    conf = unx_config.get(),
    preview_enabled = false,
    on_submit = function(selection)
      if selection then
        -- For folders use folder_full_path; for items use absolute path
        local target = node.extra.is_favorite_folder and node_full_path or node.path
        favorites_cache.move_to_folder(target, selection, project_root, node.extra.is_favorite_folder)
        vim.notify(string.format("Moved %s to %s", node.text, selection), vim.log.levels.INFO)
        refresh()
      end
    end,
  })
end

function M.remove_folder(tree)
  local node = tree:get_node()
  if not node or not node.extra or not node.extra.is_favorite_folder then
    return vim.notify("Select a favorite folder to remove", vim.log.levels.WARN)
  end

  local ctx = ctx_uproject.get()
  local project_root = ctx.project_root
  if not project_root then return end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Remove folder '%s'? (Items will be moved to parent)", node.text),
  }, function(choice)
    if choice == "Yes" then
      favorites_cache.remove_folder(node.extra.folder_full_path, project_root)
      refresh()
    end
  end)
end

function M.rename_folder(tree)
  local node = tree:get_node()
  if not node or not node.extra or not node.extra.is_favorite_folder then
    return vim.notify("Select a favorite folder to rename", vim.log.levels.WARN)
  end
  if node.text == "Default" then
    return vim.notify("Cannot rename the Default folder", vim.log.levels.WARN)
  end

  local ctx = ctx_uproject.get()
  local project_root = ctx.project_root
  if not project_root then return end

  local input = Input({
    position = "50%",
    size = { width = 40 },
    border = { style = "rounded", text = { top = "[ Rename Favorite Folder ]", top_align = "center" } },
    win_options = { winblend = 10, winhighlight = "Normal:Normal,FloatBorder:FloatBorder" },
  }, {
    prompt = " New Name: ",
    default_value = node.text,
    on_close = function() end,
    on_submit = function(value)
      if value and value ~= "" and value ~= node.text then
        local success = favorites_cache.rename_folder(node.extra.folder_full_path, value, project_root)
        if success then
          vim.notify(string.format("Renamed: %s → %s", node.text, value), vim.log.levels.INFO)
          refresh()
        end
      end
    end,
  })

  input:mount()
  input:map("n", "<Esc>", function() input:unmount() end, { noremap = true })
end

return M
