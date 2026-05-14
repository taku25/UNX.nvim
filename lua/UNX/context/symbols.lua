-- lua/UNX/context/symbols.lua
local M = {}

local unl_context
local NS = "UNX"
local GROUP_KEY = "view_symbols"
local DATA_KEY = "state"

local default_state = {
    last_bufnr = nil,
    auto_update = true,
    filter_mode = "all",
    class_name = "",
    show_parents = false,
    show_hierarchy = false, -- クラス階層ビューモード
}

local function get_store_handle()
    if not unl_context then
        local ok, mod = pcall(require, "UNL.context")
        if ok then
            unl_context = mod
        else
            return nil
        end
    end
    return unl_context.use(NS):key(GROUP_KEY)
end

function M.get()
    local handle = get_store_handle()
    if not handle or type(handle.get) ~= "function" then
        return vim.deepcopy(default_state)
    end

    local data = handle:get(DATA_KEY)
    if not data then
        data = vim.deepcopy(default_state)
        handle:set(DATA_KEY, data)
    end
    
    if data.show_parents == nil then
        data.show_parents = false
    end
    if data.show_hierarchy == nil then
        data.show_hierarchy = false
    end

    return data
end

function M.set(data)
    local handle = get_store_handle()
    if handle and type(handle.set) == "function" then
        local clean_data = {
            last_bufnr = data.last_bufnr,
            auto_update = data.auto_update,
            filter_mode = data.filter_mode,
            class_name = data.class_name,
            show_parents = data.show_parents,
            show_hierarchy = data.show_hierarchy,
        }
        handle:set(DATA_KEY, clean_data)
    end
end

return M
