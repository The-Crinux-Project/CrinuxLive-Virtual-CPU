--cruinux CASM assembler. v4. updated last on 10/28/26
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
    callStack={},
    flags={
        zero=true,
        negative=false,
     }
}

local memory = {
    totalSize = 65536,
    bytes = {},
    schedSize = 8192,   -- 8 KiB 12.5%
    stackSize = 16384,  -- 16 KiB 25%
    programSize = 24576, -- 24 KiB 37.5%
    heapSize = 16384,    -- 16 KiB 25%
    -- Heap -> Program -> Stack -> Scheduler
}

local symbols = {}

--loader
local function loadCasm(filename)
    assert(type(filename) == "string" and filename:match("^[%w_%-]+%.casm$"),"filesystem error: invalid CASM filename")
    local source, err = love.filesystem.read(filename)
    if not source then
        error("filesystem error: could not load "..filename.. ": "..tostring(err))
    end
    return source
end

--helper functions
local function getValue(value)
    if type(value) ~= "string" then
        error("CPU error: expected a string, got " .. type(value))
    end

    if cpu.reg[value] ~= nil then
        return cpu.reg[value]
    end

    local number = tonumber(value)

    if number ~= nil then
        return number
    end

    error("CPU error: invalid value: " .. value)
end

local function checkHeapAccess(address, size)
    assert(type(address) == "number" and address % 1 == 0,"RAM error: address must be an integer")
    assert(address >= 0 and address + size <= memory.heapSize, "RAM error: attempted access outside heap")
end

local UINT32_MAX = 4294967295

local function checkRegisters()
    for i = 1, 16 do
        local name = "r" .. i
        local value = cpu.reg[name]
        if value > UINT32_MAX then
            error("CPU error: register "..name.." exceeded the 32-bit limit: "..value)
        end
    end
end

local function updateFlags(value)
    cpu.flags.zero = (value == 0)
    cpu.flags.negative = (value < 0)
end

--RAM :(

local function checkAddress(address, size)
    assert(type(address) == "number" and address % 1 == 0,"RAM error: address must be an integer")
    assert(address >= 0 and address + size <= memory.totalSize,"RAM error: address out of bounds")
end

local function read8(address)
    checkHeapAccess(address, 1)
    return memory.bytes[address + 1] or 0
end

local function write8(address, value)
    checkHeapAccess(address, 1)
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 255,"RAM error: byte must be an integer from 0 to 255")
    memory.bytes[address + 1] = value
end

-- read a 32 bit #
local function read32(address)
    checkAddress(address, 4)
    checkHeapAccess(address, 4)
    return read8(address)+ read8(address + 1) * 256 + read8(address + 2) * 65536 + read8(address + 3) * 16777216
end

-- write a 32 bit #
local function write32(address, value)
    assert(type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 4294967295, "RAM error: 32-bit value out of range")
    checkAddress(address, 4)
    checkHeapAccess(address, 4)
    for i = 0, 3 do
        write8(address + i, value % 256)
        value = math.floor(value / 256)
    end
end

--the casm executer
local function inputCASM(file)    
    symbols = {}
    local content = loadCasm(file)
    if not content then
        print("assembler error: filename not found.")
        return
    end

    local rows = {}
    --populate rows
    for line in content:gmatch("[^\r\n]+") do
        local clean = line:match("^[^;]*")
        clean = clean:match("^%s*(.-)%s*$")
        if clean ~= "" then
            local label = clean:match("^(%w+):$")
            if label then
            if symbols[label] then
                error("Duplicate label: " .. label)
            end
            symbols[label] = #rows + 1
        else
            table.insert(rows, clean)
        end      
      end
    end

    cpu.pc = 1
    cpu.halted = false

    local instructionCount = 0
    local max = 10000

while not cpu.halted do
    instructionCount = instructionCount + 1

    if instructionCount > max then
        cpu.halted = true
        error(
            "CPU error: instruction limit exceeded ("..max.."). Possible infinite loop.")
    end
    local instruction = rows[cpu.pc]
    if not instruction then
        error("CPU error: program counter out of bounds: " .. cpu.pc)
    end

    local operation = instruction:match("^(%w+)")
        -- operations for later use
        -- ^(%w+) = operation name
        -- %s+ one or more spaces | (%w+) reg name
        -- %s*=%s* match = with optional spaces
        -- (%S+) capture a value or reg name | $ end
        if instruction == "end" then
            print("assembler has completed successfully.")
            cpu.halted = true
        elseif operation == "load" then
            local register, value =
            instruction:match("^load%s+(r%d+)%s*,%s*(%S+)%s*$")
            if not register or not value then
                error("assembler error: invalid load instruction: " .. instruction)
            end
            cpu.reg[register] = getValue(value)
            cpu.pc = cpu.pc + 1
            checkRegisters()
            updateFlags(cpu.reg[register])
        elseif operation == "add" then
            local destination, left, right =
            instruction:match("^add%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                error("Invalid add instruction: " .. instruction)
            end
            cpu.reg[destination] = getValue(left) + getValue(right)
            cpu.pc = cpu.pc + 1
            checkRegisters()
            updateFlags(cpu.reg[destination])
        elseif operation == "sub" then
            local destination, left, right =
            instruction:match("^sub%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                error("Invalid sub instruction: " .. instruction)
            end
            cpu.reg[destination] = getValue(left) - getValue(right)
            cpu.pc = cpu.pc + 1
            checkRegisters()
            updateFlags(cpu.reg[destination])
        elseif operation == "sys" then
            local syscall, argument=instruction:match("^sys%s+(%w+)%s+(%S+)$")
            if syscall == "print" then
                print(getValue(argument))
            else
            error("Unknown system call: " .. tostring(syscall))
            end
            cpu.pc = cpu.pc + 1
        elseif operation == "call" then
            local target = instruction:match("^call%s+(%w+)$")
            if not target then
                error("Invalid call instruction: " .. instruction)
            end
            local address = symbols[target]
            if not address then
                error("Unknown function or label: " .. target)
            end
            table.insert(cpu.callStack, cpu.pc + 1)
            cpu.pc = address
        elseif operation == "cmp" then
            local left, right =
            instruction:match("^cmp%s+(%S+)%s*,%s*(%S+)$")
            if not left or not right then
                error("Invalid cmp instruction: " .. instruction)
            end
            local leftValue = getValue(left)
            local rightValue = getValue(right)
            cpu.flags.zero = (leftValue == rightValue)
            cpu.flags.negative = (leftValue < rightValue)
            cpu.pc = cpu.pc + 1
        elseif operation == "ret" then
            local returnAddress = table.remove(cpu.callStack)
            if not returnAddress then
                error("Return stack underflow: ret without call")
            end
            cpu.pc = returnAddress
        elseif operation =="jmp" then
            local target = instruction:match("^jmp%s+(%w+)%s*$")
            if not target then
                error("assembler error: invalid jmp statement")
            end
            local address = symbols[target]
            if not address then
                error("assembler error: unknown label: "..target)
            end
            cpu.pc = address
        elseif operation == "jz" then
            local target = instruction:match("^jz%s+(%w+)%s*$")
            if not target then
                error("assembler error: invalid target for jz "..instruction)
            end
            if cpu.flags.zero then
                local address = symbols[target]
                if not address then
                    error("assembler error: unknown symbol: "..target)
                end
                cpu.pc = address
            else
                cpu.pc = cpu.pc + 1
            end
        elseif operation == "jnz" then
            local target = instruction:match("^jnz%s+(%w+)%s*$")
            if not target then
                error("assembler error: invalid target:"..instruction)
            end
            if not cpu.flags.zero then
                local address = symbols[target]
                if not address then
                    error("assembler error: unknown address:"..target)
                end
                cpu.pc = address
            else
                cpu.pc = cpu.pc + 1
            end
        elseif operation == "read32" then
            local address, register =
            instruction:match("^read32%s+(%S+)%s*,%s*(r%d+)%s*$")
            if not address or not register then
                error("assembler error: invalid read32 instruction: " .. instruction)
            end
            address = getValue(address)
            if cpu.reg[register] == nil then
                error("CPU error: unknown register: " .. register)
            end
            cpu.reg[register] = read32(address)
            cpu.pc = cpu.pc + 1
            checkRegisters()
            updateFlags(cpu.reg[register])
        elseif operation == "write32" then
            local addressText, valueText = instruction:match("^write32%s+(%d+),%s*(%S+)$")
            if not addressText or not valueText then
                error("assembler error: invalid write32 instruction")
            end
            local address = tonumber(addressText)
            local value = getValue(valueText)
            write32(address, value)
            cpu.pc = cpu.pc + 1
        elseif operation == "read8" then
            local address, register = instruction:match("^read8%s+(%S+)%s*,%s*(r%d+)%s*$")
            if not address or not register then
                error("assembler error: invalid read8 instruction: " .. instruction)
            end
            address = getValue(address)
            if cpu.reg[register] == nil then
                error("CPU error: unknown register: " .. register)
            end
            cpu.reg[register] = read8(address)
            cpu.pc = cpu.pc + 1
            checkRegisters()
            updateFlags(cpu.reg[register])
        elseif operation == "write8" then
            local addressText, valueText = instruction:match("^write8%s+(%d+),%s*(%S+)$")
            if not addressText or not valueText then
                error("assembler error: invalid write8 instruction")
            end
            local address = tonumber(addressText)
            local value = getValue(valueText)
            write8(address, value)
            cpu.pc = cpu.pc + 1
        else
            error("assembler error: unknown operation: " .. tostring(operation))
            cpu.pc = cpu.pc + 1
        end
    end
end

inputCASM("main.casm")
--inputCASM("check.casm")
