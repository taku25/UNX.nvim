--- lua/UNX/ui/view/uproject/history.lua
--- Explorer 内でカーソルが移動した際のノード ID 履歴を管理する。
--- <BS> キーで前のノードに戻れるようにする (ブラウザの「戻る」に相当)。

local M = {}

-- ノード ID の履歴スタック。エクスプローラーのバッファごとに独立させる。
-- bufnr → string[] (node_id の配列、末尾が最新)
local histories = {}
local MAX_HISTORY = 50

--- 履歴にノード ID をプッシュする。
--- 連続する同一 ID は記録しない。
--- @param bufnr integer
--- @param node_id string
function M.push(bufnr, node_id)
  if not node_id or node_id == "" then return end
  local h = histories[bufnr]
  if not h then
    histories[bufnr] = { node_id }
    return
  end
  -- 直前と同じなら追加しない
  if h[#h] == node_id then return end
  table.insert(h, node_id)
  -- 最大サイズを超えたら先頭を削除
  if #h > MAX_HISTORY then table.remove(h, 1) end
end

--- 前のノード ID をポップして返す。現在のノード ID を渡すことで、
--- 現在と同じエントリをスキップする。
--- @param bufnr integer
--- @param current_node_id string|nil
--- @return string|nil 戻る先のノード ID、なければ nil
function M.pop(bufnr, current_node_id)
  local h = histories[bufnr]
  if not h or #h == 0 then return nil end
  -- 末尾が現在ノードと同じならそれを削除してから取得
  if h[#h] == current_node_id then
    table.remove(h)
  end
  if #h == 0 then return nil end
  local prev = table.remove(h)
  return prev
end

--- バッファの履歴をクリアする (バッファ削除時など)。
--- @param bufnr integer
function M.clear(bufnr)
  histories[bufnr] = nil
end

--- 履歴の長さを返す。
--- @param bufnr integer
--- @return integer
function M.length(bufnr)
  local h = histories[bufnr]
  return h and #h or 0
end

return M
