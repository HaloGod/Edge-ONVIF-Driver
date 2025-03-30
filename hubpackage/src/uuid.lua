---------------------------------------------------------------------------------------
-- Copyright 2012 Rackspace (original), 2013-2021 Thijs Schreijer (modifications),
-- enhanced 2025 by suggestions for dMac
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS-IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- see http://www.ietf.org/rfc/rfc4122.txt
--
-- Enhanced for SmartThings Edge with better seeding, validation, and state checking.
--

local M = {}
local log = require "log" -- Assuming log is available in Edge-ONVIF-Driver

local bitsize = 32
local lua_version = tonumber(_VERSION:match("%d%.*%d*"))
local MATRIX_AND = {{0,0},{0,1}}
local MATRIX_OR = {{0,1},{1,1}}
local HEXES = '0123456789abcdef'

local math_floor = math.floor
local math_random = math.random
local math_abs = math.abs
local string_sub = string.sub
local to_number = tonumber
local assert = assert
local type = type
local seeded = false

local function BITWISE(x, y, matrix)
    if lua_version >= 5.3 and bit32 then
        if matrix == MATRIX_AND then return bit32.band(x, y) end
        if matrix == MATRIX_OR then return bit32.bor(x, y) end
    end
    local z = 0
    local pow = 1
    while x > 0 or y > 0 do
        z = z + (matrix[x % 2 + 1][y % 2 + 1] * pow)
        pow = pow * 2
        x = math_floor(x / 2)
        y = math_floor(y / 2)
    end
    return z
end

local function INT2HEX(x)
    local s, base = '', 16
    local d
    while x > 0 do
        d = x % base + 1
        x = math_floor(x / base)
        s = string_sub(HEXES, d, d) .. s
    end
    while #s < 2 do s = "0" .. s end
    return s
end

function M.new(hwaddr)
    local bytes = {
        math_random(0, 255), math_random(0, 255), math_random(0, 255), math_random(0, 255),
        math_random(0, 255), math_random(0, 255), math_random(0, 255), math_random(0, 255),
        math_random(0, 255), math_random(0, 255), math_random(0, 255), math_random(0, 255),
        math_random(0, 255), math_random(0, 255), math_random(0, 255), math_random(0, 255)
    }

    if hwaddr then
        assert(type(hwaddr) == "string", "Expected hex string, got " .. type(hwaddr))
        local clean_hwaddr = hwaddr:gsub("[:-]", ""):lower()
        if not clean_hwaddr:match("^[%x]+$") then
            log.error("Invalid hex characters in hwaddr: " .. hwaddr)
            error("Invalid hwaddr format")
        end
        if #clean_hwaddr < 12 then
            log.error("hwaddr too short, expected at least 12 hex chars, got " .. clean_hwaddr)
            error("Insufficient hwaddr length")
        end
        local trimmed_hwaddr = clean_hwaddr:sub(-12)
        bytes[11] = to_number(trimmed_hwaddr:sub(1, 2), 16)
        bytes[12] = to_number(trimmed_hwaddr:sub(3, 4), 16)
        bytes[13] = to_number(trimmed_hwaddr:sub(5, 6), 16)
        bytes[14] = to_number(trimmed_hwaddr:sub(7, 8), 16)
        bytes[15] = to_number(trimmed_hwaddr:sub(9, 10), 16)
        bytes[16] = to_number(trimmed_hwaddr:sub(11, 12), 16)
    end

    bytes[7] = BITWISE(bytes[7], 0x0f, MATRIX_AND)
    bytes[7] = BITWISE(bytes[7], 0x40, MATRIX_OR)
    bytes[9] = BITWISE(bytes[7], 0x3f, MATRIX_AND)
    bytes[9] = BITWISE(bytes[7], 0x80, MATRIX_OR)
    return INT2HEX(bytes[1]) .. INT2HEX(bytes[2]) .. INT2HEX(bytes[3]) .. INT2HEX(bytes[4]) .. "-" ..
           INT2HEX(bytes[5]) .. INT2HEX(bytes[6]) .. "-" ..
           INT2HEX(bytes[7]) .. INT2HEX(bytes[8]) .. "-" ..
           INT2HEX(bytes[9]) .. INT2HEX(bytes[10]) .. "-" ..
           INT2HEX(bytes[11]) .. INT2HEX(bytes[12]) .. INT2HEX(bytes[13]) .. INT2HEX(bytes[14]) .. INT2HEX(bytes[15]) .. INT2HEX(bytes[16])
end

function M.randomseed(seed)
    seed = math_floor(math_abs(seed))
    if seed >= (2^bitsize) then
        seed = seed - math_floor(seed / 2^bitsize) * (2^bitsize)
    end
    if lua_version < 5.2 then
        math.randomseed(seed - 2^(bitsize-1))
    else
        math.randomseed(seed)
    end
    seeded = true
    return seed
end

function M.seed()
    if _G.ngx ~= nil then
        return M.randomseed(ngx.time() + ngx.worker.pid())
    elseif package.loaded["socket"] and package.loaded["socket"].gettime then
        return M.randomseed(package.loaded["socket"].gettime() * 10000)
    elseif require "cosock.socket".gettime then
        return M.randomseed(require "cosock.socket".gettime() * 10000)
    else
        log.warn("Using low-precision os.time() for UUID seed; consider loading cosock.socket")
        return M.randomseed(os.time())
    end
    seeded = true
end

function M.is_valid(uuid_str)
    if type(uuid_str) ~= "string" then return false end
    local pattern = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
    return uuid_str:match(pattern) ~= nil and #uuid_str == 36
end

function M.is_seeded()
    return seeded
end

return setmetatable(M, { __call = function(self, hwaddr) return self.new(hwaddr) end })