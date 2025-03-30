--[[
  Copyright 2022 Todd Austin, enhanced 2025 by HaloGod and suggestions for dMac

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.

  DESCRIPTION
  
  Event handlers for ONVIF Video camera driver for SmartThings Edge. Handles motion, linecross,
  tamper, and visitor events, including Reolink Doorbell-specific visitor events with two-way
  audio and video streaming support, with timeout passing for audio commands.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local log = require "log"

-- Driver-specific libraries
local common = require "common"
local commands = require "commands"

-- Capabilities
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_doorbell = capabilities.doorbell
local cap_linecross = capabilities["pianodream12480.linecross"]
local cap_videoStream = capabilities.videoStream

-- Constants
local LINECROSSREVERTDELAY = 1
local DEFAULT_AUDIO_TIMEOUT = 10  -- Default timeout for audio commands

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

local function test_stream_availability(stream_url)
    local cmd = string.format('ffmpeg -i "%s" -t 5 -f null -', stream_url)
    local handle = io.popen(cmd .. ' 2>&1')
    if handle then
        local result = handle:read('*a')
        handle:close()
        return not result:match('error')
    end
    return false
end

local function handle_stream(device, cam_func)
    if cam_func.stream_uri then
        local stream_url = cam_func.stream_uri
        if device.preferences.enableBackupStream and cam_func.backup_stream_uri then
            if not test_stream_availability(stream_url) then
                stream_url = cam_func.backup_stream_uri
                log.info('Switched to backup stream:', stream_url)
            end
        end
        device:emit_component_event(device.profile.components.video, cap_videoStream.stream({ uri = stream_url }))
    else
        log.error('No stream URI available for', device.label)
    end
end

local function handle_visitor_event(device, cam_func, msg, timeout)
    timeout = timeout or DEFAULT_AUDIO_TIMEOUT
    if not device:supports_capability_by_id('doorbell') then return end
    local name, value
    if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
        name = msg.Message.Message.Data.SimpleItem._attr.Name
        value = msg.Message.Message.Data.SimpleItem._attr.Value
        if name == cam_func.visitor_eventrule.item then
            log.info(string.format('Visitor notification for %s: %s', device.label, msg.Topic[1]))
            log.info(string.format('\tVisitor value = "%s"', value))
            if (value == 'true') or (value == '1') then
                if (socket.gettime() - (device:get_field('LastVisitor') or 0)) >= (device.preferences.minvisitorinterval or 5) then
                    device:emit_event(cap_doorbell.doorbell('pushed'))
                    device:set_field('LastVisitor', socket.gettime())
                    -- Start video stream
                    handle_stream(device, cam_func)
                    -- Send audio if enabled
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
    local handle = io.popen(ffmpeg_cmd)
    if handle then
        local result = handle:read('*a')
        handle:close()
        if result and not result:match('error') then
            log.info('ffmpeg audio output successful for', device.label)
            return true
        else
            log.error('ffmpeg audio output failed:', result or 'no output')
        end
    else
        log.error('Failed to execute ffmpeg command')
    end
    return false
end

-- Export Handlers
return {
    handle_motion_event = handle_motion_event,
    handle_linecross_event = handle_linecross_event,
    handle_tamper_event = handle_tamper_event,
    handle_visitor_event = handle_visitor_event,
    send_audio_output_ffmpeg = send_audio_output_ffmpeg
}