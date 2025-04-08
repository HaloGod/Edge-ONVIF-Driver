--[[
  Copyright 2025 dMac

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.

  DESCRIPTION
  ONVIF Camera event handler
--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local Thread = require "st.thread"
local log = require "log"

local commands = require "commands"
local discover = require "discover"
local common = require "common"

local initflag = false
local eventservers = {}
local shutdown = false

local eventing_thread

local DEFAULT_SUBSCRIBE_DURATION = 600		
local REOLINK_ID = 'IPC-BO'

local function process_http_message(client)
  client:settimeout(10)
  local content_length = 0

  do -- Read first line and verify it matches the expect request-line
    local line, err, partial = client:receive('*l')
    if err == nil then
      if not line then
        log.error("No start line received; probably a timeout")
        return
      end
      if line:find('POST /event HTTP/1', 1, 'plaintext') ~= 1 then
        log.error("Received unexpected start line: ", line)
        return
      else
        log.debug("Received HTTP header:", line)
      end
    else
      log.error("Socket receive failed: " .. err)
      return
    end
  end

  do -- Receive all headers until blank line is found 
    local line, err = client:receive()
    if err then
      log.error("Socket receive failed: " .. err)
      return
    end

    while line ~= "" do
      local name, value = socket.skip(2, line:find("^(.-):%s*(.*)"))
      if not (name and value) then
        log.error("Received msg has malformed response headers")
        return
      end
      if string.lower(name) == "user-agent" and value:find("Reolink") then
        log.debug("Detected Reolink-specific User-Agent:", value)
      end
      if string.lower(name) == "content-length" then
        content_length = tonumber(value)
      end

      line, err = client:receive()
      if err ~= nil then
        log.error("Failed to receive message headers: " .. err)
        return
      end
    end
  end
 
  local body = ""
  local err
  
  if content_length > 0 then
    local recv
    while #body < content_length do
      recv, err = client:receive(content_length - #body)
      if err == nil then
        body = body .. recv
      else
        log.error("Error while receiving body: " .. err)
        break
      end
    end
  end
  
  if #body > 0 then
    return body
  end
end

-- Handle event connections from device
local function eventaccept_handler(eventsock)
  local client, accept_err = eventsock:accept()
  
  if accept_err ~= nil then
    log.error("Connection accept error: " .. accept_err)
    return
  end
  
  if client == nil then
    log.error('Client connection for event is nil')
    return
  end
  
  local eventserver
  for id, evntsrvr in pairs(eventservers) do
    if evntsrvr.sock == eventsock then
      eventserver = evntsrvr
      eventserver.client = client
      break
    end
  end

  if eventserver then
    cosock.spawn(function()
      local data = process_http_message(client)
      
      if data then
        local xmldata_index = data:find('<?xml version=', 1, 'plaintext')
        if xmldata_index then
          local parsed_xml = common.xml_to_table(string.sub(data, xmldata_index, #data))
          if parsed_xml then
            log.debug('Received event message')
            parsed_xml = common.strip_xmlns(parsed_xml)
            local event_messages
            if common.is_element(parsed_xml, {'Envelope','Body','Notify','NotificationMessage'}) then
              event_messages = parsed_xml['Envelope']['Body']['Notify']['NotificationMessage']
            else
              log.warn('Non-standard event format detected, attempting Reolink fallback')
              if parsed_xml['Envelope'] and parsed_xml['Envelope']['Body'] then
                event_messages = parsed_xml['Envelope']['Body']
              else
                log.error('No valid event data found in XML')
                common.disptable(parsed_xml, '  ', 8)
                client:close()
                return
              end
            end
            
            if event_messages then
              eventserver.callback(eventserver.device, event_messages)
            else
              log.warn('No event messages extracted from XML')
            end
          else
            log.error('Could not parse message XML')
          end
        else
          log.error("XML Header not found: " .. data)
        end
      else
        log.error("Event message receive failed")
      end
      
      client:close()
    end, "read socket task")
  else
    log.error('No eventserver record found for socket; cannot receive event data')
    client:close()
  end
end

local function init(driver, eventserver)
  eventserver.sock = socket.tcp()
  assert(eventserver.sock:bind("*", 0))
  assert(eventserver.sock:listen(5))
  local ip, port, _ = eventserver.sock:getsockname()

  if ip ~= nil and port ~= nil then
    eventserver.listen_ip = ip
    eventserver.listen_port = port
    
    if not eventserver.eventing_thread then
      eventserver.eventing_thread = Thread.Thread(driver, 'event server thread')
    end
  
    shutdown = false
    
    cosock.spawn(function()
      while shutdown == false do
        eventaccept_handler(eventserver.sock)
      end	
    end)
    
    log.info("Event server started and listening on: " .. ip .. ":" .. port)
    return true
  else
    log.error("Could not get IP/port from TCP getsockname(), not listening for events")
    eventserver.sock:close()
    eventserver.sock = nil
    return false
  end	
end

local function proc_renew_time(eventserver, response)
  local termination_time = response['TerminationTime']
  local current_time = response['CurrentTime']
  
  if termination_time and current_time then
    local t = {}
    t['year'], t['month'], t['day'], t['hour'], t['min'], t['sec'] = termination_time:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z')
    local c = {}
    c['year'], c['month'], c['day'], c['hour'], c['min'], c['sec'] = current_time:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z')
    
    eventserver.epoch_termination_time = os.time(t)
    
    local renewtime = {}
    renewtime.duration = eventserver.epoch_termination_time - os.time(c)
    
    renewtime.interval = {}
    renewtime.interval.totsecs = renewtime.duration - math.random(45, 60)
    renewtime.interval.min = math.modf(renewtime.interval.totsecs/60)
    renewtime.interval.sec = math.fmod(renewtime.interval.totsecs, 60)
    
    return renewtime
  else
    log.error('Missing termination time from subscription response')
  end
end

local function renew_subscribe(eventserver)
  local device = eventserver.device
  local cam_func = device:get_field('onvif_func')
  local response
  
  if cam_func.event_source_addr:match('//([%d%.]+):') == cam_func.event_service_addr:match('//([%d%.]+):') then
    local termtime = 'PT10M'
    response = commands.RenewSubscription(device, cam_func.event_source_addr, termtime)
  else
    local listen_uri = string.format('http://%s:%s/event', eventserver.listen_ip, eventserver.listen_port)
    response = commands.Subscribe(device, cam_func.event_service_addr, listen_uri)
  end
     
  if response then
    local renew_time = proc_renew_time(eventserver, response)
    
    if renew_time then
      log.info('Successfully renewed subscription for', device.label)
      log.info(string.format('\tDuration = %s minutes', renew_time.duration/60))
      
      if renew_time.duration >= 60 then
        log.debug(string.format('Re-scheduling subscription renewal to run in %02d:%02d', renew_time.interval.min, renew_time.interval.sec))
        eventserver.renew_timer = device.thread:call_with_delay(renew_time.interval.totsecs, 
                                                                function()
                                                                  renew_subscribe(eventserver)
                                                                end,
                                                                "Subscription renewal timer")
        return response
      else
        log.error('Invalid duration; ignored')
      end
    end
  else
    log.error('Subscription renewal failed for', device.label)
    if device:get_field('onvif_online') == false then
      local discotype = device:get_field('onvif_disco').discotype
      if (discotype == nil) or (discotype == 'auto') then
        discover.schedule_rediscover(onvifDriver, device, 20, init_device)
      end
    end
  end
end

local function _do_subscribe(eventserver)
  local listen_uri = string.format('http://%s:%s/event', eventserver.listen_ip, eventserver.listen_port)
  local device = eventserver.device
  
  log.info('Subscribing to events for', device.label)
  
  local cam_func = device:get_field('onvif_func')
  local cam_meta = device:get_field('onvif_disco')
  
  local response
  local max_attempts = 3
  for attempt = 1, max_attempts do
    response = commands.Subscribe(device, cam_func.event_service_addr, listen_uri)
    if response then break end
    log.warn(string.format("Subscribe attempt %d failed for %s, retrying...", attempt, device.label))
    socket.sleep(5)
  end
  
  if response then
    if common.is_element(response, {'SubscriptionReference', 'ReferenceParameters'}) then
      if response.SubscriptionReference.ReferenceParameters.SubscriptionId then
        local SubscriptionId = response.SubscriptionReference.ReferenceParameters.SubscriptionId
        cam_func.subscriptionid = {}
        cam_func.subscriptionid.id = SubscriptionId[1]
        if SubscriptionId._attr then
          for key, value in pairs(SubscriptionId._attr) do
            cam_func.subscriptionid.attr = key .. '="' .. value .. '"'
          end
        end
        device:set_field('onvif_func', cam_func)
        log.debug(string.format('Found Subscription ID [%s], attr: %s', cam_func.subscriptionid.id, cam_func.subscriptionid.attr or 'none'))
      else
        log.warn('Unexpected reference parameter')
      end
    end
    
    local renew_time = proc_renew_time(eventserver, response)
    
    if renew_time then
      log.info('Successfully subscribed to events for', device.label)
      log.info(string.format('\tDuration = %s minutes', renew_time.duration/60))
      log.info('\tRef Address:', response.SubscriptionReference.Address)
      log.debug(string.format('Scheduling subscription renewal to run in %02d:%02d', renew_time.interval.min, renew_time.interval.sec))
      
      local resubscribe_function
      if cam_meta.vendname == REOLINK_ID then
        resubscribe_function = _do_subscribe
      else
        resubscribe_function = renew_subscribe
      end
      eventserver.renew_timer = device.thread:call_with_delay(renew_time.interval.totsecs, 
                                                              function()
                                                                resubscribe_function(eventserver)
                                                              end,
                                                              "Refresh Subscription timer")
      return response
    else
      log.warn('Failed to process renew time for subscription')
    end
  else
    log.error('Subscription failed for', device.label)
    if device:get_field('onvif_online') == false then
      if (cam_meta.discotype == nil) or (cam_meta.discotype == 'auto') then
        discover.schedule_rediscover(onvifDriver, device, 20, init_device)
      end
    end
  end
end

local function subscribe(driver, device, eventname, callback)
  local eventserver
  local device_network_id = device.device_network_id
  
  for id, evntsrvr in pairs(eventservers) do
    if id == device_network_id then
      eventserver = evntsrvr
    end
  end
  
  local continue = true
  
  if eventserver == nil then
    eventservers[device_network_id] = {}
    eventserver = eventservers[device_network_id]
    continue = init(driver, eventserver)
  end
  
  if continue then
    eventserver.device = device
    eventserver.eventname = eventname
    eventserver.callback = callback
    
    local cam_meta = device:get_field('onvif_disco')
    
    if not (cam_meta.ip) then
      log.error('Camera IP not known; cannot subscribe to', device.label)
      return nil
    end

    if eventserver.listen_port == nil then
      log.error("Cannot subscribe, no event listen server address available:", device.label)
      return nil
    end
    
    if not eventserver.sock then
      log.error('No event server socket for', device.label)
      return nil
    end
    
    local subscribe_response = _do_subscribe(eventserver)
    
    if not subscribe_response then
      device.thread:unregister_socket(eventserver.sock)
      eventserver.sock:close()
      eventserver.eventing_thread:close()
      eventservers[device_network_id] = nil
    end
    
    return subscribe_response
  else
    log.error('Subscribe failed for', device.label)
  end
  
  return false
end

local function shutdownserver(driver, device)
  local device_network_id = device.device_network_id
  local eventserver
  
  for id, evntsrvr in pairs(eventservers) do
    if id == device_network_id then
      eventserver = evntsrvr
    end
  end

  if eventserver then
    shutdown = true
    eventserver.sock:close()
    eventserver.eventing_thread:close()
    if eventserver.renew_timer then
      driver:cancel_timer(eventserver.renew_timer)
    end
    log.info('Event server shutdown for device', device.label)
  end
  
  eventservers[device_network_id] = nil
end

return {
  subscribe = subscribe,
  shutdownserver = shutdownserver,
}