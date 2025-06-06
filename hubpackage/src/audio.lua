-- audio.lua (Two-Way Audio and Capability Detection)

local log = require "log"
local json = require "dkjson"
local auth = require "auth"
local cosock = require "cosock"
local http = cosock.asyncify("socket.http")
local ltn12 = require "ltn12"
local common = require "common"
local config = require "config"

local M = {}

-- Build audio control request
local function build_audio_command(cmd_name)
  return json.encode({{
    cmd = cmd_name,
    param = {
      Audio = { channel = 0 }
    }
  }})
end

-- Execute audio command via token session
local function send_audio_command(device, cmd_name)
  local ip = device.preferences.ipAddress
  local token = auth.get_token(device)
  if not token then
    log.error("🔒 No token available for audio command")
    return false
  end

  local payload = build_audio_command(cmd_name)
  local url = string.format("http://%s/api.cgi?cmd=%s&token=%s", ip, cmd_name, token)
  local resp = {}

  local _, code = http.request {
    method = "POST",
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload)
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(resp)
  }

  if code == 200 then
    log.info("📢 Audio command succeeded: " .. cmd_name)
    return true
  else
    log.warn("❌ Audio command failed: " .. cmd_name .. " (code: " .. tostring(code) .. ")")
    return false
  end
end

-- Public start/stop audio API
function M.start(device)
  return send_audio_command(device, "StartTalk")
end

function M.stop(device)
  return send_audio_command(device, "StopTalk")
end

-- Capability presence checker for audio
function M.is_audio_supported(ability)
  return common.has_ability(ability, "talk") or
         common.has_ability(ability, "supportAudioAlarmEnable")
end

return M