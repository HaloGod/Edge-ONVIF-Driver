--[[
  Copyright 2022 Todd Austin, adapted 2025 for SmartThings Edge driver
  Licensed under the Apache License, Version 2.0 (the "License");
  http://www.apache.org/licenses/LICENSE-2.0

  Modifications based on findings:
  - ONVIF service for Reolink doorbell (10.0.0.72) is at http://10.0.0.72:8000/onvif/device_service (port 8000 from multicast).
  - TrackMix at 10.0.0.102 added with direct probe, assumed port 8000 (to be confirmed).
  - NVR at 10.0.0.67 detected via multicast, port 8000.
  - Requires Digest Auth (admin:Doggies44) for 10.0.0.72; applying as default for all devices.
  - Direct probe timed out previously, increased timeout to 10s.
  - RTSP fallback for 10.0.0.72: rtsp://admin:Doggies44@10.0.0.72/h264Preview_01_main (port 554).
  - Multicast detected 10.0.0.58, 10.0.0.67, 10.0.0.72 successfully.
  - Added default credentials (admin:Doggies44) to all discovered devices.
  - Updated device_network_id to use IP only (e.g., "10.0.0.72") to fix incorrect lan.networkId format (previously ":10.0.0.72").
--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local log = require "log"
local common = require "common"
local uuid = require "uuid"

local multicast_ip = "239.255.255.250"
local multicast_port = 3702
local listen_ip = "0.0.0.0"
local listen_port = 0

local discovered_urns = {}

-- Default credentials applied to all devices
local DEFAULT_USERNAME = "admin"
local DEFAULT_PASSWORD = "Doggies44"

local discover_1 = [[<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>
    <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
    <a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>
  </s:Header>
  <s:Body>
    <Probe xmlns="http://schemas.xmlsoap.org/ws/2005/04/discovery">
      <d:Types xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dp0="http://www.onvif.org/ver10/network/wsdl" xmlns:tns1="http://www.onvif.org/ver10/topics">]]
local discover_2 = [[</d:Types>
    </Probe>
  </s:Body>
</s:Envelope>]]

local function build_probe(probetype)
    local probe = discover_1 .. probetype .. discover_2
    local msgid = '<a:MessageID>uuid:' .. uuid() .. '</a:MessageID>\n'
    probe = common.add_XML_header(probe, msgid)
    return common.compact_XML(probe)
end

local function parse(data)
    local metadata = {}
    log.debug("Raw response data: " .. data)
    
    local parsed_xml = common.xml_to_table(data)
    if not parsed_xml then
        log.error("Failed to parse XML response")
        return nil
    end

    -- Extract SOAP envelope and body
    local envelope = parsed_xml['SOAP-ENV:Envelope'] or parsed_xml['s:Envelope']
    if not envelope then
        log.error("No SOAP Envelope found in response")
        return nil
    end

    local body = envelope['SOAP-ENV:Body'] or envelope['s:Body']
    if not body then
        log.error("No SOAP Body found in response")
        return nil
    end

    -- Extract ProbeMatches
    local probe_matches = body['wsdd:ProbeMatches'] or body['d:ProbeMatches']
    if not probe_matches then
        log.error("No ProbeMatches found in response")
        return nil
    end

    local probe_match = probe_matches['wsdd:ProbeMatch'] or probe_matches['d:ProbeMatch']
    if not probe_match then
        log.error("No ProbeMatch found in response")
        return nil
    end

    -- Extract Types
    local types = probe_match['wsdd:Types'] or probe_match['d:Types']
    if not types then
        log.warn("No Types found in ProbeMatch")
    end

    -- Extract XAddrs (service URI)
    local xaddrs = probe_match['wsdd:XAddrs'] or probe_match['d:XAddrs']
    if xaddrs then
        for addr in xaddrs:gmatch('[^ ]+') do
            local ip, port = addr:match('^(http://)([%d%.]+):?(%d*)/')
            if ip then
                metadata.uri = addr
                metadata.ip = ip:gsub('http://', '')
                metadata.port = port or "80"
                break
            end
        end
        if not metadata.uri then
            log.error("No valid service URI found in XAddrs: " .. xaddrs)
            return nil
        end
    else
        log.warn("Missing XAddrs in response; ignored")
        return nil
    end

    -- Extract Scopes
    local scopes = probe_match['wsdd:Scopes'] or probe_match['d:Scopes']
    if not scopes then
        log.warn("No Scopes found in ProbeMatch")
        return nil
    end

    metadata.vendname = ''
    metadata.hardware = ''
    metadata.location = ''
    for scope in scopes:gmatch('[^ ]+') do
        if scope:match('onvif://www.onvif.org/name/') then
            metadata.vendname = scope:match('onvif://www.onvif.org/name/(.+)$') or ''
        elseif scope:match('onvif://www.onvif.org/hardware/') then
            metadata.hardware = scope:match('onvif://www.onvif.org/hardware/(.+)$') or ''
        elseif scope:match('onvif://www.onvif.org/location/') then
            metadata.location = scope:match('onvif://www.onvif.org/location/(.+)$') or ''
        end
    end

    -- Extract EndpointReference Address (URN)
    local endpoint_ref = probe_match['wsa:EndpointReference'] or probe_match['a:EndpointReference']
    if not endpoint_ref then
        log.error("No EndpointReference found in ProbeMatch")
        return nil
    end

    local urn = endpoint_ref['wsa:Address'] or endpoint_ref['a:Address']
    if not urn then
        log.error("No Address found in EndpointReference")
        return nil
    end

    if discovered_urns[urn] then
        log.debug("Ignoring duplicate URN: " .. urn)
        return nil
    end
    discovered_urns[urn] = true
    metadata.urn = urn

    -- SmartThings-specific fields with default credentials
    -- Use IP only for device_network_id to fix incorrect lan.networkId format
    metadata.device_network_id = metadata.ip  -- Changed from metadata.ip .. ":" .. metadata.port
    metadata.label = metadata.hardware ~= '' and metadata.hardware or "ONVIF Camera " .. metadata.ip
    metadata.manufacturer = metadata.vendname ~= '' and metadata.vendname or "Reolink"
    metadata.username = DEFAULT_USERNAME
    metadata.password = DEFAULT_PASSWORD
    metadata.rtsp_url = "rtsp://" .. DEFAULT_USERNAME .. ":" .. DEFAULT_PASSWORD .. "@" .. metadata.ip .. "/h264Preview_01_main"

    return metadata
end

local function direct_probe(ip, port, callback)
    local url = "http://" .. ip .. ":" .. port .. "/onvif/device_service"
    local probe = build_probe("dp0:Device")
    local response_body = {}
    http.TIMEOUT = 10
    local res, code, headers = http.request {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/soap+xml",
            ["Content-Length"] = tostring(#probe)
        },
        source = ltn12.source.string(probe),
        sink = ltn12.sink.table(response_body),
        user = DEFAULT_USERNAME,
        password = DEFAULT_PASSWORD,
        authentication = "digest"
    }

    if res and code == 200 then
        local data = table.concat(response_body)
        log.debug("Direct ONVIF response from " .. ip .. ": " .. data)
        local cam_meta = parse(data)
        if cam_meta then
            cam_meta.ip = ip
            cam_meta.port = port
            cam_meta.addr = ip .. ":" .. port
            cam_meta.rtsp_url = "rtsp://" .. DEFAULT_USERNAME .. ":" .. DEFAULT_PASSWORD .. "@" .. ip .. "/h264Preview_01_main"  -- Ensure RTSP URL is set
            log.info("Device discovered at " .. cam_meta.addr .. " via direct probe")
            log.debug("Calling callback with metadata: ip=" .. cam_meta.ip .. ", label=" .. cam_meta.label)
            callback(cam_meta)
        end
    else
        log.warn("Direct probe to " .. ip .. " failed: " .. (code or "unknown"))
        local cam_meta = {
            ip = ip,
            port = "554",
            addr = ip .. ":554",
            rtsp_url = "rtsp://" .. DEFAULT_USERNAME .. ":" .. DEFAULT_PASSWORD .. "@" .. ip .. "/h264Preview_01_main",
            device_network_id = ip,  -- Changed from ip .. ":554"
            label = "Reolink Device (RTSP) " .. ip,
            manufacturer = "Reolink",
            username = DEFAULT_USERNAME,
            password = DEFAULT_PASSWORD
        }
        log.info("Falling back to RTSP for " .. ip)
        log.debug("Calling callback with RTSP fallback: ip=" .. cam_meta.ip .. ", label=" .. cam_meta.label)
        callback(cam_meta)
    end
end

local function multicast_discover(waitsecs, callback)
    local s, err = socket.udp()
    if not s then
        log.error("Failed to create UDP socket: " .. (err or "unknown error"))
        return
    end
    
    local ok, bind_err = s:setsockname(listen_ip, listen_port)
    if not ok then
        log.error("Failed to bind socket: " .. (bind_err or "unknown error"))
        s:close()
        return
    end

    local probes = {
        'dp0:NetworkVideoTransmitter',
        'dp0:Device',
        'tns1:Device',
        'tns1:Door',
        'tns1:VideoDoor',
        'dp0:NetworkVideoDoor'
    }
    
    for _, probetype in ipairs(probes) do
        log.debug("Sending multicast probe: " .. probetype)
        local ok, send_err = s:sendto(build_probe(probetype), multicast_ip, multicast_port)
        if not ok then
            log.warn("Failed to send probe " .. probetype .. ": " .. (send_err or "unknown error"))
        end
        cosock.socket.sleep(0.2)
    end

    local timeouttime = socket.gettime() + waitsecs

    cosock.spawn(function()
        log.debug("Starting multicast discovery listen loop with timeout: " .. waitsecs .. " seconds")
        while true do
            local time_remaining = math.max(0, timeouttime - socket.gettime())
            s:settimeout(time_remaining)

            local data, rip, rport = s:receivefrom()
            if data then
                log.debug("Multicast response from: " .. rip .. ":" .. rport)
                local cam_meta = parse(data)
                if cam_meta then
                    cam_meta.ip = rip
                    cam_meta.addr = rip .. ':' .. cam_meta.port
                    log.debug("Valid device found at " .. cam_meta.addr .. " with URI: " .. cam_meta.uri)
                    log.debug("Calling callback with metadata: ip=" .. cam_meta.ip .. ", label=" .. cam_meta.label)
                    callback(cam_meta)
                end
            elseif rip == "timeout" then
                log.debug("Multicast discovery timeout reached")
                break
            else
                log.error("Socket error: " .. (rip or "unknown"))
            end
        end
        s:close()
        log.debug("Multicast discovery socket closed")
        discovered_urns = {}
    end, "multicast_discovery_task")
end

local function discover(waitsecs, callback)
    -- Direct probe for Reolink doorbell at 10.0.0.72
    cosock.spawn(function()
        direct_probe("10.0.0.72", "8000", callback)
    end, "direct_probe_doorbell_task")

    -- Direct probe for TrackMix at 10.0.0.102
    cosock.spawn(function()
        direct_probe("10.0.0.102", "8000", callback)
    end, "direct_probe_trackmix_task")

    -- Multicast for other devices (e.g., 10.0.0.58, 10.0.0.67 NVR)
    multicast_discover(waitsecs, callback)
end

return {
    discover = discover
}