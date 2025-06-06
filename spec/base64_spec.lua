require 'spec.spec_helper'
local base64 = require 'hubpackage.src.base64'

describe('base64 module', function()
  it('encodes and decodes basic strings', function()
    local enc = base64.encode('hello')
    assert.are.equal('aGVsbG8=', enc)
    assert.are.equal('hello', base64.decode(enc))
  end)

  it('supports urlsafe encode/decode', function()
    local enc = base64.encode_urlsafe('hello world')
    assert.are.equal('aGVsbG8gd29ybGQ=', enc)
    assert.are.equal('hello world', base64.decode_urlsafe(enc))
  end)
end)
