--casm assembler and vcpu. v10 last updated 11/4/26
local errors = {}

local function asmError(message, line)
    if line then
        message = "line " .. line .. ": " .. message
    end
    errors[#errors + 1] = message
end

local function raise(message)
    error(message, 0)
end


local loadChunk = loadstring or load   -- lua 5.1 (love) or 5.2+
local busFile = "sbus.lua"
local inputDriverFile = "live_inputdriver.lua"
local graphicsDriverFile = "live_graphicsdriver.lua"

local function loadSysBus()
    local source, err = love.filesystem.read(busFile)
    if not source then
        print("sbus: could not read " .. busFile .. (err and (" (" .. tostring(err) .. ")") or ""))
        return nil
    end
    local chunk, loadErr = loadChunk(source, "@" .. busFile)
    if not chunk then
        print("sbus: syntax error in " .. busFile .. ": " .. tostring(loadErr))
        return nil
    end
    local ok, bus = pcall(chunk)
    if not ok then
        print("sbus: error while loading " .. busFile .. ": " .. tostring(bus))
        return nil
    end
    if type(bus) ~= "table" or type(bus.run) ~= "function" then
        print("sbus: " .. busFile .. " must return a table with a run(context) function")
        return nil
    end
    if type(bus.calls) ~= "table" then
        print("sbus: " .. busFile .. " must define calls (name -> opcode)")
        return nil
    end
    if type(bus.keywords) == "table" then
        local names = {}
        for name, index in pairs(bus.keywords) do
            names[index] = name
        end
        bus.keywordNames = names
        bus.keywordCount = #names
    end

    return bus
end

local sysBus = loadSysBus()

local function syscallFor(name)
    if not sysBus then
        return nil
    end

    local callName = name
    local opcode = tonumber(name)
    if opcode then
        for busName, busOpcode in pairs(sysBus.calls) do
            if busOpcode == opcode then
                callName = busName
                break
            end
        end
        if not callName then
            return nil
        end
        local kind = (sysBus.argKinds and sysBus.argKinds[callName]) or "value"
        return { callName, opcode, kind }
    end

    local id = sysBus.calls[callName]
    if not id then
        return nil
    end
    local kind = (sysBus.argKinds and sysBus.argKinds[callName]) or "value"
    return { callName, id, kind }
end

local assembler = {
    ic = 1,
}

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
    pid = 0,
    running = false,
    callStack={},
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
    schedSize = 8192,   -- 8 KiB 12.5%
    stackSize = 16384,  -- 16 KiB 25%
    programSize = 24576, -- 24 KiB 37.5%
    heapSize = 16384,    -- 16 KiB 25%

    reProgramSize = 24576
}

local schedBase = 0
local stackBase = schedBase + memory.schedSize
local programBase = stackBase + memory.stackSize
local heapSize = programBase + memory.programSize

memory.schedBase = schedBase          -- 0      scheduler process slots, 128 bytes each
memory.stackBase = stackBase          -- 8192   stack
memory.programBase = programBase      -- 24576  program memory, 4 bytes per instruction
memory.heapBase = heapSize                    -- 49152  heap, use this for scratch data
memory.heapEnd = memory.totalSize - 1         -- 65535
memory.maxProcs = memory.schedSize / 128


local UINT32_MAX = 4294967295

local PROGRAM_BASE = programBase

local symbols = {}
local nextSymbol = 1

local function symbolIdFor(name, line)
    if not symbols[name] then
        if nextSymbol > 255 then
            asmError("too many symbols, the max is 255", line)
            return nil
        end

        symbols[name] = {
            id = nextSymbol,
            defined = false,
            line = line
        }
        nextSymbol = nextSymbol + 1
    end

    return symbols[name].id
end

--loader
local function loadCasm(filename)
    if type(filename) ~= "string" or not filename:match("^[%w_%-]+%.casm$") then
        asmError("invalid CASM filename: " .. tostring(filename))
        return nil
    end

    local source, err = love.filesystem.read(filename)
    if not source then
        asmError("could not load " .. filename .. (err and (": " .. tostring(err)) or ""))
        return nil
    end

    return source
end

local function regNumber(token, line)
    local number = type(token) == "string" and token:match("^[rR](%d+)$") or nil
    if not number then
        asmError("expected a register, got: " .. tostring(token), line)
        return nil
    end

    number = tonumber(number)
    if number < 1 or number > 16 then
        asmError("register out of range, use r1 to r16: " .. token, line)
        return nil
    end

    return number
end

local function flagByte(name, line)
    name = ({ z = "Z", n = "N", o = "O" })[name] or name
    if cpu.flags[name] == nil then
        asmError("invalid flag: " .. tostring(name) .. ", flags are Z, N, O and f1-f8", line)
        return nil
    end

    local number = 0
    if name == "N" then
        number = 9
    elseif name == "O" then
        number = 10
    elseif name ~= "Z" then
        number = tonumber(name:sub(2))
    end

    return string.format("%02X", number)
end

local maxSysArgs = 8

-- flags as numbers, matching flagByte's encoding
local function flagNumber(name)
    if name == "N" then
        return 9
    elseif name == "O" then
        return 10
    elseif name == "Z" then
        return 0
    end
    return tonumber(name:sub(2))
end

local function encodeSysArg(token, callName, line)
    if token:match("^[rR]%d+$") then
        return regNumber(token, line)
    end

    local number = tonumber(token)
    if number then
        if number % 1 ~= 0 or number < 0 or number > 127 then
            asmError("sys " .. callName .. " value arguments must be 0 to 127, got " .. token, line)
            return nil
        end
        return 0x80 + number
    end

    local flagName = ({ z = "Z", n = "N", o = "O" })[token] or token
    if cpu.flags[flagName] ~= nil then
        return 100 + flagNumber(flagName)
    end

    if sysBus and sysBus.keywords and sysBus.keywords[token] then
        local index = sysBus.keywords[token]
        if index < 1 or index > 83 then
            asmError("sbus keywords run out at 83, " .. token .. " is number " .. index, line)
            return nil
        end
        return 16 + index
    end

    local id = symbolIdFor(token, line)
    if id then
        if id > 127 then
            asmError("sys arguments can only reference the first 128 labels, " .. token .. " is " .. id, line)
            return nil
        end
        return 0x80 + id
    end

    return nil
end

local function arithOperand(token, line)
    if token:match("^[rR]%d+$") then
        local number = regNumber(token, line)
        if not number then
            return nil
        end
        return string.format("%X", number)
    end

    local number = tonumber(token)
    if not number or number % 1 ~= 0 or number < 0 or number > 127 then
        asmError("invalid value: " .. token .. ", a value here is 0 to 127", line)
        return nil
    end

    return string.format("%X", 0x80 + number)
end

local function operand(token, line)
    if type(token) ~= "string" then
        asmError("expected a value, got: " .. type(token), line)
        return nil
    end

    if token:match("^[rR]%d+$") then
        local number = regNumber(token, line)
        if not number then
            return nil
        end
        return string.format("%X", number)
    end

    local number = tonumber(token)
    if not number or number % 1 ~= 0 or number < 0 or number > 127 then
        if cpu.flags[token] ~= nil or ({ z = 1, n = 1, o = 1 })[token] ~= nil then
            asmError("cmp and arithmetic take registers and values, not flags; use jf or jnf to test a flag: " .. token, line)
        else
            asmError("a literal operand here must be 0 to 127 (one byte); load larger values into a register first: " .. token, line)
        end
        return nil
    end

    return string.format("0x%X", 0x80 + number)
end

--helper functions
local function getValue(value)
    if type(value) ~= "string" then
        raise("expected a string, got " .. type(value))
    end

    if cpu.reg[value] ~= nil then
        return cpu.reg[value]
    end

    local number = tonumber(value)

    if number ~= nil then
        return number
    end

    raise("invalid value: " .. value)
end

local function checkRegisters()
    for i = 1, 16 do
        local name = "r" .. i
        local value = cpu.reg[name]
        if value > UINT32_MAX then
            raise("register "..name.." exceeded the 32-bit limit: "..value)
        end
    end
end

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

--RAM :(
local function checkHeapAccess(address, size)
    if type(address) ~= "number" or address % 1 ~= 0 then
        raise("address must be an integer")
    end
    if address < 0 or address + size > memory.heapSize then
        raise("attempted access outside heap")
    end
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

-- read a 32 bit #
local function read32(address)
    checkAddress(address, 4)
    local value = read8(address) + read8(address + 1) * 256 + read8(address + 2) * 65536 + read8(address + 3) * 16777216
    if value > 2147483647 then
        value = value - 4294967296
    end
    return value
end

-- write a 32 bit # (negative values are stored as two's complement)
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

local program = ""
local programCount = 0
local programStart = 0
local thisId = nil

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

-- each process owns stackSize / maxProcs bytes of the stack region
local maxProcs = memory.schedSize / PROC_SLOT
local stackBytesPerProc = memory.stackSize / maxProcs

local function stackBaseFor(id)
    return stackBase + id * stackBytesPerProc
end

-- program visible memory access is heap only
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
    if type(id) ~= "number" or id % 1 ~= 0 or id < 0 or id >= memory.schedSize / PROC_SLOT then
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

    local depth = #cpu.callStack
    if depth > 8 then
        depth = 8
    end
    write8(base + 90, depth)
    for i = 1, 8 do
        local frame = math.floor(tonumber(cpu.callStack[i]) or 0)
        write8(base + 92 + (i - 1) * 2, math.floor(frame / 256) % 256)
        write8(base + 93 + (i - 1) * 2, frame % 256)
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

    local depth = read8(base + 90)
    cpu.callStack = {}
    for i = 1, depth do
        cpu.callStack[i] = read8(base + 92 + (i - 1) * 2) * 256 + read8(base + 93 + (i - 1) * 2)
    end

    return true
end

local function newProc()
    for id = 0, memory.schedSize / PROC_SLOT - 1 do
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

    return true
end

local function procStart(id)
    local base = procBase(id)
    if not base then
        return nil
    end
    return read32(base + 108)
end

--the casm assembler
local function assemble(file)
    symbols = {}
    nextSymbol = 1
    errors = {}
    program = ""
    assembler.ic = 1

    local rows = {}
    local pending = {}
    local lineNumber = 0
    for line in file:gmatch("[^\r\n]+") do
        lineNumber = lineNumber + 1
        local clean = line:match("^[^;]*")
        clean = clean:match("^%s*(.-)%s*$")

        if clean ~= "" then
            local label = clean:match("^([%a_][%w_]*):$")
            if label then
                local id = symbolIdFor(label, lineNumber)
                if id then
                    if symbols[label].defined then
                        asmError("duplicate label: " .. label, lineNumber)
                    else
                        symbols[label].defined = true
                        pending[#pending + 1] = label
                    end
                end
            else
                rows[#rows + 1] = {
                    text = clean,
                    line = lineNumber,
                    labels = pending
                }
                pending = {}
            end
        end
    end

    local sawEnd = false

    while assembler.ic <= #rows do
        local row = rows[assembler.ic]

        for i = 1, #row.labels do
            program = program .. "15 " .. string.format("%02X", symbols[row.labels[i]].id) .. " 00 00 "
        end

        local instruction = row.text
        local line = row.line
        local operation = instruction:match("^%w+")

        if operation == "load" then
            local register, value = instruction:match("^load%s+(r%d+)%s*,%s*(%S+)%s*$")
            if not register or not value then
                asmError("invalid load instruction: " .. instruction, line)
            else
                local registerByte = regNumber(register, line)
                local number = tonumber(value)
                if not number or number % 1 ~= 0 or number < 0 or number > 255 then
                    asmError("load takes a value from 0 to 255: " .. instruction, line)
                elseif registerByte then
                    program = program .. "01 " .. string.format("%X", registerByte) .. " " .. string.format("0x%X", number) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1
        elseif operation == "add" then
            local destination, left, right = instruction:match("^add%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                asmError("invalid add instruction: " .. instruction, line)
            else
                local destinationByte = regNumber(destination, line)
                local leftByte = arithOperand(left, line)
                local rightByte = arithOperand(right, line)
                if destinationByte and leftByte and rightByte then
                    program = program .. "02 " .. string.format("%X", destinationByte) .. " " .. leftByte .. " " .. rightByte .. " "
                end
            end
            assembler.ic = assembler.ic + 1
        elseif operation == "sub" then
            local destination, left, right = instruction:match("^sub%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                asmError("invalid sub instruction: " .. instruction, line)
            else
                local destinationByte = regNumber(destination, line)
                local leftByte = arithOperand(left, line)
                local rightByte = arithOperand(right, line)
                if destinationByte and leftByte and rightByte then
                    program = program .. "03 " .. string.format("%X", destinationByte) .. " " .. leftByte .. " " .. rightByte .. " "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "sys" then
            local name, arguments = instruction:match("^sys%s+(%S+)%s*(.-)%s*$")
            local call = name and syscallFor(name)

            if not name then
                asmError("invalid sys instruction: " .. instruction, line)
            elseif not call then
                asmError("unknown syscall: " .. name, line)
            else
                local tokens = {}
                for token in arguments:gmatch("[^,%s]+") do
                    tokens[#tokens + 1] = token
                end

                local encoded = {}
                local bad = false
                for i = 1, #tokens do
                    encoded[i] = encodeSysArg(tokens[i], call[1], line)
                    if not encoded[i] then
                        bad = true
                        break
                    end
                end

                if not bad and #tokens > maxSysArgs then
                    asmError("sys " .. call[1] .. " takes at most " .. maxSysArgs .. " arguments", line)
                    bad = true
                end

                if not bad and #tokens == 1 then
                    -- one argument keeps the old inline form
                    program = program .. "12 " .. string.format("%02X", call[2]) .. " " ..
                        string.format("%02X", encoded[1]) .. " 00 "
                elseif not bad and #tokens > 1 then
                    for i = 1, #tokens do
                        program = program .. "17 " .. string.format("%02X", encoded[i]) .. " 00 00 "
                    end
                    program = program .. "12 " .. string.format("%02X", call[2]) .. " 00 " ..
                        string.format("%02X", #tokens) .. " "
                elseif not bad then
                    program = program .. "12 " .. string.format("%02X", call[2]) .. " 00 00 "
                end

                assembler.ic = assembler.ic + 1
            end
        elseif operation == "call" then
            local target = instruction:match("^call%s+([%a_][%w_]*)$")
            if not target then
                asmError("invalid call instruction: " .. instruction, line)
            else
                local id = symbolIdFor(target, line)
                if id then
                    program = program .. "10 " .. string.format("%02X", id) .. " 00 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "cmp" then
            local left, right = instruction:match("^cmp%s+(%S+)%s*,%s*(%S+)$")
            if not left or not right then
                asmError("invalid cmp instruction: " .. instruction, line)
            else
                local leftOperand = operand(left, line)
                local rightOperand = operand(right, line)
                if leftOperand and rightOperand then
                    program = program .. "04 " .. leftOperand .. " " .. rightOperand .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "ret" then
            if instruction ~= "ret" then
                asmError("ret takes no arguments: " .. instruction, line)
            else
                program = program .. "11 00 00 00 "
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "jmp" then
            local target = instruction:match("^jmp%s+([%a_][%w_]*)$")
            if not target then
                asmError("invalid target for jmp: " .. instruction, line)
            else
                local id = symbolIdFor(target, line)
                if id then
                    program = program .. "07 " .. string.format("%02X", id) .. " 00 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "jf" then
            local flag, target = instruction:match("^jf%s+(%S+)%s*,%s*([%a_][%w_]*)$")
            if not flag or not target then
                asmError("invalid jf, use jf <flag>, <label>: " .. instruction, line)
            else
                local flagOperand = flagByte(flag, line)
                local id = symbolIdFor(target, line)
                if flagOperand and id then
                    program = program .. "08 " .. flagOperand .. " " .. string.format("%02X", id) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1
        elseif operation == "jnf" then
            local flag, target = instruction:match("^jnf%s+(%S+)%s*,%s*([%a_][%w_]*)$")
            if not flag or not target then
                asmError("invalid jnf, use jnf <flag>, <label>: " .. instruction, line)
            else
                local flagOperand = flagByte(flag, line)
                local id = symbolIdFor(target, line)
                if flagOperand and id then
                    program = program .. "09 " .. flagOperand .. " " .. string.format("%02X", id) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1
        elseif operation == "read32" then
            local address, register = instruction:match("^read32%s+(%S+)%s*,%s*(%S+)%s*$")
            if not address or not register then
                asmError("invalid read32 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    program = program .. "05 " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "write32" then
            local address, register = instruction:match("^write32%s+(%S+)%s*,%s*(%S+)$")
            if not address or not register then
                asmError("invalid write32 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    program = program .. "06 " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "read8" then
            local address, register = instruction:match("^read8%s+(%S+)%s*,%s*(%S+)%s*$")
            if not address or not register then
                asmError("invalid read8 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    program = program .. "0A " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "write8" then
            local address, register = instruction:match("^write8%s+(%S+)%s*,%s*(%S+)$")
            if not address or not register then
                asmError("invalid write8 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    program = program .. "0B " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "wait" then
            local target = instruction:match("^wait%s+(%S+)$")
            if not target then
                asmError("invalid wait instruction, use wait 50 or wait r1: " .. instruction, line)
            else
                local operandByte = nil
                if target:match("^[rR]%d+$") then
                    local register = regNumber(target, line)
                    if register then
                        operandByte = string.format("%02X", register)
                    end
                else
                    local number = tonumber(target)
                    if not number or number % 1 ~= 0 or number < 0 or number > 127 then
                        asmError("wait takes a register or 0 to 127 ms, for longer waits load the value into a register first: " .. target, line)
                    else
                        operandByte = string.format("%02X", 0x80 + number)
                    end
                end
                if operandByte then
                    program = program .. "0D " .. operandByte .. " 00 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "load16" then
            local register, value = instruction:match("^load16%s+(r%d+)%s*,%s*(%S+)$")
            if not register or not value then
                asmError("invalid load16 instruction, use load16 r1, 49152: " .. instruction, line)
            else
                local registerByte = regNumber(register, line)
                local number = tonumber(value)
                if not number or number % 1 ~= 0 or number < 0 or number > 65535 then
                    asmError("load16 takes 0 to 65535: " .. instruction, line)
                elseif registerByte then
                    program = program .. "14 " .. string.format("%X", registerByte) .. " " ..
                        string.format("%02X", math.floor(number / 256) % 256) .. " " ..
                        string.format("%02X", number % 256) .. " "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "push" then
            local target = instruction:match("^push%s+(%S+)$")
            if not target then
                asmError("invalid push instruction, use push r1 or push 5: " .. instruction, line)
            else
                local operandByte = nil
                if target:match("^[rR]%d+$") then
                    local register = regNumber(target, line)
                    if register then
                        operandByte = string.format("%02X", register)
                    end
                else
                    local number = tonumber(target)
                    if not number or number % 1 ~= 0 or number < 0 or number > 127 then
                        asmError("push takes a register or 0 to 127, load bigger values into a register first: " .. target, line)
                    else
                        operandByte = string.format("%02X", 0x80 + number)
                    end
                end
                if operandByte then
                    program = program .. "0E " .. operandByte .. " 00 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "pop" then
            local target = instruction:match("^pop%s+(%S+)$")
            if not target or not target:match("^[rR]%d+$") then
                asmError("pop takes a register, use pop r1: " .. instruction, line)
            else
                local register = regNumber(target, line)
                if register then
                    program = program .. "0F " .. string.format("%02X", register) .. " 00 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "flag" then
            local flagName, state = instruction:match("^flag%s+(%S+)%s*,%s*(%S+)$")
            if not flagName or not state then
                asmError("invalid flag instruction, use flag f1, true: " .. instruction, line)
            else
                local flagOperand = flagByte(flagName, line)
                local lowered = state:lower()
                local stateByte = nil
                if lowered == "true" or lowered == "1" then
                    stateByte = 1
                elseif lowered == "false" or lowered == "0" then
                    stateByte = 0
                end
                if stateByte == nil then
                    asmError("flag state must be true or false: " .. instruction, line)
                elseif flagOperand then
                    program = program .. "0C " .. flagOperand .. " " .. string.format("%02X", stateByte) .. " 00 "
                end
            end
            assembler.ic = assembler.ic + 1

        elseif operation == "end" then
            if instruction ~= "end" then
                asmError("end takes no arguments: " .. instruction, line)
            else
                program = program .. "13 00 00 00 "
                sawEnd = true
            end
            assembler.ic = assembler.ic + 1

        else
            asmError("unknown operation: " .. tostring(operation) .. " in: " .. instruction, line)
            assembler.ic = assembler.ic + 1
        end
    end

    for i = 1, #pending do
        program = program .. "15 " .. string.format("%02X", symbols[pending[i]].id) .. " 00 00 "
    end

    if not sawEnd then
        asmError("missing end")
    end

    for name, symbol in pairs(symbols) do
        if not symbol.defined then
            asmError("undefined label: " .. name, symbol.line)
        end
    end

    if #errors > 0 then
        program = ""
        for i = 1, #errors do
            print("assembler error: " .. errors[i])
        end
        return false
    end

    print("assembler has completed successfully.")
    return true
end

local startProc

local function placeProgram(bytes)
    local size = programBytes(bytes)
    if size > memory.reProgramSize then
        cpuError("not enough program memory left for another program")
        return nil
    end

    programStart = memory.programSize - memory.reProgramSize
    programCount = writeProgram(bytes, programStart)
    memory.reProgramSize = memory.reProgramSize - size

    print("program at " .. programStart .. " (" .. size .. " bytes)")

    return newProc()
end

local function buildProgram(filename)
    local source = loadCasm(filename)
    if not source then
        return nil
    end
    if not assemble(source) then
        return nil
    end
    return program
end

local function execProgram(bytes)
    if type(bytes) ~= "string" then
        return nil
    end
    return startProc(placeProgram(bytes))
end

local function loadProgram(casmText)
    if type(casmText) ~= "string" then
        return nil
    end
    if not assemble(casmText) then
        return nil
    end
    return execProgram(program)
end

local instructionLimit = 100000
local cpuSymbols = {}

local schedulerClock = function()
    -- inside love, timer.getTime is the monotonic wall clock. os.clock is cpu time
    -- and behaves oddly under wasm, which would stall every wait.
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
local input               -- the input engine, defined after the flag helpers
local graphics            -- the screen driver, attached at boot

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

-- sys: b holds an inline argument (old single argument form), c holds the argument count
-- when the arguments were pushed with sysarg instructions first
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

    local context = {
        call = call,
        name = callName,
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
        park = function() cpu.waitUntil = 1 end,
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

-- cmp compares values and registers only. Use jf / jnf to test a flag.
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

-- one sys argument byte: 1-16 register, 17-99 bus keyword, 100-115 flag, 128-255 value
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

-- 0x08 jf: jump when the flag is set
opcodes[0x08] = function(flag, id)
    if (cpu.flags[flagKey(flag)] or 0) ~= 0 then
        jumpTo(id)
    end
end

-- 0x09 jnf: jump when the flag is NOT set
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
        cpu.waitUntil = 0
    else
        cpu.waitUntil = math.floor(schedulerClock() * 1000) + ms
    end
end

opcodes[0x0C] = function(flag, state)
    cpu.flags[flagKey(flag)] = (state ~= 0) and 1 or 0
end

opcodes[0x10] = function(id)
    if #cpu.callStack >= 8 then
        cpuError("call stack overflow (max depth 8)")
        return
    end
    cpu.callStack[#cpu.callStack + 1] = cpu.pc
    jumpTo(id)
end

opcodes[0x11] = function()
    local at = table.remove(cpu.callStack)
    if not at then
        cpuError("ret with an empty call stack")
        return
    end
    cpu.pc = at
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

-- pushes one encoded argument for the following sys instruction (emitted by the assembler)
opcodes[0x17] = function(encoded)
    local pid = cpu.pid or 0
    sysArgBuffer[pid] = sysArgBuffer[pid] or {}
    sysArgBuffer[pid][#sysArgBuffer[pid] + 1] = encoded
end

opcodes[0x13] = function()
    cpu.halted = true
end

-- ======================== input ============================
-- kernel level: key state, listeners, event queue, parked processes, pending calls
-- the driver:  live_inputdriver.lua pushes love events in, nothing polls

input = {
    keys = {},            -- love key name -> true while held
    listeners = {},       -- id -> listener table
    nextId = 1,
    lastId = 0,
    events = {},          -- queued transitions for sys input poll
    waiters = {},         -- pid -> love key name
    pendingCalls = {},    -- pid -> symbol id to call before that process runs again
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

input.driver = loadDriver(inputDriverFile)
if input.driver and input.driver.attach then
    input.driver.attach(input)
end

graphics = loadDriver(graphicsDriverFile)
if graphics and graphics.attach then
    graphics.attach()
end

local scheduler = {
    procs = {},
    loadQueue = {},
    running = false,
    switches = 0,
    maxSwitches = 10000
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
    cpu.running = true

    local base = procBase(id)
    cpuSymbols = scanSymbols(read32(base + 108), read32(base + 112))

    local pendingSymbol = input.takePendingCall(id)
    if pendingSymbol then
        local at = cpuSymbols[pendingSymbol]
        if at and #cpu.callStack < 8 then
            cpu.callStack[#cpu.callStack + 1] = cpu.pc
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
        if cpu.waitUntil > 0 then
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

local function schedulerLoad(casmText)
    scheduler.loadQueue[#scheduler.loadQueue + 1] = casmText
end

local function schedulerLoadFile(filename)
    local source = loadCasm(filename)
    if not source then
        return false
    end
    schedulerLoad(source)
    return true
end

local function schedulerPass(sliceSeconds)
    while #scheduler.loadQueue > 0 do
        local casmText = table.remove(scheduler.loadQueue, 1)
        startProc(loadProgram(casmText))
    end

    local anyAlive = false
    local anyReady = false
    local index = 1

    while index <= #scheduler.procs do
        local id = scheduler.procs[index]
        local state = procState(id)
        if state ~= "dead" then
            anyAlive = true
            if state == "ready" then
                anyReady = true
                runProcSlice(id, sliceSeconds)
                scheduler.switches = scheduler.switches + 1
                if scheduler.switches >= scheduler.maxSwitches then
                    break
                end
            end
        end
        index = index + 1
    end

    return anyAlive, anyReady
end

local function schedulerBegin()
    scheduler.running = true
    scheduler.active = true
    scheduler.switches = 0
end

local function schedulerCap() 
    return scheduler.switches >= scheduler.maxSwitches
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

-- the whole public surface
casm = {
    load = schedulerLoad,
    loadFile = schedulerLoadFile,
    build = buildProgram,
    exec = execProgram,
    run = function(options)
        if options then
            if options.clock then schedulerSetClock(options.clock) end
            if options.idle then schedulerSetIdle(options.idle) end
        end
        return schedulerRun()
    end,
    step = function(budgetSeconds)
        return schedulerStep(budgetSeconds or 0.008)
    end,
    setClock = schedulerSetClock,
    input = input,
    graphics = graphics,
    reloadBus = function()
        sysBus = loadSysBus()
        return sysBus
    end,
}

if love then
    local previousUpdate = love.update
    love.update = function(dt)
        if previousUpdate then
            previousUpdate(dt)
        end
        if scheduler.active or #scheduler.procs > 0 or #scheduler.loadQueue > 0 then
            schedulerStep(0.008)
        end
    end
end


-- loader v
local main = casm.build("main.casm")
casm.exec(main)
