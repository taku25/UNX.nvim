local unl_picker = require("UNL.picker")
local favorites_cache = require("UNX.cache.favorites")
local unx_config = require("UNX.config")
local unl_buf_open = require("UNL.buf.open")
local unl_path = require("UNL.path")
local unl_db = require("UNL.db.remote")

local M = {}

function M.execute(opts)
  local favorites = favorites_cache.load()
  if #favorites == 0 then
    return vim.notify("No favorites found. Use :UNX add_favorites to add some.", vim.log.levels.WARN)
  end

  -- お気に入りを dirs（ディレクトリ）と exact_files（個別ファイル）に分類
  local dirs = {}
  local exact_files = {}

  for _, item in ipairs(favorites) do
    if item.is_folder or not item.path then goto continue end

    local norm = unl_path.normalize(item.path)

    if vim.fn.isdirectory(item.path) == 1 then
      -- ディレクトリ: 末尾 '/' を保証してプレフィックスマッチ用に追加
      if norm:sub(-1) ~= "/" then norm = norm .. "/" end
      table.insert(dirs, norm)
    else
      table.insert(exact_files, norm)
    end

    ::continue::
  end

  if #dirs == 0 and #exact_files == 0 then
    return vim.notify("No valid favorite paths found.", vim.log.levels.WARN)
  end

  -- Rust 側の cpp.db にパスリストを渡して直接フィルタリング（全件取得を回避）
  unl_db.get_files_in_favorite_paths(dirs, exact_files, function(items)
    if not items or #items == 0 then
      return vim.notify("No files found within your favorite locations.", vim.log.levels.WARN)
    end

    local picker_items = {}
    for _, item in ipairs(items) do
      table.insert(picker_items, {
        display  = item.filename,
        value    = item.path,
        filename = item.path,
      })
    end

    unl_picker.open({
      kind             = "unx_favorites_all",
      title            = "Favorites (All Files)",
      items            = picker_items,
      conf             = unx_config.get(),
      preview_enabled  = true,
      devicons_enabled = true,

      on_submit = function(selection)
        if selection then
          unl_buf_open.safe({ file_path = selection.value, open_cmd = "edit", plugin_name = "UNX" })
        end
      end,
    })
  end)
end

return M

