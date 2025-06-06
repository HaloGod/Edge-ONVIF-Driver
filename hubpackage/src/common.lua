-- common.lua (Utility Functions with Support for Capability Detection and Robust XML Handling)

local log = require "log"
local lom = require "lxp.lom"

local M = {}

-- Recursively remove XML namespaces
function M.strip_xmlns(t)
  if type(t) ~= "table" then return t end
  local stripped = {}
  for k, v in pairs(t) do
    local name = k:gsub("^.-:", "")
    stripped[name] = M.strip_xmlns(v)
  end
  return stripped
end

-- Convert XML string to Lua table
function M.xml_to_table(xml_str)
  local handler = {}

  function handler:StartElement(tag, attr)
    local t = { _attr = attr }
    table.insert(self.stack[#self.stack], { [tag] = t })
    table.insert(self.stack, t)
  end

  function handler:EndElement()
    table.remove(self.stack)
  end

  function handler:CharacterData(text)
    if text:match("^%s*$") then return end
    local current = self.stack[#self.stack]
    current._text = (current._text or "") .. text
  end

  function M.parse(xml)
    local parser = lom.new(handler)
    handler.stack = {{} }
    local ok, err = pcall(parser.parse, parser, xml)
    if not ok then
      log.error("XML parsing error: " .. err)
      return nil
    end
    parser:close()
    return handler.stack[1][1]
  end

  return M.parse(xml_str)
end

-- Check deeply for a key path
function M.is_element(tbl, path)
  local t = tbl
  for _, key in ipairs(path) do
    if type(t) ~= "table" or t[key] == nil then return false end
    t = t[key]
  end
  return true
end

-- Print Lua table
function M.disptable(t, indent, depth)
  indent = indent or "  "
  depth = depth or 3
  local function print_table(tbl, level)
    if level > depth then return end
    for k, v in pairs(tbl) do
      if type(v) == "table" then
        log.debug(string.rep(indent, level) .. tostring(k) .. ":")
        print_table(v, level + 1)
      else
        log.debug(string.rep(indent, level) .. tostring(k) .. ": " .. tostring(v))
      end
    end
  end
  print_table(t, 1)
end

-- Retry wrapper
function M.retry(max_attempts, delay, action)
  for attempt = 1, max_attempts do
    local ok, result = pcall(action)
    if ok then return result end
    log.warn("Retry " .. attempt .. "/" .. max_attempts .. " failed: " .. tostring(result))
    socket.sleep(delay)
  end
  return nil
end

-- Capability support detector
function M.has_ability(ability_table, key)
  if not ability_table then return false end
  local val = ability_table[key]
  return val and val.permit and val.permit > 0
end

return M