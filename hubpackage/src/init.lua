--[[
  Copyright 2025 David MacDonald

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.

  DESCRIPTION
  
  ONVIF Video camera driver for SmartThings Edge

  MODIFIED BY HaloGod (2025) to add Reolink doorbell support, including Visitor event handling.
--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                   -- cosock used only for sleep timer in this module
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
  if ipcam