--[[
  Copyright 2022 Todd Austin, enhanced 2025 by suggestions for dMac

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  ONVIF Discovery with enhanced error handling and compatibility


--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local Thread = require "st.thread"
local log = require "log"

local common = require "common"
local uuid = require "uuid"
local classify = require "classify"
local Semaphore = require "semaphore"

local multicast_ip = "239.255.255.250"
local multicast_port = 3702
local listen_ip = "0.0.0.0"
local listen_port = 0

local ids_found = {}
local unfoundlist = {}
local rediscovery_thread
local thread_status = false
local rediscover_timer

local discover_1 = [[<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">
      http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe
    </a:Action>
    <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
    <a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>
  </s:Header>
  <s:Body>
    <Probe xmlns="http://schemas.xmlsoap.org/ws/2005/04/discovery">
      <d:Types xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dp0="http://www.onvif.org/ver10/network/wsdl">]]
local discover_2 = [[</d:Types>
    </Probe>
  </s:Body>
</s:Envelope>
]]

local function build_probe(probetype)
    local _probe1 = discover_1 .. probetype .. discover_2
    local msgid = '<a:MessageID>uuid:' .. uuid() .. '</a:MessageID>\n'
    local _probe2 = common.add_XML_header(_probe1, msgid)
    return common.compact_XML(_probe2)
end

local function parse(data)
    local metadata = {}
    local parsed_xml, err = common.xml_to_table(data)
    
    if not parsed_xml then
        log.error('Invalid XML returned in discovery response:', err or data)
        return nil, false, err or "Invalid XML"
    end
    
    parsed_xml = common.strip_xmlns(parsed_xml)
    if not parsed_xml['Envelope'] then
        log.error("Unexpected discovery response - missing 'Envelope'", data)
        return nil, false, "Missing Envelope"
    end
    
    if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches'}) then
        common.disptable(parsed_xml['Envelope']['Body']['ProbeMatches'], '  ', 10)
        
        if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'Types'}) then
            local types = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['Types']
            local valid_types = { 'NetworkVideoTransmitter', 'Device', 'NetworkVideoStorage' }
            local found_matchtype = false
            for matchtype in types:gmatch('[^ ]+') do
                for _, valid_type in ipairs(valid_types) do
                    if string.find(matchtype, valid_type, nil, true) then
                        found_matchtype = true
                        break
                    end
                end
                if found_matchtype then break end
            end
            if not found_matchtype then
                log.debug('\tResponse not from a supported ONVIF type; ignored')
                return nil, false, "Unsupported type"
            end
        else
            log.warn('Discovery response missing ProbMatch.Types element; ignored')
            return nil, false, "Missing Types"
        end
        
        metadata.uri = {}
        if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'XAddrs'}) then
            local service_addrs = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['XAddrs']
            for addr in service_addrs:gmatch('[^ ]+') do
                local ipv4 = addr:match('^(http://)([%d%.:]+)/')
                if ipv4 then
                    metadata.uri.device_service = addr
                    break
                end
                local ipv6 = addr:match('^(http://)%[([%w:]+)%]/')
                if ipv6 then
                    metadata.uri.device_service = addr
                    break
                end
                local hostname = addr:match('^(http://)([%w:]+)/')
                if hostname then
                    metadata.uri.device_service = addr
                    break
                end
            end
            if not metadata.uri.device_service then
                log.error('Could not find device service address')
                return nil, false, "No valid address"
            end
            
            metadata.scopes = {}
            metadata.profiles = {}
            metadata.vendname = ''
            metadata.location = ''
            metadata.hardware = ''
            
            if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'Scopes'}) then
                local scopestring = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['Scopes']
                for item in scopestring:gmatch('[^ ]+') do
                    table.insert(metadata.scopes, item)
                    if item:find('/name/') then
                        metadata.vendname = item:match('/name/(.+)$')
                    elseif item:find('/location/') then
                        metadata.location = item:match('/location/(.+)$')
                    elseif item:find('/hardware/') then
                        metadata.hardware = item:match('/hardware/(.+)$')
                    elseif item:find('/Profile/') then
                        table.insert(metadata.profiles, item:match('/Profile/(.+)$'))
                    end
                end
            else
                log.warn('No Scopes found in discovery response')
            end
            
            if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'EndpointReference', 'Address'}) then
                metadata.urn = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['EndpointReference']['Address']
            else
                log.warn('EndpointReference Address not found in discovery response')
            end
            
            return metadata, true, nil
        else
            log.warn('Discovery response missing ProbeMatch.XAddrs element; ignored')
            return nil, false, "Missing XAddrs"
        end
    elseif common.is_element(parsed_xml, {'Envelope', 'Body', 'Fault'}) then
        local fault = parsed_xml['Envelope']['Body']['Fault']['Reason']['Text'][1]
        log.error('SOAP ERROR:', fault)
        return nil, false, "SOAP Fault: " .. fault
    else
        log.error('Unexpected discovery response:', data)
        return nil, false, "Unexpected response"
    end
end

local function discover(waitsecs, callback, reset)
    if reset then ids_found = {} end
    
    local s = assert(socket.udp(), "create discovery socket")
    assert(s:setsockname(listen_ip, listen_port), "discovery socket setsockname")
    
    local max_attempts = 3
    for attempt = 1, max_attempts do
        local success, err = pcall(function()
            s:sendto(build_probe('dp0:NetworkVideoTransmitter'), multicast_ip, multicast_port)
            cosock.socket.sleep(0.1)
            s:sendto(build_probe('dp0:Device'), multicast_ip, multicast_port)
        end)
        if success then break end
        log.warn(string.format("Discovery send attempt %d failed: %s, retrying...", attempt, err))
        cosock.socket.sleep(1)
    end
    
    local timeouttime = socket.gettime() + waitsecs
    
    cosock.spawn(function()
        while true do
            local time_remaining = math.max(0, timeouttime - socket.gettime())
            s:settimeout(time_remaining)
            
            local data, rip, port = s:receivefrom()
            if data then
                log.debug(string.format('Discovery response from: %s', rip))
                local cam_meta, success, err = parse(data)
                
                if success and cam_meta then
                    local streamprofile
                    for _, profile in ipairs(cam_meta.profiles) do
                        if profile == 'Streaming' then
                            streamprofile = profile
                        end
                    end
                    if not streamprofile then
                        log.warn('No Streaming profile identified by discovered device')
                    end
                    
                    cam_meta.ip = rip
                    cam_meta.port = port
                    cam_meta.addr = rip .. ':' .. tostring(port)
                    cam_meta.discotype = 'auto'
                    callback(cam_meta)
                end
            elseif rip == "timeout" then
                break
            else
                log.error('ERROR:', rip)
            end
        end
        s:close()
    end, 'discovery responses task')
end

local function proc_rediscover(driver, base_delay)
    if next(unfoundlist) == nil then return end
    
    log.debug('Running periodic re-discovery process for uninitialized devices:')
    for device_network_id, table in pairs(unfoundlist) do
        log.debug(string.format('\t%s (%s)', device_network_id, table.device.label))
    end
    
    discover(5, function(ipcam)
        for device_network_id, table in pairs(unfoundlist) do
            if device_network_id == ipcam.urn then
                local device = table.device
                local callback = table.callback
                log.info(string.format('Known device <%s (%s)> re-discovered at %s', ipcam.urn, device.label, ipcam.ip))
                
                local devmeta = device:get_field('onvif_disco')
                devmeta.uri = ipcam.uri
                devmeta.ip = ipcam.ip
                devmeta.vendname = ipcam.vendname
                devmeta.hardware = ipcam.hardware
                devmeta.location = ipcam.location
                devmeta.profiles = ipcam.profiles
                devmeta.urn = ipcam.urn
                device:set_field('onvif_disco', ipcam, {['persist'] = true })
                
                unfoundlist[device_network_id] = nil
                callback(device)
            end
        end
    end, true)
    
    cosock.socket.sleep(10)
    if next(unfoundlist) ~= nil then
        local delay = base_delay * (1 + math.random()) -- Exponential backoff with jitter
        rediscover_timer = rediscovery_thread:call_with_delay(delay, function()
            proc_rediscover(driver, math.min(base_delay * 2, 300))
        end, 're-discover routine')
    else
        rediscovery_thread:close()
        thread_status = false
    end
end

local function schedule_rediscover(driver, device, delay, callback)
    if next(unfoundlist) == nil then
        unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = callback }
        log.warn(string.format('\tScheduling re-discover routine in %d seconds', delay))
        if not thread_status then
            rediscovery_thread = Thread.Thread(driver, 'rediscover thread')
            thread_status = true
        end
        rediscover_timer = rediscovery_thread:call_with_delay(delay, function()
            proc_rediscover(driver, delay)
        end, 're-discover routine')
    else
        unfoundlist[device.device_network_id] = { ['device'] = device, ['callback'] = callback }
    end
end

local function cancel_rediscover(driver, device)
    if next(unfoundlist) == nil then return end
    
    for network_id, _ in pairs(unfoundlist) do
        if network_id == device.device_network_id then
            unfoundlist[network_id] = nil
            if next(unfoundlist) == nil and rediscover_timer then
                driver:cancel_timer(rediscover_timer)
            end
            break
        end
    end
end

return {
    discover = discover,
    schedule_rediscover = schedule_rediscover,
    cancel_rediscover = cancel_rediscover
}