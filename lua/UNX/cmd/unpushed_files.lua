local unl_picker = require("UNL.picker")
local unx_config = require("UNX.config")
local unl_buf_open = require("UNL.buf.open")
local unl_finder = require("UNL.finder")
local unl_path = require("UNL.path")
local unx_vcs = require("UNX.vcs")

local M = {}

local function get_relative_path(full_path, project_root)
    local norm_path = unl_path.normalize(full_path)
    if project_root then
        local p_root = unl_path.normalize(project_root)
        if norm_path:find(p_root, 1, true) == 1 then
            return norm_path:sub(#p_root + 2)
        end
    end
    return norm_path
end

function M.execute(opts)
  local cwd = vim.loop.cwd()
  local project_root = unl_finder.project.find_project_root(cwd)
  local conf = unx_config.get()

  if not project_root then
      return vim.notify("Not in a project root.", vim.log.levels.WARN)
  end

  -- ★変更: 実行時にVCS情報をリフレッシュする
  unx_vcs.refresh(project_root, function()
      -- コールバック内で最新データを取得
      local unpushed = unx_vcs.get_aggregated_unpushed()

      if #unpushed == 0 then
        return vim.notify("No unpushed commits found.", vim.log.levels.INFO)
      end

      local picker_items = {}
      local seen = {}

      for _, item in ipairs(unpushed) do
        if not seen[item.path] then
            local icon = ""
            local relative_path = get_relative_path(item.path, project_root)
            
            table.insert(picker_items, {
                display = icon .. " " .. relative_path,
                value = item.path,
                filename = item.path,
            })
            seen[item.path] = true
        end
      end

      unl_picker.open({
        kind = "unx_unpushed_files",
        title = "Unpushed Files",
        items = picker_items,
        conf = conf,
        preview_enabled = true,
        on_submit = function(selection)
          if selection then
            unl_buf_open.safe({ file_path = selection, open_cmd = "edit", plugin_name = "UNX" })
          end
        end,
      })
  end)
end

return M

