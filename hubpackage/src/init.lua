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

  MODIFIED BY HaloGod (2025) to add Reolink doorbell support with Visitor event handling and two-way audio.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

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

-- Standard capabilities for two-way communication
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
          device:emit_event(capabilities.motionSensor.motion('active'))
          device:set_field('LastMotion', socket.gettime())
          if device.preferences.autorevert == 'yesauto' then
            device.thread:call_with_delay(device.preferences.revertdelay, function()
              device:emit_event(capabilities.motionSensor.motion('inactive'))
            end, 'revert motion')
          end
        else
          log.info('Motion event ignored due to configured min interval')
        end
      else
        device:emit_event(capabilities.motionSensor.motion('inactive'))
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
          device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('detected'))
          device:set_field('LastTamper', socket.gettime())
          if device.preferences.autorevert == 'yesauto' then
            device.thread:call_with_delay(device.preferences.revertdelay, function()
              device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
            end, 'revert tamper')
          end
        else
          log.info('Tamper event ignored due to configured min interval')
        end
      else
        device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
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
          device:emit_event(capabilities.doorbell.doorbell('pushed'))
          device:set_field('LastVisitor', socket.gettime())
          -- Auto-start video and audio stream for two-way communication
          handle_stream(onvifDriver, device, { command = 'startStream' })
          -- Send greeting if audio output is enabled
          if device.preferences.enableaudiooutput and cam_func.audio_output_token then
            log.debug('Sending auto-greeting for', device.label)
            commands.SendAudioOutput(device, cam_func.audio_output_token, device.preferences.visitorgreeting)
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
  else
    log.warn('No audio outputs available for', device.label)
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
        log.debug('Found Tamper L1 Topic: TamperDetector')
        local enabled, eventrule = parserule(rules.TamperDetector)
        onvif_func.tamper_events = enabled
        if enabled then
          onvif_func.tamper_eventrule = eventrule
          log.info('Tamper events available')
        end
      end
      
      for rule, ruletable in pairs(rules) do
        if string.find(rule, 'Line') and string.find(rule, 'Detector') then
          log.debug('Found Line-crossed L1 Topic:', rule)
          local enabled, eventrule = parserule(ruletable)
          onvif_func.linecross_events = enabled
          if enabled then
            onvif_func.linecross_eventrule = eventrule
            log.info('LineCross events available')
          end
        end
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
    else
      log.error('Event properties not available or missing RuleEngine section')
    end
  end
  
  device:emit_component_event(device.profile.components.info, cap_info.info(build_html(infolist)))
  device:set_field('onvif_info', infolist)
  device:set_field('onvif_func', onvif_func)
  return true
end

local function resetlastevents(device)
  device:set_field('LastMotion', socket.gettime() - device.preferences.minmotioninterval)
  device:set_field('LastLinecross', socket.gettime() - device.preferences.minlinecrossinterval)
  device:set_field('LastTamper', socket.gettime() - device.preferences.mintamperinterval)
  device:set_field('LastVisitor', socket.gettime() - device.preferences.minvisitorinterval)
end

local function start_events(device)
  local cam_func = device:get_field('onvif_func')
  if cam_func and (cam_func.motion_events or cam_func.visitor_events) then
    local response = events.subscribe(onvifDriver, device, cam_func.motion_event_name or "visitor", event_handler)
    if response then
      cam_func.event_source_addr = response.SubscriptionReference.Address
      device:set_field('onvif_func', cam_func)
      resetlastevents(device)
      device:emit_component_event(device.profile.components.info, cap_status.status('Subscribed to events'))
      return true
    else
      log.error('Failed to subscribe to events', device.label)
    end
  else
    log.warn('No motion or visitor events available from this camera')
  end
end

function init_device(device)
  if get_cam_config(device) then
    local cam_func = device:get_field('onvif_func')
    if cam_func and (cam_func.motion_events or cam_func.visitor_events) then
      local curstate = device:get_latest_state("main", cap_motion.ID, cap_motion.motionSwitch.NAME)
      log.debug('Current motion switch value: ', curstate)
      if curstate == 'On' then
        start_events(device)
      end
    else
      device:emit_event(cap_motion.motionSwitch('Off'))
    end
    log.info(string.format('%s initialized', device.label))
    device:online()
    device:set_field('init_retries', 0)
  else
    log.error('Failed to initialize device', device.label)
    device:emit_component_event(device.profile.components.info, cap_status.status('Not responding'))
    if not device:get_field('onvif_online') then
      device:offline()
      local discotype = device:get_field('onvif_disco').discotype
      if not discotype or discotype == 'auto' then
        discover.schedule_rediscover(onvifDriver, device, 20, init_device)
      end
    else
      device:set_field('init_retries', device:get_field('init_retries') + 1)
      if device:get_field('init_retries') < 5 then
        onvifDriver:call_with_delay(14 + math.random(1, 8), function()
          device.thread:queue_event(init_device, device)
        end)
      end
    end
  end
end

local function handle_refresh(driver, device, command)
  log.info('Refresh requested')
  discover.cancel_rediscover(driver, device)
  init_device(device)
end

local function handle_switch(driver, device, command)
  log.debug(string.format('%s switch command received: %s', command.component, command.command))
  local cam_func = device:get_field('onvif_func')
  if cam_func and (cam_func.motion_events or cam_func.visitor_events) then
    if command.command == 'switchOn' then
      if start_events(device) then
        device:emit_event(cap_motion.motionSwitch('On'))
        return
      end
    elseif command.command == 'switchOff' then
      commands.Unsubscribe(device, cam_func.event_service_addr)
      log.info('Unsubscribed to events for', device.label)
      events.shutdownserver(driver, device)
      device:emit_component_event(device.profile.components.info, cap_status.status('Unsubscribed to events'))
      device:emit_event(capabilities.motionSensor.motion('inactive'))
    end
  else
    log.warn(string.format('Cannot enable events - %s not yet initialized or events unavailable', device.label))
  end
  device:emit_event(cap_motion.motionSwitch('Off'))
end

local function handle_stream(driver, device, command)
  log.debug('Streaming handler invoked with command', command.command)
  local live_video = {
    ['InHomeURL'] = '',
    ['OutHomeURL'] = ''
  }
  local cam_func = device:get_field('onvif_func')
  if cam_func then
    if command.command == 'startStream' then
      if cam_func.stream_uri then
        local build_url = 'rtsp://' .. device.preferences.userid .. ':' .. device.preferences.password .. '@' .. cam_func.stream_uri:match('//(.+)')
        log.debug('Providing video stream URL to SmartThings:', build_url)
        live_video.InHomeURL = build_url
        if device.preferences.enableaudiocapture and cam_func.audio_source_token then
          local audio_uri = commands.GetStreamUri(device, cam_func.audio_source_token, cam_func.media_service_addr)
          if audio_uri then
            log.debug('Providing audio stream URL:', audio_uri['Uri'])
            live_video.AudioURL = audio_uri['Uri'] -- Custom field for future SmartThings support
          end
        end
      end
    end
    local success, err = pcall(function()
      device:emit_event(capabilities.videoStream.stream(live_video, { visibility = { displayed = false } }))
    end)
    if not success then
      log.error('Failed to emit stream event: ' .. err)
    end
  else
    log.error('Cannot stream - onvif_func not initialized for', device.label)
  end
end

local function handle_audio_output(driver, device, command)
  log.debug('Audio output handler invoked with command', command.command)
  local cam_func = device:get_field('onvif_func')
  if cam_func and cam_func.audio_output_token and device.preferences.enableaudiooutput then
    if command.command == 'play' and command.args and command.args.message then
      log.info('Sending audio message to', device.label, ':', command.args.message)
      local success, err = pcall(function()
        commands.SendAudioOutput(device, cam_func.audio_output_token, command.args.message)
        device:emit_event(capabilities.audioOutput.audioOutput('playing'))
      end)
      if not success then
        log.error('Failed to send audio output: ' .. err)
        device:emit_event(capabilities.audioOutput.audioOutput('stopped'))
      end
    else
      log.warn('Invalid audio output command or missing message')
    end
  else
    log.warn('Audio output not supported or disabled for', device.label)
  end
end

local function device_init(driver, device)
  log.debug(string.format("INIT handler for: <%s (%s)>", device.device_network_id, device.label))
  device:try_update_metadata({profile='onvif_cam.v3'})
  device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
  device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
  device:set_field('init_retries', 0)
  resetlastevents(device)
  device.thread:queue_event(init_device, device)
end

local function device_added(driver, device)
  local urn = device.device_network_id
  log.info(string.format('ADDED handler: <%s (%s)> successfully added; device_network_id = %s', device.id, device.label, urn))
  local ipcam = newly_added[urn]
  if ipcam then
    device:set_field('onvif_disco', ipcam, {['persist'] = true})
    newly_added[urn] = nil
  else
    if urn:match('^MAN_') then
      log.debug('Processing manually-created device')
      ipcam = {}
      ipcam.uri = {}
      ipcam.scopes = {}
      ipcam.profiles = {}
      ipcam.urn, ipcam.addr = urn:match('MAN_(.+)_(.+)$')
      ipcam.ip = ipcam.addr:match('([%d%.]+):')
      ipcam.port = tonumber(ipcam.addr:match(':(%d+)'))
      ipcam.uri.device_service = 'http://' .. ipcam.addr .. ONVIFDEVSERVPATH
      ipcam.discotype = 'manual'
      device:set_field('onvif_disco', ipcam, {['persist'] = true})
    end
  end
  if ipcam then
    device:emit_event(capabilities.motionSensor.motion('inactive'))
    device:emit_event(cap_motion.motionSwitch('Off'))
    device:emit_component_event(device.profile.components.line, cap_linecross.linecross('inactive'))
    device:emit_component_event(device.profile.components.tamper, capabilities.tamperAlert.tamper('clear'))
    device:emit_component_event(device.profile.components.info, cap_info.info(" "))
    device:emit_component_event(device.profile.components.info, cap_status.status('Not configured'))
  else
    log.error('IPCam meta data not found for new device')
  end
  log.debug('ADDED handler exiting for ' .. device.label)
  devcreate_sem:release()
end

local function device_doconfigure(_, device)
end

local function device_removed(driver, device)
  log.info("<" .. device.id .. "> removed")
  if device:get_field('onvif_func') then
    commands.Unsubscribe(device, device:get_field('onvif_func').event_service_addr)
  end
  events.shutdownserver(driver, device)
  discover.cancel_rediscover(driver, device)
  local device_list = driver:get_devices()
  if #device_list == 0 then
    log.warn('No more devices')
  end
end

local function shutdown_handler(driver, event)
  log.debug('Driver lifecycle handler invoked; event=', event)
  if event == 'shutdown' then
    log.info('*** Driver being shut down ***')
    local device_list = driver:get_devices()
    for _, device in ipairs(device_list) do
      if device:get_field('onvif_func') then
        commands.Unsubscribe(device, device:get_field('onvif_func').event_service_addr)
      end
      events.shutdownserver(driver, device)
      discover.cancel_rediscover(driver, device)
    end
    log.info('Shutdown complete')
  end
end

local function handler_infochanged(driver, device, event, args)
  log.debug('INFOCHANGED handler; event=', event)
  if args.old_st_store.preferences then
    local reinit = false
    if args.old_st_store.preferences.userid ~= device.preferences.userid then
      log.info('UserID updated to', device.preferences.userid)
      if device.preferences.userid ~= '*****' and device.preferences.password ~= '*****' then
        device:emit_component_event(device.profile.components.info, cap_status.status('Tap Refresh to connect'))
      end
    elseif args.old_st_store.preferences.password ~= device.preferences.password then
      log.info('Password updated')
      if device.preferences.userid ~= '*****' and device.preferences.password ~= '*****' then
        device:emit_component_event(device.profile.components.info, cap_status.status('Tap Refresh to connect'))
      end
    elseif args.old_st_store.preferences.minmotioninterval ~= device.preferences.minmotioninterval then
      log.info('Min Motion interval updated to', device.preferences.minmotioninterval)
    elseif args.old_st_store.preferences.stream ~= device.preferences.stream then
      log.info('Video stream changed to', device.preferences.stream)
      reinit = true
    elseif args.old_st_store.preferences.motionrule ~= device.preferences.motionrule then
      log.info('Motion rule changed to', device.preferences.motionrule)
      reinit = true
    elseif args.old_st_store.preferences.eventmethod ~= device.preferences.eventmethod then
      log.info('Event subscription method updated to', device.preferences.eventmethod)
    elseif args.old_st_store.preferences.autorevert ~= device.preferences.autorevert then
      log.info('Motion auto-revert updated to', device.preferences.autorevert)
    elseif args.old_st_store.preferences.revertdelay ~= device.preferences.revertdelay then
      log.info('Motion auto-revert delay updated to', device.preferences.revertdelay)
    else
      log.debug('****** DRIVER RESTART ASSUMED ******')
    end
  end
end

local function lan_info_changed_handler(driver, hub_ipv4)
  if driver.listen_ip == nil or hub_ipv4 ~= driver.listen_ip then
    log.info("Hub IP address has changed; need to restart driver")
  end
end

local function discovery_handler(driver, _, should_continue)
  log.debug("Discovery handler invoked")
  local known_devices = {}
  local found_devices = {}
  local device_list = driver:get_devices()
  for _, device in ipairs(device_list) do
    known_devices[device.device_network_id] = true
  end
  local waittime = 10
  local reset_option = true
  local cycle = 0
  local newcreates = 0
  while should_continue() and (cycle < 4) do
    cycle = cycle + 1
    log.info(string.format('Starting Discovery cycle #%s', cycle))
    discover.discover(waittime, function(ipcam)
      local urn = ipcam.urn
      local ip = ipcam.ip
      if not known_devices[urn] and not found_devices[urn] then
        found_devices[urn] = true
        local modelname = 'Unknown'
        local name = 'IPCam #' .. tostring(discovered_num) .. ' (configure!)'
        discovered_num = discovered_num + 1
        local manufacturer = 'Unknown'
        local vendlabel = ipcam.vendname or name
        local devprofile = 'onvif_cam.v3'
        local create_device_msg = {
          type = "LAN",
          device_network_id = urn,
          label = name,
          profile = devprofile,
          manufacturer = manufacturer,
          model = modelname,
          vendor_provided_label = vendlabel,
        }
        newly_added[urn] = ipcam
        devcreate_sem:acquire(function()
          log.info(string.format('Creating discovered IP Camera found at %s', ip))
          log.info("\tdevice_network_id = " .. urn)
          assert(driver:try_create_device(create_device_msg), "failed to create device record")
        end)
        newcreates = newcreates + 1
      else
        log.debug("Discovered device was already known")
      end
    end, reset_option)
    cosock.socket.sleep(waittime + 1)
    cosock.socket.sleep(newcreates)
    reset_option = false
  end
  log.info("Exiting discovery")
end

onvifDriver = Driver("onvifDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    deleted = device_removed,
    removed = device_removed,
  },
  driver_lifecycle = shutdown_handler,
  lan_info_changed_handler = lan_info_changed_handler,
  capability_handlers = {
    [cap_refresh.ID] = {
      [cap_refresh.commands.push.NAME] = handle_refresh,
    },
    [cap_motion.ID] = {
      [cap_motion.commands.setSwitch.NAME] = handle_switch,
      [cap_motion.commands.switchOn.NAME] = handle_switch,
      [cap_motion.commands.switchOff.NAME] = handle_switch,
    },
    [capabilities.videoStream.ID] = {
      [capabilities.videoStream.commands.startStream.NAME] = handle_stream,
      [capabilities.videoStream.commands.stopStream.NAME] = handle_stream,
    },
    [capabilities.audioOutput.ID] = {
      [capabilities.audioOutput.commands.play.NAME] = handle_audio_output,
    },
  }
})

log.debug("**** ONVIF Driver V1.3 Start (Modified by HaloGod) ****")

devcreate_sem = Semaphore()

onvifDriver:run()