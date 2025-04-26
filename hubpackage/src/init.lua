--[[
  Copyright 2022 Todd Austin, enhanced 2025 by HaloGod and suggestions for dMac
  Licensed under the Apache License, Version 2.0 (the "License");
  http://www.apache.org/licenses/LICENSE-2.0
--]]

-- Edge libraries
-- package.path = "./?.lua;" .. package.path
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local log = require "log"
local Driver = require "st.driver"
local http = require "socket.http"
local ltn12 = require "ltn12"

-- Driver-specific libraries
local common = require "common"
local commands = require "commands"
local discover = require "discover"
local event_handlers = require "event_handlers"
local success, onvif_events = pcall(require, "onvif_events")
if not success then
    log.error("Failed to load onvif_events: " .. tostring(onvif_events))
    onvif_events = { subscribe = function() log.warn("onvif_events.subscribe not available") end }
end

-- Capabilities
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_linecross = capabilities["pianodream12480.linecross"]
local onvif_status = capabilities["pianodream12480.onvifStatus"]
local onvif_info = capabilities["pianodream12480.onvifInfo"]
local cap_videoStream = capabilities.videoStream
local cap_videoCapture = capabilities.videoCapture

-- Constants
local LINECROSSREVERTDELAY = 1
local DEFAULT_AUDIO_TIMEOUT = 10
local MAX_RETRIES = 3
local RETRY_DELAY = 5
local SNAPSHOT_INTERVAL = 120
local HA_LOCAL_URL = "http://10.0.0.122:8123"
local HA_LOCAL_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJmYzZiMTA4ZTZhZjQ0MmM0ODJmNWVmYTg3MzY0N2JkYyIsImlhdCI6MTc0NDMzMTQwNiwiZXhwIjoyMDU5NjkxNDA2fQ.wWC3wnFUL9sBfTTe2x2eNAWq1VdLnH_eEdGJ3VY9YuI"

-- Function to fetch a snapshot from the local Home Assistant server
local function fetch_snapshot(device)
    local prefs = device:get_field('effective_prefs')
    if not prefs then
        log.error("No effective_prefs for " .. device.label)
        return nil
    end
    local camera_entity = prefs.haCameraEntity
    if not camera_entity then
        log.error("No HA camera entity for " .. device.label)
        return nil
    end
    local snapshot_url = HA_LOCAL_URL .. "/api/camera_proxy/" .. camera_entity
    local response_body = {}
    http.TIMEOUT = 30
    local headers = {
        ["Authorization"] = "Bearer " .. HA_LOCAL_TOKEN,
        ["Accept"] = "*/*",
        ["Connection"] = "keep-alive",
        ["User-Agent"] = "SmartThingsEdgeDriver/1.0"
    }
    for attempt = 1, MAX_RETRIES do
        local res, code = http.request {
            url = snapshot_url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(response_body)
        }
        if res and code == 200 then
            log.info("Snapshot fetched for " .. device.label)
            return snapshot_url
        end
        log.warn("Snapshot fetch failed for " .. device.label .. ": HTTP " .. tostring(code))
        if attempt < MAX_RETRIES then
            socket.sleep(RETRY_DELAY)
        end
    end
    log.error("Snapshot fetch failed after " .. MAX_RETRIES .. " attempts for " .. device.label)
    return nil
end

-- Function to construct RTSP URL directly from the device
local function get_rtsp_url(device)
    local prefs = device:get_field('effective_prefs') or {}
    local ip = prefs.ipAddress
    if not ip then
        ip = device.device_network_id:match("^([^:]+)") or device.label:match("(%d+%.%d+%.%d+%.%d+)") or "unknown_ip"
        log.warn("No ipAddress in preferences for " .. device.label .. ", using device_network_id: " .. device.device_network_id .. " -> " .. ip)
    end
    local port = prefs.rtspPort or 554
    local userid = prefs.userid or "admin"
    local password = prefs.password or "Doggies44"
    local stream_path = prefs.rtspPath or "/h264Preview_01_main"
    if prefs.stream == "substream" then
        stream_path = stream_path:gsub("_main", "_sub")
    end
    local rtsp_url = string.format("rtsp://%s:%s@%s:%s%s", userid, password, ip, port, stream_path)
    log.debug("Constructed RTSP URL for " .. device.label .. ": " .. rtsp_url)
    return rtsp_url
end

-- Utility Function to Emit Stream and Snapshot
local function emit_video_stream(device)
    local stream_url = get_rtsp_url(device)
    if not stream_url or stream_url:match("unknown_ip") then
        log.error("Invalid stream URL for " .. device.label)
        return
    end
    device:set_field("rtsp_url", stream_url, { persist = true })
    local success = pcall(function()
        device:emit_event(cap_videoStream.stream({ uri = stream_url }))
    end)
    if success then
        log.info("Video stream emitted for " .. device.label)
        device:set_field("onvif_status", "connected", { persist = true })
        local snapshot_url = fetch_snapshot(device)
        if snapshot_url then
            device:emit_event(cap_videoStream.snapshot({ uri = snapshot_url }))
            log.info("Snapshot emitted for " .. device.label)
        end
    else
        log.error("Failed to emit video stream for " .. device.label)
    end
end

-- Function to fetch ONVIF info
local function fetch_onvif_info(device)
    local prefs = device:get_field('effective_prefs')
    if not prefs then
        log.error(string.format("No effective_prefs defined for device %s", device.label))
        return
    end
    local ip = prefs.ipAddress
    local port = prefs.port
    local userid = prefs.userid
    local password = prefs.password
    log.debug("Fetching ONVIF info from device at " .. ip .. ":" .. port)
    local success, result = pcall(function()
        return commands.GetDeviceInformation(ip, port, userid, password)
    end)
    if success and result then
        local model = result.Model or "Unknown Model"
        local firmware = result.FirmwareVersion or "Unknown Firmware"
        device:emit_event(onvif_info.model(model))
        device:emit_event(onvif_info.firmware(firmware))
        log.info("Successfully fetched ONVIF info for " .. device.label .. ": Model=" .. model .. ", Firmware=" .. firmware)
    else
        log.error("Failed to fetch ONVIF info for " .. device.label .. ": " .. tostring(result))
    end
end

-- Driver Setup
local onvif_driver = Driver("ONVIF Video Camera V2.1", {
    discovery = function(driver, _, should_continue)
        log.info("Starting ONVIF discovery")
        discover.discover(10, function(cam_meta)  -- Increased timeout
            -- Ensure a valid device_network_id
            local device_network_id = cam_meta.device_network_id
            if not device_network_id or device_network_id == "" then
                device_network_id = cam_meta.ip or cam_meta.urn or "unknown_" .. os.time()
                log.warn("No valid device_network_id provided, using fallback: " .. device_network_id)
            end
            local metadata = {
                type = "LAN",
                device_network_id = device_network_id,
                label = cam_meta.label or "ONVIF Device",
                profile = "ONVIF-Doorbell",
                manufacturer = cam_meta.manufacturer or "Unknown",
                model = cam_meta.hardware or "Unknown",
                vendor_provided_label = cam_meta.vendname,
                rtsp_url = cam_meta.rtsp_url
            }
            log.info("Attempting to create device: " .. metadata.label .. " with device_network_id: " .. metadata.device_network_id)
            driver:try_create_device(metadata)
        end)
    end,
    lifecycle_handlers = {
        init = function(driver, device)
            log.info("Initializing device: " .. device.label)
            -- Validate and clean device_network_id without direct modification
            local current_network_id = device.device_network_id
            local cleaned_network_id = current_network_id:match("^:?([^:]+)") or device.label:match("(%d+%.%d+%.%d+%.%d+)") or "unknown_" .. device.id
            if current_network_id ~= cleaned_network_id then
                log.warn("Invalid device_network_id detected: " .. current_network_id .. ", using cleaned: " .. cleaned_network_id)
                device:set_field("cleaned_network_id", cleaned_network_id, { persist = true })
            end
            local default_prefs = {
                ipAddress = device.label:match("Side Lot") and "10.0.0.58" or 
                            device.label:match("Driveway Overwatch") and "10.0.0.102" or 
                            device.label:match("Doorbell") and "10.0.0.72" or "10.0.0.67",
                port = 8000,
                userid = "admin",
                password = "Doggies44",
                stream = "mainstream",
                rtspPort = 554,
                rtspPath = "/h264Preview_01_main",
                enableTwoWayAudio = false,
                audioFilePath = "/default/audio.wav",
                quickReply = "Please wait",
                nvrIp = "10.0.0.67",
                minmotioninterval = 5,
                minlinecrossinterval = 5,
                mintamperinterval = 5,
                minvisitorinterval = 5,
                autorevert = "yesauto",
                revertdelay = 10,
                enableBackupStream = false,
                useNvrForStreams = false,
                haCameraEntity = device.label:match("Doorbell") and "camera.frontdoorproxy" or
                                device.label:match("Side Lot") and "camera.side_lot_fluent" or
                                device.label:match("Driveway Overwatch") and "camera.driveway_overwatch_snapshots_fluent_lens_0" or "camera.unknown"
            }
            local effective_prefs = {}
            for key, default_value in pairs(default_prefs) do
                if not device.preferences[key] then
                    log.warn(string.format("Preference %s missing for %s, using default: %s", key, device.label, tostring(default_value)))
                end
                effective_prefs[key] = device.preferences[key] or default_value
                log.info(string.format("Set %s to %s for %s", key, tostring(effective_prefs[key]), device.label))
            end
            device:set_field('effective_prefs', effective_prefs, { persist = true })
            device:set_field("onvif_status", "disconnected", { persist = true })
            emit_video_stream(device)
        end,
        added = function(driver, device)
            log.info("Device added: " .. device.label .. " (ID: " .. device.id .. ")")
            emit_video_stream(device)
            fetch_onvif_info(device)
            onvif_events.subscribe(device)
        end,
        doConfigure = function(driver, device)
            log.info("Configuring device: " .. device.label)
            device:online()
            emit_video_stream(device)
            onvif_events.subscribe(device)
        end,
        infoChanged = function(driver, device)
            log.info("Device info changed for " .. device.label)
            local effective_prefs = device:get_field('effective_prefs') or {}
            local default_prefs = {
                ipAddress = device.label:match("Side Lot") and "10.0.0.58" or 
                            device.label:match("Driveway Overwatch") and "10.0.0.102" or 
                            device.label:match("Doorbell") and "10.0.0.72" or "10.0.0.67",
                port = 8000,
                userid = "admin",
                password = "Doggies44",
                stream = "mainstream",
                rtspPort = 554,
                rtspPath = "/h264Preview_01_main",
                enableTwoWayAudio = false,
                audioFilePath = "/default/audio.wav",
                quickReply = "Please wait",
                nvrIp = "10.0.0.67",
                minmotioninterval = 5,
                minlinecrossinterval = 5,
                mintamperinterval = 5,
                minvisitorinterval = 5,
                autorevert = "yesauto",
                revertdelay = 10,
                enableBackupStream = false,
                useNvrForStreams = false,
                haCameraEntity = device.label:match("Doorbell") and "camera.frontdoorproxy" or
                                device.label:match("Side Lot") and "camera.side_lot_fluent" or
                                device.label:match("Driveway Overwatch") and "camera.driveway_overwatch_snapshots_fluent_lens_0" or "camera.unknown"
            }
            local updated = false
            for key, default_value in pairs(default_prefs) do
                if device.preferences[key] ~= effective_prefs[key] then
                    effective_prefs[key] = device.preferences[key] or default_value
                    log.info(string.format("Updated %s to %s", key, tostring(effective_prefs[key])))
                    updated = true
                end
            end
            if updated then
                device:set_field('effective_prefs', effective_prefs, { persist = true })
                emit_video_stream(device)
                onvif_events.subscribe(device)
            end
        end
    },
    capability_handlers = {
        [capabilities.videoCapture.ID] = {
            ["start"] = function(driver, device, command)
                log.info("Video capture start requested for " .. device.label)
                local prefs = device:get_field('effective_prefs')
                if not prefs then
                    log.error(string.format("No effective_prefs defined for device %s", device.label))
                    return
                end
                local ip = prefs.ipAddress
                local port = prefs.port
                local userid = prefs.userid
                local password = prefs.password
                local success, err = pcall(function()
                    return commands.StartRecording(ip, port, userid, password)
                end)
                if success then
                    log.info("Video capture started for " .. device.label)
                else
                    log.error("Failed to start video capture for " .. device.label .. ": " .. tostring(err))
                end
            end,
            ["stop"] = function(driver, device, command)
                log.info("Video capture stop requested for " .. device.label)
                local prefs = device:get_field('effective_prefs')
                if not prefs then
                    log.error(string.format("No effective_prefs defined for device %s", device.label))
                    return
                end
                local ip = prefs.ipAddress
                local port = prefs.port
                local userid = prefs.userid
                local password = prefs.password
                local success, err = pcall(function()
                    return commands.StopRecording(ip, port, userid, password)
                end)
                if success then
                    log.info("Video capture stopped for " .. device.label)
                else
                    log.error("Failed to stop video capture for " .. device.label .. ": " .. tostring(err))
                end
            end
        },
        [capabilities.videoStream.ID] = {
            ["startStream"] = function(driver, device, command)
                log.info("Video stream start requested for " .. device.label)
                emit_video_stream(device)
            end,
            ["stopStream"] = function(driver, device, command)
                log.info("Video stream stop requested for " .. device.label)
            end
        },
        [capabilities.refresh.ID] = {
            ["refresh"] = function(driver, device, command)
                log.info("Refresh requested for " .. device.label)
                emit_video_stream(device)
                fetch_onvif_info(device)
                onvif_events.subscribe(device)
            end
        }
    }
})

-- Periodic Snapshot Refresh Task
local function start_snapshot_refresh(driver)
    local function refresh_snapshots()
        for _, device in ipairs(driver:get_devices()) do
            if device:get_field("onvif_status") == "connected" then
                local snapshot_url = fetch_snapshot(device)
                if snapshot_url then
                    device:emit_event(cap_videoStream.snapshot({ uri = snapshot_url }))
                    log.info("Periodic snapshot emitted for " .. device.label .. ": " .. snapshot_url)
                else
                    log.error("Failed to emit periodic snapshot for " .. device.label)
                end
            end
        end
        driver:call_with_delay(SNAPSHOT_INTERVAL, refresh_snapshots, "snapshot_refresh_task")
    end
    driver:call_with_delay(10, refresh_snapshots, "snapshot_refresh_task")
end

start_snapshot_refresh(onvif_driver)
onvif_driver:run()

return event_handlers