--[[
Credit: Ross Tyler, enhanced 2025 by suggestions for dMac
Support for the Object-Oriented Programming concepts discussed here
https://www.lua.org/pil/contents.html#16
]]--

local log = require "log" -- Assuming log is available in your driver

-- new creates an object, assigns class as its metatable, and initializes it
local function new(class, ...)
    local self = setmetatable({}, class)
    self._class_name = class.name or "UnnamedClass"
    class:_init(self, ...)
    return self
end

-- join implements multiple-inheritance lookup with caching
local function join(_supers)
    local cache = {}
    return function(class, key)
        if key == nil then return _supers end
        if cache[key] ~= nil then return cache[key] end
        for _, _super in ipairs(_supers) do
            local value = _super[key]
            if value ~= nil then
                cache[key] = value
                class[key] = value
                return value
            end
        end
        cache[key] = false
        return nil
    end
end

-- super returns the super class or join function
local function super(class)
    return getmetatable(class).__index
end

-- supers iterates over multiple-inheritance super classes
local function supers(class)
    return coroutine.wrap(function()
        for _, _super in ipairs(super(class)()) do
            coroutine.yield(_super)
        end
    end)
end

-- is_instance checks if an object is an instance of a class
local function is_instance(obj, class)
    if type(obj) ~= "table" or type(class) ~= "table" then return false end
    local mt = getmetatable(obj)
    while mt do
        if mt == class then return true end
        mt = getmetatable(mt).__index
        if type(mt) == "function" then
            for _, super in ipairs(mt(nil)) do
                if super == class then return true end
            end
        end
    end
    return false
end

-- methods lists all callable methods of a class
local function methods(class)
    local result = {}
    local seen = {}
    local function collect(tbl)
        if not tbl or seen[tbl] then return end
        seen[tbl] = true
        for key, value in pairs(tbl) do
            if type(value) == "function" and not result[key] then
                result[key] = value
            end
        end
        local mt = getmetatable(tbl)
        if mt and mt.__index then
            if type(mt.__index) == "table" then
                collect(mt.__index)
            elseif type(mt.__index) == "function" then
                for _, super in ipairs(mt.__index(nil)) do
                    collect(super)
                end
            end
        end
    end
    collect(class)
    return result
end

return {
    super = super,
    supers = supers,
    class = function(self) return getmetatable(self) end,
    
    single = function(class, super_class)
        if type(class) ~= "table" then
            log.error("classify.single: class must be a table, got " .. type(class))
            error("Invalid class argument")
        end
        if super_class and type(super_class) ~= "table" then
            log.error("classify.single: super_class must be a table or nil, got " .. type(super_class))
            error("Invalid super_class argument")
        end
        class.__index = class
        setmetatable(class, {
            __index = super_class,
            __call = new
        })
        return class
    end,
    
    multiple = function(class, ...)
        if type(class) ~= "table" then
            log.error("classify.multiple: class must be a table, got " .. type(class))
            error("Invalid class argument")
        end
        local supers = {...}
        for i, super in ipairs(supers) do
            if type(super) ~= "table" then
                log.error("classify.multiple: super class at index " .. i .. " must be a table, got " .. type(super))
                error("Invalid super class argument")
            end
        end
        class.__index = class
        setmetatable(class, {
            __index = join(supers),
            __call = new
        })
        return class
    end,
    
    error = function(class)
        if type(class) ~= "table" then
            log.error("classify.error: class must be a table, got " .. type(class))
            error("Invalid class argument")
        end
        class.__index = class
        setmetatable(class, {
            __call = function(_class, ...)
                local class_name = _class.name or "UnnamedErrorClass"
                error(setmetatable({message = class_name .. " error", ...}, _class))
            end
        })
        return class
    end,
    
    is_instance = is_instance,
    methods = methods
}