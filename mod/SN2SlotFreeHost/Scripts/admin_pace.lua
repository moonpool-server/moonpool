-- The in-game admin queue, paced: one command per gap, so a burst of "!" signals cannot stall the
-- server again and again in a row (each console command can stall it for a second or two). Bounded
-- in total and per sender, because the admin check happens when an item runs: without a per-sender
-- cap, anyone could fill the queue and hold real admins back. Pure Lua, no game calls.
local M = {}

M.MAX_QUEUED = 20
M.MAX_PER_SENDER = 3

function M.new(gap_s)
  return { items = {}, gap_s = gap_s or 0, last_run = nil }
end

-- Adds ITEM for sender KEY. Returns true, or false and 'queue_full' or 'sender_busy'.
function M.push(q, item, key)
  if #q.items >= M.MAX_QUEUED then return false, 'queue_full' end
  local mine = 0
  for _, it in ipairs(q.items) do
    if it.key == key then mine = mine + 1 end
  end
  if mine >= M.MAX_PER_SENDER then return false, 'sender_busy' end
  q.items[#q.items + 1] = { key = key, item = item }
  return true
end

-- The next item to try at NOW, or nil while the queue is empty or the gap since the last command
-- that ran is not over. The gap starts only at mark(): an item that turned out to need nothing run
-- (a signal from someone who is not an admin) does not hold the next one back.
function M.take(q, now)
  if #q.items == 0 then return nil end
  if q.last_run and now - q.last_run < q.gap_s then return nil end
  return table.remove(q.items, 1).item
end

-- A command ran at NOW: the next waits a full gap.
function M.mark(q, now) q.last_run = now end

function M.size(q) return #q.items end

return M
