--[[
  Copyright 2025, enhancements for dMac, based on original SHA-1 common utilities

  Licensed under the MIT License (see sha1.lua for details)

  DESCRIPTION
  Common utility functions for SHA-1 library, optimized for performance and compatibility.
  Provides byte-to-uint32 and uint32-to-byte conversions with bitwise optimizations and error handling.
--]]

local common = {}

-- Attempt to load logging (e.g., SmartThings Edge), fallback to print
local log
if pcall(function() log = require "log" end) then
    -- SmartThings Edge logging available
else
    log = { info = print, warn = print, error = print, debug = print }
end

-- Detect bitwise operation support
local bit32
local has_bit32 = pcall(function() bit32 = require "bit32" end)
local has_lua53 = _VERSION:match("Lua%s+5%.3") or _VERSION:match("Lua%s+5%.4")

-- Optimized bytes_to_uint32 with bitwise operations if available
if has_bit32 then
    --- Converts four bytes into a uint32 number using bit32 operations.
    -- @param a First byte (most significant)
    -- @param b Second byte
    -- @param c Third byte
    -- @param d Fourth byte (least significant)
    -- @return uint32 number
    -- @raise Error if inputs are not integers or out of byte range (0-255)
    function common.bytes_to_uint32(a, b, c, d)
        if not (type(a) == "number" and type(b) == "number" and type(c) == "number" and type(d) == "number") or
           not (a % 1 == 0 and b % 1 == 0 and c % 1 == 0 and d % 1 == 0) or
           not (a >= 0 and a <= 255 and b >= 0 and b <= 255 and c >= 0 and c <= 255 and d >= 0 and d <= 255) then
            log.error("bytes_to_uint32: Invalid input - must be integers between 0 and 255")
            error("Invalid byte values")
        end
        return bit32.bor(bit32.lshift(a, 24), bit32.lshift(b, 16), bit32.lshift(c, 8), d)
    end
elseif has_lua53 then
    --- Converts four bytes into a uint32 number using Lua 5.3+ bitwise operators.
    -- @param a First byte (most significant)
    -- @param b Second byte
    -- @param c Third byte
    -- @param d Fourth byte (least significant)
    -- @return uint32 number
    -- @raise Error if inputs are not integers or out of byte range (0-255)
    function common.bytes_to_uint32(a, b, c, d)
        if not (type(a) == "number" and type(b) == "number" and type(c) == "number" and type(d) == "number") or
           not (a % 1 == 0 and b % 1 == 0 and c % 1 == 0 and d % 1 == 0) or
           not (a >= 0 and a <= 255 and b >= 0 and b <= 255 and c >= 0 and c <= 255 and d >= 0 and d <= 255) then
            log.error("bytes_to_uint32: Invalid input - must be integers between 0 and 255")
            error("Invalid byte values")
        end
        return (a << 24) | (b << 16) | (c << 8) | d
    end
else
    --- Converts four bytes into a uint32 number using arithmetic (pure Lua fallback).
    -- @param a First byte (most significant)
    -- @param b Second byte
    -- @param c Third byte
    -- @param d Fourth byte (least significant)
    -- @return uint32 number
    -- @raise Error if inputs are not integers or out of byte range (0-255)
    function common.bytes_to_uint32(a, b, c, d)
        if not (type(a) == "number" and type(b) == "number" and type(c) == "number" and type(d) == "number") or
           not (a % 1 == 0 and b % 1 == 0 and c % 1 == 0 and d % 1 == 0) or
           not (a >= 0 and a <= 255 and b >= 0 and b <= 255 and c >= 0 and c <= 255 and d >= 0 and d <= 255) then
            log.error("bytes_to_uint32: Invalid input - must be integers between 0 and 255")
            error("Invalid byte values")
        end
        return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
    end
end

-- Optimized uint32_to_bytes with bitwise operations if available
if has_bit32 then
    --- Splits a uint32 number into four bytes using bit32 operations.
    -- @param a uint32 number
    -- @return Four bytes (a1 most significant, a4 least significant)
    -- @raise Error if input is not an integer or out of uint32 range (0 to 4294967295)
    function common.uint32_to_bytes(a)
        if type(a) ~= "number" or a % 1 ~= 0 or a < 0 or a > 4294967295 then
            log.error("uint32_to_bytes: Invalid input - must be an integer between 0 and 4294967295")
            error("Invalid uint32 value")
        end
        local a1 = bit32.rshift(a, 24)
        local a2 = bit32.band(bit32.rshift(a, 16), 0xff)
        local a3 = bit32.band(bit32.rshift(a, 8), 0xff)
        local a4 = bit32.band(a, 0xff)
        return a1, a2, a3, a4
    end
elseif has_lua53 then
    --- Splits a uint32 number into four bytes using Lua 5.3+ bitwise operators.
    -- @param a uint32 number
    -- @return Four bytes (a1 most significant, a4 least significant)
    -- @raise Error if input is not an integer or out of uint32 range (0 to 4294967295)
    function common.uint32_to_bytes(a)
        if type(a) ~= "number" or a % 1 ~= 0 or a < 0 or a > 4294967295 then
            log.error("uint32_to_bytes: Invalid input - must be an integer between 0 and 4294967295")
            error("Invalid uint32 value")
        end
        local a1 = a >> 24
        local a2 = (a >> 16) & 0xff
        local a3 = (a >> 8) & 0xff
        local a4 = a & 0xff
        return a1, a2, a3, a4
    end
else
    --- Splits a uint32 number into four bytes using arithmetic (pure Lua fallback).
    -- @param a uint32 number
    -- @return Four bytes (a1 most significant, a4 least significant)
    -- @raise Error if input is not an integer or out of uint32 range (0 to 4294967295)
    function common.uint32_to_bytes(a)
        if type(a) ~= "number" or a % 1 ~= 0 or a < 0 or a > 4294967295 then
            log.error("uint32_to_bytes: Invalid input - must be an integer between 0 and 4294967295")
            error("Invalid uint32 value")
        end
        local a4 = a % 256
        a = (a - a4) / 256
        local a3 = a % 256
        a = (a - a3) / 256
        local a2 = a % 256
        local a1 = (a - a2) / 256
        return a1, a2, a3, a4
    end
end

-- Precomputed lookup table for bytes_to_uint32 (optional, for frequent fixed patterns)
local precomputed = {}
function common.precompute_bytes_to_uint32()
    for a = 0, 255 do
        for b = 0, 255 do
            for c = 0, 255 do
                for d = 0, 255 do
                    local key = string.format("%d,%d,%d,%d", a, b, c, d)
                    precomputed[key] = common.bytes_to_uint32(a, b, c, d)
                end
            end
        end
    end
    log.debug("Precomputed bytes_to_uint32 lookup table")
end

--- Looks up a precomputed uint32 value for four bytes.
-- @param a First byte
-- @param b Second byte
-- @param c Third byte
-- @param d Fourth byte
-- @return uint32 number or nil if not precomputed
function common.lookup_bytes_to_uint32(a, b, c, d)
    local key = string.format("%d,%d,%d,%d", a, b, c, d)
    return precomputed[key]
end

-- Self-test to validate functionality
local function self_test()
    local test_bytes = {0x12, 0x34, 0x56, 0x78}
    local expected_uint32 = 0x12345678
    local result_uint32 = common.bytes_to_uint32(test_bytes[1], test_bytes[2], test_bytes[3], test_bytes[4])
    if result_uint32 ~= expected_uint32 then
        log.error(string.format("Self-test failed: bytes_to_uint32 expected %08x, got %08x", expected_uint32, result_uint32))
        return false
    end

    local a1, a2, a3, a4 = common.uint32_to_bytes(expected_uint32)
    if a1 ~= test_bytes[1] or a2 ~= test_bytes[2] or a3 ~= test_bytes[3] or a4 ~= test_bytes[4] then
        log.error(string.format("Self-test failed: uint32_to_bytes expected %d,%d,%d,%d, got %d,%d,%d,%d",
            test_bytes[1], test_bytes[2], test_bytes[3], test_bytes[4], a1, a2, a3, a4))
        return false
    end

    log.info("sha1/common.lua self-test passed")
    return true
end

-- Run self-test on load
self_test()

return common