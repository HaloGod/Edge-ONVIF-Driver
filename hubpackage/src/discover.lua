--[[
  Copyright 2022 Todd Austin, adapted 2025 for your SmartThings Edge driver

  Licensed under the Apache License, Version 2.0 (the "License");
  http://www.apache.org/licenses/LICENSE-2.0
--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local common = require "common"
local uuid = require "uuid"

local multicast_ip = "239.255.255.250"
local multicast_port = 3702
local listen_ip = "0.0.0.0"
local listen_port = 0

-- WS-Discovery probe template
local discover_1 = [[<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>
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

-- Build the WS-Discovery probe with a unique message ID
local function build_probe(probetype)
    local probe = discover_1 .. probetype .. discover_2
    local msgid = '<a:MessageID>uuid:' .. uuid() .. '</a:MessageID>\n'
    probe = common.add_XML_header(probe, msgid)
    return common.compact_XML(probe)
end

-- Parse the XML response from ONVIF devices
local function parse(data)
    local metadata = {}
    local parsed_xml = common.xml_to_table(data)

    if not parsed_xml or not parsed_xml['Envelope'] then
        log.error("Invalid or missing 'Envelope' in discovery response")
        return nil
    end

    parsed_xml = common.strip_xmlns(parsed_xml)
    if not common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'Types'}) then
        log.warn("No valid ProbeMatch.Types in response; ignored")
        return nil
    end

    -- Check for NetworkVideoTransmitter type
    local types = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['Types']
    if not types:find('NetworkVideoTransmitter', nil, true) then
        log.debug("Response not from NetworkVideoTransmitter; ignored")
        return nil
    end

    -- Extract device service URI
    if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'XAddrs'}) then
        local service_addrs = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['XAddrs']
        for addr in service_addrs:gmatch('[^ ]+') do
            local ipv4 = addr:match('^(http://)([%d%.:]+)/')
            if ipv4 then
                metadata.uri = addr
                break
            end
        end
        if not metadata.uri then
            log.error("No valid IPv4 service URI found")
            return nil
        end
    else
        log.warn("Missing XAddrs in response; ignored")
        return nil
    end

    -- Extract scopes and other metadata
    metadata.scopes = {}
    metadata.profiles = {}
    metadata.vendname = ''
    metadata.hardware = ''
    metadata.location = ''
    if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'Scopes'}) then
        local scopestring = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['Scopes']
        for item in scopestring:gmatch('[^ ]+') do
            table.insert(metadata.scopes, item)
            if item:find('/name/') then
                metadata.vendname = item:match('/name/(.+)$')
            elseif item:find('/hardware/') then
                metadata.hardware = item:match('/hardware/(.+)$')
            elseif item:find('/location/') then
                metadata.location = item:match('/location/(.+)$')
            elseif item:find('/Profile/') then
                table.insert(metadata.profiles, item:match('/Profile/(.+)$'))
            end
        end
    end

    -- Extract URN
    if common.is_element(parsed_xml, {'Envelope', 'Body', 'ProbeMatches', 'ProbeMatch', 'EndpointReference', 'Address'}) then
        metadata.urn = parsed_xml['Envelope']['Body']['ProbeMatches']['ProbeMatch']['EndpointReference']['Address']
    end

    return metadata
end

-- Discover ONVIF cameras
local function discover(waitsecs, callback)
    local s = assert(socket.udp(), "Failed to create UDP socket")
    assert(s:setsockname(listen_ip, listen_port), "Failed to bind socket")

    -- Send probes
    s:sendto(build_probe('dp0:NetworkVideoTransmitter'), multicast_ip, multicast_port)
    cosock.socket.sleep(0.1)
    s:sendto(build_probe('dp0:Device'), multicast_ip, multicast_port)

    local timeouttime = socket.gettime() + waitsecs

    cosock.spawn(function()
        while true do
            local time_remaining = math.max(0, timeouttime - socket.gettime())
            s:settimeout(time_remaining)

            local data, rip = s:receivefrom()
            if data then
                log.debug("Discovery response from: " .. rip)
                local cam_meta = parse(data)
                if cam_meta then
                    cam_meta.ip = rip
                    callback(cam_meta)
                end
            elseif rip == "timeout" then
                break
            else
                log.error("Socket error: " .. (rip or "unknown"))
            end
        end
        s:close()
    end, "discovery_task")
end

return {
    discover = discover
}