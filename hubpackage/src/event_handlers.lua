-- event_handlers.lua (Handles SmartThings Capability Events and Info Changes)

local log = require "log"
local commands = require "commands"
local capabilities = require "st.capabilities"
local audio = require "audio"
local common = require "common"
local config = require "config"

local M = {}

-- Toggle Two-Way Audio from Capability Command
function M.handle_two_way_audio(driver, device, command)
  local action = command.command
  log.info("🎙️ Two-Way Audio command received: " .. action)

  if action == "startAudio" then
    audio.start(device)
    device:emit_event(capabilities.audioMute.mute.unmuted())
  elseif action == "stopAudio" then
    audio.stop(device)
    device:emit_event(capabilities.audioMute.mute.muted())
  else
    log.warn("🚫 Unknown audio command: " .. tostring(action))
  end
end

-- Refresh Device Capability Handler
function M.handle_refresh(driver, device, command)
  log.info("🔄 Refreshing device: " .. device.label)
  commands.smart_initialize(device)
end

-- Basic PTZ Movement
function M.handle_ptz_left(_, device)
  commands.send_ptz_command(device, { x = -0.5, y = 0.0, name = "left" })
end

function M.handle_ptz_right(_, device)
  commands.send_ptz_command(device, { x = 0.5, y = 0.0, name = "right" })
end

function M.handle_ptz_up(_, device)
  commands.send_ptz_command(device, { x = 0.0, y = 0.5, name = "up" })
end

function M.handle_ptz_down(_, device)
  commands.send_ptz_command(device, { x = 0.0, y = -0.5, name = "down" })
end

-- Doorbell Chime Trigger
function M.handle_play_chime(_, device)
  log.info("🔔 Play Chime trigger issued from UI")
  commands.play_chime(device)
end

-- Doorbell Press Event + Snapshot Refresh
function M.handle_doorbell_press(device)
  log.info("🔔 Doorbell pressed on device: " .. device.label)

  -- Emit button pushed for TV/Fridge notifications
  if config.EMIT_STANDARD_EVENTS then
    device:emit_event(capabilities.button.button.pushed({ state_change = true }))
  end
  if config.EMIT_CUSTOM_EVENTS then
    device:emit_event(capabilities["pianodream12480.doorbell"].button("pressed"))
  end

  -- Always refresh snapshot to update tile (even if motion missed it)
  commands.refresh_snapshot(device)
end

-- Motion Detected → Trigger Snapshot
function M.handle_motion_trigger(device)
  log.info("🚨 Motion detected on device: " .. device.label)

  device:emit_event(capabilities.motionSensor.motion("active"))
  commands.refresh_snapshot(device)

  device.thread:call_with_delay(30, function()
    device:emit_event(capabilities.motionSensor.motion("inactive"))
  end)
end

-- Info Changed Handler
function M.info_changed(driver, device, event, args)
  log.info("ℹ️ Device info changed for: " .. device.label)

  -- Re-init if critical settings changed
  local changed = args.old_st_store.preferences ~= args.new_st_store.preferences
  if changed then
    log.info("🔁 Reinitializing device due to preference changes")
    commands.smart_initialize(device)
  end
end

return M
