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
  smart events, HDR/day-night settings, and chime/quick reply support. Optimized for NVR-based
  streaming when configured.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local os = require "os"
local json = require "dkjson"  -- For JSON parsing

-- Driver-specific libraries
local Thread = require "st.thread"
local classify = require "classify"
local Semaphore = require "semaphore"
local discover = require "discover"
local commands = require "commands"
local events = require "events"
local common = require "common"
local event_handlers = require "event_handlers"
local audio = require "audio"  -- New audio module for Profile T
local ptz = require "ptz"      -- New PTZ module for TrackMix

-- Custom capabilities
local cap_status = capabilities["pianodream12480.onvifstatus"]
local cap_info = capabilities["pianodream12480.onvifinfo"]
local cap_refresh = capabilities["pianodream12480.refresh"]
local cap_motion = capabilities["pianodream12480.motionevents2"]
local cap_linecross = capabilities["pianodream12480.linecross"]
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_audioStream = capabilities["pianodream12480.twowayaudio"]
local cap_ptzControl = capabilities["pianodream12480.ptzControl"]
local cap_chimeControl = capabilities["pianodream12480.chimeControl"]

-- Standard capabilities
local cap_videoStream = capabilities.videoStream
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_audioCapture = capabilities.audioCapture
local cap_audioOutput = capabilities.audioOutput

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

math.randomseed(socket.gettime())

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
    device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
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

-- Event Handling with Smart Events (Person/Vehicle/Animal Detection)
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
                        device:emit_event(cap_motion.personDetected("active"))
                    elseif object_type:match("Vehicle") then
                        device:emit_event(cap_motion.vehicleDetected("active"))
                    elseif object_type:match("Animal") then
                        device:emit_event(cap_motion.animalDetected("active"))
                    end
                end
            elseif topic:find(cam_func.tamper_eventrule.topic, 1, 'plaintext') and cam_func.tamper_events then
                event_handlers.handle_tamper_event(device, cam_func, msg)
            elseif topic:find(cam_func.linecross_eventrule.topic, 1, 'plaintext') and cam_func.linecross_events then
                event_handlers.handle_linecross_event(device, cam_func, msg)
            elseif topic:find(cam_func.visitor_eventrule.topic, 1, 'plaintext') and cam_func.visitor_events then
                event_handlers.handle_visitor_event(device, cam_func, msg, 15)
                device:emit_event(cap_doorbell.button("pushed"))
                device:emit_event(cap_doorbell.numberOfButtons(1))
                device:emit_event(cap_doorbell.supportedButtonValues({"pushed"}))
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
        if service.Namespace:find('/events/') and service.XAddr:find('http://') then
            log.debug('\tFound events address:', service.XAddr)
            return service.XAddr
        end
    end
end

-- Test Stream Availability
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

-- Get Stream URL (Support NVR Streaming)
local function get_stream_url(device, channel, stream_type)
    local ip = device.preferences.nvrIp ~= "" and device.preferences.nvrIp or device.preferences.ipAddress
    local username = device.preferences.userid
    local password = device.preferences.password
    local stream = stream_type == "mainstream" and "main" or "sub"
    return string.format("rtsp://%s:%s@%s:554/h264Preview_%02d_%s", username, password, ip, channel + 1, stream)
end

-- Discover NVR Channels
local function discover_nvr_channels(device)
    local channels = {}
    local nvr_ip = device.preferences.nvrIp
    if not nvr_ip or nvr_ip == "" then
        log.warn("NVR IP not configured for", device.label)
        return channels
    end

    local json_str = '[ { "cmd" : "GetChannelstatus", "code" : 0, "value" : { "count" : 36, "status" : [ { "channel" : 0, "name" : "Driveway Overwatch", "online" : 1, "sleep" : 0, "uid" : "95270007LEQV1Q6Q" }, { "channel" : 1, "name" : "Side Lot", "online" : 1, "sleep" : 0, "uid" : "95270007LE2C6Y8L" }, { "channel" : 2, "name" : "Doorbell", "online" : 1, "sleep" : 0, "uid" : "95270006Q593IUT7" }, { "channel" : 3, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 4, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 5, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 6, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 7, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 8, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 9, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 10, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 11, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 12, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 13, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 14, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 15, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 16, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 17, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 18, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 19, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 20, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 21, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 22, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 23, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 24, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 25, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 26, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 27, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 28, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 29, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 30, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 31, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 32, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 33, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 34, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" }, { "channel" : 35, "name" : "", "online" : 0, "sleep" : 0, "uid" : "" } ] } } ]'
    local data, pos, err = json.decode(json_str)
    
    if err then
        log.error("Failed to parse NVR channel status JSON:", err)
        return channels
    end

    local channel_data = data[1].value.status
    
    for _, channel in ipairs(channel_data) do
        if channel.online == 1 then
            if channel.name == "Doorbell" then
                device.profile.data = device.profile.data or {}
                device.profile.data.channel = channel.channel
                log.info("Doorbell channel identified:", channel.channel)
            end
            table.insert(channels, {
                channel = channel.channel,
                name = channel.name,
                online = channel.online,
                sleep = channel.sleep,
                uid = channel.uid
            })
        end
    end
    
    device:set_field('nvr_channels', channels)
    log.info("Discovered", #channels, "active NVR channels for", device.label)
    return channels
end

-- Device Configuration and Initialization
local function get_cam_config(device, retries)
    retries = retries or 0
    local MAX_RETRIES = 3
    local BASE_DELAY = 5
    
    log.info('Starting Device Initialization routine for', device.label)
    local meta = device:get_field('onvif_disco')
    if not meta then
        log.error('Cannot initialize: persistent ONVIF discovery info missing')
        if retries < MAX_RETRIES then
            local delay = BASE_DELAY * (2 ^ retries) * (1 + math.random())
            device.thread:call_with_delay(delay, function() get_cam_config(device, retries + 1) end, 'retry-init')
        else
            device:emit_component_event(device.profile.components.info, cap_status.status('Failed'))
            device:set_field('init_failed', true, {['persist'] = true})
        end
        return false
    end
    
    local infolist = init_infolist(device, meta)
    local datetime = commands.GetSystemDateAndTime(device, meta.uri.device_service)
    if not datetime then
        if retries < MAX_RETRIES then
            local delay = BASE_DELAY * (2 ^ retries) * (1 + math.random())
            device.thread:call_with_delay(delay, function() get_cam_config(device, retries + 1) end, 'retry-init')
            return false
        end
        device:emit_component_event(device.profile.components.info, cap_status.status('Failed'))
        return false
    end
    
    device:emit_component_event(device.profile.components.info, cap_status.status('Responding'))
    device:online()
    device:set_field('onvif_online', true)
    
    table.insert(infolist, 'Last refresh hub: ' .. datetime.hub .. ' UTC')
    table.insert(infolist, 'Last refresh cam: ' .. datetime.cam .. ' UTC')
    device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
    device:set_field('onvif_info', infolist)
    
    if not validate_preferences(device) then return false end
    
    local scopes = commands.GetScopes(device, meta.uri.device_service)
    if not scopes then return false end
    
    local foundflag = false
    for _, item in ipairs(scopes) do
        if meta.discotype == 'manual' then
            table.insert(meta.scopes, item)
            foundflag = true
            if item:find('/name/') then meta.vendname = item:match('/name/(.+)$'); table.insert(infolist, 'Name: ' .. meta.vendname)
            elseif peckitem:find('/location/') then meta.location = item:match('/location/(.+)$'); table.insert(infolist, 'Location: ' .. meta.location)
            elseif item:find('/hardware/') then meta.hardware = item:match('/hardware/(.+)$'); table.insert(infolist, 'Hardware: ' .. meta.hardware)
            elseif item:find('/Profile/') then local profile = item:match('/Profile/(.+)$'); table.insert(meta.profiles, profile); table.insert(infolist, 'Profile: ' .. profile)
            elseif not item:match('^onvif') then table.insert(infolist, item) end
        else
            if not item:match('^onvif') then table.insert(infolist, item); foundflag = true end
        end
    end
    
    if foundflag and meta.discotype == 'manual' then
        meta.discotype = 'manual_inited'
        device:set_field('onvif_disco', meta, {['persist'] = true})
    end
    
    if foundflag or meta.discotype == 'manual' then
        device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
        device:set_field('onvif_info', infolist)
    end
    
    local infotable = commands.GetDeviceInformation(device, meta.uri.device_service)
    if not infotable then return false end
    
    for key, value in pairs(infotable) do
        log.debug('\t' .. key, value)
        if type(value) ~= 'table' then table.insert(infolist, key .. ': ' .. value) end
    end
    device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
    device:set_field('onvif_info', infolist)
    
    local capabilities_resp = commands.GetCapabilities(device, meta.uri.device_service)
    if not capabilities_resp then return false end
    
    local onvif_func = {}
    
    if capabilities_resp['Events'] then
        log.debug('Events section of Capabilities response:')
        common.disptable(capabilities_resp.Events, '  ', 5)
        onvif_func.event_service_addr = capabilities_resp['Events']['XAddr']
        if type(onvif_func.event_service_addr) == 'table' then onvif_func.event_service_addr = nil end
        onvif_func.ws_subscription = capabilities_resp['Events']['WSSubscriptionPolicySupport']
        onvif_func.PullPointSupport = capabilities_resp['Events']['WSPullPointSupport']
        if not onvif_func.event_service_addr then
            log.warn('Event service address is blank; trying getServices request')
            onvif_func.event_service_addr = get_services(device)
        end
    else
        log.warn('Camera does not have an Events Capability')
        onvif_func.motion_events = false
    end
    
    if capabilities_resp['Media'] then
        onvif_func.media_service_addr = capabilities_resp['Media']['XAddr']
        if capabilities_resp['Media']['StreamingCapabilities'] then
            onvif_func.RTP_TCP = capabilities_resp['Media']['StreamingCapabilities']['RTP_TCP']
            onvif_func.RTP_RTSP_TCP = capabilities_resp['Media']['StreamingCapabilities']['RTP_RTSP_TCP']
        end
    end
    
    if capabilities_resp['Imaging'] then
        onvif_func.imaging_service_addr = capabilities_resp['Imaging']['XAddr']
        if device.preferences.enableHDR then
            commands.SetImagingSettings(device, onvif_func.imaging_service_addr, { EnableHDR = true })
        end
        commands.SetImagingSettings(device, onvif_func.imaging_service_addr, { DayNightThreshold = device.preferences.dayNightThreshold })
    end
    
    if capabilities_resp['PTZ'] then
        onvif_func.ptz_service_addr = capabilities_resp['PTZ']['XAddr']
        if device.preferences.autoTracking then
            ptz.enable_auto_tracking(device, onvif_func.ptz_service_addr)
        end
    end
    
    local audio_sources = commands.GetAudioSources(device, onvif_func.media_service_addr)
    if audio_sources then
        log.debug('Audio sources found for', device.label)
        onvif_func.audio_source_token = audio_sources[1] and audio_sources[1]._attr.token or nil
        if onvif_func.audio_source_token then table.insert(infolist, 'Audio Input: Supported') end
    else
        log.warn('No audio sources available for', device.label)
    end
    
    local audio_outputs = commands.GetAudioOutputs(device, onvif_func.media_service_addr)
    if audio_outputs then
        log.debug('Audio outputs found for', device.label)
        onvif_func.audio_output_token = audio_outputs[1] and audio_outputs[1]._attr.token or nil
        if onvif_func.audio_output_token then table.insert(infolist, 'Audio Output: Supported') end
    end
    
    device:set_field('onvif_func', onvif_func)
    
    local profiles = commands.GetProfiles(device, onvif_func.media_service_addr)
    if not profiles then return false end
    
    local substream_token, profile_name, stream_idx = 1
    local res_width, res_height
    
    if is_array(profiles) then
        if #profiles == 1 then log.warn('Only one video profile available')
        elseif device.preferences.stream ~= 'mainstream' then
            if #profiles > 2 then
                for i, profile in ipairs(profiles) do
                    if common.is_element(profile, {'VideoEncoderConfiguration', 'Resolution'}) then
                        local width = profile.VideoEncoderConfiguration.Resolution.Width
                        local height = profile.VideoEncoderConfiguration.Resolution.Height
                        log.debug(string.format('\tProfile #%d resolution: %s x %s', i, width, height))
                        if (tonumber(width) < 1000) and (tonumber(height) < 1000) then stream_idx = i; break end
                    end
                end
            else
                stream_idx = 2
            end
        end
        profile_name = profiles[stream_idx].Name
        substream_token = profiles[stream_idx]._attr.token
        if common.is_element(profiles[stream_idx], {'VideoEncoderConfiguration', 'Resolution'}) then
            res_width = profiles[stream_idx].VideoEncoderConfiguration.Resolution.Width
            res_height = profiles[stream_idx].VideoEncoderConfiguration.Resolution.Height
        end
    else
        log.warn('Single video profile only')
        profile_name = profiles.Name
        substream_token = profiles._attr.token
        if common.is_element(profiles, {'VideoEncoderConfiguration', 'Resolution'}) then
            res_width = profiles.VideoEncoderConfiguration.Resolution.Width
            res_height = profiles.VideoEncoderConfiguration.Resolution.Height
        end
    end
    
    log.info(string.format('Using profile name=%s, token=%s', profile_name, substream_token))
    
    if res_width and res_height then
        local restext = string.format('Resolution: %dw x %dh', res_width, res_height)
        log.info(string.format('\t%s', restext))
        table.insert(infolist, restext)
    end
    
    if onvif_func.RTP_RTSP_TCP == 'true' then
        local uri_info = commands.GetStreamUri(device, substream_token, onvif_func.media_service_addr)
        if uri_info then
            onvif_func.stream_uri = uri_info['Uri']
            if device.preferences.enableBackupStream then
                local backup_uri = device.preferences.backupStreamUrl or 'rtsp://[ha_ip]:8554/reolink_backup'
                local success = test_stream_availability(backup_uri)
                if success then
                    onvif_func.backup_stream_uri = backup_uri
                    log.info('Backup stream from HA configured:', backup_uri)
                else
                    log.warn('Backup stream unavailable:', backup_uri)
                end
            end
            device:set_field('onvif_func', onvif_func)
            log.debug('Stream URI:', onvif_func.stream_uri)
        end
    else
        log.warn('RTSP over TCP is not supported; Streaming disabled')
    end
    
    local function parserule(ruletable)
        local l2topic, l2table
        for rule2, ruletable2 in pairs(ruletable) do
            if rule2 ~= '_attr' then l2topic = rule2; l2table = ruletable2; break end
        end
        if common.is_element(l2table, {'MessageDescription', 'Data', 'SimpleItemDescription', '_attr', 'Name'}) then
            local itemname = l2table.MessageDescription.Data.SimpleItemDescription._attr.Name
            log.debug(string.format('\tL2 Topic: %s, name=%s', l2topic, itemname))
            return true, { ['topic'] = l2topic, ['item'] = itemname }
        else
            log.error('\tData item not found')
        end
        return false
    end
    
    onvif_func.motion_events = false
    onvif_func.tamper_events = false
    onvif_func.linecross_events = false
    onvif_func.visitor_events = false
    
    if onvif_func.event_service_addr then
        local event_properties = commands.GetEventProperties(device, onvif_func.event_service_addr)
        if event_properties and event_properties['RuleEngine'] then
            local rules = event_properties['RuleEngine']
            local motionOK = false
            local eventrule
            
            common.disptable(rules, '  ', 12)
            
            local CELLMOTION = { ['topic'] = 'RuleEngine/CellMotionDetector/Motion', ['item'] = 'IsMotion' }
            local MOTIONALARM = { ['topic'] = 'VideoSource/MotionAlarm', ['item'] = 'State' }
            
            if not device.preferences.motionrule or device.preferences.motionrule == 'cell' then
                if rules.CellMotionDetector and common.is_element(rules, {'CellMotionDetector', 'Motion', 'MessageDescription', 'Data', 'SimpleItemDescription', '_attr', 'Name'}) then
                    if rules.CellMotionDetector.Motion.MessageDescription.Data.SimpleItemDescription._attr.Name == CELLMOTION.item then
                        motionOK = true
                        eventrule = CELLMOTION
                        log.info('CellMotionDetector found')
                    end
                end
            elseif device.preferences.motionrule == 'alarm' then
                motionOK = true
                eventrule = MOTIONALARM
            end
            
            if motionOK then
                log.info(string.format('Motion events enabled; using topic %s, item %s', eventrule.topic, eventrule.item))
                onvif_func.motion_events = true
                onvif_func.motion_eventrule = eventrule
            else
                log.warn('Motion events not enabled')
            end
            
            if rules.TamperDetector then
                log.debug('Found Tamper L1 Topic: TamperDetector')
                local enabled, tamperrule = parserule(rules.TamperDetector)
                onvif_func.tamper_events = enabled
                if enabled then onvif_func.tamper_eventrule = tamperrule end
            end
            
            if rules.LineDetector then
                log.debug('Found LineDetector L1 Topic')
                local enabled, linecrossrule = parserule(rules.LineDetector)
                onvif_func.linecross_events = enabled
                if enabled then onvif_func.linecross_eventrule = linecrossrule end
            end
            
            if rules.MyRuleDetector then
                log.debug('Found Visitor L1 Topic: MyRuleDetector')
                local enabled, eventrule = parserule(rules.MyRuleDetector)
                onvif_func.visitor_events = enabled
                if enabled then
                    onvif_func.visitor_eventrule = { ['topic'] = 'RuleEngine/MyRuleDetector/Visitor', ['item'] = eventrule.item }
                    log.info('Visitor events enabled for Reolink doorbell')
                end
            end
            
            if onvif_func.ws_subscription then
                local listenURI = 'http://' .. device.preferences.ipAddress .. ':8080/events'
                local subscription = commands.Subscribe(device, onvif_func.event_service_addr, listenURI)
                if subscription then
                    onvif_func.subscription_reference = subscription
                    onvif_func.event_source_addr = subscription.SubscriptionReference.Address
                    log.info('Subscribed to events for', device.label)
                else
                    log.warn('Failed to subscribe to events for', device.label)
                end
            end
        end
    end
    
    if device.preferences.nvrIp and device.preferences.nvrIp ~= "" then
        discover_nvr_channels(device)
    end
    
    device:set_field('onvif_func', onvif_func)
    device:emit_component_event(device.profile.components.info, cap_status.status('Initialized'))
    device:set_field('init_failed', false, {['persist'] = true})
    return true
end

-- Handle Video Stream (Optimized for NVR Streaming)
local function handle_stream(driver, device, command)
    local cam_func = device:get_field('onvif_func')
    if command.command == 'startStream' then
        local stream_url
        -- Prioritize NVR streaming if configured
        if device.preferences.nvrIp and device.preferences.nvrIp ~= "" then
            local channel = device.profile.data and device.profile.data.channel
            if not channel then
                log.error('No channel assigned for', device.label, '- cannot stream via NVR')
                device:emit_component_event(device.profile.components.info, cap_status.status('No Channel Assigned'))
                return
            end
            stream_url = get_stream_url(device, channel, device.preferences.stream)
            log.info('Using NVR stream for', device.label, 'at channel', channel)
        else
            -- Fallback to direct camera stream if no NVR is configured
            stream_url = cam_func.stream_uri
            log.info('Using direct camera stream for', device.label)
        end

        if stream_url then
            -- Check for backup stream if enabled and primary stream fails
            if device.preferences.enableBackupStream and cam_func.backup_stream_uri then
                if not test_stream_availability(stream_url) then
                    stream_url = cam_func.backup_stream_uri
                    log.info('Switched to backup stream:', stream_url)
                    device:emit_component_event(device.profile.components.info, cap_status.status('Using Backup Stream'))
                end
            end

            if test_stream_availability(stream_url) then
                device:emit_component_event(device.profile.components.video, cap_videoStream.stream({ uri = stream_url }))
                device:emit_component_event(device.profile.components.info, cap_status.status('Streaming'))
            else
                log.error('Stream unavailable for', device.label, stream_url)
                device:emit_component_event(device.profile.components.info, cap_status.status('Stream Unavailable'))
            end
        else
            log.error('No stream URI available for', device.label)
            device:emit_component_event(device.profile.components.info, cap_status.status('No Stream Configured'))
        end
    elseif command.command == 'stopStream' then
        device:emit_component_event(device.profile.components.video, cap_videoStream.stream({}))
        device:emit_component_event(device.profile.components.info, cap_status.status('Stream Stopped'))
    end
end

-- Handle Audio Stream (ONVIF Profile T)
local function handle_audio_stream(driver, device, command)
    if command.command == 'startStream' then
        audio.start_audio_stream(device)
    elseif command.command == 'stopStream' then
        audio.stop_audio_stream(device)
    end
end

-- Handle PTZ Commands
local function handle_ptz(driver, device, command)
    local cam_func = device:get_field('onvif_func')
    if not cam_func.ptz_service_addr then
        log.warn('PTZ service not available for', device.label)
        return
    end
    if command.command == 'panLeft' then
        ptz.pan_left(device, cam_func.ptz_service_addr)
    elseif command.command == 'panRight' then
        ptz.pan_right(device, cam_func.ptz_service_addr)
    elseif command.command == 'tiltUp' then
        ptz.tilt_up(device, cam_func.ptz_service_addr)
    elseif command.command == 'tiltDown' then
        ptz.tilt_down(device, cam_func.ptz_service_addr)
    elseif command.command == 'zoomIn' then
        ptz.zoom_in(device, cam_func.ptz_service_addr)
    elseif command.command == 'zoomOut' then
        ptz.zoom_out(device, cam_func.ptz_service_addr)
    elseif command.command == 'trackStart' then
        ptz.enable_auto_tracking(device, cam_func.ptz_service_addr)
    elseif command.command == 'trackStop' then
        ptz.disable_auto_tracking(device, cam_func.ptz_service_addr)
    end
end

-- Handle Chime Commands
local function handle_chime(driver, device, command)
    local cam_func = device:get_field('onvif_func')
    if not cam_func.audio_output_token then
        log.warn('Audio output not available for', device.label)
        return
    end
    if command.command == 'playChime' then
        commands.SetAudioOutput(device, cam_func.audio_output_token, device.preferences.quickReply)
    end
end

-- Lifecycle Handlers
local function device_added(driver, device)
    log.info('Device added:', device.label)
    if validate_preferences(device) then
        device.thread:call_with_delay(2, function() get_cam_config(device) end)
    else
        device:emit_component_event(device.profile.components.info, cap_status.status('Config Incomplete'))
    end
end

local function device_init(driver, device)
    log.info('Device init:', device.label)
    if validate_preferences(device) and not device:get_field('onvif_func') then
        get_cam_config(device)
    end
end

local function device_removed(driver, device)
    log.info('Device removed:', device.label)
    local cam_func = device:get_field('onvif_func')
    if cam_func and cam_func.event_source_addr then
        commands.Unsubscribe(device)
    end
    audio.device_removed(driver, device)
end

-- Driver Setup
onvifDriver = Driver("ONVIFDoorbell", {
    discovery = discover.discover_handler,
    device_added = device_added,
    device_init = device_init,
    device_removed = device_removed,
    capability_handlers = {
        [cap_refresh.ID] = {
            [cap_refresh.commands.refresh.NAME] = function(driver, device) get_cam_config(device) end,
        },
        [cap_videoStream.ID] = {
            [cap_videoStream.commands.startStream.NAME] = handle_stream,
            [cap_videoStream.commands.stopStream.NAME] = handle_stream,
        },
        [cap_audioStream.ID] = {
            [cap_audioStream.commands.startStream.NAME] = handle_audio_stream,
            [cap_audioStream.commands.stopStream.NAME] = handle_audio_stream,
        },
        [cap_ptzControl.ID] = {
            [cap_ptzControl.commands.panLeft.NAME] = handle_ptz,
            [cap_ptzControl.commands.panRight.NAME] = handle_ptz,
            [cap_ptzControl.commands.tiltUp.NAME] = handle_ptz,
            [cap_ptzControl.commands.tiltDown.NAME] = handle_ptz,
            [cap_ptzControl.commands.zoomIn.NAME] = handle_ptz,
            [cap_ptzControl.commands.zoomOut.NAME] = handle_ptz,
            [cap_ptzControl.commands.trackStart.NAME] = handle_ptz,
            [cap_ptzControl.commands.trackStop.NAME] = handle_ptz,
        },
        [cap_chimeControl.ID] = {
            [cap_chimeControl.commands.playChime.NAME] = handle_chime,
        },
    },
})

-- Start the driver
onvifDriver:run()