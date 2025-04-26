--[[
  Copyright 2022 Todd Austin, enhanced 2025 by HaloGod and suggestions for dMac
  Licensed under the Apache License, Version 2.0
  http://www.apache.org/licenses/LICENSE-2.0
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local socket = require "socket" -- Changed from cosock.socket
local log = require "log"

-- Driver-specific libraries
local common = require "common"
local commands = require "commands"

-- Capabilities
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_linecross = capabilities["pianodream12480.linecross"]
local cap_videoStream = capabilities.videoStream

-- Constants
local LINECROSSREVERTDELAY = 1
local DEFAULT_AUDIO_TIMEOUT = 10

-- Initialize device fields to prevent nil errors
local function initialize_device_fields(device)
    device:set_field('LastMotion', device:get_field('LastMotion') or 0, { persist = true })
    device:set_field('LastLinecross', device:get_field('LastLinecross') or 0, { persist = true })
    device:set_field('LastTamper', device:get_field('LastTamper') or 0, { persist = true })
    device:set_field('LastVisitor', device:get_field('LastVisitor') or 0, { persist = true })
end

-- Event Handler Functions
local function handle_motion_event(device, cam_func, msg)
    initialize_device_fields(device)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.motion_eventrule.item then
            log.info("Motion event for " .. device.label .. ": " .. tostring(msg.Topic[1]))
            local prefs = device:get_field('effective_prefs') or {}
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastMotion')) >= (prefs.minmotioninterval or 5) then
                    device:emit_event(cap_motionSensor.motion('active'))
                    device:set_field('LastMotion', socket.gettime(), { persist = true })
                    if prefs.autorevert == 'yesauto' then
                        device.thread:call_with_delay(prefs.revertdelay or 10, function()
                            device:emit_event(cap_motionSensor.motion('inactive'))
                        end, 'revert_motion_' .. device.id)
                    end
                end
            else
                device:emit_event(cap_motionSensor.motion('inactive'))
            end
        else
            log.warn("Motion event name mismatch: " .. tostring(name))
        end
    else
        log.error("Missing motion event name/value")
    end
end

local function handle_linecross_event(device, cam_func, msg)
    if not device:supports_capability_by_id("pianodream12480.linecross") then return end
    initialize_device_fields(device)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.linecross_eventrule.item then
            log.info("Linecross event for " .. device.label .. ": " .. tostring(msg.Topic[1]))
            local prefs = device:get_field('effective_prefs') or {}
            if type(value) == 'string' then value = string.lower(value) end
            if (value ~= 'false') and (value ~= '0') then
                if (socket.gettime() - device:get_field('LastLinecross')) >= (prefs.minlinecrossinterval or 5) then
                    device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('active'))
                    device:set_field('LastLinecross', socket.gettime(), { persist = true })
                    device.thread:call_with_delay(LINECROSSREVERTDELAY, function()
                        device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('inactive'))
                    end, 'revert_linecross_' .. device.id)
                end
            else
                device:emit_component_event(device.profile.components.lineComponent, cap_linecross.linecross('inactive'))
            end
        else
            log.warn("Linecross event name mismatch: " .. tostring(name))
        end
    else
        log.error("Missing linecross event name/value")
    end
end

local function handle_tamper_event(device, cam_func, msg)
    if not device:supports_capability_by_id('tamperAlert') then return end
    initialize_device_fields(device)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.tamper_eventrule.item then
            log.info("Tamper event for " .. device.label .. ": " .. tostring(msg.Topic[1]))
            local prefs = device:get_field('effective_prefs') or {}
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastTamper')) >= (prefs.mintamperinterval or 5) then
                    device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('detected'))
                    device:set_field('LastTamper', socket.gettime(), { persist = true })
                    if prefs.autorevert == 'yesauto' then
                        device.thread:call_with_delay(prefs.revertdelay or 10, function()
                            device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('clear'))
                        end, 'revert_tamper_' .. device.id)
                    end
                end
            else
                device:emit_component_event(device.profile.components.tamperComponent, cap_tamperAlert.tamper('clear'))
            end
        else
            log.warn("Tamper event name mismatch: " .. tostring(name))
        end
    else
        log.error("Missing tamper event name/value")
    end
end

local function handle_stream(device, cam_func)
    if cam_func.stream_uri then
        local stream_url = cam_func.stream_uri
        local prefs = device:get_field('effective_prefs') or {}
        if prefs.enableBackupStream and cam_func.backup_stream_uri then
            stream_url = cam_func.backup_stream_uri
            log.info("Using backup stream: " .. stream_url)
        end
        device:emit_event(cap_videoStream.stream({ uri = stream_url }))
    else
        log.error("No stream URI for " .. device.label)
    end
end

local function handle_visitor_event(device, cam_func, msg)
    if not device:supports_capability_by_id('pianodream12480.doorbell') then return end
    initialize_device_fields(device)
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.visitor_eventrule.item then
            log.info("Visitor event for " .. device.label .. ": " .. tostring(msg.Topic[1]))
            local prefs = device:get_field('effective_prefs') or {}
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - device:get_field('LastVisitor')) >= (prefs.minvisitorinterval or 5) then
                    device:emit_component_event(device.profile.components.doorbellComponent, cap_doorbell.button('pressed'))
                    device:set_field('LastVisitor', socket.gettime(), { persist = true })
                    handle_stream(device, cam_func)
                    if prefs.enableTwoWayAudio and cam_func.audio_output_token then
                        local success = commands.SendAudioOutput(device, cam_func.audio_output_token, "Visitor detected", DEFAULT_AUDIO_TIMEOUT)
                        if not success then
                            log.warn("ONVIF audio output failed for " .. device.label)
                        end
                    end
                    device.thread:call_with_delay(1, function()
                        device:emit_component_event(device.profile.components.doorbellComponent, cap_doorbell.button('released'))
                    end, 'doorbell_release_' .. device.id)
                end
            end
        else
            log.warn("Visitor event name mismatch: " .. tostring(name))
        end
    else
        log.error("Missing visitor event name/value")
    end
end

local function send_audio_output_fallback(device, output_token, audio_file)
    local cam_func = device:get_field('onvif_func') or {}
    if not cam_func.stream_uri then
        log.error("No stream URI for audio output")
        return false
    end
    log.info("Fallback audio output for " .. device.label)
    local success = commands.SendAudioOutput(device, output_token, "Fallback audio message", DEFAULT_AUDIO_TIMEOUT)
    if success then
        log.info("Fallback audio succeeded for " .. device.label)
        return true
    end
    log.error("Fallback audio failed for " .. device.label)
    return false
end

return {
    handle_motion_event = handle_motion_event,
    handle_linecross_event = handle_linecross_event,
    handle_tamper_event = handle_tamper_event,
    handle_visitor_event = handle_visitor_event,
    handle_stream = handle_stream,
    send_audio_output_fallback = send_audio_output_fallback
}