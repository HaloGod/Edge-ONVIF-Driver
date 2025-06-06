-- capability_handlers.lua (SmartThings Capability Dispatch Table)

local log = require "log"
local capabilities = require "st.capabilities"
local events = require "event_handlers"

local M = {}

-- Core capability handlers
M[capabilities.refresh.ID] = {
  [capabilities.refresh.commands.refresh.NAME] = events.handle_refresh
}

-- Two-way audio control
M["pianodream12480.twoWayAudio"] = {
  ["startAudio"] = events.handle_two_way_audio,
  ["stopAudio"] = events.handle_two_way_audio
}

-- PTZ directional controls
M["pianodream12480.customPtzControl"] = {
  ["left"] = events.handle_ptz_left,
  ["right"] = events.handle_ptz_right,
  ["up"] = events.handle_ptz_up,
  ["down"] = events.handle_ptz_down
}

-- Doorbell chime trigger
M["pianodream12480.customChimeControl"] = {
  ["playChime"] = events.handle_play_chime
}

-- Doorbell press (triggered by driver or cloud event, not user interaction)
-- You don't need a capability handler here unless exposing the button as pressable
-- But you may still want to route other UI interactions later

return M
