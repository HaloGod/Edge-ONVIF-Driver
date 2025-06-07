-- common.lua (Utility Functions with Support for Capability Detection and Robust XML Handling)

local log = require "log"
-- lxp.lom is not available in the Edge environment. Implement a
-- lightweight XML parser in pure Lua to avoid the dependency while
-- retaining a similar table structure.

-- Parse attributes from a tag into a table
local function parse_attrs(attr_str)
  local attrs = {}
  string.gsub(attr_str, "([%w_:.-]+)%s*=%s*\"(.-)\"", function(k, v)
    attrs[k] = v
  end)
  return attrs
end

-- Very small XML to Lua table converter supporting the subset of XML
-- returned by Reolink/ONVIF APIs. It is not a full XML parser but is
-- sufficient for discovery/event messages.
local function parse_xml(xml)
  local stack = {{}}
  local top = stack[#stack]
  local pos = 1

  while true do
    local start, finish, closing, tag, attrs, empty = xml:find("<(%/?)([%w:._-]+)(.-)(%/?)>", pos)
    if not start then break end

    local text = xml:sub(pos, start - 1)
    if text:match("%S") then
      local cur = stack[#stack]
      cur._text = (cur._text or "") .. text
    end

    if empty == "/" then
      local node = { _attr = parse_attrs(attrs) }
      local cur = stack[#stack]
      if cur[tag] == nil then
        cur[tag] = node
      else
        if cur[tag][1] == nil then
          cur[tag] = { cur[tag], node }
        else
          table.insert(cur[tag], node)
        end
      end
    elseif closing == "" then
      local node = { _attr = parse_attrs(attrs) }
      local cur = stack[#stack]
      if cur[tag] == nil then
        cur[tag] = node
      else
        if cur[tag][1] == nil then
          cur[tag] = { cur[tag], node }
        else
          table.insert(cur[tag], node)
        end
      end
      table.insert(stack, node)
    else
      table.remove(stack)
    end

    pos = finish + 1
  end

  local text = xml:sub(pos)
  if text:match("%S") then
    local cur = stack[#stack]
    cur._text = (cur._text or "") .. text
  end

  return stack[1]
end

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
  local ok, result = pcall(parse_xml, xml_str)
  if not ok then
    log.error("XML parsing error: " .. tostring(result))
    return nil
  end
  return result
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