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

local DEBUG            = false  -- true = verbose text HUD; false = quiet chevron pulse
local REQUIRE_DOUBLE   = false  -- true = must beep/flash twice quickly
local DOUBLE_WINDOW    = 0.85
local COOLDOWN         = 0.8    -- 2.0 swallowed most rapid flashes as "cooling down"
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

-- int32, not int: ac.StructItem has no `int`, and calling it dies at load with
-- "attempt to call field 'int' (a nil value)". int32 is also what matches the
-- plugin's C# `public int` fields.
local hornNudge = ac.OnlineEvent({
  ac.StructItem.key('srpHornNudge'),
  targetSessionId = ac.StructItem.int32(),
  roadClear       = ac.StructItem.int32(),
})

-- Broadcast through the relay so AssettoServer receives the event on both
-- 0.0.54 and 0.0.55. Direct target 255 is not delivered on this host's path.
local BUILD = ac.getPatchVersionCode()
local SERVER_TARGET = nil

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
local pulseAt      = -99   -- when the HUD chevrons last fired
local pulseOk      = false -- true = packet sent, false = nothing ahead

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
  pulseAt = t
  if not target then
    pulseOk = false
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
    pulseOk = true
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
-- HUD
--
-- Invisible until it fires. Three chevrons sweep outward and fade in about a
-- second, low on the left where nobody is looking through. No text: the words
-- were only ever there to debug the script, and the log does that better.
--
-- Whole thing is wrapped in pcall. A missing ui.* call would otherwise throw
-- every frame and take the HUD out silently, which is how the first version
-- managed to look identical to "script never loaded".
------------------------------------------------------------------------------

local PULSE = 1.1                        -- seconds the chevrons stay visible
local drawFailed = false

local function chevron(cx, cy, size, thick, col)
  ui.drawLine(vec2(cx - size, cy - size), vec2(cx, cy), col, thick)
  ui.drawLine(vec2(cx, cy), vec2(cx - size, cy + size), col, thick)
end

local function paint()
  local age = t - pulseAt
  if age > PULSE then return end

  local k = 1 - age / PULSE              -- 1 -> 0
  local fade = k * k                     -- ease out, no hard pop
  local col = pulseOk and rgbm(0.35, 0.95, 1.0, fade)   -- cyan: sent
                      or rgbm(1.0, 0.45, 0.25, fade)    -- amber-red: nothing there

  -- Chevrons march outward as the pulse decays.
  local slide = (1 - k) * 14
  for n = 0, 2 do
    local a = fade * (1 - n * 0.28)
    if a > 0.01 then
      local c = rgbm(col.r, col.g, col.b, a)
      chevron(34 + n * 11 + slide, 26, 7, 2.0, c)
    end
  end

  -- A thin trailing bar, so a single glance reads as "something fired"
  -- rather than "is that part of the car HUD?".
  ui.drawLine(vec2(20, 26), vec2(20, 26 - 9 * fade), rgbm(col.r, col.g, col.b, fade * 0.9), 2.0)
  ui.drawLine(vec2(20, 26), vec2(20, 26 + 9 * fade), rgbm(col.r, col.g, col.b, fade * 0.9), 2.0)
end

function script.drawUI()
  if DEBUG then
    ui.transparentWindow('srpHornDebug', vec2(30, 200), vec2(480, 150), function()
      ui.textColored(string.format('SRP ALIVE %.0fs (CSP %d)', t, BUILD), rgbm(0.4, 1, 0.5, 1))
      ui.text('horn:  ' .. tostring(btnHorn:boundTo()))
      ui.text('flash: ' .. tostring(btnFlash:boundTo()))
      ui.text(string.format('near: %d   sent: %d', trafficSeen, sentCount))
      ui.textColored('> ' .. status, rgbm(1, 0.86, 0.2, 1))
    end)
    return
  end

  if drawFailed or t - pulseAt > PULSE then return end
  local ok, err = pcall(function()
    ui.transparentWindow('srpHornPulse', vec2(26, 300), vec2(120, 52), true, paint)
  end)
  if not ok then
    drawFailed = true                    -- once, then stay out of the way
    log('HUD disabled after draw error: %s', tostring(err))
  end
end

------------------------------------------------------------------------------

log('loaded OK -- CSP build %d, server target %s, horn=%s flash=%s',
  BUILD,
  SERVER_TARGET and '255 (direct)' or 'broadcast',
  tostring(btnHorn:boundTo()),
  tostring(btnFlash:boundTo()))
