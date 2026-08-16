-- RichGuyLos Radio Station: server-delivered CSP online script.
-- Uses CSP/Windows Media Foundation directly: no Python, VLC or local bridge.
-- Everyone who joins gets it and it starts playing on its own.
--
-- Stream URLs must be DIRECT audio (mp3/aac/icecast). Media Foundation will not
-- follow an HLS .m3u8 manifest, and it cannot open YouTube/Spotify page links.
-- Each station may list backup URLs; a station that goes silent falls through
-- to the next one automatically.

local stations = {
  {
    id = 'power1051',
    frequency = '105.1',
    name = 'POWER 105.1',
    -- Bare revma mount, NOT .../hls.m3u8: the manifest URL never played.
    urls = { 'https://stream.revma.ihrhls.com/zc1481' }
  },
  {
    id = 'wbls',
    frequency = '107.5',
    name = 'WBLS NEW YORK',
    urls = {
      'https://playerservices.streamtheworld.com/api/livestream-redirect/WBLSFM.mp3',
      'https://playerservices.streamtheworld.com/api/livestream-redirect/WBLSFMAAC.aac'
    }
  },
  {
    id = 'hot97',
    frequency = '97.1',
    name = 'HOT 97',
    urls = { 'https://playerservices.streamtheworld.com/api/livestream-redirect/WQHTFMAAC_SC' }
  },
  {
    id = 'lamega',
    frequency = '97.9',
    name = 'LA MEGA // ESPANOL',
    urls = { 'https://liveaudio.lamusica.com/NY_WSKQ_icy' }
  },
  {
    id = 'zip103',
    frequency = 'DANCEHALL',
    name = 'ZIP 103 JAMAICA',
    urls = {
      'https://stream.zeno.fm/c0ytcn43vxquv',
      'https://sensidancehall.radioca.st/;'
    }
  },
  {
    id = 'iriefm',
    frequency = '107.5 JA',
    name = 'IRIE FM JAMAICA',
    urls = { 'https://usa19.fastcast4u.com:7430/;' }
  },
  {
    id = 'reggae',
    frequency = 'REGGAE',
    name = 'HEAVYWEIGHT',
    urls = { 'https://ice5.somafm.com/reggae-128-mp3' }
  }
}

-- Seconds a stream gets to produce audio before we fall through to its backup.
local CONNECT_TIMEOUT = 9
-- Full passes through a station's URL list before giving up on it, so a dead
-- station can't sit there reconnecting forever in the background.
local MAX_PASSES = 3

local selected = 1
local urlIndex = 1
local passes = 0
local volume = 0.55
local muted = false
local powered = true
local player = nil
local status = 'STARTING'
local statusDetail = 'Loading CSP native audio'
local statusTimer = 0
local sinceTune = 0
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

local function tune(index, urlIdx)
  selected = ((index - 1) % #stations) + 1
  local station = currentStation()
  urlIndex = urlIdx or 1

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
  player:setSource(station.urls[urlIndex])
  player:setAutoPlay(true)
  applyVolume()
  player:play()
  statusTimer = 0
  sinceTune = 0
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
    passes = 0
    tune(selected, 1)
  end
end

local function radioUI()
  local station = currentStation()

  ui.textColored('RICHGUYLOS RADIO STATION', rgbm(0.08, 0.88, 1.00, 1))
  ui.textColored('SERVER RADIO // NO BRIDGE', rgbm(1.00, 0.12, 0.68, 1))
  ui.separator()
  ui.text(status .. '  //  ' .. station.frequency)
  ui.textWrapped(statusDetail)
  ui.separator()

  for i, item in ipairs(stations) do
    if ui.selectable(item.frequency .. '  //  ' .. item.name, selected == i) then
      passes = 0
      tune(i, 1)
    end
  end

  ui.separator()
  ui.text('AUDIO OUTPUT // CSP NATIVE')
  local nextVolume = ui.slider('##rglRadioVolume', volume * 100, 0, 100, '%.0f%%') / 100
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
    passes = 0
    tune(selected, 1)
  end

  ui.textColored('Voice chat: CSP Mumble // positional PTT', rgbm(0.28, 1.00, 0.58, 1))
  return false
end

ui.registerOnlineExtra(
  ui.Icons.Radio,
  { title = 'RichGuyLos Radio Station', tooltip = 'Native server radio controls' },
  nil,
  radioUI,
  nil,
  ui.OnlineExtraFlags.Tool,
  ui.WindowFlags.None,
  vec2(390, 430)
)

ui.MediaPlayer.supportedAsync(function (supported)
  if supported then
    tune(selected, 1)
  else
    status = 'UNAVAILABLE'
    statusDetail = 'CSP native media playback is not supported on this PC'
    powered = false
  end
end)

function script.update(dt)
  statusTimer = statusTimer + dt
  sinceTune = sinceTune + dt
  toastTimer = toastTimer - dt

  if not toastShown and toastTimer <= 0 then
    toastShown = true
    ui.toast(ui.Icons.Radio, 'RichGuyLos Radio Station is playing. Open Chat > lightbulb for stations and volume.')
  end

  if not player or not powered then return end

  if player:playing() then
    -- Audio is flowing, so a stream that dies hours from now still gets a full
    -- set of retries rather than inheriting an old failure count.
    passes = 0
    if statusTimer >= 0.5 then
      statusTimer = 0
      status = muted and 'MUTED' or 'PLAYING'
      statusDetail = currentStation().name ..
        (urlIndex > 1 and ' // backup stream' or ' // live stream')
    end
    return
  end

  if sinceTune < CONNECT_TIMEOUT then
    if statusTimer >= 0.5 then
      statusTimer = 0
      status = player:hasAudio() and 'BUFFERING' or 'CONNECTING'
      statusDetail = 'Opening ' .. currentStation().name
    end
    return
  end

  -- Silent past the timeout: move to this station's next URL, and once the list
  -- is exhausted start it over until MAX_PASSES.
  local station = currentStation()
  if station.urls[urlIndex + 1] then
    tune(selected, urlIndex + 1)
  else
    passes = passes + 1
    if passes >= MAX_PASSES then
      status = 'UNAVAILABLE'
      statusDetail = station.name .. ' is not responding // pick another station'
      powered = false
      player:pause()
    else
      tune(selected, 1)
    end
  end
end
