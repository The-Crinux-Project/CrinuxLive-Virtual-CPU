local loadChunk = loadstring or load

local function loadModule(name)
    if not (love and love.filesystem and love.filesystem.read) then
        return nil
    end
    local source, err = love.filesystem.read(name)
    if not source then
        print("main: could not read " .. name .. (err and (" (" .. tostring(err) .. ")") or ""))
        return nil
    end
    local chunk, loadErr = loadChunk(source, "@" .. name)
    if not chunk then
        print("main: syntax error in " .. name .. ": " .. tostring(loadErr))
        return nil
    end
    local ok, mod = pcall(chunk)
    if not ok then
        print("main: error while loading " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local bus = loadModule("sbus.lua")
local assembler = loadModule("assembler.lua")
local cpu = loadModule("cpu.lua")

if not assembler or not cpu then
    print("main: missing assembler.lua or cpu.lua")
    return
end

assembler.setBus(bus)
cpu.setBus(bus)

local assemble = assembler.assemble

cpu.boot()

local prg1 = assemble("main.casm")
if prg1 then
    local pid = cpu.exec(prg1)
end

casm = {
    assemble = assemble,
    assembleFile = assembler.assembleFile,
    size = assembler.size,

    cpu = cpu,
    exec = cpu.exec,
    load = function(image)
        return cpu.exec(image)
    end,
    step = cpu.step,
    run = cpu.run,
    setClock = cpu.setClock,
    setSwitchLimit = cpu.setSwitchLimit,
    reset = cpu.reset,

    input = cpu.input,
    graphics = cpu.graphics,
    memory = cpu.memory,

    build = assemble,
    loadFile = function(filename)
        local image = assemble(filename)
        if not image then return nil end
        return cpu.exec(image)
    end,
}
casm.loadCasm = casm.loadFile
