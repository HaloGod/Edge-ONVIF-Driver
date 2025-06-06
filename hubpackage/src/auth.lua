-- auth.lua (Enhanced Authentication with Reolink Short Session Support)

local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local base64 = require "base64"
local sha1 = require "sha1"
local md5 = require "md5"
local json = require "dkjson"
local config = require "config"

local M = {}

-- Session cache
local session_store = {}

-- Generate token via short-session login
function M.login_short_session(device)
  local ip = device.preferences.ipAddress
  local username = device.preferences.userid or config.DEFAULT_USER
  local password = device.preferences.password or config.DEFAULT_PASS

  local login_payload = json.encode({{
    cmd = "Login",
    param = {
      User = {
        Version = "0",
        userName = username,
        password = password
      }
    }
  }})

  local http = cosock.asyncify("socket.http")
  local ltn12 = require "ltn12"
  local resp = {}
  local url = string.format("http://%s/api.cgi?cmd=Login", ip)
  local _, code = http.request {
    method = "POST",
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#login_payload)
    },
    source = ltn12.source.string(login_payload),
    sink = ltn12.sink.table(resp)
  }

  if code == 200 then
    local body = table.concat(resp)
    local parsed = json.decode(body)
    if parsed and parsed[1] and parsed[1].value and parsed[1].value.Token then
      local token = parsed[1].value.Token.name
      session_store[ip] = {
        token = token,
        expires = socket.gettime() + (parsed[1].value.Token.leaseTime or 3600)
      }
      log.info("🔐 Token acquired for " .. ip .. ": " .. token)
      return token
    end
  end
  log.error("❌ Login failed for " .. ip .. " (status " .. tostring(code) .. ")")
  return nil
end

-- Get a valid token, refreshing if needed
function M.get_token(device)
  local ip = device.preferences.ipAddress
  local session = session_store[ip]
  if session and socket.gettime() < session.expires then
    return session.token
  end
  return M.login_short_session(device)
end

-- Logout from short session
function M.logout_short_session(device)
  local token = M.get_token(device)
  if not token then return end
  local ip = device.preferences.ipAddress
  local payload = json.encode({{ cmd = "Logout", param = {} }})
  local http = cosock.asyncify("socket.http")
  local ltn12 = require "ltn12"
  local resp = {}
  local url = string.format("http://%s/api.cgi?cmd=Logout&token=%s", ip, token)
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

  session_store[ip] = nil
  log.info("🔓 Logout complete for " .. ip .. " (status " .. tostring(code) .. ")")
end

return M
