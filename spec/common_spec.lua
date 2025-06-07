require 'spec.spec_helper'
local common = require 'hubpackage.src.common'

describe('common module', function()
  it('parses xml into tables', function()
    local xml = '<root><child>text</child></root>'
    local t = common.xml_to_table(xml)
    assert.are.equal('text', t.root.child._text)
  end)

  it('checks element paths correctly', function()
    local xml = '<root><child>text</child></root>'
    local t = common.xml_to_table(xml)
    assert.is_true(common.is_element(t, {'root', 'child'}))
    assert.is_false(common.is_element(t, {'root', 'missing'}))
  end)

  it('retries actions until success', function()
    local count = 0
    local res = common.retry(3, 0, function()
      count = count + 1
      if count < 2 then error('fail') end
      return 'ok'
    end)
    assert.are.equal('ok', res)
    assert.are.equal(2, count)
  end)
end)
