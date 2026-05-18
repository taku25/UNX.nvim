-- lua/UNX/ui/view/action/pair.lua
-- .h ↔ .cpp ペアファイルへのツリーカーソル移動 (UCM の resolve_class_pair を利用)

local logger = require("UNX.logger")

local M = {}

function M.goto_pair(tree)
    local node = tree:get_node()
    if not node or not node.path or node.type == "directory" then return end

    local ok, ucm_core = pcall(require, "UCM.cmd.core")
    if not ok then
        logger.get().warn("UCM is required for pair navigation.")
        return
    end

    ucm_core.resolve_class_pair(node.path, function(class_info, err)
        if not class_info then
            logger.get().warn(err or "Pair file not found.")
            return
        end

        local target
        if class_info.is_header_input then
            target = class_info.cpp
        else
            target = class_info.h
        end
        if not target then
            logger.get().warn("Pair file does not exist: " .. class_info.class_name)
            return
        end

        vim.schedule(function()
            require("UNX.ui.explorer").focus(target)
        end)
    end)
end

return M
