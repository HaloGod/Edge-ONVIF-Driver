-- discover.lua (Enhanced Discovery with Fallback & Classification)

local cosock = require "cosock"
local socket = require "cosock.socket"
local socket_utils = require "socket.url"
local log = require "log"
local config = require "config"
local common = require "common"
local json = require "dkjson"
local auth = require "auth"

local M = {}

local function parse_scopes(scope_str)
  local scopes = {}
  for match in scope_str:gmatch("onvif://www.onvif.org/[^%s]+") do
    table.insert(scopes, match)
  end
  return scopes
end

local function send_multicast_probe(sock, probe_types)
  local probe_msg = [[
    <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
                xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
                xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
      <e:Header>
        <w:MessageID>uuid:]] .. os.time() .. [[</w:MessageID>
        <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
        <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
      </e:Header>
      <e:Body>
        <d:Probe>
          <d:Types>]] .. table.concat(probe_types, " ") .. [[</d:Types>
        </d:Probe>
      </e:Body>
    </e:Envelope>
  ]]
  sock:sendto(probe_msg, "239.255.255.250", 3702)
end

-- Attempt to classify and enrich metadata using HTTP API fallback
local function enrich_with_http_api(meta)
  local ip = meta.ip
  local token = auth.get_token({ preferences = {
  ipAddress = ip,
  userid = "admin",
  password = "Doggies44"
    }})
  if not token then return end
  local url = string.format("http://%s/api.cgi?cmd=GetDevInfo&token=%s", ip, token)
  local http = cosock.asyncify("socket.http")
  local resp = {}
  local _, code = http.request {
    method = "POST",
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#'[{"cmd":"GetDevInfo"}]')
    },
    source = require("ltn12").source.string('[{"cmd":"GetDevInfo"}]'),
    sink = require("ltn12").sink.table(resp)
  }

  if code ~= 200 then
    log.warn("⚠️ Fallback GetDevInfo failed for " .. ip)
    return
  end

  local parsed = json.decode(table.concat(resp))
  if parsed and parsed[1] and parsed[1].value and parsed[1].value.DevInfo then
    local dev = parsed[1].value.DevInfo
    meta.label = dev.model or meta.label
    meta.serial = dev.serial or meta.serial
    meta.profile_hint = dev.exactType == "NVR" and "nvr"
                      or (dev.exactType == "IPC" and "ptz")
                      or (dev.exactType == "BELL" and "doorbell")
                      or "standard"
  end
end

function M.discover(timeout, callback)
  local probe_types = { "dn:NetworkVideoTransmitter" }
  local ip_list = config.STATIC_IP_LIST or {}
  local sock = socket.udp()
  sock:setsockname("*", 0)
  sock:setoption("reuseaddr", true)
  pcall(function() sock:setoption("reuseport", true) end)
  sock:settimeout(0)

  send_multicast_probe(sock, probe_types)

  for _, ip in ipairs(ip_list) do
    local fallback_meta = {
      ip = ip,
      urn = "Manual_" .. os.time(),
      label = "Manual ONVIF Device",
      uri = { device_service = "http://" .. ip .. "/onvif/device_service" },
      scopes = {},
      profiles = {},
      discotype = "manual"
    }
    enrich_with_http_api(fallback_meta)
    callback(fallback_meta)
  end

  log.debug(string.format("Starting multicast discovery listen loop with timeout: %d seconds", timeout))
  local start_time = socket.gettime()

  while socket.gettime() - start_time < timeout do
    local ok, data, ip, port = pcall(function() return sock:receivefrom() end)
    if ok and data then
      log.debug("Received raw multicast data from " .. ip)
      local parsed_xml = common.xml_to_table(data)
      parsed_xml = common.strip_xmlns(parsed_xml)

      local info = parsed_xml["Envelope"] and parsed_xml["Envelope"]["Body"]
      if info and info["GetDeviceInformationResponse"] then
        local dev = info["GetDeviceInformationResponse"]
        local meta = {
          ip = ip,
          urn = dev.SerialNumber or ("Auto_" .. os.time()),
          label = dev.Model or "ONVIF Device",
          vendname = dev.Manufacturer,
          hardware = dev.HardwareId,
          uri = {
            device_service = "http://" .. ip .. "/onvif/device_service"
          },
          scopes = parse_scopes(data),
          profiles = {},
          discotype = "auto"
        }
        enrich_with_http_api(meta)
        callback(meta)
      else
        log.warn("⚠️ XML response missing expected fields from " .. ip)
      end
    else
      socket.sleep(0.1)
    end
  end
end

return M