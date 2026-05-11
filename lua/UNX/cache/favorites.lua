-- lua/UNX/cache/favorites.lua
local unx_config = require("UNX.config")
local unl_cache_core = require("UNL.cache.core")
local fs = require("vim.fs")
local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")

local M = {}

local CACHE_FILENAME_SUFFIX = "_favorites.json"
local FORMAT_VERSION = 2

-- ──────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ──────────────────────────────────────────────────────────────────────────────

local function get_cache_path(project_root)
  project_root = project_root or unl_finder.project.find_project_root(vim.loop.cwd())
  if not project_root then return nil end
  local safe_project_name = unl_path.normalize(project_root):gsub("[\\/:]", "_")
  local conf = unx_config.get()
  local base_dir = unl_cache_core.get_cache_dir(conf)
  if not base_dir then return nil end
  return fs.joinpath(base_dir, safe_project_name .. CACHE_FILENAME_SUFFIX)
end

-- Compute full path = parent_full_path + "/" + name  (nil parent → root)
local function folder_full_path(f)
  if not f.parent then return f.name end
  return f.parent .. "/" .. f.name
end

-- Migrate v1 data (parent/folder as short names) → v2 (full paths).
-- In v1: folder.parent = short name of parent folder
--        item.folder   = short name of containing folder
-- In v2: folder.parent = full path of parent folder (nil = root)
--        item.folder   = full path of containing folder (or "Default")
local function migrate_v1(items)
  local folder_defs = {}
  for _, item in ipairs(items) do
    if item.is_folder then table.insert(folder_defs, item) end
  end

  -- Resolve short name → full path using the v1 parent chain.
  -- If duplicate names exist the first match is used (best-effort for legacy data).
  local resolved = {}
  local function resolve(name)
    if not name or name == "Default" then return nil end
    if resolved[name] then return resolved[name] end
    for _, f in ipairs(folder_defs) do
      if f.name == name then
        local parent_path = resolve(f.parent)
        local full = parent_path and (parent_path .. "/" .. f.name) or f.name
        resolved[name] = full
        return full
      end
    end
    return name
  end

  local migrated = {}
  for _, item in ipairs(items) do
    local new_item = vim.deepcopy(item)
    if item.is_folder then
      new_item.parent = resolve(item.parent)
    else
      if item.folder and item.folder ~= "Default" then
        new_item.folder = resolve(item.folder) or "Default"
      end
    end
    table.insert(migrated, new_item)
  end
  return migrated
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Load / Save
-- ──────────────────────────────────────────────────────────────────────────────

function M.load(project_root)
  local path = get_cache_path(project_root)
  if not path or vim.fn.filereadable(path) == 0 then return {} end
  local raw = unl_cache_core.load_json(path)
  if not raw then return {} end

  -- v2: { _v = 2, items = [...] }
  if raw._v == FORMAT_VERSION then
    return raw.items or {}
  end

  -- v1: plain array → migrate and re-save as v2
  local v1_items = {}
  for _, v in ipairs(raw) do table.insert(v1_items, v) end
  local migrated = migrate_v1(v1_items)
  M.save(migrated, project_root)
  return migrated
end

function M.save(data, project_root)
  local path = get_cache_path(project_root)
  if not path then return false end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  return unl_cache_core.save_json(path, { _v = FORMAT_VERSION, items = data })
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public API
-- ──────────────────────────────────────────────────────────────────────────────

--- Toggle a file/directory in favorites.
--- @param target_path       string   absolute path to toggle
--- @param project_root      string?
--- @param folder_full_path_ string?  full path of destination folder (or "Default")
function M.toggle(target_path, project_root, folder_full_path_)
  if not target_path or target_path == "" then return false, "Invalid path" end
  local favorites = M.load(project_root)
  local norm_target = unl_path.normalize(target_path)

  for i, item in ipairs(favorites) do
    if not item.is_folder and unl_path.normalize(item.path) == norm_target then
      table.remove(favorites, i)
      M.save(favorites, project_root)
      return false, "Removed from Favorites"
    end
  end

  table.insert(favorites, {
    path     = target_path,
    name     = vim.fn.fnamemodify(target_path, ":t"),
    folder   = folder_full_path_ or "Default",
    added_at = os.time(),
  })
  M.save(favorites, project_root)
  return true, "Added to Favorites"
end

--- Create a new favorite folder.
--- @param folder_name      string   short display name for the new folder
--- @param project_root     string?
--- @param parent_full_path string?  full path of parent folder (nil = root)
function M.add_folder(folder_name, project_root, parent_full_path)
  if not folder_name or folder_name == "" then return false end
  local favorites = M.load(project_root)

  -- Duplicate check: same name under the same parent
  for _, item in ipairs(favorites) do
    if item.is_folder and item.name == folder_name and item.parent == parent_full_path then
      return false, "Folder already exists in this location"
    end
  end

  table.insert(favorites, {
    is_folder = true,
    name      = folder_name,
    parent    = parent_full_path,  -- full path of parent, or nil for root
    added_at  = os.time(),
  })
  M.save(favorites, project_root)
  return true
end

--- Remove a favorite folder (children are reparented, items go to parent).
--- @param old_full_path string  full path of folder to remove (e.g. "Root/B/A")
--- @param project_root  string?
function M.remove_folder(old_full_path, project_root)
  local favorites = M.load(project_root)

  -- Find the parent of the folder being deleted
  local target_parent = nil
  for _, item in ipairs(favorites) do
    if item.is_folder and folder_full_path(item) == old_full_path then
      target_parent = item.parent
      break
    end
  end

  local new_list = {}
  for _, item in ipairs(favorites) do
    if item.is_folder and folder_full_path(item) == old_full_path then
      -- Drop this folder
    else
      local new_item = vim.deepcopy(item)
      if item.is_folder then
        -- Reparent direct children of the deleted folder
        if item.parent == old_full_path then
          new_item.parent = target_parent
        end
      else
        -- Move items in deleted folder up to its parent
        if item.folder == old_full_path then
          new_item.folder = target_parent or "Default"
        end
      end
      table.insert(new_list, new_item)
    end
  end
  M.save(new_list, project_root)
end

--- Rename a favorite folder in-place (updates all descendant parent paths).
--- @param old_full_path string  current full path (e.g. "Root/B/A")
--- @param new_name      string  new short name for the folder
--- @param project_root  string?
function M.rename_folder(old_full_path, new_name, project_root)
  if not new_name or new_name == "" or old_full_path == new_name then return false end
  local favorites = M.load(project_root)

  -- Determine the new full path
  local parent_path = nil
  for _, item in ipairs(favorites) do
    if item.is_folder and folder_full_path(item) == old_full_path then
      parent_path = item.parent
      break
    end
  end
  local new_full_path = parent_path and (parent_path .. "/" .. new_name) or new_name

  local prefix_old = old_full_path .. "/"
  local prefix_new = new_full_path .. "/"

  for _, item in ipairs(favorites) do
    if item.is_folder then
      if folder_full_path(item) == old_full_path then
        item.name = new_name
        -- item.parent stays the same
      elseif item.parent == old_full_path then
        item.parent = new_full_path
      elseif item.parent and item.parent:sub(1, #prefix_old) == prefix_old then
        item.parent = prefix_new .. item.parent:sub(#prefix_old + 1)
      end
    else
      if item.folder == old_full_path then
        item.folder = new_full_path
      elseif item.folder and item.folder:sub(1, #prefix_old) == prefix_old then
        item.folder = prefix_new .. item.folder:sub(#prefix_old + 1)
      end
    end
  end

  M.save(favorites, project_root)
  return true
end

--- Move an item or folder to a different folder.
--- @param target           string   full path for folders; absolute path for items
--- @param dest_full_path   string   full path of destination folder, or "Default"
--- @param project_root     string?
--- @param is_target_folder boolean
function M.move_to_folder(target, dest_full_path, project_root, is_target_folder)
  local favorites = M.load(project_root)
  local dest = (dest_full_path == "Default") and "Default" or dest_full_path

  if is_target_folder then
    if target == dest_full_path then return end
    for _, item in ipairs(favorites) do
      if item.is_folder and folder_full_path(item) == target then
        item.parent = (dest == "Default") and nil or dest
        break
      end
    end
  else
    local norm_target = unl_path.normalize(target)
    for _, item in ipairs(favorites) do
      if not item.is_folder and unl_path.normalize(item.path) == norm_target then
        item.folder = dest
        break
      end
    end
  end
  M.save(favorites, project_root)
end

--- Returns all folder full-paths, including "Default", sorted.
function M.get_folders(project_root)
  local favorites = M.load(project_root)
  local paths = { "Default" }
  for _, item in ipairs(favorites) do
    if item.is_folder then
      table.insert(paths, folder_full_path(item))
    end
  end
  table.sort(paths, function(a, b)
    if a == "Default" then return true end
    if b == "Default" then return false end
    return a:lower() < b:lower()
  end)
  return paths
end

return M
