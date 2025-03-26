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
  
  Implement ONVIF Network Device Operations (client)

  MODIFIED BY HaloGod (2025) to add Reolink doorbell support, two-way audio, and improved error handling.
--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local log = require "log"

local common = require "common"
local auth = require "auth"
local uuid = require "uuid"

http.TIMEOUT = 5

local function parse_XMLresponse(data)
  local parsed_xml = common.xml_to_table(data)
  if parsed_xml then
    parsed_xml = common.strip_xmlns(parsed_xml)
    if parsed_xml['Envelope'] then
      if common.is_element(parsed_xml, {'Envelope', 'Body', 'Fault'}) then
        local fault_text = parsed_xml['Envelope']['Body']['Fault'].faultcode and
                          parsed_xml['Envelope']['Body']['Fault'].faultstring or
                          parsed_xml['Envelope']['Body']['Fault']['Reason']['Text'][1]
        log.warn('SOAP ERROR:', fault_text)
        return nil, nil, fault_text
      else
        return parsed_xml['Envelope']['Header'], parsed_xml['Envelope']['Body']
      end
    else
      log.error("Unexpected XML - missing 'Envelope'")
    end
  end
end

local function onvif_cmd(sendurl, command, sendbody, authheader, timeout)
  local responsechunks = {}
  local ret, code, headers, status

  local old_timeout = http.TIMEOUT
  http.TIMEOUT = timeout or http.TIMEOUT

  if sendbody then
    local content_type = 'application/soap+xml; charset=utf-8'
    local actions = {
      GetSystemDateAndTime = 'http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime',
      GetScopes = 'http://www.onvif.org/ver10/device/wsdl/GetScopes',
      GetDeviceInformation = 'http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation',
      GetCapabilities = 'http://www.onvif.org/ver10/device/wsdl/GetCapabilities',
      GetServices = 'http://www.onvif.org/ver10/device/wsdl/GetServices',
      GetVideoSources = 'http://www.onvif.org/ver10/media/wsdl/GetVideoSources',
      GetProfiles = 'http://www.onvif.org/ver10/media/wsdl/GetProfiles',
      GetStreamUri = 'http://www.onvif.org/ver10/media/wsdl/GetStreamUri',
      GetAudioSources = 'http://www.onvif.org/ver10/media/wsdl/GetAudioSources',
      GetAudioOutputs = 'http://www.onvif.org/ver10/media/wsdl/GetAudioOutputs',
      SendAudioOutput = 'http://www.onvif.org/ver10/media/wsdl/SetAudioOutputConfiguration'
    }
    if actions[command] then
      content_type = content_type .. '; action="' .. actions[command] .. '"'
    end

    sendbody = common.compact_XML(sendbody)
    local sendheaders = {
      ["Content-Type"] = content_type,
      ["Host"] = sendurl:match('//([^:/]+)'),
      ["Accept"] = 'gzip, deflate',
      ["Content-Length"] = #sendbody,
      ["Connection"] = 'close',
    }
    if authheader then
      sendheaders['Authorization'] = authheader
    end

    log.debug(string.format('Sending %s request to %s', command, sendurl))
    ret, code, headers, status = http.request {
      method = 'POST',
      url = sendurl,
      headers = sendheaders,
      source = ltn12.source.string(sendbody),
      sink = ltn12.sink.table(responsechunks)
    }
  else
    local sendheaders = { ["Accept"] = '*/*' }
    if authheader then
      sendheaders['Authorization'] = authheader
    end
    ret, code, headers, status = http.request {
      method = 'POST',
      url = sendurl,
      sink = ltn12.sink.table(responsechunks),
      headers = sendheaders
    }
  end

  http.TIMEOUT = old_timeout
  local response = table.concat(responsechunks)
  
  log.debug('HTTP Response Header:', status)
  if ret and code == 200 then
    return true, code, response, headers
  end
  
  if code ~= 400 and code ~= 401 then
    if #response > 0 then
      local xmlhead, xmlbody = parse_XMLresponse(response)
      if xmlbody then common.disptable(xmlbody, '  ', 8) end
    end
  end
  
  return false, code, response, headers
end

local function parse_authenticate(headers)
  for key, value in pairs(headers) do
    if string.lower(key) == 'www-authenticate' then
      return value
    end
  end
end

local function create_authdata_table(authrecord)
  local authtype, parms = authrecord:match('^(%a+) (.+)$')
  local authdata = { type = authtype }
  authdata.qop = parms:match('qop="([^"]+)"')
  authdata.realm = parms:match('realm="([^"]+)"')
  authdata.nonce = parms:match('nonce="([^"]+)"')
  authdata.algorithm = parms:match('algorithm="([^"]+)"') or parms:match('algorithm=([%w-]+)')
  authdata.stale = parms:match('stale="([^"]+)"') or parms:match('stale=([%a]+)')
  authdata.opaque = parms:match('opaque="([^"]+)"')
  authdata.domain = parms:match('domain="([^"]+)"')
  log.debug('Authorization record:')
  for key, value in pairs(authdata) do
    log.debug(string.format('\t%s: %s', key, value))
  end
  return authdata
end

local function update_nonce(authinfo, headers)
  for key, value in pairs(headers) do
    if string.lower(key) == 'authentication-info' then
      local nextnonce = value:match('nextnonce="([^"]+)"')
      if nextnonce then
        authinfo.authdata.nonce = nextnonce
        return authinfo
      end
    end
  end
end

local function augment_header(request, url)
  local to = '    <wsa:To s:mustUnderstand="1">' .. url .. '</wsa:To>\n'
  local msgid = '    <wsa:MessageID>urn:uuid:' .. uuid() .. '</wsa:MessageID>\n'
  request = common.add_XML_header(request, to)
  request = common.add_XML_header(request, msgid)
  return request
end

local function check_offline(device, code)
  if code and type(code) == 'string' then
    if string.lower(code):find('no route to host') or 
       string.lower(code):find('connection refused') or
       string.lower(code):find('timeout') then
      device:set_field('onvif_online', false)
    end
  end
end

local function get_new_auth(device, reqname, serviceURI, request)
  local authinited = false
  local auth_header, auth_request
  local success, code, response, headers = onvif_cmd(serviceURI, reqname, request)
  
  if response then
    if code == 200 then
      local authinfo = { type = 'none' }
      device:set_field('onvif_authinfo', authinfo)
      return authinfo, nil, request, code, response
    else
      local xml_head, xml_body, fault_text = parse_XMLresponse(response)
      if code == 400 then
        if string.lower(fault_text):find('not authorized') or string.lower(fault_text):find('authority failure') then
          auth_request = common.add_XML_header(request, auth.build_UsernameToken(device))
          authinited = true
        else
          log.error('HTTP Error: 400 Bad Request; unknown authentication method')
          return
        end
      elseif code == 401 then
        local auth_record = parse_authenticate(headers)
        if auth_record then
          if auth_record:find('gSOAP Web Service') then
            log.debug('Assuming WS authentication')
            auth_request = common.add_XML_header(request, auth.build_UsernameToken(device))
            authinited = true
          else
            local authdata = create_authdata_table(auth_record)
            auth_header = auth.build_authheader(device, "POST", serviceURI, authdata)
            auth_request = request
            authinited = true
          end
        else
          log.error('HTTP 401 returned without WWW-Authenticate header')
          return nil, nil, nil, code
        end
      else
        log.error(string.format('Unexpected HTTP Error %s from camera: %s', code, device.label))
        return nil, nil, nil, code
      end
      if authinited then
        return device:get_field('onvif_authinfo'), auth_header, auth_request, code, response
      end
    end
  else
    log.error(string.format('No response data from camera %s (HTTP code %s)', device.label, code))
    check_offline(device, code)
    return nil, nil, nil, code
  end
end

local function _send_request(device, serviceURI, reqname, auth_request, auth_header, timeout)
  local success, code, response, headers = onvif_cmd(serviceURI, reqname, auth_request, auth_header, timeout)
  if code == 200 and response then
    local authinfo = device:get_field('onvif_authinfo')
    if authinfo and authinfo.type == 'http' then
      local newauthinfo = update_nonce(authinfo, headers)
      if newauthinfo then
        device:set_field('onvif_authinfo', newauthinfo)
      end
    end
  end
  return success, code, response, headers
end

local function send_request(device, reqname, serviceURI, request, timeout)
  local auth_request, auth_header
  local authinfo = device:get_field('onvif_authinfo')
  local retries = 3
  local retry_delay = 2

  for attempt = 1, retries do
    log.debug(string.format("Sending %s to %s (attempt %d/%d, timeout %ds)", reqname, serviceURI, attempt, retries, timeout or 5))

    if not authinfo then
      authinfo, auth_header, auth_request, http_code, http_response = get_new_auth(device, reqname, serviceURI, request)
      if not authinfo then
        log.error('Failed to determine authentication method')
        return nil, http_code
      end
    else
      if authinfo.type == 'wss' then
        auth_request = common.add_XML_header(request, auth.build_UsernameToken(device))
      elseif authinfo.type == 'http' and authinfo.authdata then
        auth_header = auth.build_authheader(device, "POST", serviceURI, authinfo.authdata)
        auth_request = request
      elseif authinfo.type == 'none' then
        auth_request = request
      else
        log.error('Invalid authinfo state')
        return
      end
    end

    local success, http_code, http_response, headers = _send_request(device, serviceURI, reqname, auth_request, auth_header, timeout)
    if success and http_code == 200 then
      local xml_head, xml_body = parse_XMLresponse(http_response)
      if xml_body then
        return common.strip_xmlns(xml_body), http_code
      end
    elseif attempt < retries then
      log.warn(string.format("%s failed with code %s, retrying in %ds", reqname, http_code, retry_delay))
      socket.sleep(retry_delay)
    else
      log.error(string.format("%s failed after %d attempts with HTTP Error %s", reqname, retries, http_code))
      check_offline(device, http_code)
      return nil, http_code
    end
  end
end

------------------------------------------------------------------------
--                        ONVIF COMMANDS
------------------------------------------------------------------------

function GetSystemDateAndTime(device, device_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body, code = send_request(device, 'GetSystemDateAndTime', device_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetSystemDateAndTimeResponse', 'SystemDateAndTime', 'UTCDateTime'}) then
    local cam_datetime = {}
    local datetime = {}
    local hub_datetime = os.date("!*t")
    datetime.hub = string.format('%d/%d/%d %d:%02d:%02d', hub_datetime.month, hub_datetime.day, hub_datetime.year, hub_datetime.hour, hub_datetime.min, hub_datetime.sec)
    local cam_UTC = xml_body['GetSystemDateAndTimeResponse']['SystemDateAndTime']['UTCDateTime']
    cam_datetime.hour = tonumber(cam_UTC['Time']['Hour'])
    cam_datetime.min = tonumber(cam_UTC['Time']['Minute'])
    cam_datetime.sec = tonumber(cam_UTC['Time']['Second'])
    cam_datetime.month = tonumber(cam_UTC['Date']['Month'])
    cam_datetime.day = tonumber(cam_UTC['Date']['Day'])
    cam_datetime.year = tonumber(cam_UTC['Date']['Year'])
    datetime.cam = string.format('%d/%d/%d %d:%02d:%02d', cam_datetime.month, cam_datetime.day, cam_datetime.year, cam_datetime.hour, cam_datetime.min, cam_datetime.sec)
    log.info(string.format('Hub UTC datetime: %s', datetime.hub))
    log.info(string.format('IP cam UTC datetime: %s', datetime.cam))
    if math.abs(os.time(hub_datetime) - os.time(cam_datetime)) > 300 then
      log.warn(string.format('Date/Time not synchronized with %s (%s)', device_serviceURI, device.label))
    end
    return datetime
  end
  log.error(string.format('Failed to get date/time from %s (%s)', device_serviceURI, device.label))
  check_offline(device, code)
end

function GetScopes(device, device_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetScopes xmlns="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetScopes', device_serviceURI, request)
  if xml_body and xml_body['GetScopesResponse'] then
    local scopelist = {}
    for _, scope in ipairs(xml_body['GetScopesResponse']['Scopes']) do
      table.insert(scopelist, scope['ScopeItem'])
    end
    return scopelist
  end
  log.error(string.format('Failed to get Scopes from %s', device_serviceURI))
end

function GetDeviceInformation(device, device_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetDeviceInformation', device_serviceURI, request)
  if xml_body and xml_body['GetDeviceInformationResponse'] then
    local infolist = {}
    for key, value in pairs(xml_body['GetDeviceInformationResponse']) do
      infolist[key] = value
    end
    return infolist
  end
  log.error(string.format('Failed to get device info from %s', device_serviceURI))
end

function GetCapabilities(device, device_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl">
      <Category>All</Category>
    </GetCapabilities>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetCapabilities', device_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetCapabilitiesResponse', 'Capabilities'}) then
    return xml_body['GetCapabilitiesResponse']['Capabilities']
  end
  log.error(string.format('Failed to get capabilities from %s', device_serviceURI))
end

function GetServices(device, device_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetServices xmlns="http://www.onvif.org/ver10/device/wsdl">
      <IncludeCapability>false</IncludeCapability>
    </GetServices>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetServices', device_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetServicesResponse'}) then
    return xml_body['GetServicesResponse']
  end
  log.error(string.format('Failed to get Services from %s', device_serviceURI))
end

function GetVideoSources(device, media_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetVideoSources xmlns="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetVideoSources', media_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetVideoSourcesResponse', 'VideoSources'}) then
    return xml_body['GetVideoSourcesResponse']['VideoSources']
  end
  log.error(string.format('Failed to get video sources from %s', media_serviceURI))
end

function GetProfiles(device, media_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetProfiles', media_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetProfilesResponse', 'Profiles'}) then
    return xml_body['GetProfilesResponse']['Profiles']
  end
  log.error(string.format('Failed to get profiles from %s', media_serviceURI))
end

function GetStreamUri(device, token, media_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Header>
  </s:Header>
  <s:Body>
    <trt:GetStreamUri>
      <trt:StreamSetup>
        <tt:Stream>RTP-Unicast</tt:Stream>
        <tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>
      </trt:StreamSetup>
      <trt:ProfileToken>]] .. token .. [[</trt:ProfileToken>
    </trt:GetStreamUri>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetStreamUri', media_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetStreamUriResponse', 'MediaUri'}) then
    return xml_body['GetStreamUriResponse']['MediaUri']
  end
  log.error(string.format('Failed to get stream URI from %s', media_serviceURI))
end

function GetAudioSources(device, media_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetAudioSources xmlns="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetAudioSources', media_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetAudioSourcesResponse', 'AudioSources'}) then
    return xml_body['GetAudioSourcesResponse']['AudioSources']
  end
  log.warn(string.format('Failed to get audio sources from %s', media_serviceURI))
  return nil
end

function GetAudioOutputs(device, media_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <GetAudioOutputs xmlns="http://www.onvif.org/ver10/media/wsdl"/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetAudioOutputs', media_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetAudioOutputsResponse', 'AudioOutputs'}) then
    return xml_body['GetAudioOutputsResponse']['AudioOutputs']
  end
  log.warn(string.format('Failed to get audio outputs from %s', media_serviceURI))
  return nil
end

function SendAudioOutput(device, output_token, message)
  local media_serviceURI = device:get_field('onvif_func').media_service_addr
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Header>
  </s:Header>
  <s:Body>
    <trt:SetAudioOutputConfiguration>
      <trt:ConfigurationToken>]] .. output_token .. [[</trt:ConfigurationToken>
      <trt:Configuration>
        <tt:OutputLevel>50</tt:OutputLevel>
      </trt:Configuration>
    </trt:SetAudioOutputConfiguration>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'SendAudioOutput', media_serviceURI, request, 10)
  if xml_body then
    log.debug('Audio output set for', device.label, 'with message:', message)
    return true
  end
  log.error(string.format('Failed to send audio output to %s', media_serviceURI))
  return false
end

------------------------------------------------------------------------
--                          EVENT-related
------------------------------------------------------------------------

function GetEventProperties(device, event_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:tet="http://www.onvif.org/ver10/events/wsdl">
  <s:Header>
    <wsa:Action>http://www.onvif.org/ver10/events/wsdl/EventPortType/GetEventPropertiesRequest</wsa:Action>
  </s:Header>
  <s:Body>
    <tet:GetEventProperties/>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'GetEventProperties', event_serviceURI, request)
  if xml_body and common.is_element(xml_body, {'GetEventPropertiesResponse', 'TopicSet'}) then
    return xml_body['GetEventPropertiesResponse']['TopicSet']
  end
  log.error(string.format('Failed to get event properties from %s', event_serviceURI))
end

function Subscribe(device, event_serviceURI, listenURI)
  local request_part1 = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:tet="http://www.onvif.org/ver10/events/wsdl" xmlns:tns1="http://www.onvif.org/ver10/topics" xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Header>
    <wsa:Action s:mustUnderstand="1">http://docs.oasis-open.org/wsn/bw-2/NotificationProducer/SubscribeRequest</wsa:Action>
    <wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo>
  </s:Header>
  <s:Body>
    <wsnt:Subscribe>
      <wsnt:ConsumerReference>
        <wsa:Address>]] .. listenURI .. [[</wsa:Address>
      </wsnt:ConsumerReference>
]]

  local visitor_filter = [[
      <wsnt:Filter>
        <wsnt:TopicExpression Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">
          tns1:RuleEngine/MyRuleDetector/Visitor//.
        </wsnt:TopicExpression>
      </wsnt:Filter>
]]
  local motion_filter = device.preferences.motionrule == 'alarm' and [[
      <wsnt:Filter>
        <wsnt:TopicExpression Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">
          tns1:VideoSource/MotionAlarm//.
        </wsnt:TopicExpression>
      </wsnt:Filter>
]] or [[
      <wsnt:Filter>
        <wsnt:TopicExpression Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">
          tns1:RuleEngine/CellMotionDetector//.
        </wsnt:TopicExpression>
      </wsnt:Filter>
]]
  local request_lastpart = [[
      <wsnt:InitialTerminationTime>PT10M</wsnt:InitialTerminationTime>
    </wsnt:Subscribe>
  </s:Body>
</s:Envelope>
]]

  local request = request_part1 .. (device.preferences.motionrule and motion_filter or '') .. visitor_filter .. request_lastpart
  request = augment_header(request, event_serviceURI)
  
  local xml_body = send_request(device, 'Subscribe', event_serviceURI, request)
  if xml_body and xml_body['SubscribeResponse'] then
    return xml_body['SubscribeResponse']
  end
  log.error(string.format('Failed to subscribe to %s', event_serviceURI))
end

function RenewSubscription(device, event_source_addr, termtime)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing">
  <s:Header>
    <wsa:Action s:mustUnderstand="1">http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest</wsa:Action>
    <wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo>
  </s:Header>
  <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <Renew xmlns="http://docs.oasis-open.org/wsn/b-2"><TerminationTime>]] .. termtime .. [[</TerminationTime></Renew>
  </s:Body>
</s:Envelope>
]]
  request = gen_subid_header(device, request)
  request = augment_header(request, event_source_addr)
  local xml_body = send_request(device, 'RenewSubscription', event_source_addr, request)
  if xml_body and xml_body['RenewResponse'] then
    return xml_body['RenewResponse']
  end
  log.error(string.format('Failed to renew subscription to %s', event_source_addr))
end

function Unsubscribe(device)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2">
  <s:Header>
    <wsa:Action>http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest</wsa:Action>
    <wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo>
  </s:Header>
  <s:Body><wsnt:Unsubscribe/></s:Body>
</s:Envelope>
]]
  local cam_func = device:get_field('onvif_func')
  if cam_func.event_source_addr then
    request = gen_subid_header(device, request)
    request = augment_header(request, cam_func.event_source_addr)
    local xml_body = send_request(device, 'Unsubscribe', cam_func.event_source_addr, request)
    if xml_body then return true end
    log.warn(string.format('Failed to unsubscribe to %s', cam_func.event_source_addr))
  end
end

function CreatePullPointSubscription(device, event_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:tet="http://www.onvif.org/ver10/events/wsdl" xmlns:tns1="http://www.onvif.org/ver10/topics" xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Header>
    <wsa:Action s:mustUnderstand="1">http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest</wsa:Action>
  </s:Header>
  <s:Body>
    <tet:CreatePullPointSubscription xmlns="http://www.onvif.org/ver10/events/wsdl">
      <tet:InitialTerminationTime>PT1H</tet:InitialTerminationTime>
    </tet:CreatePullPointSubscription>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'CreatePullPointSubscription', event_serviceURI, request)
  if xml_body and xml_body['CreatePullPointSubscriptionResponse'] then
    return xml_body['CreatePullPointSubscriptionResponse']
  end
  log.error(string.format('Failed to create pullpoint subscription to %s', event_serviceURI))
end

function PullMessages(device, event_serviceURI)
  local request = [[
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:tet="http://www.onvif.org/ver10/events/wsdl">
  <s:Header>
    <wsa:Action>http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest</wsa:Action>
  </s:Header>
  <s:Body>
    <tet:PullMessages>
      <tet:Timeout>PT1H</tet:Timeout>
      <tet:MessageLimit>30</tet:MessageLimit>
    </tet:PullMessages>
  </s:Body>
</s:Envelope>
]]
  local xml_body = send_request(device, 'PullMessages', event_serviceURI, request)
  if xml_body and xml_body['PullMessagesResponse'] then
    return xml_body['PullMessagesResponse']
  end
  log.error(string.format('Failed to pull messages from %s', event_serviceURI))
end

return {
  GetSystemDateAndTime = GetSystemDateAndTime,
  GetScopes = GetScopes,
  GetDeviceInformation = GetDeviceInformation,
  GetCapabilities = GetCapabilities,
  GetServices = GetServices,
  GetVideoSources = GetVideoSources,
  GetProfiles = GetProfiles,
  GetStreamUri = GetStreamUri,
  GetAudioSources = GetAudioSources,
  GetAudioOutputs = GetAudioOutputs,
  SendAudioOutput = SendAudioOutput,
  GetEventProperties = GetEventProperties,
  Subscribe = Subscribe,
  CreatePullPointSubscription = CreatePullPointSubscription,
  PullMessages = PullMessages,
  RenewSubscription = RenewSubscription,
  Unsubscribe = Unsubscribe,
}