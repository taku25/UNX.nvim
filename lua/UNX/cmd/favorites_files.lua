local unl_picker = require("UNL.picker")
local favorites_cache = require("UNX.cache.favorites")
local unx_config = require("UNX.config")
local unl_buf_open = require("UNL.buf.open")
local unl_path = require("UNL.path")
local unl_api = require("UNL.api")
local unl_finder = require("UNL.finder") -- ルート判定用に追加

local M = {}

function M.execute(opts)
  local favorites = favorites_cache.load()
  if #favorites == 0 then
    return vim.notify("No favorites found. Use :UNX add_favorites to add some.", vim.log.levels.WARN)
  end

  -- vim.notify("Building favorites file list...", vim.log.levels.INFO)

  -- 1. 検索スコープの自動最適化
  -- お気に入りの中に「エンジン側のファイル」が含まれているかチェック
  local cwd = vim.loop.cwd()
  local project_info = unl_finder.project.find_project(cwd)
  local engine_root = nil
  if project_info then
      engine_root = unl_finder.engine.find_engine_root(project_info.uproject, { 
          engine_override_path = unx_config.get().engine_path 
      })
  end

  local request_scope = "game" -- デフォルトはゲームのみ（高速）
  local target_dirs = {}
  local target_files = {} 

  for _, item in ipairs(favorites) do
    -- 仮想フォルダ（パネル整理用グループ）はpathを持たないのでスキップ
    if item.is_folder or not item.path then goto continue end

    local norm_path = unl_path.normalize(item.path)
    
    -- エンジンフォルダが含まれていたら、スコープを "full" に広げる
    if engine_root then
        local norm_engine = unl_path.normalize(engine_root)
        if norm_path:find(norm_engine, 1, true) then
            request_scope = "full"
        end
    end

    if vim.fn.isdirectory(item.path) == 1 then
      if norm_path:sub(-1) ~= "/" then norm_path = norm_path .. "/" end
      table.insert(target_dirs, norm_path)
    else
      target_files[norm_path] = true
    end

    ::continue::
  end

  -- 最適化されたスコープでログ出し
  -- vim.notify("Scope optimized to: " .. request_scope, vim.log.levels.INFO)

  -- 2. UEPからファイルを取得 (範囲を絞って高速化)
  unl_api.provider.request("uep.get_project_items", { 
      scope = request_scope,
      deps_flag = "--deep-deps"
  }, function(ok, items)
      if not ok or not items then
          return vim.notify("Failed to get file list from UEP.", vim.log.levels.ERROR)
      end

      local filtered_items = {}
      
      -- 3. 高速フィルタリング
      for _, item in ipairs(items) do
          if item.type ~= "directory" then
              local item_path = unl_path.normalize(item.path)
              local match = false

              if target_files[item_path] then
                  match = true
              else
                  for _, dir_prefix in ipairs(target_dirs) do
                      if item_path:find(dir_prefix, 1, true) == 1 then
                          match = true
                          break
                      end
                  end
              end

              if match then
                  table.insert(filtered_items, {
                      display = item.display,
                      value = item.path,
                      filename = item.path,
                  })
              end
          end
      end

      if #filtered_items == 0 then
          return vim.notify("No files found within your favorite locations.", vim.log.levels.WARN)
      end

      table.sort(filtered_items, function(a, b) return a.display < b.display end)

      unl_picker.open({
        kind = "unx_favorites_all",
        title = "Favorites (All Files)",
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

return M

