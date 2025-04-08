-- sha1/sha1.lua
local sha1 = {}

-- Local variables for operations (to be set via set_operations)
local byte_xor
local uint32_lrot
local uint32_xor_3
local uint32_xor_4
local uint32_ternary
local uint32_majority

-- Function to set the operations from sha1/lua53_ops.lua
function sha1.set_operations(ops)
    byte_xor = ops.byte_xor
    uint32_lrot = ops.uint32_lrot
    uint32_xor_3 = ops.uint32_xor_3
    uint32_xor_4 = ops.uint32_xor_4
    uint32_ternary = ops.uint32_ternary
    uint32_majority = ops.uint32_majority
end

-- SHA-1 Constants
local K = {
    0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6
}

-- Helper function to convert a string to a byte array
local function string_to_bytes(str)
    local bytes = {}
    for i = 1, #str do
        bytes[i] = string.byte(str, i)
    end
    return bytes
end

-- Helper function to convert a number to a hexadecimal string
local function to_hex(num)
    return string.format("%08x", num)
end

-- Main SHA-1 function
function sha1.sha1(message)
    if not byte_xor then
        error("Operations not set; call set_operations first")
    end

    -- Convert message to byte array
    local bytes = string_to_bytes(message)

    -- Pre-processing: append the bit '1' to the message
    local msg_len = #bytes * 8
    bytes[#bytes + 1] = 0x80

    -- Append padding bytes (zeros) until length is congruent to 56 (mod 64)
    while (#bytes % 64) ~= 56 do
        bytes[#bytes + 1] = 0x00
    end

    -- Append original message length as a 64-bit big-endian integer
    for i = 7, 0, -1 do
        bytes[#bytes + 1] = bit32.rshift(msg_len, i * 8) % 256
    end

    -- Initialize hash values
    local h0 = 0x67452301
    local h1 = 0xEFCDAB89
    local h2 = 0x98BADCFE
    local h3 = 0x10325476
    local h4 = 0xC3D2E1F0

    -- Process message in 512-bit (64-byte) chunks
    for chunk_start = 1, #bytes, 64 do
        local w = {}
        -- Break chunk into sixteen 32-bit big-endian words
        for i = 0, 15 do
            w[i] = bytes[chunk_start + i * 4] * 2^24 +
                   bytes[chunk_start + i * 4 + 1] * 2^16 +
                   bytes[chunk_start + i * 4 + 2] * 2^8 +
                   bytes[chunk_start + i * 4 + 3]
        end

        -- Extend the sixteen 32-bit words into eighty 32-bit words
        for i = 16, 79 do
            w[i] = uint32_lrot(uint32_xor_4(w[i-3], w[i-8], w[i-14], w[i-16]), 1)
        end

        -- Initialize working variables
        local a = h0
        local b = h1
        local c = h2
        local d = h3
        local e = h4

        -- Main loop
        for i = 0, 79 do
            local f, k
            if i <= 19 then
                f = uint32_ternary(b, c, d)
                k = K[1]
            elseif i <= 39 then
                f = uint32_xor_3(b, c, d)
                k = K[2]
            elseif i <= 59 then
                f = uint32_majority(b, c, d)
                k = K[3]
            else
                f = uint32_xor_3(b, c, d)
                k = K[4]
            end

            local temp = (uint32_lrot(a, 5) + f + e + k + w[i]) % 2^32
            e = d
            d = c
            c = uint32_lrot(b, 30)
            b = a
            a = temp
        end

        -- Update hash values
        h0 = (h0 + a) % 2^32
        h1 = (h1 + b) % 2^32
        h2 = (h2 + c) % 2^32
        h3 = (h3 + d) % 2^32
        h4 = (h4 + e) % 2^32
    end

    -- Produce the final hash as a hexadecimal string
    return to_hex(h0) .. to_hex(h1) .. to_hex(h2) .. to_hex(h3) .. to_hex(h4)
end

return sha1