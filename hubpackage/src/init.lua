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

-- Driver-specific libraries
local common = require "common"
local commands = require "commands"
local discover = require "discover"

-- Capabilities
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_linecross = capabilities["pianodream12480.linecross"]
local cap_videoStream = capabilities.videoStream
local cap_videoCapture = capabilities.videoCapture

-- Constants
local LINECROSSREVERTDELAY = 1
local DEFAULT_AUDIO_TIMEOUT = 10

-- Event Handler Functions
local function handle_motion_event(device, cam_func, msg)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.motion_eventrule.item then
            log.info(string.format('Message for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tMotion value = "%s"', value))
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastMotion')) >= device.preferences.minmotioninterval then
                    device:emit_event(cap_motionSensor.motion('active'))
                    device:set_field('LastMotion', socket.gettime())
                    if device.preferences.autorevert == 'yesauto' then
                        device.thread:call_with_delay(device.preferences.revertdelay, function()
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
            if (value ~= 'false') and (value ~= '0') then
                if (socket.gettime() - device:get_field('LastLinecross')) >= device.preferences.minlinecrossinterval then
                    device:emit_component_event(device.profile.components.line, cap_linecross.linecross('active'))
                    device:set_field('LastLinecross', socket.gettime())
                    device.thread:call_with_delay(LINECROSSREVERTDELAY, function()
                        device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
                    end, 'revert linecross')
                else
                    log.info('Linecross event ignored due to configured min interval')
                end
            else
                device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
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
                if (socket.gettime() - device:get_field('LastTamper')) >= device.preferences.mintamperinterval then
                    device:emit_component_event(device.profile.components.tamper, cap_tamperAlert.tamper('detected'))
                    device:set_field('LastTamper', socket.gettime())
                    if device.preferences.autorevert == 'yesauto' then
                        device.thread:call_with_delay(device.preferences.revertdelay, function()
                            device:emit_component_event(device.profile.components.tamper, cap_tamperAlert.tamper('clear'))
                        end, 'revert tamper')
                    end
                else
                    log.info('Tamper event ignored due to configured min interval')
                end
            else
                device:emit_component_event(device.profile.components.tamper, cap_tamperAlert.tamper('clear'))
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
        if device.preferences.enableBackupStream and cam_func.backup_stream_uri then
            log.warn("Backup stream requested but availability check skipped (no io library)")
            stream_url = cam_func.backup_stream_uri
            log.info('Switched to backup stream:', stream_url)
        end
        device:emit_event(cap_videoStream.stream({ uri = stream_url }))
    else
        log.error('No stream URI available for', device.label)
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
                if (socket.gettime() - (device:get_field('LastVisitor') or 0)) >= (device.preferences.minvisitorinterval or 5) then
                    device:emit_component_event(device.profile.components.doorbellComponent, cap_doorbell.doorbell('pushed'))
                    device:set_field('LastVisitor', socket.gettime())
                    handle_stream(device, cam_func)
                    if device.preferences.enableTwoWayAudio and cam_func.audio_output_token then
                        log.debug('Sending audio for', device.label)
                        local success = commands.SendAudioOutput(device, cam_func.audio_output_token, "Visitor detected", timeout)
                        if not success then
                            log.warn('ONVIF audio output failed, attempting ffmpeg fallback')
                            local ffmpeg_success = send_audio_output_ffmpeg(device, cam_func.audio_output_token, device.preferences.audioFilePath)
                            if not ffmpeg_success then
                                log.error('Both ONVIF and ffmpeg audio output failed for', device.label)
                            end
                        end
                    end
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
        log.error('Cannot find stream URI for ffmpeg audio output')
        return false
    end
    local rtsp_url = 'rtsp://' .. device.preferences.userid .. ':' .. device.preferences.password .. '@' .. cam_func.stream_uri:match('//(.+)')
    local ffmpeg_cmd = string.format('ffmpeg -re -i "%s" -c:a aac -b:a 64k -f rtsp "%s"', audio_file, rtsp_url)
    log.debug('Executing ffmpeg command:', ffmpeg_cmd)
    log.error('ffmpeg not available in this environment (no io library)')
    return false
end

-- Utility Function to Emit Stream
local function emit_video_stream(device)
    local ip = device.preferences.ipAddress
    if not ip then
        ip = device.device_network_id:match("^([^:]+)") or "unknown_ip"
        log.warn("No ipAddress in preferences for " .. device.label .. ", using device_network_id: " .. ip)
    end
    local username = device.preferences.userid or "admin"
    local password = device.preferences.password or "Doggies44"
    local stream_path = device.preferences.stream == "substream" and "/h264Preview_01_sub" or "/h264Preview_01_main"
    local rtsp_url = string.format("rtsp://%s:%s@%s:554%s", username, password, ip, stream_path)
    device:set_field("rtsp_url", rtsp_url)
    log.info("Emitting video stream for " .. device.label .. " (network_id: " .. device.device_network_id .. "): " .. rtsp_url)
    device:emit_event(cap_videoStream.stream({ uri = rtsp_url }))
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
            log.info("Attempting to create device: " .. cam_meta.label)
            driver:try_create_device(metadata)
        end)
    end,
    lifecycle_handlers = {
        init = function(driver, device)
            log.info("Initializing device: " .. device.label)
            emit_video_stream(device)
        end,
        added = function(driver, device)
            log.info("Device added: " .. device.label .. " (ID: " .. device.id .. ")")
            emit_video_stream(device)
        end,
        doConfigure = function(driver, device)
            log.info("Configuring device: " .. device.label)
            device:online()
            emit_video_stream(device)
        end,
        infoChanged = function(driver, device)
            log.info("Device info changed for " .. device.label)
            emit_video_stream(device)
        end
    },
    capability_handlers = {
        [capabilities.videoCapture.ID] = {
            ["start"] = function(driver, device, command)
                log.info("Video capture start requested for " .. device.label)
            end,
            ["stop"] = function(driver, device, command)
                log.info("Video capture stop requested for " .. device.label)
            end
        },
        [capabilities.videoStream.ID] = {
            ["startStream"] = function(driver, device, command)
                log.info("Video stream start requested for " .. device.label)
                emit_video_stream(device)
            end,
            ["stopStream"] = function(driver, device, command)
                log.info("Video stream stop requested for " .. device.label)
                -- No state change needed; app manages visibility
            end
        },
        [capabilities.refresh.ID] = {
            ["refresh"] = function(driver, device, command)
                log.info("Refresh requested for " .. device.label)
                emit_video_stream(device)
            end
        }
    }
})

-- Run the driver
onvif_driver:run()

-- Export Handlers
return {
    handle_motion_event = handle_motion_event,
    handle_linecross_event = handle_linecross_event,
    handle_tamper_event = handle_tamper_event,
    handle_visitor_event = handle_visitor_event,
    send_audio_output_ffmpeg = send_audio_output_ffmpeg
}