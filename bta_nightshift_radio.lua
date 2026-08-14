-- BTA NightShift Radio: server-delivered CSP online script.
-- Uses CSP/Windows Media Foundation directly: no Python, VLC or local bridge.

local stations = {
  {
    id = 'power1051',
    frequency = '105.1',
    name = 'POWER 105.1',
    url = 'https://stream.revma.ihrhls.com/zc1481/hls.m3u8'
  },
  {
    id = 'hot97',
    frequency = '97.1',
    name = 'HOT 97',
    url = 'https://playerservices.streamtheworld.com/api/livestream-redirect/WQHTFMAAC_SC'
  },
  {
    id = 'reggae',
    frequency = 'REGGAE',
    name = 'HEAVYWEIGHT',
    url = 'https://ice5.somafm.com/reggae-128-mp3'
  },
  {
    id = 'iriefm',
    frequency = '107.5',
    name = 'IRIE FM JAMAICA',
    url = 'https://usa19.fastcast4u.com:7430/;'
  }
}

local selected = 1
local volume = 0.55
local muted = false
local powered = true
local player = nil
local status = 'STARTING'
local statusDetail = 'Loading CSP native audio'
local statusTimer = 0
local toastTimer = 1.5
local toastShown = false

local function currentStation()
  return stations[selected]
end

local function applyVolume()
  if player then
    player:setVolume(volume)
    player:setMuted(muted or not powered)
  end
end

local function tune(index)
  selected = ((index - 1) % #stations) + 1
  local station = currentStation()

  if not ui.MediaPlayer.supported() then
    status = 'UNAVAILABLE'
    statusDetail = 'CSP native media playback is not supported on this PC'
    powered = false
    return
  end

  if not player then
    player = ui.MediaPlayer(nil, { rawOutput = false, use3D = false })
  end

  powered = true
  muted = false
  status = 'TUNING'
  statusDetail = 'Opening ' .. station.name
  player:setSource(station.url)
  player:setAutoPlay(true)
  applyVolume()
  player:play()
  statusTimer = 0
end

local function stopRadio()
  powered = false
  status = 'STOPPED'
  statusDetail = 'Radio off'
  if player then
    player:pause()
    player:setMuted(true)
  end
end

local function togglePower()
  if powered then
    stopRadio()
  else
    tune(selected)
  end
end

local function radioUI()
  local station = currentStation()

  ui.textColored('BTA // NIGHTSHIFT RADIO', rgbm(0.08, 0.88, 1.00, 1))
  ui.textColored('SERVER RADIO // NO BRIDGE', rgbm(1.00, 0.12, 0.68, 1))
  ui.separator()
  ui.text(status .. '  //  ' .. station.frequency)
  ui.textWrapped(statusDetail)
  ui.separator()

  for i, item in ipairs(stations) do
    if ui.selectable(item.frequency .. '  //  ' .. item.name, selected == i) then
      tune(i)
    end
  end

  ui.separator()
  ui.text('AUDIO OUTPUT // CSP NATIVE')
  local nextVolume = ui.slider('##btaRadioVolume', volume * 100, 0, 100, '%.0f%%') / 100
  if math.abs(nextVolume - volume) > 0.001 then
    volume = nextVolume
    applyVolume()
  end

  if ui.button(powered and 'POWER OFF' or 'POWER ON', vec2(105, 32)) then
    togglePower()
  end
  ui.sameLine()
  if ui.button(muted and 'UNMUTE' or 'MUTE', vec2(90, 32)) then
    muted = not muted
    applyVolume()
  end
  ui.sameLine()
  if ui.button('RECONNECT', vec2(105, 32)) then
    tune(selected)
  end

  ui.textColored('Voice chat: CSP Mumble // positional PTT', rgbm(0.28, 1.00, 0.58, 1))
  return false
end

ui.registerOnlineExtra(
  ui.Icons.Radio,
  { title = 'BTA NightShift Radio', tooltip = 'Native server radio controls' },
  nil,
  radioUI,
  nil,
  ui.OnlineExtraFlags.Tool,
  ui.WindowFlags.None,
  vec2(390, 390)
)

ui.MediaPlayer.supportedAsync(function (supported)
  if supported then
    tune(selected)
  else
    status = 'UNAVAILABLE'
    statusDetail = 'CSP native media playback is not supported on this PC'
    powered = false
  end
end)

function script.update(dt)
  statusTimer = statusTimer + dt
  toastTimer = toastTimer - dt

  if not toastShown and toastTimer <= 0 then
    toastShown = true
    ui.toast(ui.Icons.Radio, 'BTA NightShift Radio is playing. Open Chat > lightbulb for stations and volume.')
  end

  if not player or not powered or statusTimer < 0.5 then return end
  statusTimer = 0

  if player:playing() then
    status = muted and 'MUTED' or 'PLAYING'
    statusDetail = currentStation().name .. ' // live stream'
  elseif player:hasAudio() then
    status = 'BUFFERING'
    statusDetail = 'Connecting to ' .. currentStation().name
  else
    status = 'CONNECTING'
    statusDetail = 'Waiting for the station stream'
  end
end
