-- src/discover.lua
local log = require "log"
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local uuid = require "uuid"
local common = require "common"

local function send_multicast_probe(sock, probe_types)
    local multicast_ip = "239.255.255.250"
    local multicast_port = 3702
    local message_id = "uuid:" .. uuid()
    local probes = {}
    for _, ptype in ipairs(probe_types) do
        local probe = string.format([[
            <?xml version="1.0" encoding="UTF-8"?>
            <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
                <e:Header>
                    <w:MessageID>%s</w:MessageID>
                    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
                    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
                </e:Header>
                <e:Body>
                    <d:Probe>
                        <d:Types>%s</d:Types>
                    </d:Probe>
                </e:Body>
            </e:Envelope>
        ]], message_id, ptype)
        table.insert(probes, probe)
    end

    for _, probe in ipairs(probes) do
        log.debug(string.format("Sending multicast probe: %s", probe:match("<d:Types>(.-)</d:Types>")))
        sock:sendto(probe, multicast_ip, multicast_port)
        socket.sleep(0.2)
    end
end

local function direct_probe(ip, callback, discovery_timeout)
    local url = string.format("http://%s:8000/onvif/device_service", ip)
    local response_body = {}
    http.TIMEOUT = 30  -- Increased timeout
    log.debug(string.format("Attempting direct probe to %s", ip))
    local res, code, headers = http.request {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(response_body)
    }
    if res and code == 200 then
        local xml_str = table.concat(response_body)
        log.debug(string.format("Direct probe to %s succeeded, response: %s", ip, xml_str))
        local parsed_xml = common.xml_to_table(xml_str)
        if parsed_xml then
            local device_info = parsed_xml["s:Envelope"]["s:Body"]["GetDeviceInformationResponse"]
            if device_info then
                local metadata = {
                    ip = ip,
                    urn = device_info.SerialNumber or ip,
                    device_network_id = "urn:uuid:" .. uuid(),
                    label = device_info.Model or "ONVIF Device",
                    manufacturer = device_info.Manufacturer or "Unknown",
                    hardware = device_info.Model or "Unknown",
                    vendname = device_info.FirmwareVersion or "Unknown",
                    rtsp_url = string.format("rtsp://admin:Doggies44@%s:554/h264Preview_01_main", ip)
                }
                log.debug(string.format("Direct probe found device at %s: label=%s, device_network_id=%s", ip, metadata.label, metadata.device_network_id))
                callback(metadata)
            else
                log.warn(string.format("Direct probe to %s returned valid XML but no device info", ip))
            end
        else
            log.warn(string.format("Direct probe to %s failed to parse XML response", ip))
        end
    else
        log.warn(string.format("Direct probe to %s failed: %s", ip, tostring(code)))
    end
end

local function discover(timeout, callback)
    local probe_types = {
        "dp0:NetworkVideoTransmitter",
        "dp0:Device",
        "tns1:Device",
        "tns1:Door",
        "tns1:VideoDoor",
        "dp0:NetworkVideoDoor"
    }
    local sock = socket.udp()
    sock:setsockname("*", 0)
    sock:setoption("reuseaddr", true)
    sock:settimeout(0)

    send_multicast_probe(sock, probe_types)

    local ip_list = { "10.0.0.58", "10.0.0.67", "10.0.0.72", "10.0.0.102" }
    for _, ip in ipairs(ip_list) do
        direct_probe(ip, callback, timeout)
    end

    log.debug(string.format("Starting multicast discovery listen loop with timeout: %d seconds", timeout))
    local start_time = socket.gettime()
    while socket.gettime() - start_time < timeout do
        local data, ip, port = sock:receivefrom()
        if data then
            log.debug(string.format("Multicast response from: %s:%s", ip, port))
            log.debug(string.format("Raw response data: %s", data))
            local parsed_xml = common.xml_to_table(data)
            if parsed_xml then
                local probe_match = parsed_xml["SOAP-ENV:Envelope"]["SOAP-ENV:Body"]["wsdd:ProbeMatches"]["wsdd:ProbeMatch"]
                if probe_match then
                    local urn = probe_match["wsa:EndpointReference"]["wsa:Address"]
                    local xaddrs = probe_match["wsdd:XAddrs"]
                    local scopes = probe_match["wsdd:Scopes"]
                    local types = probe_match["wsdd:Types"]
                    if urn and xaddrs and scopes and types then
                        local metadata = {
                            ip = ip,
                            urn = urn,
                            device_network_id = urn,
                            label = "ONVIF Device",
                            manufacturer = "Unknown",
                            hardware = "Unknown",
                            vendname = "Unknown",
                            rtsp_url = string.format("rtsp://admin:Doggies44@%s:554/h264Preview_01_main", ip)
                        }
                        for scope in scopes:gmatch("onvif://www.onvif.org/([^%s]+)") do
                            local key, value = scope:match("([^/]+)/(.+)")
                            if key == "name" then metadata.label = value end
                            if key == "hardware" then metadata.hardware = value end
                            if key == "type" then metadata.type = value end
                        end
                        log.debug(string.format("Multicast discovered device at %s:%s with URI: %s, device_network_id=%s", ip, port, xaddrs, urn))
                        callback(metadata)
                    else
                        log.warn(string.format("Multicast response from %s:%s missing required fields", ip, port))
                    end
                else
                    log.warn(string.format("Multicast response from %s:%s failed to parse as valid ProbeMatch", ip, port))
                end
            else
                log.warn(string.format("Multicast response from %s:%s failed to parse as XML", ip, port))
            end
        else
            log.debug("No multicast response received, continuing to listen...")
        end
        socket.sleep(0.1)
    end

    log.debug("Multicast discovery timeout reached")
    sock:close()
    log.debug("Multicast discovery socket closed")
end

return {
    discover = discover
}