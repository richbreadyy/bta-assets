--[[
  Police Pursuit — server-delivered CSP online script.

  Every player who joins runs this. It works out its own role from the car the
  player picked:

    * driving a police model  -> COP:  radar HUD listing everyone over the limit
    * driving anything else   -> CIVILIAN: WANTED HUD once you cross the limit

  Entirely client-side. No plugin, no DLL, no server restart to retune — edit
  this file and players pick it up on their next join.

  Companion piece: PursuitPlugin (server-side) drives AI police cars using the
  same threshold. The two do not talk to each other on purpose — each works
  alone, so neither can break the other. If you change SPEED_LIMIT_MPH here,
  change SpeedThresholdMph in plugin_pursuit_cfg.yml to match.
]]

----------------------------------------------------------------------------
-- TUNING
----------------------------------------------------------------------------

local SPEED_LIMIT_MPH  = 90    -- cross this and you are wanted
local CLEAR_MARGIN_MPH = 10    -- drop below (limit - this) to start cooling off
local TRIGGER_HOLD     = 0.6   -- seconds over the limit before it actually flags
local ESCAPE_SECONDS   = 12    -- seconds clean + clear of police to lose them
local ESCAPE_DISTANCE  = 350   -- metres: nearest cop must be beyond this to count as clean
local RADAR_RANGE      = 800   -- metres: how far a cop's radar reads other cars
local BUST_DISTANCE    = 12    -- metres
local BUST_SPEED_MPH   = 15    -- both cars under this...
local BUST_SECONDS     = 3.0   -- ...for this long, next to each other, = busted
local SCAN_INTERVAL    = 0.1   -- seconds between full car sweeps

-- A car counts as police if its folder id matches any of these Lua patterns.
local POLICE_PATTERNS = {
  '^mpw_police_',
  'police',
  '_cop_',
}

----------------------------------------------------------------------------

-- CSP runs LuaJIT (Lua 5.1), which has math.atan2 and whose math.atan silently
-- ignores a second argument. 5.3+ is the other way round. Bind once, work on both.
local atan2 = math.atan2 or math.atan

local KMH_TO_MPH = 0.621371
local LIMIT_KMH  = SPEED_LIMIT_MPH / KMH_TO_MPH
local CLEAR_KMH  = (SPEED_LIMIT_MPH - CLEAR_MARGIN_MPH) / KMH_TO_MPH
local BUST_KMH   = BUST_SPEED_MPH / KMH_TO_MPH

local settings = ac.storage{ enabled = true }

local isCop        = false
local myModel      = ''
local scanTimer    = 0

-- civilian state
local wanted       = false
local heat         = 0        -- 0..5
local overTimer    = 0        -- seconds continuously over the limit
local cleanTimer   = 0        -- seconds counting toward escape
local bustTimer    = 0
local busted       = false
local topMph       = 0
local nearestCop   = nil      -- { dist = number, name = string }

-- cop state
local targets      = {}       -- sorted by distance

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function isPoliceModel(id)
  if not id then return false end
  id = id:lower()
  for _, pattern in ipairs(POLICE_PATTERNS) do
    if id:match(pattern) then return true end
  end
  return false
end

-- Signed angle in degrees from `fromCar`'s nose to `worldPos`, flattened to
-- the horizontal plane. Negative = to the left, positive = to the right.
local function bearingTo(fromCar, worldPos)
  local look = fromCar.look
  local dx, dz = worldPos.x - fromCar.position.x, worldPos.z - fromCar.position.z
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 0.001 then return 0 end
  dx, dz = dx / len, dz / len
  -- forward component and right component (right = look rotated -90deg in xz)
  local fwd   = look.x * dx + look.z * dz
  local right = look.z * dx - look.x * dz
  return math.deg(atan2(right, fwd))
end

local function bearingArrow(deg)
  local a = math.abs(deg)
  if a < 25 then return '^' end
  if a > 155 then return 'v' end
  return deg < 0 and '<' or '>'
end

local function refreshRole()
  local id = ac.getCarID(0)
  if id and id ~= myModel then
    myModel = id
    isCop = isPoliceModel(id)
    ac.log('[PURSUIT] role: ' .. (isCop and 'POLICE' or 'CIVILIAN') .. ' (' .. id .. ')')
  end
end

----------------------------------------------------------------------------
-- per-frame sweep
----------------------------------------------------------------------------

-- Walks every car once. Fills `targets` when we're a cop, and `nearestCop`
-- when we're not. One pass serves both roles.
local function sweep()
  local me = ac.getCar(0)
  if not me then return end

  targets = {}
  nearestCop = nil

  local count = sim.carsCount
  for i = 1, count - 1 do
    local other = ac.getCar(i)
    if other and other.isConnected and other.isActive then
      local dx = other.position.x - me.position.x
      local dy = other.position.y - me.position.y
      local dz = other.position.z - me.position.z
      local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
      local otherIsCop = isPoliceModel(ac.getCarID(i))

      if isCop then
        -- police radar: anyone not in a police car, over the limit, in range
        if not otherIsCop and dist <= RADAR_RANGE and other.speedKmh >= LIMIT_KMH then
          targets[#targets + 1] = {
            index   = i,
            name    = ac.getDriverName(i) or ('Car ' .. i),
            mph     = other.speedKmh * KMH_TO_MPH,
            dist    = dist,
            bearing = bearingTo(me, other.position),
          }
        end
      elseif otherIsCop then
        -- civilian: how close is the nearest police car
        if nearestCop == nil or dist < nearestCop.dist then
          nearestCop = {
            dist  = dist,
            name  = ac.getDriverName(i) or 'Police unit',
            speed = other.speedKmh * KMH_TO_MPH,
          }
        end
      end
    end
  end

  if isCop then
    table.sort(targets, function(a, b) return a.dist < b.dist end)
  end
end

----------------------------------------------------------------------------
-- civilian state machine
----------------------------------------------------------------------------

local function updateCivilian(dt)
  local me = ac.getCar(0)
  if not me then return end
  local mph = me.speedKmh * KMH_TO_MPH

  if not wanted then
    if me.speedKmh >= LIMIT_KMH then
      overTimer = overTimer + dt
      if overTimer >= TRIGGER_HOLD then
        wanted     = true
        busted     = false
        heat       = 1
        topMph     = mph
        cleanTimer = 0
        bustTimer  = 0
        ac.setMessage('WANTED', string.format('%d mph in a %d zone. Lose them.',
          math.floor(mph), SPEED_LIMIT_MPH))
        ac.log(string.format('[PURSUIT] wanted at %.0f mph', mph))
      end
    else
      overTimer = 0
    end
    return
  end

  -- --- wanted ---
  topMph = math.max(topMph, mph)

  -- heat climbs the longer you stay over the limit, and faster the faster you go
  if me.speedKmh >= LIMIT_KMH then
    local overBy = (mph - SPEED_LIMIT_MPH) / 40   -- +1 heat per ~40 mph over
    heat = math.min(5, heat + dt * (0.12 + overBy * 0.12))
    cleanTimer = 0
  else
    local copClear = (nearestCop == nil) or (nearestCop.dist > ESCAPE_DISTANCE)
    if me.speedKmh < CLEAR_KMH and copClear then
      cleanTimer = cleanTimer + dt
      if cleanTimer >= ESCAPE_SECONDS then
        wanted = false
        overTimer, cleanTimer, heat, bustTimer = 0, 0, 0, 0
        ac.setMessage('LOST THEM', string.format('Topped out at %d mph.', math.floor(topMph)))
        ac.log('[PURSUIT] escaped')
        return
      end
    else
      cleanTimer = 0
    end
  end

  -- --- busted: a cop pinned you and you both stopped ---
  if nearestCop and nearestCop.dist < BUST_DISTANCE
     and me.speedKmh < BUST_KMH and nearestCop.speed < BUST_SPEED_MPH then
    bustTimer = bustTimer + dt
    if bustTimer >= BUST_SECONDS and not busted then
      busted = true
      wanted = false
      overTimer, cleanTimer, heat, bustTimer = 0, 0, 0, 0
      ac.setMessage('BUSTED', string.format('%s pulled you over at %d mph.',
        nearestCop.name, math.floor(topMph)), 'illegal')
      ac.log('[PURSUIT] busted')
    end
  else
    bustTimer = 0
  end
end

----------------------------------------------------------------------------
-- HUDs
----------------------------------------------------------------------------

local RED   = rgbm(0.95, 0.16, 0.16, 1)
local BLUE  = rgbm(0.20, 0.55, 1.00, 1)
local WHITE = rgbm(1, 1, 1, 1)
local DIM   = rgbm(0.75, 0.78, 0.82, 1)

local function drawCivilianHud()
  if not wanted and not busted then return end

  -- ui.windowSize() inside a draw callback is the UI canvas, which is what CSP's
  -- own HUD scripts use. sim.windowWidth is raw pixels and is wrong under UI scaling.
  local screen = ui.windowSize()
  local w, h = 300, 84
  local pos = vec2(screen.x / 2 - w / 2, 74)

  ui.transparentWindow('pursuitWanted', pos, vec2(w, h), true, false, function()
    -- flashing red/blue bar so it reads as police even at a glance
    local flash = math.floor(os.clock() * 4) % 2 == 0
    ui.drawRectFilled(vec2(0, 0), vec2(w, 4), flash and RED or BLUE)
    ui.drawRectFilled(vec2(0, 4), vec2(w, h), rgbm(0, 0, 0, 0.62))

    ui.dwriteDrawText('WANTED', 26, vec2(12, 12), flash and RED or WHITE)

    local stars = string.rep('*', math.max(1, math.floor(heat))) ..
                  string.rep('-', 5 - math.max(1, math.floor(heat)))
    ui.dwriteDrawText(stars, 22, vec2(w - 96, 13), RED)

    if nearestCop then
      ui.dwriteDrawText(string.format('NEAREST UNIT  %d m', math.floor(nearestCop.dist)),
        15, vec2(12, 44), nearestCop.dist < 120 and RED or DIM)
    else
      ui.dwriteDrawText('NO UNITS IN RANGE', 15, vec2(12, 44), DIM)
    end

    if cleanTimer > 0 then
      local frac = math.min(1, cleanTimer / ESCAPE_SECONDS)
      ui.drawRectFilled(vec2(12, 66), vec2(12 + (w - 24) * frac, 72), BLUE)
      ui.dwriteDrawText(string.format('LOSING THEM  %.0fs', ESCAPE_SECONDS - cleanTimer),
        13, vec2(w - 124, 62), BLUE)
    end
  end)
end

local function drawCopHud()
  local rows = math.min(#targets, 6)
  local h = 40 + rows * 22
  local w = 286
  local pos = vec2(ui.windowSize().x - w - 24, 150)

  ui.transparentWindow('pursuitRadar', pos, vec2(w, h), true, false, function()
    ui.drawRectFilled(vec2(0, 0), vec2(w, h), rgbm(0, 0, 0, 0.58))
    ui.drawRectFilled(vec2(0, 0), vec2(w, 3), BLUE)

    if rows == 0 then
      ui.dwriteDrawText('RADAR  //  CLEAR', 16, vec2(12, 12), DIM)
      return
    end

    ui.dwriteDrawText(string.format('RADAR  //  %d SPEEDING', #targets), 16, vec2(12, 10), WHITE)

    for i = 1, rows do
      local t = targets[i]
      local y = 34 + (i - 1) * 22
      local col = i == 1 and RED or DIM
      ui.dwriteDrawText(bearingArrow(t.bearing), 15, vec2(12, y), col)
      ui.dwriteDrawText(t.name:sub(1, 16), 15, vec2(30, y), col)
      ui.dwriteDrawText(string.format('%3d mph', math.floor(t.mph)), 15, vec2(w - 130, y), col)
      ui.dwriteDrawText(string.format('%5d m', math.floor(t.dist)), 15, vec2(w - 62, y), col)
    end
  end)
end

----------------------------------------------------------------------------
-- settings panel (Chat > lightbulb icon)
----------------------------------------------------------------------------

local function settingsUI()
  ui.dwriteText('POLICE PURSUIT', 20, WHITE)
  ui.dwriteText(string.format('Speed limit: %d mph', SPEED_LIMIT_MPH), 15, DIM)
  ui.dwriteText('Role: ' .. (isCop and 'POLICE UNIT' or 'CIVILIAN'), 15, isCop and BLUE or DIM)
  ui.dwriteText('Car: ' .. myModel, 13, DIM)
  ui.separator()

  if isCop then
    ui.textWrapped('Your radar lists every civilian over the limit within '
      .. RADAR_RANGE .. ' m, nearest first. The arrow points at them relative to your nose.')
    ui.textWrapped('Horn is wired to the siren on this car (HORN_AS_SIREN). Lightbar is CSP Extra Option A.')
  else
    ui.textWrapped(string.format(
      'Cross %d mph and you are flagged. To lose it: get under %d mph with no police within %d m for %d seconds.',
      SPEED_LIMIT_MPH, SPEED_LIMIT_MPH - CLEAR_MARGIN_MPH, ESCAPE_DISTANCE, ESCAPE_SECONDS))
  end

  ui.separator()
  if ui.checkbox('Show HUD', settings.enabled) then
    settings.enabled = not settings.enabled
  end
  return false
end

ui.registerOnlineExtra(
  ui.Icons.Attention,
  { title = 'Police Pursuit', tooltip = 'Speed limit, your role, and HUD toggle' },
  nil,
  settingsUI,
  nil,
  ui.OnlineExtraFlags.Tool,
  ui.WindowFlags.None,
  vec2(360, 340)
)

----------------------------------------------------------------------------
-- entry points
----------------------------------------------------------------------------

ac.log('[PURSUIT] script loaded, limit ' .. SPEED_LIMIT_MPH .. ' mph')

function script.update(dt)
  refreshRole()

  scanTimer = scanTimer + dt
  if scanTimer >= SCAN_INTERVAL then
    scanTimer = 0
    sweep()
  end

  if not isCop then
    updateCivilian(dt)
  end
end

function script.drawUI()
  if not settings.enabled then return end
  if isCop then
    drawCopHud()
  else
    drawCivilianHud()
  end
end
