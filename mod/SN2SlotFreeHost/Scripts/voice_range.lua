-- voice_range.lua: pure policy for private out-of-range voice signals.
-- The game-facing ping store is injected, so distance, hysteresis, movement and
-- leave cleanup are covered without UE4SS in tests/lua/voice_range_spec.lua.
local M = {}

M.DEFAULT_RANGE_M = 100 -- provisional until the public build's cutoff is measured live
M.DEFAULT_HYSTERESIS_M = 10
M.AMBER = { R = 1.0, G = 0.55, B = 0.10, A = 1.0 }

local function finite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function usable(p, host)
  return type(p) == 'table' and type(p.name) == 'string' and p.name ~= '' and p.name ~= '?'
    and p.name ~= host and finite(p.x) and finite(p.y) and finite(p.z)
end

local function distance_m(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

function M.new(opts)
  opts = opts or {}
  local range = tonumber(opts.range_m) or M.DEFAULT_RANGE_M
  local hysteresis = tonumber(opts.hysteresis_m) or M.DEFAULT_HYSTERESIS_M
  if range <= 0 then range = M.DEFAULT_RANGE_M end
  if hysteresis < 0 then hysteresis = 0 end
  if hysteresis >= range then hysteresis = range / 2 end
  return { range_m = range, restore_m = range - hysteresis,
    host = opts.host or 'SN2 Host', signals = {} }
end

local function key(listener, target) return listener.name .. '\0' .. target.name end

-- store:add(listener, target, label, position, color) -> opaque handle or nil
-- store:move(handle, position), store:remove(handle). Positions remain in cm,
-- matching the game and status.json; only the distance comparison converts to m.
function M.update(state, players, store)
  local present, list = {}, {}
  for _, p in ipairs(players or {}) do
    if usable(p, state.host) and not present[p.name] then
      present[p.name] = p
      list[#list + 1] = p
    end
  end

  local wanted = {}
  for i = 1, #list do
    for j = i + 1, #list do
      local a, b = list[i], list[j]
      local d = distance_m(a, b)
      for _, pair in ipairs({ { a, b }, { b, a } }) do
        local listener, target = pair[1], pair[2]
        local k = key(listener, target)
        local old = state.signals[k]
        local out = old and d > state.restore_m or d > state.range_m
        if out then
          wanted[k] = true
          if old then
            store:move(old.handle, { x = target.x, y = target.y, z = target.z })
          else
            local handle = store:add(listener, target, target.name .. ' · out of voice range',
              { x = target.x, y = target.y, z = target.z }, M.AMBER, target.player)
            if handle ~= nil then state.signals[k] = { handle = handle } end
          end
        end
      end
    end
  end

  for k, signal in pairs(state.signals) do
    if not wanted[k] then
      store:remove(signal.handle)
      state.signals[k] = nil
    end
  end
end

function M.clear(state, store)
  for k, signal in pairs(state.signals) do
    store:remove(signal.handle)
    state.signals[k] = nil
  end
end

return M
