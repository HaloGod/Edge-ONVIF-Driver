--[[
Credit: Ross Tyler, enhanced 2025 by suggestions for dMac
Semaphore implementation with improved error handling, timeouts, and state inspection
]]--

local classify = require "classify"
local log = require "log" -- Assuming log is available
local socket = require "cosock.socket" -- For timeout support

return classify.single({
    _init = function(class, self, permits)
        if permits and type(permits) ~= "number" then
            log.error("Semaphore._init: permits must be a number or nil, got " .. type(permits))
            error("Invalid permits argument")
        end
        permits = permits or 1
        if permits < 0 then
            log.error("Semaphore._init: permits cannot be negative, got " .. permits)
            error("Negative permits not allowed")
        end
        self._permits = permits
        self._initial_permits = permits
        self._pending = {}
    end,

    acquire = function(self, use, timeout, timeout_callback)
        if type(use) ~= "function" then
            log.error("Semaphore.acquire: use must be a function, got " .. type(use))
            error("Invalid use argument")
        end
        self._permits = self._permits - 1
        if self._permits < 0 then
            if timeout and type(timeout) == "number" then
                local pending = { use = use, timeout = socket.gettime() + timeout, callback = timeout_callback }
                table.insert(self._pending, pending)
                log.debug("Semaphore.acquire: resource pending with timeout, queue length: " .. #self._pending)
            else
                table.insert(self._pending, use)
                log.debug("Semaphore.acquire: resource pending, queue length: " .. #self._pending)
            end
        else
            use()
        end
    end,

    release = function(self)
        if self._permits >= self._initial_permits then
            log.warn("Semaphore.release: releasing more permits than initially set")
        end
        self._permits = self._permits + 1
        if #self._pending > 0 then
            local pending = table.remove(self._pending, 1)
            if type(pending) == "table" and pending.timeout then
                if socket.gettime() < pending.timeout then
                    pending.use()
                elseif pending.callback then
                    pending.callback()
                    log.debug("Semaphore.release: timeout expired, executed callback")
                end
            else
                pending()
            end
            log.debug("Semaphore.release: executed pending use, remaining: " .. #self._pending)
        end
    end,

    try_acquire = function(self, use)
        if type(use) ~= "function" then
            log.error("Semaphore.try_acquire: use must be a function, got " .. type(use))
            error("Invalid use argument")
        end
        if self._permits > 0 then
            self._permits = self._permits - 1
            use()
            return true
        end
        return false
    end,

    available = function(self)
        return math.max(0, self._permits)
    end,

    pending_count = function(self)
        return #self._pending
    end
})