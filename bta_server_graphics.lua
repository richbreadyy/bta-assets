--[[
  BTA Server Graphics

  CSP online script derived from the color section of the ARRI RAW Wet Night
  Sci-Fi Spec v2.4 PP-filter preset. Online scripts cannot replace a player's
  complete PP filter, but CSP does allow them to add live color corrections.

  Source values:
    BRIGHTNESS  = 1.00
    CONTRAST    = 1.045
    SATURATION  = 0.94
    COLOR_TEMP  = 5700 K
    WHITE_BALANCE = 5700 K
]]

local corrections = {}

local function addCorrection(correction)
  corrections[#corrections + 1] = correction
  ac.addColorCorrection(correction)
end

if ac.addColorCorrection
    and ac.ColorCorrectionBrightness
    and ac.ColorCorrectionContrast
    and ac.ColorCorrectionSaturation
    and ac.ColorCorrectionTemperature then
  addCorrection(ac.ColorCorrectionBrightness({ value = 1.00 }))
  addCorrection(ac.ColorCorrectionContrast({ value = 1.045 }))
  addCorrection(ac.ColorCorrectionSaturation({ value = 0.94 }))
  addCorrection(ac.ColorCorrectionTemperature({
    temperature = 5700,
    luminance = 0.0,
  }))
  ac.log('[BTA GRAPHICS] Server color profile enabled')
else
  ac.log('[BTA GRAPHICS] CSP color-correction API is unavailable; update CSP')
end

function script.update(dt)
  -- Corrections stay registered for the lifetime of this online script.
end
