-- sha1/lua53_ops.lua
local bit32 = require "bit32"

local ops = {}

-- XORs two bytes using bit32.bxor
function ops.byte_xor(a, b)
    return bit32.bxor(a, b)
end

-- Left rotates a 32-bit integer by a specified number of bits
function ops.uint32_lrot(a, bits)
    return bit32.lrotate(a, bits)
end

-- XORs three 32-bit integers
function ops.uint32_xor_3(a, b, c)
    return bit32.bxor(a, bit32.bxor(b, c))
end

-- XORs four 32-bit integers
function ops.uint32_xor_4(a, b, c, d)
    return bit32.bxor(a, bit32.bxor(b, bit32.bxor(c, d)))
end

-- Computes the ternary operation: c | (~a & b)
function ops.uint32_ternary(a, b, c)
    local not_a = bit32.bnot(a)
    local and_not_a_b = bit32.band(not_a, b)
    return bit32.bor(c, and_not_a_b)
end

-- Computes the majority operation: (a & b) | (a & c) | (b & c)
function ops.uint32_majority(a, b, c)
    local and_ab = bit32.band(a, b)
    local and_ac = bit32.band(a, c)
    local and_bc = bit32.band(b, c)
    return bit32.bor(and_ab, bit32.bor(and_ac, and_bc))
end

return ops