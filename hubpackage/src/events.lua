-- events.lua (ONVIF and Reolink Event Listener with Fallback Parsing)

local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local Thread = require "st.thread"
local log = require "log"
local capabilities = require "st.capabilities"

local common = require "common"
local auth = require "auth"
local json = require "dkjson"

local eventservers = {}
local shutdown = false

local function process_http_message(client)
  client:settimeout(10)
  local content_length = 0
  local body = ""

  repeat
    local line, err = client:receive("*l")
    if not line then break end
    if line:find("^Content%-Length:") then
      content_length = tonumber(line:match("%d+")) or 0
    end
  until line == ""

  if content_length > 0 then
    local recv
    while #body < content_length do
      recv, err = client:receive(content_length - #body)
      if recv then
        body = body .. recv
      else
        log.error("❌ Error reading HTTP body: " .. tostring(err))
        return nil
      end
    end
  end
  return body
end

local function parse_event_xml(xml_str)
  local parsed = common.xml_to_table(xml_str)
  if not parsed then return nil end
  parsed = common.strip_xmlns(parsed)

  if common.is_element(parsed, {"Envelope", "Body", "Notify", "NotificationMessage"}) then
    return parsed.Envelope.Body.Notify.NotificationMessage
  elseif common.is_element(parsed, {"Envelope", "Body"}) then
    return parsed.Envelope.Body
  end
  return nil
end

local function eventaccept_handler(eventsock)
  local client, err = eventsock:accept()
  if not client then
    log.error("❌ Accept error: " .. tostring(err))
    return
  end

  cosock.spawn(function()
    local data = process_http_message(client)
    if not data then
      client:close()
      return
    end

    local xmldata_index = data:find('<?xml')
    if not xmldata_index then
      log.warn("⚠️ No XML content found in HTTP body")
      client:close()
      return
    end

    local event = parse_event_xml(data:sub(xmldata_index))
    if not event then
      log.warn("⚠️ Event XML could not be parsed")
      client:close()
      return
    end

    for id, es in pairs(eventservers) do
      if es.sock == eventsock then
        if es.callback then
          es.callback(es.device, event)
        end
      end
    end
    client:close()
  end, "reolink_event_handler")
end

local function init(driver, eventserver)
  eventserver.sock = socket.tcp()
  assert(eventserver.sock:bind("*", 0))
  assert(eventserver.sock:listen(5))
  local ip, port = eventserver.sock:getsockname()

  eventserver.listen_ip = ip
  eventserver.listen_port = port

  if not eventserver.eventing_thread then
    eventserver.eventing_thread = Thread.Thread(driver, "event server thread")
  end

  shutdown = false
  cosock.spawn(function()
    while not shutdown do
      eventaccept_handler(eventserver.sock)
    end
  end, "event_accept_loop")

  log.info("🔔 Event server listening on " .. ip .. ":" .. port)
  return true
end

local function register(device, callback)
  if not eventservers[device.id] then
    eventservers[device.id] = {
      sock = nil,
      client = nil,
      device = device,
      callback = callback,
      eventing_thread = nil
    }
  end
  return init(device.driver, eventservers[device.id])
end

local function shutdown_all()
  shutdown = true
  for _, ev in pairs(eventservers) do
    if ev.sock then
      pcall(function() ev.sock:close() end)
    end
  end
end

return {
  register = register,
  shutdown = shutdown_all
}
