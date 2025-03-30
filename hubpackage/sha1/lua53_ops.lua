--[[
  Copyright 2025, enhancements for dMac, based on original SHA-1 Lua 5.3 operations

  Licensed under the MIT License (see sha1.lua for details)

  DESCRIPTION
  Bitwise operations for SHA-1 library, optimized for Lua 5.3+ with fallbacks for Lua 5.1 (bit32)
  and pure Lua. Includes error handling, logging, and self-testing for reliability.
--]]

local ops = {}

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

-- Constants
local UINT32_MAX = 4294967295

-- Helper to validate uint32 input
local function validate_uint32(name, ...)
    for i, v in ipairs({...}) do
        if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > UINT32_MAX then
            log.error(string.format("%s: Argument %d invalid - must be an integer between 0 and %d", name, i, UINT32_MAX))
            error("Invalid uint32 value")
        end
    end
end

-- Bitwise operations with environment-specific implementations
if has_lua53 then
    log.info("Using Lua 5.3+ bitwise operators in sha1/lua53_ops.lua")

    --- Left rotates a uint32 number by a specified number of bits.
    -- @param a uint32 number
    -- @param bits Number of bits to rotate (0-31)
    -- @return Rotated uint32 number
    function ops.uint32_lrot(a, bits)
        validate_uint32("uint32_lrot", a)
        if type(bits) ~= "number" or bits % 1 ~= 0 or bits < 0 or bits > 31 then
            log.error("uint32_lrot: bits must be an integer between 0 and 31")
            error("Invalid rotation bits")
        end
        return ((a << bits) & UINT32_MAX) | (a >> (32 - bits))
    end

    --- XORs two bytes.
    -- @param a First byte (0-255)
    -- @param b Second byte (0-255)
    -- @return Resulting byte
    function ops.byte_xor(a, b)
        validate_uint32("byte_xor", a, b)
        if a > 255 or b > 255 then
            log.error("byte_xor: Arguments must be bytes (0-255)")
            error("Invalid byte value")
        end
        return a ~ b
    end

    --- XORs three uint32 numbers.
    -- @param a First uint32
    -- @param b Second uint32
    -- @param c Third uint32
    -- @return Resulting uint32
    function ops.uint32_xor_3(a, b, c)
        validate_uint32("uint32_xor_3", a, b, c)
        return a ~ b ~ c
    end

    --- XORs four uint32 numbers.
    -- @param a First uint32
    -- @param b Second uint32
    -- @param c Third uint32
    -- @param d Fourth uint32
    -- @return Resulting uint32
    function ops.uint32_xor_4(a, b, c, d)
        validate_uint32("uint32_xor_4", a, b, c, d)
        return a ~ b ~ c ~ d
    end

    --- Computes ternary operation (b AND c) OR (NOT a AND c) for uint32 numbers.
    -- @param a First uint32
    -- @param b Second uint32
    -- @param c Third uint32
    -- @return Resulting uint32
    function ops.uint32_ternary(a, b, c)
        validate_uint32("uint32_ternary", a, b, c)
        return c ~ (a & (b ~ c))
    end

    --- Computes majority operation (a AND b) OR (a AND c) OR (b AND c) for uint32 numbers.
    -- @param a First uint32
    -- @param b Second uint32
    -- @param c Third uint32
    -- @return Resulting uint32
    function ops.uint32_majority(a, b, c)
        validate_uint32("uint32_majority", a, b, c)
        return (a & (b | c)) | (b & c)
    end
elseif has_bit32 then
    log.info("Using bit32 module in sha1/lua53_ops.lua")

    function ops.uint32_lrot(a, bits)
        validate_uint32("uint32_lrot", a)
        if type(bits) ~= "number" or bits % 1 ~= 0 or bits < 0 or bits > 31 then
            log.error("uint32_lrot: bits must be an integer between 0 and 31")
            error("Invalid rotation bits")
        end
        return bit32.lrotate(a, bits)
    end

    function ops.byte_xor(a, b)
        validate_uint32("byte_xor", a, b)
        if a > 255 or b > 255 then
            log.error("byte_xor: Arguments must be bytes (0-255)")
            error("Invalid byte value")
        end
        return bit32.bxor(a, b)
    end

    function ops.uint32_xor_3(a, b, c)
        validate_uint32("uint32_xor_3", a, b, c)
        return bit32.bxor(a, b, c)
    end

    function ops.uint32_xor_4(a, b, c, d)
        validate_uint32("uint32_xor_4", a, b, c, d)
        return bit32.bxor(a, bit32.bxor(b, c), d)
    end

    function ops.uint32_ternary(a, b, c)
        validate_uint32("uint32_ternary", a, b, c)
        return bit32.bxor(c, bit32.band(a, bit32.bxor(b, c)))
    end

    function ops.uint32_majority(a, b, c)
        validate_uint32("uint32_majority", a, b, c)
        return bit32.bor(bit32.band(a, bit32.bor(b, c)), bit32.band(b, c))
    end
else
    log.warn("No Lua 5.3+ or bit32 support; using pure Lua in sha1/lua53_ops.lua")

    function ops.uint32_lrot(a, bits)
        validate_uint32("uint32_lrot", a)
        if type(bits) ~= "number" or bits % 1 ~= 0 or bits < 0 or bits > 31 then
            log.error("uint32_lrot: bits must be an integer between 0 and 31")
            error("Invalid rotation bits")
        end
        local left = (a % (2 ^ (32 - bits))) * (2 ^ bits)
        local right = math.floor(a / (2 ^ (32 - bits)))
        return (left + right) % (UINT32_MAX + 1)
    end

    function ops.byte_xor(a, b)
        validate_uint32("byte_xor", a, b)
        if a > 255 or b > 255 then
            log.error("byte_xor: Arguments must be bytes (0-255)")
            error("Invalid byte value")
        end
        local result = 0
        for i = 0, 7 do
            local bit_a = math.floor(a / (2 ^ i)) % 2
            local bit_b = math.floor(b / (2 ^ i)) % 2
            result = result + ((bit_a ~= bit_b) and (2 ^ i) or 0)
        end
        return result
    end

    function ops.uint32_xor_3(a, b, c)
        validate_uint32("uint32_xor_3", a, b, c)
        local result = 0
        for i = 0, 31 do
            local bit_a = math.floor(a / (2 ^ i)) % 2
            local bit_b = math.floor(b / (2 ^ i)) % 2
            local bit_c = math.floor(c / (2 ^ i)) % 2
            result = result + (((bit_a + bit_b + bit_c) % 2 == 1) and (2 ^ i) or 0)
        end
        return result
    end

    function ops.uint32_xor_4(a, b, c, d)
        validate_uint32("uint32_xor_4", a, b, c, d)
        local result = 0
        for i = 0, 31 do
            local bit_a = math.floor(a / (2 ^ i)) % 2
            local bit_b = math.floor(b / (2 ^ i)) % 2
            local bit_c = math.floor(c / (2 ^ i)) % 2
            local bit_d = math.floor(d / (2 ^ i)) % 2
            result = result + (((bit_a + bit_b + bit_c + bit_d) % 2 == 1) and (2 ^ i) or 0)
        end
        return result
    end

    function ops.uint32_ternary(a, b, c)
        validate_uint32("uint32_ternary", a, b, c)
        local result = 0
        for i = 0, 31 do
            local bit_a = math.floor(a / (2 ^ i)) % 2
            local bit_b = math.floor(b / (2 ^ i)) % 2
            local bit_c = math.floor(c / (2 ^ i)) % 2
            result = result + (((bit_a == 1 and bit_b or bit_c) == 1) and (2 ^ i) or 0)
        end
        return result
    end

    function ops.uint32_majority(a, b, c)
        validate_uint32("uint32_majority", a, b, c)
        local result = 0
        for i = 0, 31 do
            local bit_a = math.floor(a / (2 ^ i)) % 2
            local bit_b = math.floor(b / (2 ^ i)) % 2
            local bit_c = math.floor(c / (2 ^ i)) % 2
            result = result + (((bit_a + bit_b + bit_c) >= 2) and (2 ^ i) or 0)
        end
        return result
    end
end

-- Self-test to validate operations
local function self_test()
    local tests = {
        { func = "uint32_lrot", args = {0x12345678, 4}, expected = 0x23456781 },
        { func = "byte_xor", args = {0x5c, 0x36}, expected = 0x6a },
        { func = "uint32_xor_3", args = {0x11111111, 0x22222222, 0x33333333}, expected = 0x00000000 },
        { func = "uint32_xor_4", args = {0x11111111, 0x22222222, 0x33333333, 0x00000000}, expected = 0x00000000 },
        { func = "uint32_ternary", args = {0xFFFF0000, 0xFF00FF00, 0x00FF00FF}, expected = 0x00FFFFFF },
        { func = "uint32_majority", args = {0xFFFF0000, 0xFF00FF00, 0x00FF00FF}, expected = 0xFFFF00FF }
    }

    for _, test in ipairs(tests) do
        local result = ops[test.func](table.unpack(test.args))
        if result ~= test.expected then
            log.error(string.format("Self-test failed: %s(%s) expected %08x, got %08x",
                test.func, table.concat(test.args, ","), test.expected, result))
            return false
        end
    end

    log.info("sha1/lua53_ops.lua self-test passed")
    return true
end

-- Run self-test on load
self_test()

return ops