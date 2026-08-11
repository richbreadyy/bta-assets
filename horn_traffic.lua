--[[
  SRP traffic -- horn / headlight-flash nudge, client side.  v3

  Beep the horn or flash the headlights and the traffic car ahead moves over.

  v3 exists because a HUD is a bad way to find out whether a script is alive.
  Everything important now goes through ac.log(), which lands in
  Documents/Assetto Corsa/logs/custom_shaders_patch.log tagged [SRP-HORN].
  Grep that file and you get the truth without having to watch the screen.

  Also drops ui.pushFont: if ui.Font were unavailable in this context the whole
  draw call would throw and you'd get a window with no text in it, which is
  exactly the symptom that wasted a round earlier.

  Install: raw URL in the server's CSP Extra Options, QUOTED --

    [SCRIPT_2]
    SCRIPT = 'https://pastebin.com/raw/XXXXXXX'

  The quotes matter. Unquoted, the INI parser eats everything from the '//'
  onward and CSP tries to run the string 'https:' as Lua.
]]

local DEBUG            = true   -- HUD + verbose logging
local REQUIRE_DOUBLE   = false  -- true = must beep/flash twice quickly
local DOUBLE_WINDOW    = 0.85
local COOLDOWN         = 2.0
local LOOK_AHEAD       = 70
local LANE_TOLERANCE   = 3.0
local MIN_AHEAD        = 3.0
local CLEAR_AHEAD      = 45

local function log(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  ac.log('[SRP-HORN] ' .. (ok and msg or tostring(fmt)))
end

------------------------------------------------------------------------------
-- packet -- layout must match HornNudgePlugin exactly, key included
------------------------------------------------------------------------------

local hornNudge = ac.OnlineEvent({
  ac.StructItem.key('srpHornNudge'),
  targetSessionId = ac.StructItem.int(),
  roadClear       = ac.StructItem.int(),
})

-- CSP 2506+ can address the server directly with target 255. Older builds
-- ignore the argument, so there we broadcast and let AssettoServer pick it up
-- off the relay.
local BUILD = ac.getPatchVersionCode()
local SERVER_TARGET = BUILD >= 2506 and 255 or nil

------------------------------------------------------------------------------
-- input -- read the player's real bindings, not car-state fields that vary
-- between CSP builds
------------------------------------------------------------------------------

local btnHorn  = ac.ControlButton('ACTION_HORN')
local btnFlash = ac.ControlButton('ACTION_HEADLIGHTS_FLASH')

--- Read a field that may not exist on this CSP build without dying.
local function probe(obj, name)
  if obj == nil then return nil end
  local ok, v = pcall(function() return obj[name] end)
  if ok then return v end
  return nil
end

------------------------------------------------------------------------------
-- state
------------------------------------------------------------------------------

local t            = 0
local prevSignal   = false
local lastSignalAt = -99
local lastNudgeAt  = -99
local armed        = false
local status       = 'waiting for horn / flash'
local statusAt     = 0
local lastSource   = '-'
local trafficSeen  = 0
local sentCount    = 0
local nextHeartbeat = 0

local function say(msg)
  status, statusAt = msg, t
  log('%s', msg)
end

------------------------------------------------------------------------------
-- geometry
------------------------------------------------------------------------------

local function relativeTo(me, other)
  local rel = other.position - me.position
  return rel:dot(me.look), rel:dot(me.side)
end

--- Is this car AI traffic rather than a player?
local function isTraffic(c)
  return probe(c, 'isHidingLabels') == true or probe(c, 'isAIControlled') == true
end

local function findCarAhead(me, sim)
  local best, bestFwd = nil, LOOK_AHEAD
  trafficSeen = 0
  for i = 1, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected and isTraffic(c) then
      trafficSeen = trafficSeen + 1
      local fwd, side = relativeTo(me, c)
      if fwd > MIN_AHEAD and fwd < bestFwd and math.abs(side) < LANE_TOLERANCE then
        best, bestFwd = c, fwd
      end
    end
  end
  return best, bestFwd
end

local function roadClearFor(target, sim)
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected and c.index ~= target.index then
      local rel = c.position - target.position
      local fwd = rel:dot(target.look)
      local side = rel:dot(target.side)
      if fwd > 0 and fwd < CLEAR_AHEAD and math.abs(side) < LANE_TOLERANCE then
        return false
      end
    end
  end
  return true
end

------------------------------------------------------------------------------
-- the nudge
------------------------------------------------------------------------------

local function nudge()
  local sim = ac.getSim()
  local me = ac.getCar(0)
  if not me then return end

  local target, dist = findCarAhead(me, sim)
  if not target then
    say(string.format('no traffic ahead (%d traffic cars nearby, %d cars total)',
      trafficSeen, sim.carsCount))
    return
  end

  local clear = roadClearFor(target, sim)
  local ok = hornNudge({
    targetSessionId = target.sessionID,
    roadClear       = clear and 1 or 0,
  }, nil, SERVER_TARGET)

  lastNudgeAt = t
  if ok == false then
    say('SEND FAILED -- rate limited or messaging blocked')
  else
    sentCount = sentCount + 1
    say(string.format('SENT nudge #%d -> slot %d at %.0fm (%s)',
      sentCount, target.sessionID, dist,
      clear and 'clear road' or 'boxed in'))
  end
end

------------------------------------------------------------------------------
-- main loop
------------------------------------------------------------------------------

function script.update(dt)
  t = t + dt

  local me = ac.getCar(0)
  if not me then return end

  local hornDown  = btnHorn:down()
  local flashDown = btnFlash:down()
  local src = nil

  if hornDown then src = 'horn (binding)'
  elseif flashDown then src = 'flash (binding)' end

  if not src then
    if probe(me, 'hornActive') == true then
      src = 'horn (car state)'
    elseif probe(me, 'flashingLightsActive') == true then
      src = 'flash (car state)'
    end
  end

  local signal = src ~= nil
  local rising = signal and not prevSignal
  prevSignal = signal

  if rising then
    lastSource = src
    log('input edge: %s', src)
    if not REQUIRE_DOUBLE then
      if t - lastNudgeAt > COOLDOWN then nudge() else say('cooling down') end
    else
      if armed and (t - lastSignalAt) < DOUBLE_WINDOW then
        if t - lastNudgeAt > COOLDOWN then nudge() else say('cooling down') end
        armed = false
      else
        armed = true
        say('armed -- signal again')
      end
    end
    lastSignalAt = t
  end

  if armed and t - lastSignalAt > DOUBLE_WINDOW then armed = false end

  -- Heartbeat so the log proves the update loop is running even when nothing
  -- is pressed. Backs off once we know it's alive.
  if t >= nextHeartbeat then
    local sim = ac.getSim()
    log('alive t=%.0fs cars=%d horn=%s flash=%s sent=%d',
      t, sim.carsCount,
      tostring(btnHorn:boundTo()), tostring(btnFlash:boundTo()), sentCount)
    nextHeartbeat = t < 30 and (t + 5) or (t + 60)
  end

  if DEBUG then
    ac.debug('srp/horn bound', btnHorn:boundTo() or 'NOT BOUND')
    ac.debug('srp/flash bound', btnFlash:boundTo() or 'NOT BOUND')
    ac.debug('srp/traffic seen', trafficSeen)
    ac.debug('srp/packets sent', sentCount)
  end
end

------------------------------------------------------------------------------
-- HUD -- no fonts, no styling, nothing that can throw
------------------------------------------------------------------------------

function script.drawUI()
  if not DEBUG then
    if t - statusAt > 2.5 then return end
    ui.beginTransparentWindow('srpHorn', vec2(40, 260), vec2(460, 60))
    ui.textColored(status, rgbm(1, 0.86, 0.2, 1))
    ui.endTransparentWindow()
    return
  end

  ui.beginTransparentWindow('srpHornDebug', vec2(30, 200), vec2(480, 170))
  ui.textColored(string.format('SRP horn nudge ALIVE  %.0fs  (CSP %d)', t, BUILD),
    rgbm(0.4, 1, 0.5, 1))
  ui.text('horn:  ' .. tostring(btnHorn:boundTo()))
  ui.text('flash: ' .. tostring(btnFlash:boundTo()))
  ui.text(string.format('target: %s   traffic near: %d   sent: %d',
    SERVER_TARGET and '255' or 'broadcast', trafficSeen, sentCount))
  ui.text('last input: ' .. lastSource)
  ui.textColored('> ' .. status, rgbm(1, 0.86, 0.2, 1))
  ui.endTransparentWindow()
end

------------------------------------------------------------------------------

log('loaded OK -- CSP build %d, server target %s, horn=%s flash=%s',
  BUILD,
  SERVER_TARGET and '255 (direct)' or 'broadcast',
  tostring(btnHorn:boundTo()),
  tostring(btnFlash:boundTo()))
