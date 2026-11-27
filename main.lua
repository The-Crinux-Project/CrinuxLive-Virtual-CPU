function love.load()
    local casm = tostring(love.filesystem.read("main.casm"))
    local assembled, startAdr = assemble(casm)
    --print(assembled)
    globalStartAdr = startAdr
    loadBin(assembled, startAdr)
    resetCpu()
    stepCpu(1000)
end

pc = 0
sp = 0
returnAdr = nil
reg = {}
halted = true
flags = {
    z = false,
    n = false,
}

for i = 1, 16 do
    table.insert(reg, 0)
end

memSize = 65536
ioBase = 100000
ioMax = 110000
memory = {}

for i = 0, ioMax - 1 do
    memory[i] = "00000000"
end

local stackBase = memSize - 1
local lastAvMemory = memSize - 1

--so so many helper funcstions
function decimalToBinary(input)
    local result = ""
    for i = 8 - 1, 0, -1 do
        local bit = math.floor(input / (2 ^ i)) % 2
        result = result .. bit
    end
    return tostring(result)
end

function decimalToBinary32(input)
    input = input % 4294967296
    local result = ""
    for i = 32 - 1, 0, -1 do
        local bit = math.floor(input / (2 ^ i)) % 2
        result = result .. bit
    end
    return tostring(result)
end

function binaryToDecimal(input)
    local result = 0
    for i = 1, #input do
        local bit = tonumber(input:sub(i, i))
        result = result * 2 + bit
    end
    return result
end

function binary32ToDecimal(input)
    local result = 0
    for i = 1, 32 do
        local bit = tonumber(input:sub(i, i))
        result = result * 2 + bit
    end
    return result
end

function letterToBinary(input)
    local result = ""

    for i = 1, #input do
        local decimal = input:byte(i)
        result = result .. decimalToBinary(decimal)
    end

    return result
end

function binaryToLetter(input)
    assert(#input % 8 == 0, "No")
    assert(input:match("^[01]+$"), "No")

    local result = ""

    for i = 1, #input, 8 do
        local byte = input:sub(i, i + 7)
        result = result .. string.char(binaryToDecimal(byte))
    end

    return result
end

function memRead(address)
    return memory[address]
end

function memRead32(address)
    return memRead(address)..memRead(address+1)..memRead(address+2)..memRead(address+3)
end

function memWrite(address, value)
    assert(type(value) == "string" and #value == 8 and value:match("^[01]+$"), "No: memWrite error")
    memory[address] = value
end

function toSigned32(value)
    value = value % 4294967296

    if value >= 2147483648 then
        value = value - 4294967296
    end

    return value
end

function toUnsigned32(value)
    return value % 4294967296
end

local nextFree = 1

function loadBin(bin,startAdr)
    bin = string.gsub(bin, "%s+", "")
    local binLength = #bin / 64
    memWrite(nextFree, decimalToBinary(binLength))
    nextFree = nextFree + 1

    for i = 1, #bin, 64 do
        local instruction = string.sub(bin, i, i + 63)

        for j = 0, 7 do
            local byte = string.sub(instruction, j * 8 + 1, j * 8 + 8)
            memWrite(nextFree, byte)
            nextFree = nextFree + 1
        end
    end
end

function resetCpu()
    pc = globalStartAdr / 8
    reg = {}
    flags = {
        z = false,
        n = false,
    }
    returnAdr = nil
    halted = true

    for i = 1, 16 do
        table.insert(reg, 0)
    end
end

local printMass = {}
table.insert(printMass,"")
function tick()
    -- io for adding integers
    local io1 = binaryToDecimal(memRead(ioBase))
    if io1 ~= 0 then
        printMass[#printMass] = printMass[#printMass]..io1
        memWrite(ioBase, decimalToBinary(0))
    end
    -- io for adding letters
    local io2 = memRead(ioBase + 1)
    if binaryToDecimal(io2) ~= 0 then
        printMass[#printMass] = printMass[#printMass]..binaryToLetter(io2)
        memWrite(ioBase + 1, decimalToBinary(0))
    end
    -- io for adding a new line
    if binaryToDecimal(memRead(ioBase + 2)) ~= 0 then
        table.insert(printMass,"")
        memWrite(ioBase + 2, decimalToBinary(0))
    end
    -- io for sending print
    if binaryToDecimal(memRead(ioBase + 3)) ~= 0 then
        for i=1, #printMass do
            print(printMass[i])
        end
        printMass = {}
        table.insert(printMass,"")
        memWrite(ioBase + 3, decimalToBinary(0))
    end
end


function stepCpu(amt)
    halted = false
    for i = 1, amt do
        local jumped = false
        if pc ~= binaryToDecimal(memory[1]) then
            local adr = (pc * 8) + 2
            local instruct = binaryToDecimal(memory[adr])

            if instruct == 1 then
                -- mov r1, 100 (loads)
                local regAddress = (pc * 8) + 3
                local valAddress = (pc * 8) + 4
                local registerNumber = binaryToDecimal(memRead(regAddress))
                local value = binaryToDecimal(memRead32(valAddress))
                reg[registerNumber + 1] = toUnsigned32(value)

            elseif instruct == 2 then
                -- add r1,r2,r3
                local regAdr1 = (pc * 8) + 3
                local regAdr2 = (pc * 8) + 4
                local regAdr3 = (pc * 8) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))

                reg[reg1 + 1] = toSigned32(
                    reg[reg2 + 1] + reg[reg3 + 1]
                )

            elseif instruct == 3 then
                -- sub r1,r2,r3
                local regAdr1 = (pc * 8) + 3
                local regAdr2 = (pc * 8) + 4
                local regAdr3 = (pc * 8) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))

                reg[reg1 + 1] = toSigned32(
                    reg[reg2 + 1] - reg[reg3 + 1]
                )

            elseif instruct == 4 then
                -- cpy r1, r2 (mov but register -> register)
                local regAddress1 = (pc * 8) + 3
                local regAddress2 = (pc * 8) + 4
                local registerNumber1 = binaryToDecimal(memRead(regAddress1))
                local registerNumber2 = binaryToDecimal(memRead(regAddress2))
                reg[registerNumber1 + 1] = reg[registerNumber2 + 1]

            elseif instruct == 5 then
                -- sys
                returnAdr = pc + 1
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                pc = target
                jumped = true
            elseif instruct == 6 then
                --jmp
                local value = binaryToDecimal(memRead32((pc * 8) + 3))
                pc = value
                jumped = true
            elseif instruct == 7 then
                -- cmp
                local status = binaryToDecimal(memRead((pc * 8) + 5))
                local v1 = binaryToDecimal(memRead((pc * 8) + 3))
                local v2 = binaryToDecimal(memRead((pc * 8) + 4))
                local o
                if status == 1 then
                    o = reg[v1 + 1] - v2
                elseif status == 2 then
                    o = v1 - reg[v2 + 1]
                else
                    o = reg[v1 + 1] - reg[v2 + 1]
                end
                flags.z = (o == 0)
                flags.n = (o < 0)
            elseif instruct == 8 then
                 --jzpc * 8) + 3
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                if flags.z == true then
                    pc = target
                    jumped = true
                end
            elseif instruct == 9 then
                 --jzf
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                if flags.z == false then
                    pc = target
                    jumped = true
                end
            elseif instruct == 10 then
                 --jn
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                if flags.n == true then
                    pc = target
                    jumped = true
                end
            elseif instruct == 11 then
                 --jnf
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                if flags.n == false then
                    pc = target
                    jumped = true
                end
            elseif instruct == 12 then
                --call
                returnAdr = pc + 1
                local target = binaryToDecimal(memRead32((pc * 8) + 3))
                pc = target
                jumped = true
            elseif instruct == 13 then
                --ret
                pc = returnAdr
                returnAdr = 0
                jumped = true
            elseif instruct == 14 then
                -- mread

                local address = binaryToDecimal(memRead32((pc * 8) + 3))
                local reg1 = binaryToDecimal(memRead((pc * 8) + 7))
                local status = binaryToDecimal(memRead((pc * 8) + 8))

                if status == 2 then
                    address = reg[address + 1]
                end
                reg[reg1 + 1] = binaryToDecimal(memRead(address))
            elseif instruct == 15 then
                --mload
                local address = binaryToDecimal(memRead32((pc * 8) + 3))
                local value = binaryToDecimal(memRead((pc * 8) + 7))
                local status = binaryToDecimal(memRead((pc * 8) + 8))

                if status == 1 or status == 3 then
                    address = reg[address + 1]
                end
                if status == 2 or status == 3 then
                    value = reg[value + 1] % 256
                end
                memWrite(address, decimalToBinary(value))
            elseif instruct == 16 then
                -- pop
                local regAddress = (pc * 8) + 3
                local registerNumber = binaryToDecimal(memRead(regAddress))
                if sp <= 0 then
                    error("stack underflow")
                end
                local address = stackBase - (sp * 4) + 1

                reg[registerNumber + 1] = binary32ToDecimal(memRead32(address))
                sp = sp - 1
            elseif instruct == 17 then
                -- push
                local regAddress = (pc * 8) + 3
                local registerNumber = binaryToDecimal(memRead(regAddress))

                if (sp + 1) * 4 > stackBase then
                    error("Stack overflow")
                end
                sp = sp + 1
                local binary = decimalToBinary32(reg[registerNumber + 1])
                local address = stackBase - (sp * 4) + 1
                for i = 0, 3 do
                    memWrite(address + i, binary:sub(i * 8 + 1, i * 8 + 8))
                end
            elseif instruct == 18 then
                -- and
                local regAdr1 = (pc * 8) + 3
                local regAdr2 = (pc * 8) + 4
                local regAdr3 = (pc * 8) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))
                reg[reg1 + 1] = reg[reg2 + 1] & reg[reg3 + 1]
            elseif instruct == 19 then
                -- not
                local regAddress = (pc * 8) + 3
                local registerNumber = binaryToDecimal(memRead(regAddress))
                reg[registerNumber + 1] = ~reg[registerNumber + 1]
            elseif instruct == 20 then
                -- or
                local regAdr1 = (pc * 8) + 3
                local regAdr2 = (pc * 8) + 4
                local regAdr3 = (pc * 8) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))
                reg[reg1 + 1] = reg[reg2 + 1] | reg[reg3 + 1]

            elseif instruct == 21 then
                -- xor
                local regAdr1 = (pc * 8) + 3
                local regAdr2 = (pc * 8) + 4
                local regAdr3 = (pc * 8) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))
                reg[reg1 + 1] = reg[reg2 + 1] ~ reg[reg3 + 1]
            elseif instruct == 255 then
                break
            end
            if not jumped then
                pc = pc + 1
            end
            tick()
        end
    end
    halted = true
end


function assemble(casm)
    local instructions = {}
    local output = ""
    local amt = 0
    local labels = {}
    local syslabels = {}
    local startAdr = nil
    local adr = 0

    for line in string.gmatch(casm, "[^\n]+") do
        local instruction = line:match("^(.-);") or line
        instruction = instruction:match("^%s*(.-)%s*$")

        if instruction ~= "" then
            local label = string.match(instruction, "^([%w_]+):$")
            if label then
                if label:match("^SYS_") then
                    syslabels[label:sub(5)] = adr
                else
                    labels[label] = adr
                end
                if label == "START" then
                    startAdr = adr
                end
            else
                table.insert(instructions, instruction)
                amt = amt + 1
                adr = adr + 8
            end
        end
    end

    for i = 1, amt do
        local current = instructions[i]
        local before = #output
        local inst = string.match(current, "^(%S+)")

        if inst == "MOV" then
            local reg1, value1 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*(%S+)")
            reg1 = reg1:gsub("r", "")
            reg1 = decimalToBinary(tonumber(reg1))
            value1 = decimalToBinary32(tonumber(value1))
            output = output .. "00000001" .. reg1 .. value1 .. "0000000000000000"

        elseif inst == "ADD" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            reg3 = decimalToBinary(tonumber((reg3:gsub("r", ""))))
            output = output .. "00000010" .. reg1 .. reg2 .. reg3 .. "00000000000000000000000000000000"

        elseif inst == "SUB" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            reg3 = decimalToBinary(tonumber((reg3:gsub("r", ""))))
            output = output .. "00000011" .. reg1 .. reg2 .. reg3 .. "00000000000000000000000000000000"

        elseif inst == "CPY" then
            local reg1, reg2 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            output = output .. "00000100" .. reg1 .. reg2 .. "0000000000000000000000000000000000000000"
        elseif inst == "SYS" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = syslabels[label]
            output = output.."00000101"..decimalToBinary32(target / 8).."000000000000000000000000"
        elseif inst == "JMP" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00000110" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "CMP" then
            local status = 0
            local v1, v2 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*(%S+)")

            if v1:find("r", 1, true) then
                status = 1
            end

            if v2:find("r", 1, true) then
                if status == 1 then
                    status = 3
                else
                    status = 2
                end
            end
            output = output .. "00000111" .. decimalToBinary(tonumber((v1:gsub("r", "")))) .. decimalToBinary(tonumber((v2:gsub("r", "")))) .. decimalToBinary(status) .. "00000000000000000000000000000000"
        elseif inst == "JZ" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00001000" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "JZF" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00001001" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "JN" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00001010" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "JNF" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00001011" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "CALL" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output .. "00001100" .. decimalToBinary32(target / 8) .. "000000000000000000000000"

        elseif inst == "RET" then
            output = output .. "0000110100000000000000000000000000000000000000000000000000000000"

        elseif inst == "MREAD" then
            local status = 1
            local v1, reg1 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*")

            if v1:find("r", 1, true) then
                v1 = decimalToBinary32(tonumber((v1:gsub("r", ""))))
                status = 2
            else
                v1 = decimalToBinary32(tonumber(v1))
            end
            if v1:match("^io%d+$") then
                local index = tonumber(v1:match("^io(%d+)$"))
                v1 = tostring(100000 + index - 1)
            end
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            output = output .. "00001110" .. v1 .. reg1 .. decimalToBinary(status) .. "00000000"
        elseif inst == "MLOAD" then
            local status = 0
            local v1, v2 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*(%S+)")

            if v1:find("r", 1, true) then
                status = 1
            end

            if v2:find("r", 1, true) then
                if status == 1 then
                    status = 3
                else
                    status = 2
                end
            end
            if v1:match("^io%d+$") then
                local index = tonumber(v1:match("^io(%d+)$"))
                v1 = tostring(100000 + index - 1)
            end
            output = output.. "00001111" ..decimalToBinary32(tonumber((v1:gsub("r", "")))).. decimalToBinary(tonumber((v2:gsub("r", ""))))..decimalToBinary(status).."00000000"
        elseif inst == "POP" then
            local reg1 = string.match(current, "^%S+%s+([^,%s]+)")
            reg1 = reg1:gsub("r", "")
            reg1 = decimalToBinary(tonumber(reg1))
            output = output.."00010000"..reg1.."000000000000000000000000000000000000000000000000"
        elseif inst == "PUSH" then
            local reg1 = string.match(current, "^%S+%s+([^,%s]+)")
            reg1 = reg1:gsub("r", "")
            reg1 = decimalToBinary(tonumber(reg1))
            output = output.."00010001"..reg1.."000000000000000000000000000000000000000000000000"
        elseif inst == "AND" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            reg3 = decimalToBinary(tonumber((reg3:gsub("r", ""))))
            output = output .."00010010"..reg1..reg2..reg3.."00000000000000000000000000000000"
        elseif inst == "NOT" then
            local reg1 = string.match(current, "^%S+%s+([^,%s]+)")
            reg1 = reg1:gsub("r", "")
            reg1 = decimalToBinary(tonumber(reg1))
            output = output.."00010011"..reg1.."000000000000000000000000000000000000000000000000"
        elseif inst == "OR" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            reg3 = decimalToBinary(tonumber((reg3:gsub("r", ""))))
            output = output.."00010100"..reg1..reg2..reg3.."00000000000000000000000000000000"
        elseif inst == "XOR" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(tonumber((reg1:gsub("r", ""))))
            reg2 = decimalToBinary(tonumber((reg2:gsub("r", ""))))
            reg3 = decimalToBinary(tonumber((reg3:gsub("r", ""))))
            output = output.."00010101"..reg1..reg2..reg3.."00000000000000000000000000000000"
        elseif inst == "END" then
            output = output .. "1111111100000000000000000000000000000000000000000000000000000000"
        end

        local instructionLength = #output - before

        if instructionLength ~= 64 then
            error("instruction length invalid " .. current .. " made " .. instructionLength .. " bits instead of 64")
        end
    end

    return output, startAdr
end

