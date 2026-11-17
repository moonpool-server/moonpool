-- The map's squares that players stood in between two status writes. Positions are read often (with the
-- voice range check) but status.json is written every 30 s, so each reading adds the player's square to a
-- set and the status write takes the set and empties it. A player standing still adds nothing new.
-- Pure Lua: the caller passes the players it already read.
local M = {}

M.CELL_M = 50 -- the map's square; map-chart.py reads it from status.json and uses the batch only when it agrees
M.MAX = 2048 -- squares kept between two writes; past it, more are dropped until the next write
local UU_PER_M = 100
local ORIGIN_UU = 200 -- a player without a body (loading, respawning) reads as the world's origin

function M.new()
  return { seen = {}, n = 0 }
end

-- One reading: rows with name, x and y in game units; the host is skipped.
function M.add(t, rows, host)
  for _, r in ipairs(rows or {}) do
    local x, y = r.x, r.y
    if r.name ~= host and type(x) == 'number' and type(y) == 'number' and t.n < M.MAX
      and not (math.abs(x) < ORIGIN_UU and math.abs(y) < ORIGIN_UU) then
      local key = math.floor(x / (M.CELL_M * UU_PER_M)) .. ',' .. math.floor(y / (M.CELL_M * UU_PER_M))
      if not t.seen[key] then
        t.seen[key] = true
        t.n = t.n + 1
      end
    end
  end
end

-- The squares since the last call, as "x,y" keys in a stable order, and an empty set for the next batch.
function M.take(t)
  local out = {}
  for key in pairs(t.seen) do out[#out + 1] = key end
  table.sort(out)
  t.seen, t.n = {}, 0
  return out
end

return M
