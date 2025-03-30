--[[
  Enhanced init.lua for SHA-1 library
  Copyright 2025, suggestions for dMac, based on SHA-1 library by Peter Melnichenko

  Licensed under the MIT License (see sha1.lua for details)
  
  DESCRIPTION
  Initializes the SHA-1 library with error handling, version detection, and configuration options.
  Prepares the library for use in environments like SmartThings Edge with ONVIF drivers.
  Includes self-tests and utility functions for robust integration.
--]]

-- Attempt to load a logging module (e.g., from SmartThings Edge), fallback to print
local log
if pcall(function() log = require "log" end) then
    -- SmartThings Edge logging available
else
    log = { info = print, warn = print, error = print, debug = print }
end

-- Load dependencies with error checking
local common, common_err
common, common_err = pcall(function() return require "sha1.common" end)
if not common then
    log.error("Failed to load sha1.common: " .. (common_err or "unknown error"))
    error("SHA-1 initialization failed: missing sha1.common")
end
common = common_err  -- pcall returns status as first arg, result as second

local ops, ops_err
ops, ops_err = pcall(function() return require "sha1.lua53_ops" end)
if not ops then
    log.warn("Failed to load sha1.lua53_ops: " .. (ops_err or "unknown error") .. "; falling back to pure Lua")
    ops = nil
end
ops = ops_err  -- Adjust for pcall return

local sha1_module, sha1_err
sha1_module, sha1_err = pcall(function() return require "sha1.sha1" end)
if not sha1_module then
    log.error("Failed to load sha1.sha1: " .. (sha1_err or "unknown error"))
    error("SHA-1 initialization failed: missing sha1.sha1")
end
sha1_module = sha1_err  -- Adjust for pcall return

-- Detect Lua version
local lua_version = _VERSION:match("Lua%s+(%d+%.%d+)") or "unknown"
log.info("Initializing SHA-1 library on " .. _VERSION)

-- Configuration options (can be overridden by environment or runtime)
local config = {
    force_pure_lua = os.getenv("SHA1_FORCE_PURE_LUA") == "true" or false,  -- Env var override
    precompute_tables = os.getenv("SHA1_PRECOMPUTE_TABLES") ~= "false" or true,  -- Default true unless disabled
    debug_mode = os.getenv("SHA1_DEBUG") == "true" or false  -- Enable verbose logging
}

-- Check for bit operations availability
local has_bit32, bit32 = pcall(function() return require "bit32" end)
local has_bit = pcall(function() return require "bit" end)
local has_lua53 = (lua_version >= "5.3")

-- Determine implementation
local impl_desc
if has_lua53 and not config.force_pure_lua then
    impl_desc = "Lua 5.3+ operators"
elseif has_bit32 and not config.force_pure_lua then
    impl_desc = "bit32 module"
elseif has_bit and not config.force_pure_lua then
    impl_desc = "bit module"
else
    impl_desc = "pure Lua"
    if not ops then
        log.warn("No bitwise ops module loaded; pure Lua may be slower and less reliable without custom fallback")
    end
end
log.info("Using " .. impl_desc .. " for SHA-1 operations")

-- Precompute XOR tables if configured
if config.precompute_tables then
    local function precompute_xor_tables()
        local xor_with_0x5c = {}
        local xor_with_0x36 = {}
        -- Use ops.byte_xor if available, fallback to bit32, bit, or pure Lua
        local byte_xor
        if ops and ops.byte_xor then
            byte_xor = ops.byte_xor
        elseif has_bit32 then
            byte_xor = function(a, b) return bit32.bxor(a, b) end
        elseif has_bit then
            byte_xor = function(a, b) return require("bit").bxor(a, b) end
        else
            byte_xor = function(a, b)  -- Pure Lua XOR
                local result = 0
                for i = 0, 7 do
                    local bit_a = math.floor(a / 2^i) % 2
                    local bit_b = math.floor(b / 2^i) % 2
                    result = result + ((bit_a ~= bit_b) and 2^i or 0)
                end
                return result
            end
        end

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
        log.warn("Failed to precompute XOR tables: " .. tostring(xor_36)) -- Error in xor_36
        sha1_module.xor_with_0x5c = nil
        sha1_module.xor_with_0x36 = nil
    end
end

-- Utility functions for ONVIF driver integration
function sha1_module.hmac_hex(key, text)
    return sha1_module.hmac(key, text)  -- Returns hex string directly
end

function sha1_module.digest_auth(username, realm, password, nonce, method, uri)
    -- Common ONVIF HTTP Digest Auth calculation
    local ha1 = sha1_module.sha1(username .. ":" .. realm .. ":" .. password)
    local ha2 = sha1_module.sha1(method .. ":" .. uri)
    local response = sha1_module.sha1(ha1 .. ":" .. nonce .. ":" .. ha2)
    return response
end

-- Enhanced self-test with multiple cases
local function self_test()
    local tests = {
        {
            input = "test",
            expected_sha1 = "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3",
            desc = "Basic SHA-1 test"
        },
        {
            input = "",
            expected_sha1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709",
            desc = "Empty string SHA-1"
        },
        {
            input = "The quick brown fox jumps over the lazy dog",
            expected_sha1 = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
            desc = "Standard phrase SHA-1"
        },
        {
            input = "abc",
            hmac_key = "key",
            expected_hmac = "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9",
            desc = "HMAC-SHA1 test"
        }
    }

    local all_passed = true
    for _, test in ipairs(tests) do
        if test.expected_sha1 then
            local result = sha1_module.sha1(test.input)
            if result ~= test.expected_sha1 then
                log.error(string.format("Self-test failed [%s]: expected %s, got %s", test.desc, test.expected_sha1, result))
                all_passed = false
            elseif config.debug_mode then
                log.debug(string.format("Self-test passed [%s]: %s", test.desc, result))
            end
        end
        if test.expected_hmac then
            local result = sha1_module.hmac(test.hmac_key, test.input)
            if result ~= test.expected_hmac then
                log.error(string.format("Self-test failed [%s]: expected %s, got %s", test.desc, test.expected_hmac, result))
                all_passed = false
            elseif config.debug_mode then
                log.debug(string.format("Self-test passed [%s]: %s", test.desc, result))
            end
        end
    end

    if all_passed then
        log.info("SHA-1 self-test passed")
    else
        log.error("SHA-1 self-test failed; check implementation or dependencies")
    end
    return all_passed
end

-- Run self-test on load
self_test()

-- Export the module with metadata
sha1_module.config = config
sha1_module.lua_version = lua_version
sha1_module.implementation = impl_desc

return sha1_module