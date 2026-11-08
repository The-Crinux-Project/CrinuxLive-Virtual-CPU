local loadChunk = loadstring or load
local busFile = "sbus.lua"
local inputDriverFile = "live_inputdriver.lua"
local graphicsDriverFile = "live_graphicsdriver.lua"

local function loadModule(name)
    if not (love and love.filesystem and love.filesystem.read) then
        return nil
    end
    local source, err = love.filesystem.read(name)
    if not source then
        print("cpu: could not read " .. name .. (err and (" (" .. tostring(err) .. ")") or ""))
        return nil
    end
    local chunk, loadErr = loadChunk(source, "@" .. name)
    if not chunk then
        print("cpu: syntax error in " .. name .. ": " .. tostring(loadErr))
        return nil
    end
    local ok, mod = pcall(chunk)
    if not ok then
        print("cpu: error while loading " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local sysBus

local M = {}

function M.setBus(bus)
    sysBus = bus
    return M
end

local function bus()
    if not sysBus then
        sysBus = loadModule(busFile)
    end
    return sysBus
end

local cpu = {
    reg = {
      r1=0,
      r2=0,
      r3=0,
      r4=0,
      r5=0,
      r6=0,
      r7=0,
      r8=0,
      r9=0,
      r10=0,
      r11=0,
      r12=0,
      r13=0,
      r14=0,
      r15=0,
      r16=0,
    },
    pc = 1,
    sp = 1,
    halted = false,
    waitUntil = 0,
    stopSlice = false,
    pid = 0,
    running = false,
    sysArgCount = 0,
    flags={
        ["Z"]=0,
        ["O"]=0,
        N=0,
        f1=0,
        f2=0,
        f3=0,
        f4=0,
        f5=0,
        f6=0,
        f7=0,
        f8=0,
    }
}

local function cpuError(message)
    print("cpu error: " .. message)
    cpu.halted = true
end

local memory = {
    totalSize = 65536,
    bytes = {},
    schedSize = 8192,
    stackSize = 16384,
    programSize = 24576,
    heapSize = 16384,

    reProgramSize = 24576
}

local schedBase = 0
local stackBase = schedBase + memory.schedSize
local programBase = stackBase + memory.stackSize
local heapSize = programBase + memory.programSize

memory.schedBase = schedBase
memory.stackBase = stackBase
memory.programBase = programBase
memory.heapBase = heapSize
memory.heapEnd = memory.totalSize - 1
memory.maxProcs = math.floor(memory.schedSize / 128)

local UINT32_MAX = 4294967295

local PROGRAM_BASE = programBase

local maxInt = 2147483647
local minInt = -2147483648
local intRadix = 4294967296

local function updateFlags(exactValue)
    local value = exactValue
    local overflow = 0
    if exactValue > maxInt or exactValue < minInt then
        value = exactValue % intRadix
        if value > maxInt then
            value = value - intRadix
        end
        overflow = 1
    end

    cpu.flags["Z"] = (value == 0) and 1 or 0
    cpu.flags["N"] = (value < 0) and 1 or 0
    cpu.flags["O"] = overflow
    return value
end

local function checkAddress(address, size)
    if type(address) ~= "number" or address % 1 ~= 0 then
        raise("address must be an integer")
    end
    if address < 0 or address + size > memory.totalSize then
        raise("address out of bounds")
    end
end

local function read8(address)
    checkAddress(address, 1)
    return memory.bytes[address + 1] or 0
end

local function write8(address, value)
    checkAddress(address, 1)
    if type(value) ~= "number" or value % 1 ~= 0 then
        raise("byte must be a whole number, got " .. tostring(value))
    end
    memory.bytes[address + 1] = value % 256
end

local function read32(address)
    checkAddress(address, 4)
    local value = read8(address) + read8(address + 1) * 256 + read8(address + 2) * 65536 + read8(address + 3) * 16777216
    if value > 2147483647 then
        value = value - 4294967296
    end
    return value
end

local function write32(address, value)
    if type(value) ~= "number" or value % 1 ~= 0 or value < -2147483648 or value > UINT32_MAX then
        raise("32-bit value out of range")
    end
    if value < 0 then
        value = value + 4294967296
    end
    checkAddress(address, 4)
    for i = 0, 3 do
        write8(address + i, value % 256)
        value = math.floor(value / 256)
    end
end

local programStart = 0
local programCount = 0
local reProgramSizeAtBoot

local function hexDigits(token)
    local digits = token:gsub("^0[xX]", "")
    if #digits % 2 == 1 then
        digits = "0" .. digits
    end
    return digits
end

local function programBytes(text)
    local count = 0
    for token in text:gmatch("%S+") do
        count = count + #hexDigits(token) / 2
    end
    return math.floor(count)
end

local function imageTokens(text)
    local bytes = {}
    for token in tostring(text):gmatch("%S+") do
        local digits = hexDigits(token)
        for i = 1, #digits, 2 do
            bytes[#bytes + 1] = tonumber(digits:sub(i, i + 1), 16)
        end
    end
    return bytes
end

local function writeProgram(text, at)
    local offset = at
    for token in text:gmatch("%S+") do
        local digits = hexDigits(token)
        for i = 1, #digits, 2 do
            write8(programBase + offset, tonumber(digits:sub(i, i + 1), 16))
            offset = offset + 1
        end
    end
    return offset - at
end

local function programByte(address)
    return read8(programBase + address)
end

local function dumpProgram(from, to)
    local out = {}
    for address = from, to do
        out[#out + 1] = string.format("%02X", programByte(address))
    end
    return table.concat(out, " ")
end

local instructionSize = {
    [1] = 4, [2] = 4, [3] = 4, [4] = 4, [5] = 4, [6] = 4, [7] = 4,
    [8] = 4, [9] = 4, [0x0A] = 4, [0x0B] = 4, [0x0C] = 4, [0x0D] = 4,
    [0x0E] = 4, [0x0F] = 4, [0x10] = 4, [0x11] = 4, [0x14] = 4, [0x17] = 4,
    [0x13] = 4, [0x15] = 4,
}

local function walkProgram(from, to)
    local address = from or programStart
    local stop = to or (programStart + programCount - 1)
    local out = {}
    while address + 3 <= stop do
        out[#out + 1] = string.format("%04X  %s", address, dumpProgram(address, address + 3))
        address = address + 4
    end
    return out
end

local PROC_SLOT = 128

local DATA_ADDR_SLOT = 122
local DATA_LEN_SLOT = 126

local heapBlocks = {}

local function heapReset()
    heapBlocks = {}
    return true
end

local function heapAllocate(size, owner)
    if type(size) ~= "number" or size ~= math.floor(size) or size <= 0 then
        return nil
    end

    local at = memory.heapBase
    for i = 1, #heapBlocks do
        local block = heapBlocks[i]
        if block.address >= at + size then
            break
        end
        at = block.address + block.size
    end

    if at + size - 1 > memory.heapEnd then
        return nil
    end

    local entry = { address = at, size = size, owner = owner }
    local index = #heapBlocks + 1
    for i = 1, #heapBlocks do
        if heapBlocks[i].address > at then
            index = i
            break
        end
    end
    table.insert(heapBlocks, index, entry)
    return at
end

local function heapFree(owner)
    local kept = {}
    local freed = 0
    for i = 1, #heapBlocks do
        local block = heapBlocks[i]
        if block.owner == owner then
            freed = freed + block.size
        else
            kept[#kept + 1] = block
        end
    end
    heapBlocks = kept
    return freed
end

local function heapUsed()
    local used = 0
    for i = 1, #heapBlocks do
        used = used + heapBlocks[i].size
    end
    return used
end

local maxProcs = math.floor(memory.schedSize / PROC_SLOT)
local stackBytesPerProc = math.floor(memory.stackSize / maxProcs)

local function stackBaseFor(id)
    return stackBase + id * stackBytesPerProc
end

local function heapCheck(address, size)
    if type(address) ~= "number" or address % 1 ~= 0 then
        cpuError("address must be an integer, got " .. tostring(address))
        return false
    end
    if address < memory.heapBase or address + size - 1 > memory.heapEnd then
        cpuError("address " .. address .. " is outside the heap (" .. memory.heapBase .. "-" .. memory.heapEnd .. ")")
        return false
    end
    return true
end

local function procBase(id)
    if type(id) ~= "number" or id % 1 ~= 0 or id < 0 or id >= maxProcs then
        return nil
    end
    return schedBase + id * PROC_SLOT
end

local function saveProc(id)
    local base = procBase(id)
    if not base then
        return false
    end

    write8(base, 1)
    write8(base + 1, id)
    write32(base + 4, cpu.pc)
    write32(base + 8, cpu.sp)
    write8(base + 12, cpu.halted and 1 or 0)
    write32(base + 116, math.floor(cpu.waitUntil or 0))

    for i = 1, 16 do
        write32(base + 16 + (i - 1) * 4, cpu.reg["r" .. i] or 0)
    end

    write8(base + 80, cpu.flags["Z"] or 0)
    write8(base + 81, cpu.flags.N or 0)
    write8(base + 91, cpu.flags["O"] or 0)
    for i = 1, 8 do
        write8(base + 81 + i, cpu.flags["f" .. i] or 0)
    end

    return true
end

local function loadProc(id)
    local base = procBase(id)
    if not base or read8(base) ~= 1 then
        cpuError("no such process: " .. tostring(id))
        return false
    end

    cpu.pid = id
    cpu.pc = read32(base + 4)
    cpu.sp = read32(base + 8)
    cpu.halted = read8(base + 12) == 1
    cpu.waitUntil = read32(base + 116)

    for i = 1, 16 do
        cpu.reg["r" .. i] = read32(base + 16 + (i - 1) * 4)
    end

    cpu.flags["Z"] = read8(base + 80)
    cpu.flags.N = read8(base + 81)
    cpu.flags["O"] = read8(base + 91)
    for i = 1, 8 do
        cpu.flags["f" .. i] = read8(base + 81 + i)
    end

    return true
end

local function newProc()
    for id = 0, maxProcs - 1 do
        local base = schedBase + id * PROC_SLOT
        if read8(base) == 0 then
            for offset = 0, PROC_SLOT - 1 do
                write8(base + offset, 0)
            end
            write8(base, 1)
            write8(base + 1, id)
            write32(base + 4, programStart)
            write32(base + 8, 0)
            write32(base + 116, 0)
            write8(base + 120, 0)
            write8(base + 121, 0)
            write32(base + 108, programStart)
            write32(base + 112, programCount)
            write32(base + DATA_ADDR_SLOT, 0)
            write8(base + DATA_LEN_SLOT, 0)
            write8(base + DATA_LEN_SLOT + 1, 0)
            return id
        end
    end

    cpuError("scheduler is full")
    return nil
end

local function killProc(id)
    local base = procBase(id)
    if not base then
        return false
    end

    for offset = 0, PROC_SLOT - 1 do
        write8(base + offset, 0)
    end

    heapFree(id)
    return true
end

local function procStart(id)
    local base = procBase(id)
    if not base then
        return nil
    end
    return read32(base + 108)
end

local function setProcData(id, address, length)
    local base = procBase(id)
    if not base then
        return false
    end
    write32(base + DATA_ADDR_SLOT, address)
    write8(base + DATA_LEN_SLOT, math.floor(length / 256) % 256)
    write8(base + DATA_LEN_SLOT + 1, length % 256)
    return true
end

local function procData(id)
    local base = procBase(id)
    if not base or read8(base) ~= 1 then
        return 0, 0
    end
    return read32(base + DATA_ADDR_SLOT),
        read8(base + DATA_LEN_SLOT) * 256 + read8(base + DATA_LEN_SLOT + 1)
end

local startProc

local function placeProgram(image)
    local bytes = imageTokens(image)
    local total = #bytes
    if total < 4 then
        cpuError("program image is too short: no header")
        return nil
    end

    local codeLength = bytes[1] + bytes[2] * 256
    local dataLength = bytes[3] + bytes[4] * 256
    if codeLength + dataLength + 4 > total then
        cpuError("program image is truncated: header says " .. (codeLength + dataLength + 4) .. " bytes, got " .. total)
        return nil
    end
    if codeLength % 4 ~= 0 then
        cpuError("program code is not a whole number of instructions (" .. codeLength .. " bytes)")
        return nil
    end
    if codeLength > memory.reProgramSize then
        cpuError("not enough program memory left for another program")
        return nil
    end

    programStart = memory.programSize - memory.reProgramSize
    for i = 1, codeLength do
        write8(programBase + programStart + i - 1, bytes[4 + i])
    end
    programCount = codeLength
    memory.reProgramSize = memory.reProgramSize - codeLength

    local id = newProc()
    if not id then
        memory.reProgramSize = memory.reProgramSize + codeLength
        return nil
    end

    local dataAddress = 0
    if dataLength > 0 then
        dataAddress = heapAllocate(dataLength, id)
        if not dataAddress then
            killProc(id)
            memory.reProgramSize = memory.reProgramSize + codeLength
            cpuError("no heap left for " .. dataLength .. " bytes of program data (" .. heapUsed() .. " of " ..
                (memory.heapEnd - memory.heapBase + 1) .. " in use)")
            return nil
        end
        for i = 1, dataLength do
            write8(dataAddress + i - 1, bytes[4 + codeLength + i])
        end
    end
    setProcData(id, dataAddress, dataLength)

    print("program at " .. programStart .. " (" .. codeLength .. " bytes)" ..
        (dataLength > 0 and (", data at " .. dataAddress .. " (" .. dataLength .. " bytes)") or ""))

    return id
end

local function execProgram(bytes)
    if type(bytes) ~= "string" then
        return nil
    end
    return startProc(placeProgram(bytes))
end

local instructionLimit = 100000
local cpuSymbols = {}

local schedulerClock = function()

    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function operandValue(byte)
    if byte >= 0x80 then
        return byte - 0x80
    end
    return cpu.reg["r" .. byte] or 0
end

local function scanSymbols(from, size)
    local found = {}
    local at = from
    while at < from + size do
        if read8(PROGRAM_BASE + at) == 0x15 then
            found[read8(PROGRAM_BASE + at + 1)] = at + 4
        end
        at = at + 4
    end
    return found
end

local sysArgBuffer = {}
local decodeSysArg
local input
local graphics

local opcodes = {}

opcodes[0x01] = function(register, value)
    cpu.reg["r" .. register] = value
end

opcodes[0x02] = function(destination, left, right)
    cpu.reg["r" .. destination] = updateFlags(operandValue(left) + operandValue(right))
end

opcodes[0x07] = function(id)
    local at = cpuSymbols[id]
    if not at then
        cpuError("no such label: " .. id)
        return
    end
    cpu.pc = at
end

opcodes[0x12] = function(call, operand, argCount)
    if not sysBus then
        cpuError("no system bus loaded, expected " .. busFile)
        return
    end

    local callName = nil
    for busName, busOpcode in pairs(sysBus.calls) do
        if busOpcode == call then
            callName = busName
            break
        end
    end

    if not callName then
        cpuError("unknown syscall: " .. call)
        return
    end

    local pid = cpu.pid or 0
    local buffered = sysArgBuffer[pid] or {}
    local rawArgs = {}
    if operand ~= 0 then
        rawArgs[1] = operand
    end
    for i = 1, #buffered do
        rawArgs[#rawArgs + 1] = buffered[i]
    end
    sysArgBuffer[pid] = {}

    local args = {}
    for i = 1, #rawArgs do
        args[i] = decodeSysArg(rawArgs[i])
    end

    local dataAddress, dataLength = procData(pid)

    local context = {
        call = call,
        name = callName,
        dataAddress = dataAddress,
        dataLength = dataLength,
        args = args,
        argCount = #args,
        first = args[1],
        second = args[2],
        third = args[3],
        operand = (args[1] and args[1].encoded) or operand,
        value = (args[1] and args[1].value) or operandValue(operand),
        input = input,
        gfx = graphics,
        cpu = cpu,
        bus = sysBus,
        read8 = read8,
        read32 = read32,
        write8 = write8,
        write32 = write32,
        getRegister = function(register) return cpu.reg["r" .. register] or 0 end,
        setRegister = function(register, value) cpu.reg["r" .. register] = value end,
        getFlag = function(flagName) return cpu.flags[flagName] or 0 end,
        setFlag = function(flagName, on) cpu.flags[flagName] = on and 1 or 0 end,
        symbolAddress = function(id) return cpuSymbols[id] end,
        stopProcess = function() cpu.halted = true end,
        allocate = function(size) return heapAllocate(size, pid) end,
        free = function() return heapFree(pid) end,
        park = function() cpu.stopSlice = true end,
    }

    local ok, result = pcall(sysBus.run, context)
    if not ok then
        cpuError("sbus error in sys " .. callName .. ": " .. tostring(result))
        return
    end

    if result == nil then
        cpuError("sbus did not handle syscall: " .. callName)
    elseif result == false then
        cpuError("syscall failed: " .. callName)
    end
end

opcodes[0x03] = function(destination, left, right)
    cpu.reg["r" .. destination] = updateFlags(operandValue(left) - operandValue(right))
end

opcodes[0x04] = function(left, right)
    local result = operandValue(left) - operandValue(right)
    updateFlags(result)
    cpu.flags.N = (operandValue(left) < operandValue(right)) and 1 or 0
end

local function flagKey(byte)
    if byte == 0 then return "Z" end
    if byte == 9 then return "N" end
    if byte == 10 then return "O" end
    return "f" .. byte
end

decodeSysArg = function(encoded)
    local arg = { encoded = encoded, kind = "value", value = 0 }
    if encoded >= 1 and encoded <= 16 then
        arg.kind = "register"
        arg.register = encoded
        arg.value = cpu.reg["r" .. encoded] or 0
    elseif encoded >= 17 and encoded <= 99 then
        arg.kind = "keyword"
        arg.index = encoded - 16
        arg.name = (sysBus and sysBus.keywordNames and sysBus.keywordNames[arg.index]) or nil
        arg.value = arg.index
    elseif encoded >= 100 and encoded <= 115 then
        arg.kind = "flag"
        arg.flagByte = encoded - 100
        arg.name = flagKey(arg.flagByte)
        arg.value = cpu.flags[arg.name] or 0
    elseif encoded >= 128 and encoded <= 255 then
        arg.value = encoded - 128
    end
    return arg
end

local function jumpTo(id)
    local at = cpuSymbols[id]
    if not at then
        cpuError("no such label: " .. tostring(id))
        return
    end
    cpu.pc = at
end

opcodes[0x08] = function(flag, id)
    if (cpu.flags[flagKey(flag)] or 0) ~= 0 then
        jumpTo(id)
    end
end

opcodes[0x09] = function(flag, id)
    if (cpu.flags[flagKey(flag)] or 0) == 0 then
        jumpTo(id)
    end
end

opcodes[0x14] = function(register, high, low)
    cpu.reg["r" .. register] = high * 256 + low
end

opcodes[0x0E] = function(operand)
    local base = stackBaseFor(cpu.pid)
    if cpu.sp + 4 > stackBytesPerProc then
        cpuError("stack overflow in process " .. cpu.pid .. " (max " .. stackBytesPerProc .. " bytes)")
        return
    end
    write32(base + cpu.sp, operandValue(operand))
    cpu.sp = cpu.sp + 4
end

opcodes[0x0F] = function(register)
    if cpu.sp <= 0 then
        cpuError("stack underflow in process " .. cpu.pid)
        return
    end
    cpu.sp = cpu.sp - 4
    cpu.reg["r" .. register] = read32(stackBaseFor(cpu.pid) + cpu.sp)
end

opcodes[0x0D] = function(operand)
    local ms = operandValue(operand)
    if ms <= 0 then
        cpu.stopSlice = true
    else
        cpu.waitUntil = math.floor(schedulerClock() * 1000) + ms
    end
end

opcodes[0x0C] = function(flag, state)
    cpu.flags[flagKey(flag)] = (state ~= 0) and 1 or 0
end

opcodes[0x10] = function(id)
    local base = stackBaseFor(cpu.pid)
    if cpu.sp + 4 > stackBytesPerProc then
        cpuError("stack overflow in process " .. cpu.pid .. " on call (max " ..
            stackBytesPerProc .. " bytes)")
        return
    end
    write32(base + cpu.sp, cpu.pc)
    cpu.sp = cpu.sp + 4
    jumpTo(id)
end

opcodes[0x11] = function()
    if cpu.sp <= 0 then
        cpuError("ret with an empty stack in process " .. cpu.pid)
        return
    end
    cpu.sp = cpu.sp - 4
    cpu.pc = read32(stackBaseFor(cpu.pid) + cpu.sp)
end

local function ramRead(fn, address, register, size)
    if not heapCheck(address, size) then
        return
    end
    local ok, value = pcall(fn, address)
    if not ok then
        cpuError(tostring(value))
        return
    end
    cpu.reg["r" .. register] = value
end

local function ramWrite(fn, address, value, size)
    if not heapCheck(address, size) then
        return
    end
    local ok, err = pcall(fn, address, value)
    if not ok then
        cpuError(tostring(err))
    end
end

opcodes[0x05] = function(address, register)
    ramRead(read32, operandValue(address), register, 4)
end

opcodes[0x06] = function(address, register)
    ramWrite(write32, operandValue(address), cpu.reg["r" .. register] or 0, 4)
end

opcodes[0x0A] = function(address, register)
    ramRead(read8, operandValue(address), register, 1)
end

opcodes[0x0B] = function(address, register)
    ramWrite(write8, operandValue(address), cpu.reg["r" .. register] or 0, 1)
end

opcodes[0x15] = function()
end

opcodes[0x17] = function(encoded)
    local pid = cpu.pid or 0
    sysArgBuffer[pid] = sysArgBuffer[pid] or {}
    sysArgBuffer[pid][#sysArgBuffer[pid] + 1] = encoded
end

opcodes[0x13] = function()
    cpu.halted = true
end

input = {
    keys = {},
    listeners = {},
    nextId = 1,
    lastId = 0,
    events = {},
    waiters = {},
    pendingCalls = {},
    droppedCalls = 0,
}

local function flagSlotOffset(flagByte)
    if flagByte == 0 then return 80 end
    if flagByte == 9 then return 81 end
    if flagByte == 10 then return 91 end
    return 81 + flagByte
end

local function setFlagForProc(pid, flagByte, on)
    local value = on and 1 or 0
    if cpu.running and (cpu.pid or 0) == pid then
        cpu.flags[flagKey(flagByte)] = value
        return
    end
    local base = procBase(pid)
    if base and read8(base) == 1 then
        write8(base + flagSlotOffset(flagByte), value)
    end
end

local function getFlagForProc(pid, flagByte)
    if cpu.running and (cpu.pid or 0) == pid then
        return cpu.flags[flagKey(flagByte)] or 0
    end
    local base = procBase(pid)
    if base and read8(base) == 1 then
        return read8(base + flagSlotOffset(flagByte))
    end
    return 0
end

local function getRegisterForProc(pid, register)
    if cpu.running and (cpu.pid or 0) == pid then
        return cpu.reg["r" .. register] or 0
    end
    local base = procBase(pid)
    if base and read8(base) == 1 then
        return read32(base + 16 + (register - 1) * 4)
    end
    return 0
end

local function setRegisterForProc(pid, register, value)
    if cpu.running and (cpu.pid or 0) == pid then
        cpu.reg["r" .. register] = value
        return
    end
    local base = procBase(pid)
    if base and read8(base) == 1 then
        write32(base + 16 + (register - 1) * 4, value)
    end
end

local function writeTarget(target, ownerPid, value)
    if not target then
        return
    end
    if target.targetKind == "flag" then
        setFlagForProc(ownerPid, target.flagByte, value ~= 0)
    elseif target.targetKind == "register" then
        setRegisterForProc(ownerPid, target.register, value)
    elseif target.targetKind == "function" then
        target.fn(value)
    end
end

local function readTarget(target, ownerPid)
    if not target then
        return 0
    end
    if target.targetKind == "flag" then
        return getFlagForProc(ownerPid, target.flagByte)
    elseif target.targetKind == "register" then
        return getRegisterForProc(ownerPid, target.register)
    end
    return 0
end

local function fire(loveKey, down)
    if #input.events >= 256 then
        table.remove(input.events, 1)
        input.droppedEvents = (input.droppedEvents or 0) + 1
    end
    input.events[#input.events + 1] = { key = loveKey, down = down }

    local finished = nil
    for id, listener in pairs(input.listeners) do
        if listener.key == loveKey then
            local mode = listener.mode
            if mode == "down" then
                writeTarget(listener, listener.ownerPid, down and 1 or 0)
            elseif mode == "up" then
                writeTarget(listener, listener.ownerPid, down and 0 or 1)
            elseif mode == "press" and down then
                writeTarget(listener, listener.ownerPid, 1)
            elseif mode == "release" and not down then
                writeTarget(listener, listener.ownerPid, 1)
            elseif mode == "count" and down then
                writeTarget(listener, listener.ownerPid, readTarget(listener, listener.ownerPid) + 1)
            elseif mode == "call" and down then
                input.pendingCalls[listener.ownerPid] = listener.symbolId
            end

            if listener.once then
                finished = finished or {}
                finished[#finished + 1] = id
            end
        end
    end

    if finished then
        for i = 1, #finished do
            input.listeners[finished[i]] = nil
        end
    end

    for pid, waitingKey in pairs(input.waiters) do
        if waitingKey == loveKey then
            input.waiters[pid] = nil
        end
    end
end

function input.set(loveKey, down)
    down = down and true or false
    if input.keys[loveKey] == down then
        return
    end
    input.keys[loveKey] = down
    fire(loveKey, down)
end

function input.get(loveKey)
    return input.keys[loveKey] == true
end

function input.press(loveKey)
    input.set(loveKey, true)
end

function input.release(loveKey)
    input.set(loveKey, false)
end

function input.clear()
    local held = {}
    for key, down in pairs(input.keys) do
        if down then held[#held + 1] = key end
    end
    for i = 1, #held do
        input.set(held[i], false)
    end
    input.events = {}
end

function input.listen(mode, loveKey, target, once)
    local id = input.nextId
    input.nextId = id + 1
    input.lastId = id

    local listener = {
        id = id,
        mode = mode,
        key = loveKey,
        ownerPid = cpu.pid or 0,
        once = once,
    }
    if target then
        for key, value in pairs(target) do
            listener[key] = value
        end
    end

    input.listeners[id] = listener

    if mode == "down" then
        writeTarget(listener, listener.ownerPid, input.get(loveKey) and 1 or 0)
    elseif mode == "up" then
        writeTarget(listener, listener.ownerPid, input.get(loveKey) and 0 or 1)
    end

    return id
end

function input.kill(id)
    if input.listeners[id] then
        input.listeners[id] = nil
        return true
    end
    return false
end

function input.killAll(pid)
    local count = 0
    for id, listener in pairs(input.listeners) do
        if pid == nil or listener.ownerPid == pid then
            input.listeners[id] = nil
            count = count + 1
        end
    end
    return count
end

function input.killKey(loveKey, pid)
    local count = 0
    for id, listener in pairs(input.listeners) do
        if listener.key == loveKey and (pid == nil or listener.ownerPid == pid) then
            input.listeners[id] = nil
            count = count + 1
        end
    end
    return count
end

function input.poll()
    return table.remove(input.events, 1)
end

function input.waitFor(pid, loveKey)
    input.waiters[pid] = loveKey
end

function input.isWaiting(pid)
    return input.waiters[pid] ~= nil
end

function input.takePendingCall(pid)
    local symbolId = input.pendingCalls[pid]
    input.pendingCalls[pid] = nil
    return symbolId
end

function input.setTarget(target, value)
    writeTarget(target, cpu.pid or 0, value)
end

function input.getTarget(target)
    return readTarget(target, cpu.pid or 0)
end

function input.countListeners(pid)
    local count = 0
    for _, listener in pairs(input.listeners) do
        if pid == nil or listener.ownerPid == pid then
            count = count + 1
        end
    end
    return count
end

local function loadDriver(filename)
    if not (love and love.filesystem and love.filesystem.read) then
        return nil
    end
    local source, err = love.filesystem.read(filename)
    if not source then
        print("driver: could not read " .. filename .. (err and (" (" .. tostring(err) .. ")") or ""))
        return nil
    end
    local chunk, loadErr = loadChunk(source, "@" .. filename)
    if not chunk then
        print("driver: syntax error in " .. filename .. ": " .. tostring(loadErr))
        return nil
    end
    local ok, driver = pcall(chunk, filename)
    if not ok then
        print("driver: error while loading " .. filename .. ": " .. tostring(driver))
        return nil
    end
    if type(driver) ~= "table" then
        print("driver: " .. filename .. " must return a table")
        return nil
    end
    return driver
end

local scheduler = {
    procs = {},
    loadQueue = {},
    running = false,
    switches = 0,
    switchLimit = nil,
    reaped = 0,
}

startProc = function(pid)
    if not pid then
        return nil
    end
    for i = 1, #scheduler.procs do
        if scheduler.procs[i] == pid then
            return pid
        end
    end
    scheduler.procs[#scheduler.procs + 1] = pid
    return pid
end

local function schedulerSetClock(clockFn)
    schedulerClock = clockFn or function() return os.clock() end
end

local function procState(id)
    local base = procBase(id)
    if not base then
        return "dead"
    end
    if read8(base) ~= 1 or read8(base + 12) == 1 then
        return "dead"
    end
    local waitUntil = read32(base + 116)
    if waitUntil ~= 0 and math.floor(schedulerClock() * 1000) < waitUntil then
        return "waiting"
    end
    if input.isWaiting(id) then
        return "waiting"
    end
    return "ready"
end

local schedulerIdle = function()
    if love and love.timer and love.timer.sleep then
        love.timer.sleep(0.001)
    end
end

local function schedulerSetIdle(idleFn)
    schedulerIdle = idleFn or function()
        if love and love.timer and love.timer.sleep then
            love.timer.sleep(0.001)
        end
    end
end

local function runProcSlice(id, sliceSeconds)
    if not loadProc(id) then
        return false
    end
    if cpu.halted then
        return false
    end

    cpu.waitUntil = 0
    cpu.stopSlice = false
    cpu.running = true

    local base = procBase(id)
    cpuSymbols = scanSymbols(read32(base + 108), read32(base + 112))

    local pendingSymbol = input.takePendingCall(id)
    if pendingSymbol then
        local at = cpuSymbols[pendingSymbol]
        local stackBase = stackBaseFor(id)
        if at and cpu.sp + 4 <= stackBytesPerProc then
            write32(stackBase + cpu.sp, cpu.pc)
            cpu.sp = cpu.sp + 4
            cpu.pc = at
        else
            input.droppedCalls = input.droppedCalls + 1
        end
    end

    local deadline = schedulerClock() + sliceSeconds
    local steps = 0

    while not cpu.halted do
        steps = steps + 1

        if steps > instructionLimit then
            cpuError("instruction limit reached in one time slice, possible infinite loop")
            break
        end

        local at = cpu.pc
        local handler = opcodes[read8(PROGRAM_BASE + at)]

        if not handler then
            cpuError("unknown opcode " .. read8(PROGRAM_BASE + at) .. " at " .. at)
            break
        end

        cpu.pc = at + 4
        handler(read8(PROGRAM_BASE + at + 1), read8(PROGRAM_BASE + at + 2), read8(PROGRAM_BASE + at + 3))
        if cpu.waitUntil > 0 or cpu.stopSlice then
            break
        end

        if steps % 16 == 0 and schedulerClock() >= deadline then
            break
        end
    end

    cpu.running = false
    saveProc(id)
    return true
end

local function schedulerPass(sliceSeconds)
    while #scheduler.loadQueue > 0 do
        local image = table.remove(scheduler.loadQueue, 1)
        startProc(placeProgram(image))
    end

    local anyAlive = false
    local anyReady = false
    local index = 1

    while index <= #scheduler.procs do
        local id = scheduler.procs[index]
        local state = procState(id)
        if state == "dead" then

            table.remove(scheduler.procs, index)
            killProc(id)
            scheduler.reaped = scheduler.reaped + 1

        else
            anyAlive = true
            if state == "ready" then
                anyReady = true
                runProcSlice(id, sliceSeconds)
                scheduler.switches = scheduler.switches + 1
                if scheduler.switchLimit ~= nil and scheduler.switches >= scheduler.switchLimit then
                    break
                end
            end
            index = index + 1
        end
    end

    return anyAlive, anyReady
end

local function schedulerBegin()
    scheduler.running = true
    scheduler.active = true
    scheduler.switches = 0
end

local function schedulerCap()
    return scheduler.switchLimit ~= nil and scheduler.switches >= scheduler.switchLimit
end

local function schedulerStep(budgetSeconds)
    if not scheduler.running then
        schedulerBegin()
    end

    local procs = #scheduler.procs
    if procs < 1 then procs = 1 end
    local sliceSeconds = math.max(0.001, (budgetSeconds or 0.008) / procs)
    local deadline = schedulerClock() + (budgetSeconds or 0.008)
    local passes = 0

    while passes < 64 do
        passes = passes + 1
        local anyAlive, anyReady = schedulerPass(sliceSeconds)

        if schedulerCap() then
            print("scheduler: stopped after " .. scheduler.switches .. " switches")
            scheduler.running = false
            scheduler.active = false
            return false
        end

        if not anyAlive then
            scheduler.running = false
            scheduler.active = false
            return false
        end

        if not anyReady then
            return true
        end

        if schedulerClock() >= deadline then
            return true
        end
    end

    return true
end

local function schedulerRun()
    if scheduler.running then
        return
    end

    schedulerBegin()

    local anyAlive = true
    while anyAlive do
        anyAlive = schedulerStep(0.010)
        if anyAlive then
            schedulerIdle()
        end
    end
end

reProgramSizeAtBoot = memory.reProgramSize

M.cpu = cpu
M.memory = memory
M.input = input
M.graphics = graphics
M.scheduler = scheduler

M.exec = execProgram

function M.load(image)
    if type(image) ~= "string" or image == "" then
        return false
    end
    scheduler.loadQueue[#scheduler.loadQueue + 1] = image
    return true
end

function M.step(dt)
    return schedulerStep(dt or 0.008)
end

function M.run(options)
    if options then
        if options.clock then schedulerSetClock(options.clock) end
        if options.idle then schedulerSetIdle(options.idle) end
    end
    return schedulerRun()
end

M.setClock = schedulerSetClock
M.setIdle = schedulerSetIdle

function M.setSwitchLimit(count)
    if count ~= nil and (type(count) ~= "number" or count < 1) then
        return false
    end
    scheduler.switchLimit = count
    scheduler.switches = 0
    return true
end

function M.switches()
    return scheduler.switches
end

function M.procs()
    local out = {}
    for i = 1, #scheduler.procs do
        local id = scheduler.procs[i]
        local base = procBase(id)
        local dataAddress, dataLength = procData(id)
        out[i] = {
            pid = id,
            state = procState(id),
            data = dataAddress,
            dataLength = dataLength,
            pc = base and read32(base + 4) or 0,
            programStart = base and read32(base + 108) or 0,
            size = base and read32(base + 112) or 0,
        }
    end
    return out
end

function M.dump(from, to)
    return walkProgram(from, to)
end

function M.heap()
    local blocks = {}
    for i = 1, #heapBlocks do
        local b = heapBlocks[i]
        blocks[i] = { address = b.address, size = b.size, owner = b.owner }
    end
    return { used = heapUsed(), total = memory.heapEnd - memory.heapBase + 1,
        base = memory.heapBase, blocks = blocks }
end

function M.reset()
    memory.bytes = {}
    memory.reProgramSize = reProgramSizeAtBoot
    heapReset()
    programStart, programCount = 0, 0
    scheduler.procs = {}
    scheduler.loadQueue = {}
    scheduler.running = false
    scheduler.active = false
    scheduler.switches = 0
    cpu.pc = 1
    cpu.sp = 1
    cpu.halted = false
    cpu.running = false
    cpu.pid = 0
    cpu.waitUntil = 0
    cpu.stopSlice = false
    for i = 1, 16 do cpu.reg["r" .. i] = 0 end
    for name in pairs(cpu.flags) do cpu.flags[name] = 0 end
    sysArgBuffer = {}
    cpuSymbols = {}
    input.listeners = {}
    input.waiters = {}
    input.pendingCalls = {}
    input.events = {}
    input.keys = {}
    input.lastId = 0
    if graphics and graphics.reset then graphics.reset() end
    return true
end

M.reloadBus = function()
    sysBus = loadModule(busFile)
    return sysBus
end

function M.boot()
    bus()
    input.driver = input.driver or loadDriver(inputDriverFile)
    if input.driver and input.driver.attach and not input.driver.attached then
        input.driver.attach(input)
    end
    if not graphics then
        graphics = loadDriver(graphicsDriverFile)
        if graphics and graphics.attach then
            graphics.attach()
        end
        M.graphics = graphics
    end

    if love and not M.booted then
        local previousUpdate = love.update
        love.update = function(dt)
            if previousUpdate then
                previousUpdate(dt)
            end
            if scheduler.active or #scheduler.procs > 0 or #scheduler.loadQueue > 0 then
                schedulerStep(0.008)
            end
        end
        M.booted = true
    end
    return M
end

return M
