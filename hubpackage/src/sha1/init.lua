--[[
  Enhanced init.lua for SHA-1 library
  Copyright 2025, suggestions for dMac, based on SHA-1 library by Peter Melnichenko

  Licensed under the MIT License (see sha1.lua for details)
  
  DESCRIPTION
  Initializes the SHA-1 library with error handling, version detection, and configuration options.
  Prepares the library for use in environments like SmartThings Edge with ONVIF drivers.
--]]

-- Attempt to load a logging module (e.g., from SmartThings Edge), fallback to print
local log
if pcall(function() log = require "log" end) then
    -- SmartThings Edge logging available
else
    log = { info = print, warn = print, error = print, debug = print }
end

-- Load dependencies with error checking
local common, common_err = pcall(function() return require "sha1.common" end)
if not common then
    log.error("Failed to load sha1.common: " .. (common_err or "unknown error"))
    error("SHA-1 initialization failed: missing sha1.common")
end

local ops, ops_err = pcall(function() return require "sha1.lua53_ops" end)
if not ops then
    log.warn("Failed to load sha1.lua53_ops: " .. (ops_err or "unknown error") .. "; falling back to pure Lua")
end

local sha1_module, sha1_err = pcall(function() return require "sha1.sha1" end)
if not sha1_module then
    log.error("Failed to load sha1.sha1: " .. (sha1_err or "unknown error"))
    error("SHA-1 initialization failed: missing sha1.sha1")
end

-- Detect Lua version
local lua_version = _VERSION:match("Lua%s+(%d+%.%d+)") or "unknown"
log.info("Initializing SHA-1 library on " .. _VERSION)

-- Configuration options
local config = {
    force_pure_lua = false,  -- Set to true to disable bitops even if available
    precompute_tables = true -- Precompute XOR tables at init
}

-- Check for bit operations availability
local has_bit32 = pcall(function() return require "bit32" end)
local has_bit = pcall(function() return require "bit" end)
local has_lua53 = (lua_version >= "5.3")

if has_lua53 and not config.force_pure_lua then
    log.info("Using Lua 5.3 operators for SHA-1 operations")
elseif has_bit32 and not config.force_pure_lua then
    log.info("Using bit32 module for SHA-1 operations")
elseif has_bit and not config.force_pure_lua then
    log.info("Using bit module for SHA-1 operations")
else
    log.info("Using pure Lua implementation for SHA-1 operations")
end

-- Precompute XOR tables if configured
if config.precompute_tables then
    local function precompute_xor_tables()
        local xor_with_0x5c = {}
        local xor_with_0x36 = {}
        local byte_xor = ops and ops.byte_xor or function(a, b) return bit32.bxor(a, b) end -- Fallback assumes bit32
        
        for i = 0, 0xff do
            local char = string.char(i)
            xor_with_0x5c[char] = string.char(byte_xor(0x5c, i))
            xor_with_0x36[char] = string.char(byte_xor(0x36, i))
        end
        
        return xor_with_0x5c, xor_with_0x36
    end
    
    local success, xor_5c, xor_36 = pcall(precompute_xor_tables)
    if success then
        sha1_module.xor_with_0x5c = xor_5c
        sha1_module.xor_with_0x36 = xor_36
        log.debug("Precomputed XOR tables for HMAC")
    else
        log.warn("Failed to precompute XOR tables: " .. tostring(xor_36)) -- xor_36 holds the error message
    end
end

-- Add utility function for ONVIF driver integration (e.g., HMAC-SHA1 for authentication)
function sha1_module.hmac_hex(key, text)
    return sha1_module.hmac(key, text)
end

-- Validate SHA-1 functionality
local test_str = "test"
local expected_sha1 = "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3"
local test_result = sha1_module.sha1(test_str)
if test_result == expected_sha1 then
    log.info("SHA-1 self-test passed")
else
    log.error("SHA-1 self-test failed: expected " .. expected_sha1 .. ", got " .. test_result)
end

-- Export the module with metadata
sha1_module.config = config
sha1_module.lua_version = lua_version

return sha1_module