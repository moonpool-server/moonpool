-- This only adapts the game's measured UWESkyActor API to host policy.
-- Direct clock control avoids the player-facing notice produced by console commands.
local M = {}

function M.fraction(value)
  local h, m = tostring(value or ''):match('^(%d%d?):(%d%d)$')
  h, m = tonumber(h), tonumber(m)
  if not h or h > 23 or not m or m > 59 then return nil end
  return (h * 60 + m) / 1440
end

function M.apply(actor, key, value)
  if not actor then return false, 'UWESkyActor not found' end
  local ok, err
  if key == 'time_of_day' then
    local f = M.fraction(value)
    if not f then return false, 'invalid HH:MM' end
    -- UWESkyActor is an ADaySequenceActor: bool SetTimeOfDay(float InHours, const UObject* InCaller)
    -- (DaySequence.hpp in a UE4SS dump of the client). UE4SS refuses a call short of an argument.
    -- The value is in the same unit the actor's GetTimeOfDay answers, a fraction of the day here.
    local done
    ok, err = pcall(function() done = actor:SetTimeOfDay(f, actor) end)
    if ok and done == false then return false, 'SetTimeOfDay declined' end
  elseif key == 'daylight' and value == 'frozen' then
    ok, err = pcall(function() actor:Pause() end)
  elseif key == 'daylight' and value == 'normal' then
    ok, err = pcall(function() actor:Play() end)
  else return false, 'unsupported clock value' end
  if not ok then return false, tostring(err) end
  return true
end

return M
