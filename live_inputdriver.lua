local driver = {
    name = "love",
    attached = false,
    previous = {},
}

local engine

local function hook(name, handler)
    if type(love) ~= "table" then
        return false
    end
    local before = love[name]
    driver.previous[name] = before
    love[name] = function(...)
        if before then
            before(...)
        end
        return handler(...)
    end
    return true
end

local function keyPressed(key, scancode, isrepeat)
    if isrepeat then
        return
    end
    if engine.get(key) then
        return
    end
    engine.press(key)
end

local function keyReleased(key)
    if not engine.get(key) then
        return
    end
    engine.release(key)
end

local function focusChanged(focused)
    if not focused then
        engine.clear()
    end
end

function driver.attach(target)
    if target then
        engine = target
    end
    if driver.attached or not engine then
        return driver.attached
    end
    if type(love) ~= "table" then
        return false
    end
    hook("keypressed", keyPressed)
    hook("keyreleased", keyReleased)
    hook("focus", focusChanged)
    driver.attached = true
    return true
end

function driver.detach()
    if not driver.attached then
        return false
    end
    for name, before in pairs(driver.previous) do
        love[name] = before
    end
    driver.previous = {}
    driver.attached = false
    return true
end

return driver
