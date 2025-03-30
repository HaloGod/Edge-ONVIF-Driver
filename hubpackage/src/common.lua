--[[
  Copyright 2022 Todd Austin, enhanced 2025 by suggestions for dMac

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  ONVIF Driver common routines with enhanced error handling and utilities


--]]

local xml2lua = require "xml2lua"
local xml_handler = require "xmlhandler.tree"
local log = require "log"

local function xml_to_table(data)
    if string.find(data, '<?xml version="1.0"', 1, true) or
       string.find(data, "<?xml version='1.0'", 1, true) then
        local handler = xml_handler:new()
        local xml_parser = xml2lua.parser(handler)

        local success, err = pcall(function() xml_parser:parse(data) end)
        if not success or not handler.root then
            log.error("Could not parse XML: " .. (err or "Unknown error"))
            return nil, err or "Unknown error"
        end
        
        return handler.root, nil
    else
        log.warn('Not an XML response')
        return nil, "Not an XML response"
    end
end

local function is_element(xml, element_list)
    local xtable = xml
    local itemcount = #element_list
    local foundcount = 0
    
    for i, element in ipairs(element_list) do
        xtable = xtable[element]
        if xtable then
            foundcount = foundcount + 1
        else
            break
        end
    end
    return foundcount == itemcount
end

local function _strip_xmlns(xml)
    local new_keys = {}
    for key, value in pairs(xml) do
        local newkey = key:match(':(.+)') or key
        if newkey ~= key then
            new_keys[key] = newkey
        end
        if type(value) == 'table' then
            _strip_xmlns(value)
        end
    end
    for old_key, new_key in pairs(new_keys) do
        xml[new_key] = xml[old_key]
        xml[old_key] = nil
    end
end

local function strip_xmlns(xml)
    _strip_xmlns(xml)
    return xml
end

local function compact_XML(xml_in)
    local function nextchar(xml, index)
        local idx = index
        local char
        repeat
            char = string.sub(xml, idx, idx)
            if char ~= ' ' and char ~= '\t' and char ~= '\n' then
                return char, idx
            else
                idx = idx + 1
            end
        until idx > #xml
    end

    local xml_out = ''
    local element_index = 1
    local char, lastchar
    local doneflag

    repeat
        doneflag = false
        lastchar = ''
        char, element_index = nextchar(xml_in, element_index)
        
        if not char then break end
        
        if char == '<' then
            repeat
                char = string.sub(xml_in, element_index, element_index)
                if char ~= '\n' then
                    if char == '\t' then char = ' ' end
                    if char == ' ' and lastchar == ' ' then char = '' end
                    if char ~= '' then lastchar = char else lastchar = ' ' end
                    xml_out = xml_out .. char
                    if char == '>' then doneflag = true end
                end
                element_index = element_index + 1
            until doneflag or (element_index > #xml_in)
        else
            repeat
                char = string.sub(xml_in, element_index, element_index)
                if char ~= ' ' and char ~= '\t' and char ~= '\n' then
                    if char == '<' then doneflag = true break end
                    xml_out = xml_out .. char
                end
                element_index = element_index + 1
            until doneflag or (element_index > #xml_in)
        end
    until element_index > #xml_in
    
    return xml_out
end

local function disptable(table, tab, maxlevels, currlevel)
    if not currlevel then currlevel = 0 end
    currlevel = currlevel + 1
    for key, value in pairs(table) do
        local type_str = type(value) == 'table' and "[table]" or "[" .. type(value) .. "]"
        local key_str = type(key) == 'table' and "[table]" or tostring(key)
        log.debug(string.format("%s%s: %s %s", tab, key_str, type_str, tostring(value)))
        if type(value) == 'table' and currlevel < maxlevels then
            disptable(value, tab .. '  ', maxlevels, currlevel)
        end
    end
end

local function hextoint(hexstring)
    local hexconv = {
        ['0'] = 0, ['1'] = 1, ['2'] = 2, ['3'] = 3, ['4'] = 4,
        ['5'] = 5, ['6'] = 6, ['7'] = 7, ['8'] = 8, ['9'] = 9,
        ['a'] = 10, ['b'] = 11, ['c'] = 12, ['d'] = 13, ['e'] = 14, ['f'] = 15
    }

    local intnum = 0
    for i = 1, #hexstring, 2 do
        local val = (hexconv[string.sub(hexstring, i, i)] * 16) + hexconv[string.sub(hexstring, i+1, i+1)]
        intnum = intnum + val
    end
    return intnum
end

local function string_to_hex(str)
    local hex = ''
    for i = 1, #str do
        hex = hex .. string.format('%02x', str:byte(i))
    end
    return hex
end

local function add_XML_header(xml, item)
    local insert_point = xml:find('  </s:Header>', 1, 'plaintext')
    return (xml:sub(1, insert_point - 1) .. item .. xml:sub(insert_point, #xml))
end

local function getdevinfo(device, key)
    local infolist = device:get_field('onvif_info')
    for _, item in ipairs(infolist) do
        if item:match('(%w+): ') == key then
            return item:match(key .. ': (.+)$')
        end
    end
end

local function validate_onvif_xml(xml, required_elements)
    if not xml then return false, "No XML provided" end
    for _, elem in ipairs(required_elements) do
        if not is_element(xml, elem) then
            return false, "Missing required element: " .. table.concat(elem, " > ")
        end
    end
    return true, nil
end

return {
    xml_to_table = xml_to_table,
    is_element = is_element,
    strip_xmlns = strip_xmlns,
    compact_XML = compact_XML,
    disptable = disptable,
    hextoint = hextoint,
    string_to_hex = string_to_hex,
    add_XML_header = add_XML_header,
    getdevinfo = getdevinfo,
    validate_onvif_xml = validate_onvif_xml
}