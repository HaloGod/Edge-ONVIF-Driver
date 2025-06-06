local stub_log = {}
function stub_log.debug(...) end
function stub_log.info(...) end
function stub_log.warn(...) end
function stub_log.error(...) end
package.loaded['log'] = stub_log

-- simple socket stub used by retry
_G.socket = { sleep = function() end }

-- minimal lxp.lom stub using lua-expat
package.loaded['lxp.lom'] = package.loaded['lxp.lom'] or (function()
  local lxp = require 'lxp'
  local M = {}
  function M.new(handler)
    local cbs = {
      StartElement = function(_, name, attr)
        if handler.StartElement then handler:StartElement(name, attr) end
      end,
      EndElement = function(_, name)
        if handler.EndElement then handler:EndElement(name) end
      end,
      CharacterData = function(_, text)
        if handler.CharacterData then handler:CharacterData(text) end
      end
    }
    local p = lxp.new(cbs)
    return {
      parse = function(_, xml)
        p:parse(xml)
        p:parse()
        return true
      end,
      close = function()
        p:close()
      end
    }
  end
  return M
end)()
