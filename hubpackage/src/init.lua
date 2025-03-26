--[[
  Copyright 2022 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.

  DESCRIPTION
  
  ONVIF Video camera driver for SmartThings Edge

  MODIFIED BY HaloGod (2025) to add Reolink doorbell support with Visitor event, two-way audio, ffmpeg fallback, and SmartThings Video Widget support.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local os = require "os"  -- Added for ffmpeg command execution

-- Driver-specific libraries
local Thread = require "st.thread"
local classify = require "classify"
local Semaphore = require "semaphore"

local discover = require "discover"
local commands = require "commands"
local events = require "events"
local common = require "common"

-- Custom capabilities
local cap_status = capabilities["partyvoice23922.onvifstatus"]
local cap_info = capabilities["partyvoice23922.onvifinfo"]
local cap_refresh = capabilities["partyvoice23922.refresh"]
local cap_motion = capabilities["partyvoice23922.motionevents2"]
local linecross_capname = "partyvoice23922.linecross"
local cap_linecross = capabilities[linecross_capname]

-- Standard capabilities for two-way communication and video widget
local cap_doorbell = capabilities.doorbell
local cap_videoStream = capabilities.videoStream
local cap_motionSensor = capabilities.motionSensor
local cap_tamperAlert = capabilities.tamperAlert
local cap_audioCapture = capabilities.audioCapture
local cap_audioOutput = capabilities.audioOutput

-- Module Variables
local devcreate_sem
local resub_thread
local resub_timer
local newly_added = {}
local discovered_num = 1

local ONVIFDEVSERVPATH = '/onvif/device_service'
local LINECROSSREVERTDELAY = 1

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
    '<!DOCTYPE html>\n',
    '<HTML>\n',
    '<HEAD>\n',
    '<style>\n',
    'table, td {\n',
    '  border: 1px solid black;\n',
    '  border-collapse: collapse;\n',
    '  font-size: 11px;\n',
    '  padding: 3px;\n',
    '}\n',
    '</style>\n',
    '</HEAD>\n',
    '<BODY>\n',
    '<table>\n',
    html_list,
    '</table>\n',
    '</BODY>\n',
    '</HTML>\n'
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

-- Event Handlers
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
  if not device:supports_capability_by_id(linecross_capname) then return end
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

local function handle_visitor_event(device, cam_func, msg)
  if not device:supports_capability_by_id('doorbell') then return end
  local name, value
  if common.is_element(msg, {'Message', 'Message', 'Data', 'SimpleItem', '_attr', 'Name'}) then
    name = msg.Message.Message.Data.SimpleItem._attr.Name
    value = msg.Message.Message.Data.SimpleItem._attr.Value
    if name == cam_func.visitor_eventrule.item then
      log.info(string.format('Visitor notification for %s: %s', device.label, msg.Topic[1]))
      log.info(string.format('\tVisitor value = "%s"', value))
      if (value == 'true') or (value == '1') then
        if (socket.gettime() - device:get_field('LastVisitor')) >= device.preferences.minvisitorinterval then
          device:emit_event(cap_doorbell.doorbell('pushed'))
          device:set_field('LastVisitor', socket.gettime())
          -- Auto-start video and audio stream for two-way communication
          handle_stream(onvifDriver, device, { command = 'startStream' })
          -- Send greeting if audio output is enabled
          if device.preferences.enableaudiooutput and cam_func.audio_output_token then
            log.debug('Sending auto-greeting for', device.label)
            local success = commands.SendAudioOutput(device, cam_func.audio_output_token, device.preferences.visitorgreeting)
            if not success then
              log.warn('ONVIF audio output failed, attempting ffmpeg fallback')
              local ffmpeg_success = send_audio_output_ffmpeg(device, cam_func.audio_output_token, device.preferences.visitorgreeting)
              if not ffmpeg_success then
                log.error('Both ONVIF and ffmpeg audio output failed for', device.label)
              end
            end
          end
        else
          log.info('Visitor event ignored due to configured min interval')
        end
      end
    else
      log.error('Item name mismatch with Visitor event message:', name)
    end
  else
    log.error('Missing Visitor event item name/value')
  end
end

-- Fallback implementation for SendAudioOutput using ffmpeg
local function send_audio_output_ffmpeg(device, output_token, message)
  -- Ensure ffmpeg is installed on the hub (requires manual setup on SmartThings hub)
  local cam_func = device:get_field('onvif_func')
  if not cam_func or not cam_func.stream_uri then
    log.error('Cannot find stream URI for ffmpeg audio output')
    return false
  end

  -- Construct RTSP URL for audio streaming
  local rtsp_url = 'rtsp://' .. device.preferences.userid .. ':' .. device.preferences.password .. '@' .. cam_func.stream_uri:match('//(.+)')
  -- Use ffmpeg to send audio to the camera (requires audio file or input)
  local audio_file = '/tmp/greeting.wav' -- Assume a pre-recorded greeting file; user must provide
  local ffmpeg_cmd = string.format('ffmpeg -re -i %s -c:a aac -b:a 64k -f rtsp %s', audio_file, rtsp_url)
  log.debug('Attempting ffmpeg audio output with command:', ffmpeg_cmd)

  -- Execute ffmpeg command (requires hub to support os.execute, may need custom setup)
  local handle = io.popen(ffmpeg_cmd)
  if handle then
    local result = handle:read('*a')
    handle:close()
    if result and result:find('success') then
      log.info('ffmpeg audio output successful for', device.label)
      return true
    else
      log.error('ffmpeg audio output failed:', result or 'no output')
    end
  else
    log.error('Failed to execute ffmpeg command for audio output')
  end
  return false
end

local function event_handler(device, msgs)
  local function proc_msg(device, cam_func, msg)
    if not msg.Topic then
      log.error('Missing topic in event message')
      return
    end
    local topic = msg.Topic[1]
    log.debug(string.format('Received event for %s: topic=%s', device.label, topic))
    if topic:find(cam_func.motion_eventrule.topic, 1, 'plaintext') and cam_func.motion_events then
      handle_motion_event(device, cam_func, msg)
    elseif topic:find(cam_func.tamper_eventrule.topic, 1, 'plaintext') and cam_func.tamper_events then
      handle_tamper_event(device, cam_func, msg)
    elseif topic:find(cam_func.linecross_eventrule.topic, 1, 'plaintext') and cam_func.linecross_events then
      handle_linecross_event(device, cam_func, msg)
    elseif topic:find(cam_func.visitor_eventrule.topic, 1, 'plaintext') and cam_func.visitor_events then
      handle_visitor_event(device, cam_func, msg)
    else
      log.warn(string.format('Received message for %s ignored (topic=%s)', device.label, topic))
    end
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

local function get_services(device)
  local meta = device:get_field('onvif_disco')
  local services = commands.GetServices(device, meta.uri.device_service)
  for _, service in ipairs(services.Service) do
    log.debug('Searching services list:', service.Namespace)
    if service.Namespace:find('/events/') then
      if service.XAddr:find('http://') then
        log.debug('\tFound events address:', service.XAddr)
        return service.XAddr
      end
    end
  end
end

local function get_cam_config(device)
  log.info('Starting Device Initialization routine for', device.label)
  local meta = device:get_field('onvif_disco')
  if not meta then
    log.error('Cannot initialize: persistent ONVIF discovery info missing')
    return false
  end
  
  local infolist = init_infolist(device, meta)
  local datetime = commands.GetSystemDateAndTime(device, meta.uri.device_service)
  if not datetime then return false end
  
  device:emit_component_event(device.profile.components.info, cap_status.status('Responding'))
  device:online()
  device:set_field('onvif_online', true)
  
  table.insert(infolist, 'Last refresh hub: ' .. datetime.hub .. ' UTC')
  table.insert(infolist, 'Last refresh cam: ' .. datetime.cam .. ' UTC')
  device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
  device:set_field('onvif_info', infolist)
  
  if device.preferences.userid == '*****' or device.preferences.password == '*****' then
    log.warn('Userid/Password not configured:', device.label)
    return false
  end
  
  local scopes = commands.GetScopes(device, meta.uri.device_service)
  if not scopes then return false end
  
  local foundflag = false
  for _, item in ipairs(scopes) do
    if meta.discotype == 'manual' then
      table.insert(meta.scopes, item)
      foundflag = true
      if item:find('/name/') then
        meta.vendname = item:match('/name/(.+)$')
        table.insert(infolist, 'Name: ' .. meta.vendname)
      elseif item:find('/location/') then
        meta.location = item:match('/location/(.+)$')
        table.insert(infolist, 'Location: ' .. meta.location)
      elseif item:find('/hardware/') then
        meta.hardware = item:match('/hardware/(.+)$')
        table.insert(infolist, 'Hardware: ' .. meta.hardware)
      elseif item:find('/Profile/') then
        local profile = item:match('/Profile/(.+)$')
        table.insert(meta.profiles, profile)
        table.insert(infolist, 'Profile: ' .. profile)
      elseif not item:match('^onvif') then
        table.insert(infolist, item)
      end
    else
      if not item:match('^onvif') then
        table.insert(infolist, item)
        foundflag = true
      end
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
    if type(value) ~= 'table' then
      table.insert(infolist, key .. ': ' .. value)
    end
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
  
  local audio_sources = commands.GetAudioSources(device, onvif_func.media_service_addr)
  if audio_sources then
    log.debug('Audio sources found for', device.label)
    onvif_func.audio_source_token = audio_sources[1] and audio_sources[1]._attr.token or nil
    if onvif_func.audio_source_token then
      table.insert(infolist, 'Audio Input: Supported')
    end
  else
    log.warn('No audio sources available for', device.label)
  end
  
  local audio_outputs = commands.GetAudioOutputs(device, onvif_func.media_service_addr)
  if audio_outputs then
    log.debug('Audio outputs found for', device.label)
    onvif_func.audio_output_token = audio_outputs[1] and audio_outputs[1]._attr.token or nil
    if onvif_func.audio_output_token then
      table.insert(infolist, 'Audio Output: Supported')
    end
  end
  
  device:set_field('onvif_func', onvif_func)
  
  local profiles = commands.GetProfiles(device, onvif_func.media_service_addr)
  if not profiles then return false end
  
  local substream_token, profile_name
  local stream_idx = 1
  local res_width, res_height
  
  if is_array(profiles) then
    if #profiles == 1 then
      log.warn('Only one video profile available')
    else
      if device.preferences.stream ~= 'mainstream' then
        if #profiles > 2 then
          for i, profile in ipairs(profiles) do
            if common.is_element(profile, {'VideoEncoderConfiguration', 'Resolution'}) then
              local width = profile.VideoEncoderConfiguration.Resolution.Width
              local height = profile.VideoEncoderConfiguration.Resolution.Height
              log.debug(string.format('\tProfile #%d resolution: %s x %s', i, width, height))
              if (tonumber(width) < 1000) and (tonumber(height) < 1000) then
                stream_idx = i
                break
              end
            end
          end
        else
          stream_idx = 2
        end
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
      device:set_field('onvif_func', onvif_func)
      log.debug('Stream URI:', onvif_func.stream_uri)
    end
  else
    log.warn('RTSP over TCP is not supported; Streaming disabled')
  end
  
  local function parserule(ruletable)
    local l2topic, l2table
    for rule2, ruletable2 in pairs(ruletable) do
      if rule2 ~= '_attr' then
        l2topic = rule2
        l2table = ruletable2
        break
      end
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
        log.debug('Found Tamper L1 Topic: TamperDetector