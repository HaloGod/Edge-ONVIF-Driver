--[[
 base64 -- v1.5.3 public domain Lua base64 encoder/decoder, enhanced 2025
 no warranty implied; use at your own risk

 Needs bit32.extract or falls back to Lua 5.1-5.3 compatible implementations.
 Enhanced with validation, persistent caching, and URL-safe variants.

 author: Ilya Kolbin (iskolbin@gmail.com), enhanced by suggestions for dMac
 url: github.com/iskolbin/lbase64
--]]

local base64 = {}
local log = require "log" -- Assuming log is available in Edge-ONVIF-Driver

local extract = _G.bit32 and _G.bit32.extract
if not extract then
    if _G.bit then
        local shl, shr, band = _G.bit.lshift, _G.bit.rshift, _G.bit.band
        extract = function(v, from, width)
            return band(shr(v, from), shl(1, width) - 1)
        end
    elseif _G._VERSION == "Lua 5.1" then
        local floor = math.floor
        extract = function(v, from, width)
            local w = 0
            for i = from, from + width - 1 do
                w = w + (((math.floor(v / 2^i)) % 2) * 2^(i - from))
            end
            return w
        end
    else
        extract = function(v, from, width)
            return math.floor(v / 2^from) % 2^width
        end
    end
end

function base64.makeencoder(s62, s63, spad)
    local encoder = {}
    for b64code, char in pairs{[0]='A','B','C','D','E','F','G','H','I','J',
        'K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y',
        'Z','a','b','c','d','e','f','g','h','i','j','k','l','m','n',
        'o','p','q','r','s','t','u','v','w','x','y','z','0','1','2',
        '3','4','5','6','7','8','9',s62 or '+',s63 or'/',spad or'='} do
        encoder[b64code] = char:byte()
    end
    return encoder
end

function base64.makedecoder(s62, s63, spad)
    local decoder = {}
    for b64code, charcode in pairs(base64.makeencoder(s62, s63, spad)) do
        decoder[charcode] = b64code
    end
    return decoder
end

local DEFAULT_ENCODER = base64.makeencoder()
local DEFAULT_DECODER = base64.makedecoder()
local URLSAFE_ENCODER = base64.makeencoder('-', '_')
local URLSAFE_DECODER = base64.makedecoder('-', '_')
local CACHE_SIZE_LIMIT = 1000
local encode_cache = {}
local decode_cache = {}

local char, concat = string.char, table.concat

function base64.encode(str, encoder, usecaching, validate)
    if type(str) ~= "string" then
        log.error("base64.encode: expected string, got " .. type(str))
        error("Invalid input type")
    end
    encoder = encoder or DEFAULT_ENCODER
    local t, k, n = {}, 1, #str
    local lastn = n % 3
    local cache = usecaching and encode_cache or nil
    for i = 1, n - lastn, 3 do
        local a, b, c = str:byte(i, i + 2)
        local v = a * 0x10000 + b * 0x100 + c
        local s = cache and cache[v] or char(encoder[extract(v, 18, 6)], encoder[extract(v, 12, 6)], encoder[extract(v, 6, 6)], encoder[extract(v, 0, 6)])
        if cache and not cache[v] and next(cache, CACHE_SIZE_LIMIT) == nil then cache[v] = s end
        t[k] = s
        k = k + 1
    end
    if lastn == 2 then
        local a, b = str:byte(n - 1, n)
        local v = a * 0x10000 + b * 0x100
        t[k] = char(encoder[extract(v, 18, 6)], encoder[extract(v, 12, 6)], encoder[extract(v, 6, 6)], encoder[64])
    elseif lastn == 1 then
        local v = str:byte(n) * 0x10000
        t[k] = char(encoder[extract(v, 18, 6)], encoder[extract(v, 12, 6)], encoder[64], encoder[64])
    end
    local result = concat(t)
    if validate then
        local decoded = base64.decode(result, encoder, usecaching)
        if decoded ~= str then
            log.warn("base64.encode: validation failed, input and decoded output mismatch")
        end
    end
    return result
end

function base64.decode(b64, decoder, usecaching, validate)
    if type(b64) ~= "string" then
        log.error("base64.decode: expected string, got " .. type(b64))
        error("Invalid input type")
    end
    decoder = decoder or DEFAULT_DECODER
    local pattern = '[^%w%+%/%=]'
    if decoder then
        local s62, s63
        for charcode, b64code in pairs(decoder) do
            if b64code == 62 then s62 = charcode
            elseif b64code == 63 then s63 = charcode
            end
        end
        pattern = ('[^%%w%%%s%%%s%%=]'):format(char(s62 or 43), char(s63 or 47))
    end
    b64 = b64:gsub(pattern, '')
    local cache = usecaching and decode_cache or nil
    local t, k = {}, 1
    local n = #b64
    local padding = b64:sub(-2) == '==' and 2 or b64:sub(-1) == '=' and 1 or 0
    for i = 1, padding > 0 and n - 4 or n, 4 do
        local a, b, c, d = b64:byte(i, i + 3)
        local s
        if usecaching then
            local v0 = a * 0x1000000 + b * 0x10000 + c * 0x100 + d
            local v = decoder[a] * 0x40000 + decoder[b] * 0x1000 + decoder[c] * 0x40 + decoder[d]
            s = cache[v0] or char(extract(v, 16, 8), extract(v, 8, 8), extract(v, 0, 8))
            if not cache[v0] and next(cache, CACHE_SIZE_LIMIT) == nil then
                cache[v0] = s
            end
        else
            local v = decoder[a] * 0x40000 + decoder[b] * 0x1000 + decoder[c] * 0x40 + decoder[d]
            s = char(extract(v, 16, 8), extract(v, 8, 8), extract(v, 0, 8))
        end
        t[k] = s
        k = k + 1
    end
    if padding == 1 then
        local a, b, c = b64:byte(n - 3, n - 1)
        local v = decoder[a] * 0x40000 + decoder[b] * 0x1000 + decoder[c] * 0x40
        t[k] = char(extract(v, 16, 8), extract(v, 8, 8))
    elseif padding == 2 then
        local a, b = b64:byte(n - 3, n - 2)
        local v = decoder[a] * 0x40000 + decoder[b] * 0x1000
        t[k] = char(extract(v, 16, 8))
    end
    local result = concat(t)
    if validate then
        local re_encoded = base64.encode(result, decoder, usecaching)
        if re_encoded ~= b64:gsub(pattern, '') then
            log.warn("base64.decode: validation failed, output re-encoded does not match input")
        end
    end
    return result
end

function base64.encode_urlsafe(str, usecaching, validate)
    return base64.encode(str, URLSAFE_ENCODER, usecaching, validate)
end

function base64.decode_urlsafe(b64, usecaching, validate)
    return base64.decode(b64, URLSAFE_DECODER, usecaching, validate)
end

return {
    encode = base64.encode,
    decode = base64.decode,
    encode_urlsafe = base64.encode_urlsafe,
    decode_urlsafe = base64.decode_urlsafe,
    makeencoder = base64.makeencoder,
    makedecoder = base64.makedecoder
}
--[[
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2018 Ilya Kolbin
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
------------------------------------------------------------------------------
--]]
