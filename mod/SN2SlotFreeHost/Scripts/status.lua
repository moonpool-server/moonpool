-- status.json for the Discord card. Searching the whole object list on a timer stalls the world,
-- so lookups are cached. Players are kept as paths, never objects: a freed address is reused, IsValid
-- passes the new occupant and UE4SS.dll crashes. A base near a lifepod is the start area's ruin.

local M = {}

local CACHE_MAX_S = 600       -- re-search bases and the lifepods at most every 10 min
local BASE_GAP_UU = 5000      -- 50 m: pieces closer than this are one base
local POD_SKIP_UU = 8000      -- 80 m: pieces this close to a lifepod belong to it
local BASE_PREFIX = 'BP_BaseModule_'
local POD_PREFIX = 'BP_StaticLifepod_'

local SIGNAL_MAX = 100        -- the most PDA signals put in status.json
local SIGNAL_NAME_MAX = 60    -- characters of a signal's name kept

local cache = { players = nil, bases = nil, pods = nil, signal_store = nil, found_at = 0, map = nil,
  dirty = true, world_start = nil }

local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end

-- GetFullName() is "Class /Path"; StaticFindObject takes the path.
function M.path_of(full)
  if type(full) ~= 'string' then return nil end
  return full:match('^%S+%s+(.+)$') or full
end
function M.object_path(o)
  local full
  pcall(function() full = o:GetFullName() end)
  return M.path_of(full)
end


local function loc(actor)
  local x, y, z
  local ok = pcall(function()
    local v = actor.RootComponent.RelativeLocation
    x, y, z = v.X, v.Y, v.Z
  end)
  if not ok or not x then
    ok = pcall(function()
      local v = actor:K2_GetActorLocation()
      x, y, z = v.X, v.Y, v.Z
    end)
  end
  if not ok or not x then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

-- Mark the cache stale; called on a map load and when a PlayerState is created.
function M.invalidate() cache.dirty = true end

local function cluster(points)
  local groups = {}
  for _, p in ipairs(points) do
    local home
    for _, g in ipairs(groups) do
      local dx, dy, dz = p.x - g.cx, p.y - g.cy, p.z - g.cz
      if dx * dx + dy * dy + dz * dz < BASE_GAP_UU * BASE_GAP_UU then home = g; break end
    end
    if not home then
      home = { sx = 0, sy = 0, sz = 0, n = 0 }
      groups[#groups + 1] = home
    end
    home.sx, home.sy, home.sz, home.n = home.sx + p.x, home.sy + p.y, home.sz + p.z, home.n + 1
    home.cx, home.cy, home.cz = home.sx / home.n, home.sy / home.n, home.sz / home.n
  end
  local out = {}
  local i = 0
  for _, g in ipairs(groups) do
    i = i + 1
    out[#out + 1] = { name = string.format('Base %d (%d parts)', i, g.n),
      x = math.floor(g.cx + 0.5), y = math.floor(g.cy + 0.5), z = math.floor(g.cz + 0.5) }
  end
  return out
end

-- A level actor came with the map (RF_WasLoaded or bNetStartup); a player's build has neither.
local function level_actor(a)
  local yes, known = false, false
  pcall(function()
    if EObjectFlags and EObjectFlags.RF_WasLoaded then
      known = true
      yes = a:HasAnyFlags(EObjectFlags.RF_WasLoaded) and true or false
    end
  end)
  if not yes then
    pcall(function()
      local v = a.bNetStartup
      if v ~= nil then known = true; yes = yes or v == true end
    end)
  end
  if not known then return nil end
  return yes
end

local function near_pod(p, pods)
  for _, q in ipairs(pods) do
    local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
    if dx * dx + dy * dy + dz * dz < POD_SKIP_UU * POD_SKIP_UU then return true end
  end
  return false
end

local function guid_key(g)
  return string.format('%d:%d:%d:%d', g.A, g.B, g.C, g.D)
end

-- The PDA signals everyone sees, with their names and exact positions, read from the game's
-- signal store as plain properties. Signals hidden by default (story places not found yet, and
-- each player's own, such as the voice-range ones this mod adds) and in-game admin commands are
-- left out. It fails closed: no hidden list or no signal id read means nothing is listed.
-- A signal that follows something (a vehicle, a player) is marked tracked.
function M.signals(store, admin_prefix)
  local list = {}
  if not store then return list end
  local hidden = {}
  local read = pcall(function()
    store.DefaultHiddenPings:ForEach(function(_, g) hidden[guid_key(g:get())] = true end)
  end)
  if not read then return {} end
  local ok = pcall(function()
    store.ActivePings:ForEach(function(_, el)
      if #list >= SIGNAL_MAX then return end
      local p = el:get()
      local name, key, x, y, z, tracked
      pcall(function() name = p.DisplayName:ToString() end)
      pcall(function() key = guid_key(p.UniqueID) end)
      pcall(function() local l = p.Location; x, y, z = l.X, l.Y, l.Z end)
      pcall(function() tracked = p.bHasTrackingActor == true end)
      if key and not hidden[key] and type(name) == 'string' and name ~= '' and type(x) == 'number'
        and type(y) == 'number' and (admin_prefix == '' or name:sub(1, #admin_prefix) ~= admin_prefix) then
        list[#list + 1] = { name = name:sub(1, SIGNAL_NAME_MAX), x = math.floor(x + 0.5), y = math.floor(y + 0.5),
          z = math.floor((z or 0) + 0.5), tracked = tracked ~= false }
      end
    end)
  end)
  if not ok then return {} end
  return list
end

local function search(map_name)
  local players = {}
  for _, ps in ipairs(FindAllOf('PlayerState') or {}) do
    local path = valid(ps) and M.object_path(ps)
    if path then players[#players + 1] = path end
  end
  cache.players = players
  -- Bases and the lifepod: one actor pass, at most once per CACHE_MAX_S or map.
  if cache.map ~= map_name or os.time() - cache.found_at >= CACHE_MAX_S or not cache.bases then
    if cache.map ~= map_name then cache.world_start = nil end
    local first = cache.world_start == nil
    if first then cache.world_start = {} end
    local pieces, pods = {}, {}
    for _, a in ipairs(FindAllOf('Actor') or {}) do
      local cls, id
      pcall(function() cls = a:GetClass():GetFName():ToString() end)
      if cls then
        if cls:sub(1, #BASE_PREFIX) == BASE_PREFIX then
          pcall(function() id = a:GetFName():ToString() end)
          local level = level_actor(a)
          if level == nil and first then
            if id then cache.world_start[id] = true end
          elseif not level and id and not cache.world_start[id] then
            local p = loc(a)
            if p then pieces[#pieces + 1] = p end
          end
        elseif cls:sub(1, #POD_PREFIX) == POD_PREFIX then
          local p = loc(a)
          if p then
            p.kind = cls:find('Surface', 1, true) and 'surface' or 'underwater'
            p.depth_m = p.z < 0 and math.floor(-p.z / 100 + 0.5) or 0
            pods[#pods + 1] = p
          end
        end
      end
    end
    local built = {}
    for _, p in ipairs(pieces) do
      if not near_pod(p, pods) then built[#built + 1] = p end
    end
    for _, a in ipairs(FindAllOf('UWESculpturalBaseActor') or {}) do
      local cells = 0
      pcall(function() cells = a.TotalCells or 0 end)
      local p = cells > 0 and not level_actor(a) and loc(a)
      if p then built[#built + 1] = p end
    end
    -- The signal store is found here, once a refresh, and read again on every status write.
    cache.signal_store = M.object_path((FindAllOf('UWEPingSystemComponent') or {})[1])
    cache.bases, cache.pods, cache.found_at, cache.map = cluster(built), pods, os.time(), map_name
  end
  cache.dirty = false
end

local function player_entry(ps, to_str)
  local name, ping, pos
  pcall(function() name = to_str(ps:GetPlayerName()) end)
  if not name or name == '' then pcall(function() name = ps.PlayerNamePrivate:ToString() end) end
  -- ExactPing is not a reflected property in this engine version.
  pcall(function()
    local v = ps:GetPingInMilliseconds()
    if type(v) == 'number' and v == v then ping = math.floor(v + 0.5) end
  end)
  if not ping then pcall(function() ping = ps.CompressedPing * 4 end) end
  pcall(function()
    local pawn = ps.PawnPrivate
    if valid(pawn) then pos = loc(pawn) end
  end)
  local e = { name = name or '?', ping_ms = ping }
  if pos then
    e.x, e.y, e.z = pos.x, pos.y, pos.z
    -- Sea level taken as z = 0 (the surface lifepod floats at z ~ +235 uu).
    e.depth_m = pos.z < 0 and math.floor(-pos.z / 100 + 0.5) or 0
  end
  return e
end

-- The kept paths found again; the objects are good only inside the caller's callback.
local function players_now(map_name)
  if cache.dirty or not cache.players then search(map_name) end
  local found = {}
  for _, path in ipairs(cache.players) do
    local ok, ps = pcall(StaticFindObject, path)
    if ok and valid(ps) then found[#found + 1] = { ps = ps, path = path } else cache.dirty = true end
  end
  return found
end

-- live_players adds each live PlayerState and its path, for in-game policy; never in status.json.
function M.players(to_str, map_name, with_object)
  local list = {}
  for _, f in ipairs(players_now(map_name)) do
    list[#list + 1] = player_entry(f.ps, to_str)
    if with_object then list[#list].player, list[#list].path = f.ps, f.path end
  end
  return list
end
function M.live_players(to_str, map_name) return M.players(to_str, map_name, true) end

-- The whole status.json body.
function M.build(info, to_str)
  if cache.dirty or not cache.players or os.time() - cache.found_at >= CACHE_MAX_S
    or cache.map ~= info.map then
    search(info.map)
  end
  -- The game makes its signal store a little after a world loads, so a search that ran too early
  -- looks again here, at most once a minute, rather than waiting for the next refresh.
  if not cache.signal_store and os.time() - (cache.store_tried or 0) >= 60 then
    cache.store_tried = os.time()
    cache.signal_store = M.object_path((FindAllOf('UWEPingSystemComponent') or {})[1])
  end
  return {
    ts = os.time(),
    state = info.state,
    map = info.map,
    branch = info.branch,
    save = info.save,
    player_slots = info.player_slots,
    host_name = info.host_name,
    players = M.players(to_str, info.map),
    bases = cache.bases or {},
    lifepods = cache.pods or {},
    signals = M.signals(cache.signal_store and StaticFindObject(cache.signal_store),
      os.getenv('SN2_ADMIN_PREFIX') or '!'),
    day = nil, -- the in-game day is not read: no cheap source found yet
    time_of_day = info.time_of_day,
    day_fraction = info.day_fraction,
    weather = info.weather,
    weather_types = info.weather_types,
    cache_age_s = os.time() - cache.found_at,
  }
end

return M
