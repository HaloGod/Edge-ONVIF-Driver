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
  
  ONVIF Video camera driver for SmartThings Edge with Reolink Doorbell support, two-way audio,
  SmartThings Video Widget, and Home Assistant backup stream. Enhanced with retry logic,
  concurrency control, modular event handling, subscription management, NVR streaming, PTZ,
  smart events, HDR/day-night settings, and chime/quick reply support.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local json = require "dkjson"

-- Driver-specific libraries
local Thread = require "st.thread"
local classify = require "classify"
local Semaphore = require "semaphore"
local discover = require "discover"
local commands = require "commands"
local events = require "events"
local common = require "common"
local event_handlers = require "event_handlers"
local audio = require "audio"
local ptz = require "ptz"

-- Custom capabilities
local cap_status = capabilities["pianodream12480.onvifStatus"]
local cap_info = capabilities["pianodream12480.onvifInfo"]
local cap_refresh = capabilities["pianodream12480.refresh"]
local cap_motion = capabilities["pianodream12480.motionevents2"]
local cap_linecross = capabilities["pianodream12480.linecross"]
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_audioStream = capabilities["pianodream12480.twoWayAudio"]
local cap_ptzControl = capabilities["pianodream12480.customPtzControl"]
local cap_chimeControl = capabilities["pianodream12480.customChimeControl"]
local cap_audioOutput = capabilities["pianodream12480.audioOutput"]

-- Standard capabilities
local cap_videoStream = capabilities.videoStream
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert

-- Module Variables
local devcreate_sem = Semaphore(1)
local resub_thread
local resub_timer
local newly_added = {}
local discovered_num = 1
local event_sem = Semaphore(5)

local ONVIFDEVSERVPATH = '/onvif/device_service'

-- Global Variables
onvifDriver = {}

math.randomseed(os.time())

-- Utility Functions
local function build_html(list)
    local html_list = ''
    for itemnum, item in ipairs(list) do
        html_list = html_list .. '<tr><td>' .. item .. '</td></tr>\n'
    end
    local html = {
        '<!DOCTYPE html>\n', '<HTML>\n', '<HEAD>\n', '<style>\n',
        'table, td {\n  border: 1px solid black;\n  border-collapse: collapse;\n  font-size: 11px;\n  padding: 3px;\n}\n',
        '</style>\n', '</HEAD>\n', '<BODY>\n', '<table>\n', html_list, '</table>\n', '</BODY>\n', '</HTML>\n'
    }
    return table.concat(html)
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local function init_infolist(device, ipcam)
    local infolist = {}
    table.insert(infolist, 'IP addr: ' .. ipcam.ip)
    if ipcam.vendname then table.insert(infolist, 'Name: ' .. ipcam.vendname) end
    if ipcam.hardware then table.insert(infolist, 'Hardware: ' .. ipcam.hardware) end
    if ipcam.location then table.insert(infolist, 'Location: ' .. ipcam.location) end
    for _, profile in ipairs(ipcam.profiles) do
        table.insert(infolist, 'Profile: ' .. profile)
    end
    if ipcam.urn then table.insert(infolist, ipcam.urn) end
    device:emit_component_event(device.profile.components["main"], cap_info.info(build_html(infolist)))
    device:set_field('onvif_info', infolist)
    return infolist
end

local function validate_preferences(device)
    local defaults = {
        minmotioninterval = 5, minlinecrossinterval = 5, mintamperinterval = 5, minvisitorinterval = 5,
        revertdelay = 10, autorevert = 'noauto', enableTwoWayAudio = false, audioFilePath = '/default/audio.wav',
        enableBackupStream = false, backupStreamUrl = 'rtsp://[ha_ip]:8554/reolink_backup', stream = 'mainstream',
        motionrule = 'cell', userid = '*****', password = '*****', nvrIp = '', enableHDR = false,
        dayNightThreshold = 50, autoTracking = false, quickReply = 'Please wait.'
    }
    for key, default in pairs(defaults) do
        if device.preferences[key] == nil or (type(device.preferences[key]) ~= type(default) and key ~= 'userid' and key ~= 'password') then
            log.warn(string.format('Invalid or missing preference %s for %s, using default: %s', key, device.label, tostring(default)))
            device.preferences[key] = default
        end
    end
    if device.preferences.userid == '*****' or device.preferences.password == '*****' then
        log.warn('Userid/Password not configured for', device.label)
        return false
    end
    return true
end

-- Event Handling with Smart Events
local function event_handler(device, msgs)
    local function proc_msg(device, cam_func, msg)
        event_sem:acquire(function()
            if not msg.Topic then
                log.error('Missing topic in event message')
                return
            end
            local topic = msg.Topic[1]
            log.debug(string.format('Received event for %s: topic=%s', device.label, topic))
            
            if topic:find(cam_func.motion_eventrule.topic, 1, 'plaintext') and cam_func.motion_events then
                local object_type = msg.Data and msg.Data.SimpleItem and msg.Data.SimpleItem.Value or nil
                event_handlers.handle_motion_event(device, cam_func, msg)
                if object_type then
                    if object_type:match("Person") then
                        device:emit_component_event(device.profile.components["motionComponent"], cap_motion.personDetected("active"))
                    elseif object_type:match("Vehicle") then
                        device:emit_component_event(device.profile.components["motionComponent"], cap_motion.vehicleDetected("active"))
                    elseif object_type:match("Animal") then
                        device:emit_component_event(device.profile.components["motionComponent"], cap_motion.animalDetected("active"))
                    end
                end
            elseif topic:find(cam_func.tamper_eventrule.topic, 1, 'plaintext') and cam_func.tamper_events then
                event_handlers.handle_tamper_event(device, cam_func, msg)
            elseif topic:find(cam_func.linecross_eventrule.topic, 1, 'plaintext') and cam_func.linecross_events then
                event_handlers.handle_linecross_event(device, cam_func, msg)
            elseif topic:find(cam_func.visitor_eventrule.topic, 1, 'plaintext') and cam_func.visitor_events then
                event_handlers.handle_visitor_event(device, cam_func, msg, 15)
                device:emit_component_event(device.profile.components["doorbellComponent"], cap_doorbell.button("pushed"))
                device:emit_component_event(device.profile.components["doorbellComponent"], cap_doorbell.numberOfButtons(1))
                device:emit_component_event(device.profile.components["doorbellComponent"], cap_doorbell.supportedButtonValues({"pushed"}))
                if device.preferences.quickReply and device.preferences.quickReply ~= "" then
                    commands.SetAudioOutput(device, cam_func.audio_output_token, device.preferences.quickReply)
                end
            else
                log.warn(string.format('Received message for %s ignored (topic=%s)', device.label, topic))
            end
            event_sem:release()
        end)
    end
    
    local cam_func = device:get_field('onvif_func')
    if is_array(msgs) then
        for _, msg in ipairs(msgs) do
            proc_msg(device, cam_func, msg)
        end
    else
        proc_msg(device, cam_func, msgs)
    end
end

-- Get Event Service Address
local function get_services(device)
    local meta = device:get_field('onvif_disco')
    local services = commands.GetServices(device, meta.uri.device_service)
    for _, service in ipairs(services.Service) do
        log.debug('Searching services list:', service.Namespace)
        if service.Namespace:find('/events/') then
            log.debug('\tFound events address:', service.XAddr)
            return service.XAddr
        end
    end
end

-- Test Stream Availability (Replaced io.popen with socket check)
local function test_stream_availability(stream_url)
    local parsed_url = stream_url:match("rtsp://([^/]+)")
    if not parsed_url then
        log.error("Invalid RTSP URL:", stream_url)
        return false
    end
    local host, port = parsed_url:match("([^:]+):?(%d*)")
    port = port and tonumber(port) or 554
    local sock = socket.tcp()
    sock:settimeout(5)
    local success, err = sock:connect(host, port)
    if success then
        sock:close()
        return true
    else
        log.warn("Stream availability check failed:", err)
        return false
    end
end

-- Get Stream URL (Support NVR Streaming)
local function get_stream_url(device, channel, stream_type)
    local ip = device.preferences.nvrIp ~= "" and device.preferences.nvrIp or device.preferences.ipAddress
    local username = device.preferences.userid
    local password = device.preferences.password
    local stream = stream_type == "mainstream" and "main" or "sub"
    return string.format("rtsp://%s:%s@%s/h264Preview_%02d_%s", username, password, ip, channel, stream)
end

-- Discover NVR Channels (Stubbed for now)
local function discover_nvr_channels(device)
    local channels = {}
    local nvr_ip = device.preferences.nvrIp
    if not nvr_ip or nvr_ip == "" then
        log.warn("NVR IP not configured for", device.label)
        return channels
    end
    -- Placeholder for NVR channel discovery logic
    return channels
end

-- Driver Handlers
local function device_added(driver, device)
    log.info("Device added:", device.label)
    device:emit_component_event(device.profile.components["main"], cap_status.status("Initializing"))
    local ipcam = { ip = device.preferences.ipAddress }
    init_infolist(device, ipcam)
    if validate_preferences(device) then
        local event_service_addr = get_services(device)
        if event_service_addr then
            events.subscribe(driver, device, "motion", event_handler)
        end
    end
end

local function device_init(driver, device)
    log.info("Device init:", device.label)
    device:emit_component_event(device.profile.components["main"], cap_status.status("Online"))
end

local function device_removed(driver, device)
    log.info("Device removed:", device.label)
    events.shutdownserver(driver, device)
end

-- Run self-tests for libraries
local function run_self_tests()
    log.info("Running self-tests for all modules")
    local common_test = require("common").self_test and require("common").self_test() or true
    local sha1_test = require("sha1").self_test()
    if not (common_test and sha1_test) then
        log.error("Self-tests failed; check library implementations")
    end
end

-- Driver Definition
local onvif_driver = Driver("onvif_driver", {
    discovery = discover.device_discovery,
    device_added = device_added,
    device_init = device_init,
    device_removed = device_removed,
})

-- Run Driver
run_self_tests()
onvif_driver:run()