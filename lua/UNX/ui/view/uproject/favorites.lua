-- lua/UNX/ui/view/uproject/favorites.lua

local Tree = require("nui.tree")
local unl_path = require("UNL.path")
local favorites_cache = require("UNX.cache.favorites")

local M = {}

M.ROOT_TYPE = "favorites_root"

-- Compute folder full path from a folder def (parent is already a full path in v2)
local function folder_full_path(f)
  if not f.parent then return f.name end
  return f.parent .. "/" .. f.name
end

local function sort_nodes(nodes)
  table.sort(nodes, function(a, b)
    local a_is_dir = a.type == "directory"
    local b_is_dir = b.type == "directory"
    if a_is_dir ~= b_is_dir then return a_is_dir end
    local a_base = vim.fn.fnamemodify(a.text, ":r"):lower()
    local b_base = vim.fn.fnamemodify(b.text, ":r"):lower()
    if a_base == b_base then return a.text:lower() < b.text:lower() end
    return a_base < b_base
  end)
end

function M.create_children_nodes(project_root)
  local favorites = favorites_cache.load(project_root)

  local folder_defs = {}
  -- items_by_folder keyed by full folder path (or "Default")
  local items_by_folder = {}

  for _, item in ipairs(favorites) do
    if item.is_folder then
      table.insert(folder_defs, item)
    else
      local key = item.folder or "Default"
      if not items_by_folder[key] then items_by_folder[key] = {} end
      table.insert(items_by_folder[key], item)
    end
  end

  -- Recursively build nodes.
  -- parent_full_path: nil = root level, string = full path of parent folder
  local function build_children(parent_full_path)
    local nodes = {}

    -- Sub-folders whose parent matches
    for _, f in ipairs(folder_defs) do
      if f.parent == parent_full_path then
        local f_full = folder_full_path(f)
        local f_children = build_children(f_full)
        table.insert(nodes, Tree.Node({
          text  = f.name,
          id    = "fav_folder_" .. f_full,
          type  = "directory",
          _has_children = #f_children > 0,
          extra = {
            uep_type         = "fs",
            is_favorite_folder = true,
            folder_full_path = f_full,
            project_root     = project_root,
          },
        }, f_children))
      end
    end

    -- Items belonging to this folder
    local key = parent_full_path or "Default"
    if items_by_folder[key] then
      for _, item in ipairs(items_by_folder[key]) do
        local is_dir = vim.fn.isdirectory(item.path) == 1
        table.insert(nodes, Tree.Node({
          text  = item.name,
          id    = "fav_item_" .. unl_path.normalize(item.path),
          path  = item.path,
          type  = is_dir and "directory" or "file",
          extra = { uep_type = "fs", is_favorite_item = true, project_root = project_root },
        }))
      end
    end

    sort_nodes(nodes)
    return nodes
  end

  -- Root level: parent_full_path = nil → items in "Default" + top-level folders
  local root_nodes = build_children(nil)

  -- Items explicitly in "Default" that weren't caught by build_children(nil)
  -- (build_children(nil) already uses key="Default" so this handles them)

  sort_nodes(root_nodes)
  return root_nodes
end

function M.create_root_node(is_expanded, project_root, children)
    local favorites = favorites_cache.load(project_root)
    
    if #favorites == 0 then 
        return nil 
    end

    local final_children = children
    if is_expanded and not final_children then
        final_children = M.create_children_nodes(project_root)
    end

    local node = Tree.Node({
        text = "Favorites",
        id = "root_favorites",
        type = "directory",
        _has_children = true,
        extra = {
            uep_type = M.ROOT_TYPE,
            project_root = project_root
        },
        -- is_expanded = is_expanded -- REMOVED: Do not override method
    }, final_children)

    if is_expanded then
        node:expand()
    end
    
    return node
end

return M
