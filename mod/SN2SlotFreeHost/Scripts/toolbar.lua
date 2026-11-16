-- Hotbar slots. On this game build each player's character caps its hotbar at
-- SN2PlayerMaxToolbarSize (8), below the base a slot mod sets on the toolbar
-- (UWEBaseNumToolbarSlots, 10 with Ultimate Player Tweaks), and the slot count (NumSlots) is the
-- server's. With TOOLBAR_SLOTS set, a player's cap is raised to it and their count set to the smaller
-- of that base and TOOLBAR_SLOTS. A count is never lowered. Pure Lua: the caller reads and writes.
local M = {}

-- The count to set, or nil to leave the player as they are.
function M.want(limit, base, now)
  limit, base, now = tonumber(limit), tonumber(base), tonumber(now)
  if not limit or limit < 1 or not base then return nil end
  local n = math.floor(math.min(base, limit))
  if now and now >= n then return nil end
  return n
end

-- One player: read their character's numbers, then raise the cap and the count when wanted.
-- game: read(pawn) -> {base, now, cap}; set_cap(pawn, n); set_count(pawn, n). Returns the count set.
function M.apply(limit, pawn, game)
  local seen = game.read(pawn)
  if not seen then return nil end
  local n = M.want(limit, seen.base, seen.now)
  if not n then return nil end
  if tonumber(seen.cap) and seen.cap < n then game.set_cap(pawn, n) end
  game.set_count(pawn, n)
  return n
end

return M
