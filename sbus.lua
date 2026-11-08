local sbus = {}

sbus.calls = {
    print = 0x01,
    input = 0x02,
    gfx = 0x03,
    rand = 0x04,
    rand_seed = 0x05,
    data = 0x06,
    alloc = 0x07,
}

local randState = math.max(1, os.time() % 2147483646)

local function randSeed(value)
    randState = math.max(1, math.floor(value) % 2147483646)
    return randState
end

local function randNext()
    randState = (randState * 16807) % 2147483647
    return randState
end

local function randRange(minimum, maximum)
    minimum = math.floor(minimum or 1)
    maximum = math.floor(maximum or minimum)
    if maximum < minimum then
        minimum, maximum = maximum, minimum
    end
    if maximum == minimum then
        return minimum
    end
    return minimum + randNext() % (maximum - minimum + 1)
end

sbus.randRange = randRange
sbus.randSeed = randSeed

local keywordNames = {
    "down_listener", "up_listener", "press_listener",
    "release_listener", "count_listener", "call_listener",
    "kill", "kill_all", "kill_key", "read", "poll", "wait", "last", "clear",
}
for code = string.byte("a"), string.byte("z") do
    keywordNames[#keywordNames + 1] = "key_" .. string.char(code)
end
for digit = 0, 9 do
    keywordNames[#keywordNames + 1] = "key_" .. tostring(digit)
end
for _, name in ipairs({
    "key_space", "key_return", "key_tab", "key_escape", "key_backspace",
    "key_up", "key_down", "key_left", "key_right",
    "key_lshift", "key_rshift", "key_lctrl", "key_rctrl",
}) do
    keywordNames[#keywordNames + 1] = name
end
for _, name in ipairs({
    "pixel", "rect", "present", "blit",
}) do
    keywordNames[#keywordNames + 1] = name
end

sbus.keywords = {}
for index, name in ipairs(keywordNames) do
    sbus.keywords[name] = index
end

sbus.keywordNames = {}
for index, name in ipairs(keywordNames) do
    sbus.keywordNames[index] = name
end
sbus.keywordCount = #keywordNames

sbus.inputQueue = {}

local inputModes = { down = true, up = true, press = true, release = true, count = true, call = true }

local function loveKeyOf(arg)
    if not arg or arg.kind ~= "keyword" or not arg.name then
        return nil
    end
    if arg.name:sub(1, 4) ~= "key_" then
        return nil
    end
    return arg.name:sub(5)
end

local function targetOf(arg)
    if not arg then
        return nil
    end
    if arg.kind == "flag" then
        return { targetKind = "flag", flagByte = arg.flagByte }
    end
    if arg.kind == "register" then
        return { targetKind = "register", register = arg.register }
    end
    return nil
end

local function describe(arg)
    if not arg then
        return "nothing"
    end
    return arg.name or (arg.kind .. " " .. tostring(arg.value))
end

local function number(context, arg, fallback)
    if not arg then
        return fallback
    end
    if arg.kind == "register" then
        return context.getRegister(arg.register) or 0
    end
    if arg.kind == "flag" then
        return context.getFlag(arg.name or arg.flagByte) or 0
    end
    if arg.kind == "value" then
        return arg.value or 0
    end
    error("gfx takes numbers, got " .. describe(arg))
end

local function runAlloc(context)
    local args = context.args or {}
    local target = args[1]
    if not target or target.kind ~= "register" then
        error("sys alloc needs a register for the address, for example sys alloc r1 256")
    end
    local size = number(context, args[2], 0)
    if type(size) ~= "number" or size <= 0 then
        error("sys alloc needs a size above 0")
    end
    if not context.allocate then
        error("this machine cannot allocate")
    end
    local address = context.allocate(size)
    if not address then
        error("sys alloc: no " .. size .. " bytes left in the heap")
    end
    context.setRegister(target.register, address)
    return true
end

local function runData(context)
    local args = context.args or {}
    local target = args[1]
    if not target or target.kind ~= "register" then
        error("sys data needs a register to write, for example sys data r1")
    end
    context.setRegister(target.register, context.dataAddress or 0)
    return true
end

local function runRand(context)
    local args = context.args or {}
    local target = args[1]
    if not target or target.kind ~= "register" then
        error("sys rand needs a register to write, for example sys rand r1 100")
    end

    local minimum, maximum
    if not args[2] then
        minimum, maximum = 1, 255
    elseif args[3] then
        minimum = number(context, args[2], 1)
        maximum = number(context, args[3], 1)
    else
        minimum, maximum = 1, number(context, args[2], 1)
    end

    context.setRegister(target.register, randRange(minimum, maximum))
    return true
end

local function runRandSeed(context)
    local args = context.args or {}
    randSeed(number(context, args[1], 1))
    return true
end

local function runGfx(context)
    local gfx = context.gfx
    if not gfx then
        error("sys gfx needs the live graphics driver")
    end

    local args = context.args or {}
    local verb = args[1]
    if not verb or verb.kind ~= "keyword" then
        error("sys gfx needs a verb first: clear, pixel, rect or present")
    end

    local verbName = verb.name or ""

    if verbName == "clear" then
        gfx.clear(number(context, args[2], 0), number(context, args[3], 0), number(context, args[4], 0))
        return true
    end

    if verbName == "pixel" then
        gfx.pixel(number(context, args[2], 0), number(context, args[3], 0),
            number(context, args[4], 0), number(context, args[5], 0), number(context, args[6], 0))
        return true
    end

    if verbName == "rect" then
        gfx.rect(number(context, args[2], 0), number(context, args[3], 0),
            number(context, args[4], 0), number(context, args[5], 0),
            number(context, args[6], 0), number(context, args[7], 0), number(context, args[8], 0))
        return true
    end

    if verbName == "present" then
        gfx.present()
        return true
    end

    if verbName == "blit" then
        if not args[2] then
            error("sys gfx blit needs an address: sys gfx blit r1 x y")
        end
        local address = number(context, args[2], 0)
        if address <= 0 then
            error("sys gfx blit needs a real address, got " .. tostring(address) ..
                " (did you forget sys data r1?)")
        end
        local x = number(context, args[3], 0)
        local y = number(context, args[4], 0)

        local width = context.read32(address)
        local height = context.read32(address + 4)
        if not width or not height or width <= 0 or height <= 0 or width > 4096 or height > 4096 then
            error("sys gfx blit: no picture at " .. address ..
                " (width " .. tostring(width) .. ", height " .. tostring(height) .. ")")
        end

        local base = address + 8
        gfx.blit(x, y, width, height, function(index)
            return context.read8(base + index * 3),
                context.read8(base + index * 3 + 1),
                context.read8(base + index * 3 + 2)
        end)
        return true
    end

    error("sys gfx does not know " .. verbName .. ", try clear, pixel, rect or present")
end

local function runInput(context)
    local input = context.input
    if not input then
        error("sys input needs the casm input module")
    end

    local args = context.args or {}
    local verb = args[1]
    if not verb then
        error("sys input needs a mode, for example sys input down_listener key_w f1")
    end

    if verb.kind == "register" then
        local value = table.remove(sbus.inputQueue, 1)
        if value == nil then
            value = 0
        end
        context.setRegister(verb.register, value)
        return true
    end

    if verb.kind ~= "keyword" then
        error("sys input needs a mode first, such as down_listener, read, poll or wait, got " .. describe(verb))
    end

    local verbName = verb.name or ""
    local listenerMode = verbName:match("^(%a+)_listener$")

    if listenerMode and inputModes[listenerMode] then
        local loveKey = loveKeyOf(args[2])
        if not loveKey then
            error("sys input " .. verbName .. " needs a key name, got " .. describe(args[2]))
        end

        if listenerMode == "call" then
            local target = args[3]
            if not target or target.kind ~= "value" then
                error("sys input call_listener needs a label, got " .. describe(args[3]))
            end
            input.listen("call", loveKey, { symbolId = target.value })
            return true
        end

        local target = targetOf(args[3])
        if not target then
            error("sys input " .. verbName .. " needs a flag or register, got " .. describe(args[3]))
        end
        input.listen(listenerMode, loveKey, target)
        return true
    end

    if verbName == "kill" then
        local id = args[2]
        if not id then
            error("sys input kill needs a listener id")
        end
        return input.kill(id.value)
    end

    if verbName == "kill_all" then
        input.killAll(context.cpu.pid)
        return true
    end

    if verbName == "kill_key" then
        local loveKey = loveKeyOf(args[2])
        if not loveKey then
            error("sys input kill_key needs a key name, got " .. describe(args[2]))
        end
        input.killKey(loveKey, context.cpu.pid)
        return true
    end

    if verbName == "read" then
        local loveKey = loveKeyOf(args[2])
        local target = targetOf(args[3])
        if not loveKey or not target then
            error("sys input read needs a key and a flag or register")
        end
        input.setTarget(target, input.get(loveKey) and 1 or 0)
        return true
    end

    if verbName == "poll" then
        local target = targetOf(args[2])
        if not target then
            error("sys input poll needs a flag or register, got " .. describe(args[2]))
        end
        local event = input.poll()
        if not event then
            input.setTarget(target, 0)
            context.setFlag("Z", true)
            return true
        end
        input.setTarget(target, event.down and 1 or 0)
        context.setFlag("Z", false)
        return true
    end

    if verbName == "wait" then
        local loveKey = loveKeyOf(args[2])
        if not loveKey then
            error("sys input wait needs a key name, got " .. describe(args[2]))
        end
        input.waitFor(context.cpu.pid, loveKey)
        context.park()
        return true
    end

    if verbName == "last" then
        local id = args[2]
        if not id or id.kind ~= "register" then
            error("sys input last needs a register, got " .. describe(args[2]))
        end
        context.setRegister(id.register, input.lastId)
        return true
    end

    if verbName == "clear" then
        input.clear()
        return true
    end

    error("unknown sys input mode: " .. verbName)
end

function sbus.run(context)
    if context.call == sbus.calls.print then
        print(context.value)
        return true
    end

    if context.call == sbus.calls.input then
        return runInput(context)
    end

    if context.call == sbus.calls.gfx then
        return runGfx(context)
    end

    if context.call == sbus.calls.data then
        return runData(context)
    end

    if context.call == sbus.calls.alloc then
        return runAlloc(context)
    end

    if context.call == sbus.calls.rand then
        return runRand(context)
    end

    if context.call == sbus.calls.rand_seed then
        return runRandSeed(context)
    end

    return nil
end

return sbus
