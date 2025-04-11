--[[
  Copyright 2022 Todd Austin, enhanced 2025 by HaloGod and suggestions for dMac

  Licensed under the Apache License, Version 2.0 (the "License");
  http://www.apache.org/licenses/LICENSE-2.0
--]]

-- Edge libraries
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
local onvif_events = require "onvif_events"

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
local RETRY_DELAY = 5  -- seconds
local SNAPSHOT_INTERVAL = 60  -- Refresh snapshot every 60 seconds
local HA_LOCAL_URL = "http://10.0.0.122:8123"  -- RPi's local IP
local HA_LOCAL_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJmYzZiMTA4ZTZhZjQ0MmM0ODJmNWVmYTg3MzY0N2JkYyIsImlhdCI6MTc0NDMzMTQwNiwiZXhwIjoyMDU5NjkxNDA2fQ.wWC3wnFUL9sBfTTe2x2eNAWq1VdLnH_eEdGJ3VY9YuI"  -- Long-lived token

-- Event Handler Functions (unchanged)
local function handle_motion_event(device, cam_func, msg)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.motion_eventrule.item then
            log.info(string.format('Message for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tMotion value = "%s"', value))
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastMotion')) >= device:get_field('effective_prefs').minmotioninterval then
                    device:emit_event(cap_motionSensor.motion('active'))
                    device:set_field('LastMotion', socket.gettime())
                    if device:get_field('effective_prefs').autorevert == 'yesauto' then
                        device.thread:call_with_delay(device:get_field('effective_prefs').revertdelay, function()
                            device:emit_event(cap_motionSensor.motion('inactive'))
                        end, 'revert motion')
                    end
                else
                    log.info('Motion event ignored due to configured min interval')
                end
            else
                device:emit_event(cap_motionSensor.motion('inactive'))
            end
        else
            log.error('Item name mismatch with event message:', name)
        end
    else
        log.error('Missing event item name/value')
    end
end

local function handle_linecross_event(device, cam_func, msg)
    if not device:supports_capability_by_id("pianodream12480.linecross") then return end
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.linecross_eventrule.item then
            log.info(string.format('Linecross notification for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tValue = "%s"', value, type(value)))
            if type(value) == 'string' then value = string.lower(value) end
            if (value != 'false') and (value != '0') then
                if (socket.gettime() - device:get_field('LastLinecross')) >= device:get_field('effective_prefs').minlinecrossinterval then
                    device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('active'))
                    device:set_field('LastLinecross', socket.gettime())
                    device.thread:call_with_delay(LINECROSSREVERTDELAY, function()
                        device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('inactive'))
                    end, 'revert linecross')
                else
                    log.info('Linecross event ignored due to configured min interval')
                end
            else
                device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('inactive'))
            end
        else
            log.error('Item name mismatch with event message:', name)
        end
    else
        log.error('Missing linecross event item name/value')
    end
end

local function handle_tamper_event(device, cam_func, msg)
    if not device:supports_capability_by_id('tamperAlert') then return end
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.tamper_eventrule.item then
            log.info(string.format('Tamper notification for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tValue = "%s"', value))
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastTamper')) >= device:get_field('effective_prefs').mintamperinterval then
                    device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('detected'))
                    device:set_field('LastTamper', socket.gettime())
                    if device:get_field('effective_prefs').autorevert == 'yesauto' then
                        device.thread:call_with_delay(device:get_field('effective_prefs').revertdelay, function()
                            device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('clear'))
                        end, 'revert tamper')
                    end
                else
                    log.info('Tamper event ignored due to configured min interval')
                end
            else
                device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('clear'))
            end
        else
            log.error('Item name mismatch with event message:', name)
        end
    else
        log.error('Missing tamper event item name/value')
    end
end

local function handle_stream(device, cam_func)
    if cam_func.stream_uri then
        local stream_url = cam_func.stream_uri
        if device:get_field('effective_prefs').enableBackupStream and cam_func.backup_stream_uri then
            log.warn("Backup stream requested but availability check skipped (no io library)")
            stream_url = cam_func.backup_stream_uri
            log.info('Switched to backup stream:', stream_url)
        end
        device:emit_event(cap_videoStream.stream({ uri = stream_url }))
        device:emit_event(cap_videoStream.streamingStatus("active"))
    else
        log.error('No stream URI available for', device.label)
        device:emit_event(cap_videoStream.streamingStatus("inactive"))
        device:emit_event(onvif_status.status("error"))
    end
end

local function handle_visitor_event(device, cam_func, msg, timeout)
    timeout = timeout or DEFAULT_AUDIO_TIMEOUT
    if not device:supports_capability_by_id('pianodream12480.doorbell') then return end
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.visitor_eventrule.item then
            log.info(string.format('Visitor notification for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tVisitor value = "%s"', value))
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - (device:get_field('LastVisitor') or 0)) >= (device:get_field('effective_prefs').minvisitorinterval or 5) then
                    device:emit_component_event(device.profile.components.doorbellComponent, cap_doorbell.button('pressed'))
                    device:set_field('LastVisitor', socket.gettime())
                    handle_stream(device, cam_func)
                    if device:get_field('effective_prefs').enableTwoWayAudio and cam_func.audio_output_token then
                        log.debug('Sending audio for', device.label)
                        local success = commands.SendAudioOutput(device, cam_func.audio_output_token, "Visitor detected", timeout)
                        if not success then
                            log.warn('ONVIF audio output failed, attempting fallback')
                            local fallback_success = send_audio_output_ffmpeg(device, cam_func.audio_output_token, device:get_field('effective_prefs').audioFilePath)
                            if not fallback_success then
                                log.error('Both ONVIF and fallback audio output failed for', device.label)
                            end
                        end
                    end
                    device.thread:call_with_delay(1, function()
                        device:emit_component_event(device.profile.components.doorbellComponent, cap_doorbell.button('released'))
                    end, 'doorbell release')
                else
                    log.info('Visitor event ignored due to min interval')
                end
            end
        else
            log.error('Item name mismatch with Visitor event:', name)
        end
    else
        log.error('Missing Visitor event item name/value')
    end
end

local function send_audio_output_ffmpeg(device, output_token, audio_file)
    local cam_func = device:get_field('onvif_func')
    if not cam_func or not cam_func.stream_uri then
        log.error('Cannot find stream URI for audio output')
        return false
    end
    log.info('Attempting fallback audio output via ONVIF for device: ' .. device.label)
    local success = commands.SendAudioOutput(device, output_token, "Fallback audio message", DEFAULT_AUDIO_TIMEOUT)
    if success then
        log.info('Fallback audio output via ONVIF succeeded for device: ' .. device.label)
        return true
    else
        log.error('Fallback audio output via ONVIF failed for device: ' .. device.label)
        return false
    end
end

-- Function to fetch a snapshot from the local Home Assistant server
local function fetch_snapshot(device)
    local prefs = device:get_field('effective_prefs')
    local camera_entity = prefs.haCameraEntity

    if not camera_entity then
        log.error(string.format("No Home Assistant camera entity defined for device %s", device.label))
        return nil
    end

    local snapshot_url = string.format("%s/api/camera_proxy/%s", HA_LOCAL_URL, camera_entity)
    log.info(string.format("Fetching snapshot for device %s from local Home Assistant at %s", device.label, snapshot_url))

    local response_body = {}
    local res, code, headers = http.request {
        url = snapshot_url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. HA_LOCAL_TOKEN,
            ["Accept"] = "*/*",
            ["Connection"] = "keep-alive",
            ["User-Agent"] = "SmartThingsEdgeDriver/1.0"
        },
        sink = ltn12.sink.table(response_body)
    }

    if res and code == 200 then
        log.info(string.format("Successfully fetched snapshot for device %s from local Home Assistant", device.label))
        -- The SmartThings app needs a publicly accessible URL; we'll need to handle this separately
        return snapshot_url
    else
        log.error(string.format("Failed to fetch snapshot for device %s from local Home Assistant: HTTP %s", device.label, tostring(code)))
        log.debug("Response: " .. (table.concat(response_body) or "no response"))
        return nil
    end
end

-- Function to construct RTSP URL directly from the device
local function get_rtsp_url(device)
    local prefs = device:get_field('effective_prefs')
    local use_nvr = prefs.useNvrForStreams or false
    local ip, port, userid, password, stream_path

    if use_nvr then
        ip = prefs.nvrIp
        port = prefs.rtspPort
        userid = prefs.userid
        password = prefs.password
        stream_path = "/h264Preview_" .. (device.label:match("Doorbell") and "01_main" or device.label:match("Side Lot") and "02_main" or device.label:match("Driveway Overwatch") and "03_main" or "01_main")
        log.info(string.format("Using NVR for RTSP stream for device %s at %s:%s", device.label, ip, port))
    else
        ip = prefs.ipAddress
        port = prefs.rtspPort
        userid = prefs.userid
        password = prefs.password
        stream_path = prefs.rtspPath
        log.info(string.format("Using direct RTSP stream for device %s at %s:%s", device.label, ip, port))
    end

    if prefs.stream == "substream" then
        stream_path = stream_path:gsub("_main", "_sub")
    end
    local rtsp_url = string.format("rtsp://%s:%s@%s:%s%s", userid, password, ip, port, stream_path)
    return rtsp_url
end

-- Utility Function to Emit Stream and Snapshot
local function emit_video_stream(device)
    local stream_url = get_rtsp_url(device)
    if not stream_url then
        log.error("Failed to get stream URL for " .. device.label)
        device:emit_event(cap_videoStream.streamingStatus("inactive"))
        device:emit_event(onvif_status.status("error"))
        return
    end

    device:set_field("rtsp_url", stream_url)
    log.info("Attempting to emit video stream for " .. device.label .. " (network_id: " .. device.device_network_id .. "): " .. stream_url)

    for attempt = 1, MAX_RETRIES do
        local success, err = pcall(function()
            device:emit_event(cap_videoStream.stream({ uri = stream_url }))
            device:emit_event(cap_videoStream.streamingStatus("active"))
            device:emit_event(onvif_status.status("connected"))
        end)
        if success then
            log.info("Video stream successfully emitted for " .. device.label)
            break
        else
            log.error(string.format("Failed to emit video stream for %s (attempt %d/%d): %s", device.label, attempt, MAX_RETRIES, tostring(err)))
            if attempt < MAX_RETRIES then
                log.debug("Retrying in " .. RETRY_DELAY .. " seconds...")
                socket.sleep(RETRY_DELAY)
            end
        end
    end

    if device:get_field("onvif_status") == "connected" then
        local snapshot_url = fetch_snapshot(device)
        if snapshot_url then
            device:emit_event(cap_videoStream.snapshot({ uri = snapshot_url }))
            log.info("Snapshot emitted for " .. device.label .. ": " .. snapshot_url)
        else
            log.error("Failed to emit snapshot for " .. device.label)
        end
    else
        log.error("Failed to emit video stream after " .. MAX_RETRIES .. " attempts for " .. device.label)
        device:emit_event(cap_videoStream.streamingStatus("inactive"))
        device:emit_event(onvif_status.status("error"))
    end
end

-- Function to fetch ONVIF info (model and firmware) using the commands module
local function fetch_onvif_info(device)
    local prefs = device:get_field('effective_prefs')
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
        device:emit_event(onvif_status.status("error"))
    end
end

-- Driver Setup
local onvif_driver = Driver("ONVIF Video Camera V2.1", {
    discovery = function(driver, _, should_continue)
        log.info("Starting ONVIF discovery")
        discover.discover(5, function(cam_meta)
            local metadata = {
                type = "LAN",
                device_network_id = cam_meta.device_network_id,
                label = cam_meta.label,
                profile = "ONVIF-Doorbell",
                manufacturer = cam_meta.manufacturer,
                model = cam_meta.hardware,
                vendor_provided_label = cam_meta.vendname,
                rtsp_url = cam_meta.rtsp_url
            }
            log.info("Attempting to create device: " .. cam_meta.label .. " with device_network_id: " .. metadata.device_network_id)
            driver:try_create_device(metadata)
        end)
    end,
    lifecycle_handlers = {
        init = function(driver, device)
            log.info("Initializing device: " .. device.label)
            device:emit_event(onvif_status.status("disconnected"))

            -- Fix networkId: remove leading colon or trailing port
            local new_network_id = device.device_network_id
            if device.device_network_id:sub(1, 1) == ":" then
                new_network_id = device.device_network_id:sub(2)
                log.info("Removed leading colon from networkId: " .. device.device_network_id .. " -> " .. new_network_id)
            end
            -- Remove port if present (e.g., "10.0.0.102:554" -> "10.0.0.102")
            local colon_pos = new_network_id:find(":")
            if colon_pos then
                new_network_id = new_network_id:sub(1, colon_pos - 1)
                log.info("Removed port from networkId: " .. device.device_network_id .. " -> " .. new_network_id)
            end
            if new_network_id ~= device.device_network_id then
                device.device_network_id = new_network_id
                log.info("Updated device_network_id to: " .. device.device_network_id)
            end

            log.info("Attempting to sync device with updated profile: 113476c0-2367-4594-b83d-c1b50efc1241")
            device:try_update_metadata({
                profile = "113476c0-2367-4594-b83d-c1b50efc1241",  -- Replace with the new profile ID
                vendor_provided_label = "ReolinkVideoDoorbellPoE"
            })

            local default_prefs = {
                ipAddress = device.label:match("Side Lot") and "10.0.0.58" or device.label:match("Driveway Overwatch") and "10.0.0.102" or "10.0.0.72",
                port = 8000,
                userid = "admin",
                password = "password123",
                stream = "mainstream",  -- Aligns with "fluent" (higher quality); set to "substream" for "clear"
                enableTwoWayAudio = false,
                audioFilePath = "/default/audio.wav",
                quickReply = "Please wait",
                nvrIp = "10.0.0.67",
                rtspPath = "h264Preview_01_main",
                rtspPort = 554,
                minmotioninterval = 5,
                minlinecrossinterval = 5,
                mintamperinterval = 5,
                minvisitorinterval = 5,
                autorevert = "yesauto",
                revertdelay = 10,
                enableBackupStream = false,
                useNvrForStreams = false,
                -- Home Assistant camera entity for snapshots
                haCameraEntity = device.label:match("Doorbell") and "camera.frontdoorproxy" or
                                device.label:match("Side Lot") and "camera.side_lot_fluent" or
                                device.label:match("Driveway Overwatch") and "camera.driveway_overwatch_snapshots_fluent_lens_0" or "camera.unknown"
            }

            local effective_prefs = {}
            for key, default_value in pairs(default_prefs) do
                if device.preferences[key] ~= nil and not (key == "password" and device.preferences[key] == "Doggies44") then
                    effective_prefs[key] = device.preferences[key]
                    log.info(string.format("Using platform preference for %s: %s", key, tostring(effective_prefs[key])))
                else
                    effective_prefs[key] = default_value
                    log.info(string.format("Using default preference for %s: %s", key, tostring(effective_prefs[key])))
                end
            end

            device:set_field('effective_prefs', effective_prefs, { persist = true })
            log.info("Effective preferences set for device " .. device.label)

            emit_video_stream(device)

            -- Start a task to periodically refresh the snapshot
            cosock.spawn(function()
                while true do
                    if device:get_field("onvif_status") == "connected" then
                        local snapshot_url = fetch_snapshot(device)
                        if snapshot_url then
                            device:emit_event(cap_videoStream.snapshot({ uri = snapshot_url }))
                            log.info("Periodic snapshot emitted for " .. device.label .. ": " .. snapshot_url)
                        else
                            log.error("Failed to emit periodic snapshot for " .. device.label)
                        end
                    end
                    socket.sleep(SNAPSHOT_INTERVAL)
                end
            end, "snapshot_refresh_task_" .. device.id)
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
        infoChanged = function(driver, device, event, args)
            log.info("Device info changed for " .. device.label)
            local effective_prefs = device:get_field('effective_prefs') or {}
            local default_prefs = {
                ipAddress = device.label:match("Side Lot") and "10.0.0.58" or device.label:match("Driveway Overwatch") and "10.0.0.102" or "10.0.0.72",
                port = 8000,
                userid = "admin",
                password = "password123",
                stream = "mainstream",
                enableTwoWayAudio = false,
                audioFilePath = "/default/audio.wav",
                quickReply = "Please wait",
                nvrIp = "10.0.0.67",
                rtspPath = "h264Preview_01_main",
                rtspPort = 554,
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
                if args.old_st_device.preferences[key] != device.preferences[key] then
                    if device.preferences[key] != nil and not (key == "password" and device.preferences[key] == "Doggies44") then
                        effective_prefs[key] = device.preferences[key]
                        log.info(string.format("Updated %s to platform value: %s", key, tostring(effective_prefs[key])))
                    else
                        effective_prefs[key] = default_value
                        log.info(string.format("Updated %s to default value: %s", key, tostring(effective_prefs[key])))
                    end
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

onvif_driver:run()

return {
    handle_motion_event = handle_motion_event,
    handle_linecross_event = handle_linecross_event,
    handle_tamper_event = handle_tamper_event,
    handle_visitor_event = handle_visitor_event,
    send_audio_output_ffmpeg = send_audio_output_ffmpeg
}