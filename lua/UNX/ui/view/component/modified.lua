local utils = require("UNX.common.utils")
local unl_path = require("UNL.path")

return function(node, context, config)
    if not node.path then return nil end
    
    local path = unl_path.normalize(node.path)
    local opened = utils.get_opened_buffers_status()
    
    if path and opened[path] and opened[path].modified then
        local icon = config.icons.uproject.modified or "[+] "
        return { text = icon, highlight = "UNXModifiedIcon" }
    end
    
    return nil
end
