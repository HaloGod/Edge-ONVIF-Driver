-- commands.lua (Updated with NVR-first Stream/Snapshot Fallback for SmartThings Tile)

local log = require "log"
local cosock = require "cosock"
local http = cosock.asyncify("socket.http")
local ltn12 = require "ltn12"
local socket = require "cosock.socket"
local config = require "config"
local capabilities = require "st.capabilities"
local auth = require "auth"
local json = require "dkjson"
local onvif_events = require "onvif_events"
local event_handlers = require "event_handlers"

local M = {}

----------------------------------------------------
-- STREAM URL GENERATION WITH NVR CHANNEL SUPPORT
----------------------------------------------------
-- get_stream_url(device[, bypass_nvr])
-- Returns an RTSP URL. When bypass_nvr is true the camera IP is used even if
-- USENVRSTREAM is enabled.
function M.get_stream_url(device, bypass_nvr)
  local username = device.preferences.username or config.DEFAULT_USER
  local password = device.preferences.password or config.DEFAULT_PASS
  local cam_ip = device.preferences.ipAddress
  local channel = device:get_field("nvr_channel") or 0

  local function build_rtsp(ip, ch, stream)
    -- Reolink cameras, including the doorbell, expect the path
    -- 'h264Preview_XX_<stream>'. Previous versions used 'Preview',
    -- which failed for some models.
    return string.format("rtsp://%s:%s@%s:554/h264Preview_%02d_%s", username, password, ip, ch, stream)
  end

  -- Try NVR stream first unless direct access was requested
  if not bypass_nvr and config.USENVRSTREAM and config.NVR_IP then
    local nvr_url = build_rtsp(config.NVR_IP, channel, "main")
    log.debug("📡 Using NVR stream URL: " .. nvr_url)
    return nvr_url
  end

  -- Direct camera stream
  local direct_url = build_rtsp(cam_ip, 1, "main")
  log.debug("📡 Using camera stream URL: " .. direct_url)
  return direct_url
end

----------------------------------------------------
-- POST JSON HELPER WITH TOKEN
----------------------------------------------------
local function post_json_with_token(device, payload, cmd)
  local ip = device.preferences.ipAddress
  local token = auth.get_token(device)
  local url = string.format("http://%s/api.cgi?cmd=%s&token=%s", ip, cmd, token)
  local response_body = {}

  local _, code = http.request {
    method = "POST",
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload)
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(response_body)
  }

  return table.concat(response_body), code
end

----------------------------------------------------
-- SNAPSHOT URL EMISSION WITH CACHE BUSTING TIMESTAMP
----------------------------------------------------
-- refresh_snapshot(device[, bypass_nvr])
-- Emit a JPEG snapshot event. When bypass_nvr is true the camera IP is used
-- instead of the NVR.
function M.refresh_snapshot(device, bypass_nvr)
  local username = device.preferences.username or config.DEFAULT_USER
  local password = device.preferences.password or config.DEFAULT_PASS
  local ip = (not bypass_nvr and config.USENVRSTREAM and config.NVR_IP) or device.preferences.ipAddress
  local channel = device:get_field("nvr_channel") or 0
  local now = os.time()

  local snapshot_url = string.format(
    "http://%s/cgi-bin/api.cgi?cmd=Snap&channel=%d&user=%s&password=%s&_ts=%d",
    ip, channel, username, password, now
  )

  device:emit_event(capabilities.videoStream.stream({
    url = snapshot_url,
    protocol = "jpeg"
  }))

  log.info("📸 Snapshot refreshed for channel " .. channel .. " at " .. now)
end

----------------------------------------------------
-- TWO-WAY AUDIO CONTROL
----------------------------------------------------
function M.start_two_way_audio(device)
  local payload = '[{"cmd":"StartTalk","param":{"Audio":{"channel":0}}}]'
  local body, code = post_json_with_token(device, payload, "StartTalk")
  if code == 200 then
    log.info("🎤 Two-Way Audio Started for " .. device.label)
  else
    log.error("❌ StartTalk failed: " .. tostring(code))
  end
end

function M.stop_two_way_audio(device)
  local payload = '[{"cmd":"StopTalk","param":{"Audio":{"channel":0}}}]'
  local body, code = post_json_with_token(device, payload, "StopTalk")
  if code == 200 then
    log.info("🎤 Two-Way Audio Stopped for " .. device.label)
  else
    log.error("❌ StopTalk failed: " .. tostring(code))
  end
end

----------------------------------------------------
-- CAPABILITY DETECTION & INITIALIZATION
----------------------------------------------------
function M.query_device_capabilities(device)
  local payload = json.encode({{
    cmd = "GetAbility",
    param = { User = { userName = device.preferences.username or config.DEFAULT_USER } }
  }})

  local body, code = post_json_with_token(device, payload, "GetAbility")
  if code ~= 200 then
    log.warn("⚠️ GetAbility failed for " .. device.label)
    return nil
  end

  local parsed = json.decode(body)
  if parsed and parsed[1] and parsed[1].value and parsed[1].value.Ability then
    local ability = parsed[1].value.Ability
    device:set_field("device_ability", ability, { persist = true })
    log.info("📊 Device ability cached for " .. device.label)

    -- Dynamic profile classification
    if ability.devInfo and ability.devInfo.exactType == "NVR" then
      device:set_field("profile_hint", "nvr")
    elseif ability.ptzCtrl and ability.ptzCtrl.permit > 0 then
      device:set_field("profile_hint", "ptz")
    elseif ability.alarmAudio then
      device:set_field("profile_hint", "doorbell")
    else
      device:set_field("profile_hint", "standard")
    end
  end
end

----------------------------------------------------
-- CAMERA RECORDING STATUS (STUBBED FOR NOW)
----------------------------------------------------
function M.update_recording_state(device)
  -- TODO: Implement a real query if Reolink API supports GetRecState or similar.
  -- For now, assume camera or NVR is always recording if it's reachable.

  local recording_capability = capabilities["cameraRecording"]

  -- Emit recording.active if device is accessible and likely recording
  device:emit_event(recording_capability.recording.active())
  log.info("📼 Recording status emitted as ACTIVE for " .. device.label)
end


----------------------------------------------------
-- INITIALIZATION ROUTINE (Smart Init)
----------------------------------------------------
function M.smart_initialize(device)
  log.info("🚀 Running Smart Initialization for: " .. device.label)

  local queries = {
    { cmd = "GetDevInfo" },
    { cmd = "GetTime" },
    { cmd = "GetAbility", param = { User = { userName = device.preferences.username or config.DEFAULT_USER } } },
  }

  for _, entry in ipairs(queries) do
    local payload = json.encode({ entry })
    local body, code = post_json_with_token(device, payload, entry.cmd)
    if code == 200 then
      log.debug("✅ " .. entry.cmd .. " success for " .. device.label)
    else
      log.warn("⚠️ " .. entry.cmd .. " failed for " .. device.label .. ": " .. tostring(code))
    end
  end

  M.query_device_capabilities(device)
  M.update_recording_state(device)

  -- Subscribe to ONVIF events for doorbell and motion notifications
  onvif_events.subscribe(device, function(evt)
    if evt == "VisitorAlarm" then
      event_handlers.handle_doorbell_press(device)
    elseif evt == "MotionAlarm" then
      event_handlers.handle_motion_trigger(device)
    elseif evt == "TamperAlarm" then
      device:emit_event(capabilities.tamperAlert.tamper("detected"))
    end
  end)
end

return M
