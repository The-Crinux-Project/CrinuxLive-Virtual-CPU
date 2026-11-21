function love.load()
    local casm = tostring(love.filesystem.read("main.casm"))
    local assembled, startAdr = assemble(casm)
    print(assembled)
    globalStartAdr = startAdr
    print("cpu:")
    loadBin(assembled, startAdr)
    resetCpu()
    stepCpu(1000)
end

pc = 0
reg = {}
flags = {
    z = false,
    n = false,
}

for i = 1, 16 do
    table.insert(reg, 0)
end

memSize = 65536
memory = {}

for i = 0, memSize - 1 do
    memory[i] = 0
end

--so so many helper funcstions
function decimalToBinary(input)
    local result = ""

    for i = 8 - 1, 0, -1 do
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

function memWrite(address, value)
    assert(type(value) == "string" and #value == 8 and value:match("^[01]+$"), "No")
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

function loadBin(bin)
    bin = string.gsub(bin, "%s+", "")
    local binLength = #bin / 32

    memWrite(nextFree, decimalToBinary(binLength))
    nextFree = nextFree + 1

    for i = 1, #bin, 32 do
        local instruction = string.sub(bin, i, i + 31)

        for j = 0, 3 do
            local byte = string.sub(instruction, j * 8 + 1, j * 8 + 8)
            memWrite(nextFree, byte)
            nextFree = nextFree + 1
        end
    end
end

function resetCpu()
    pc = globalStartAdr / 4
    reg = {}
    flags = {
        z = false,
        n = false,
    }

    for i = 1, 16 do
        table.insert(reg, 0)
    end
end

function stepCpu(amt)
    for i = 1, amt do
        local jumped = false
        if pc ~= binaryToDecimal(memory[1]) then
            local adr = (pc * 4) + 2
            local instruct = binaryToDecimal(memory[adr])

            if instruct == 1 then
                -- mov r1, 100 (loads)
                local regAddress = (pc * 4) + 3
                local valAddress = (pc * 4) + 4
                local registerNumber = binaryToDecimal(memRead(regAddress))
                local value = binaryToDecimal(memRead(valAddress))
                reg[registerNumber + 1] = toUnsigned32(value)

            elseif instruct == 2 then
                -- add r1,r2,r3
                local regAdr1 = (pc * 4) + 3
                local regAdr2 = (pc * 4) + 4
                local regAdr3 = (pc * 4) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))

                reg[reg1 + 1] = toSigned32(
                    reg[reg2 + 1] + reg[reg3 + 1]
                )

            elseif instruct == 3 then
                -- sub r1,r2,r3
                local regAdr1 = (pc * 4) + 3
                local regAdr2 = (pc * 4) + 4
                local regAdr3 = (pc * 4) + 5
                local reg1 = binaryToDecimal(memRead(regAdr1))
                local reg2 = binaryToDecimal(memRead(regAdr2))
                local reg3 = binaryToDecimal(memRead(regAdr3))

                reg[reg1 + 1] = toSigned32(
                    reg[reg2 + 1] - reg[reg3 + 1]
                )

            elseif instruct == 4 then
                -- cpy r1, r2 (mov but register -> register)
                local regAddress1 = (pc * 4) + 3
                local regAddress2 = (pc * 4) + 4
                local registerNumber1 = binaryToDecimal(memRead(regAddress1))
                local registerNumber2 = binaryToDecimal(memRead(regAddress2))
                reg[registerNumber1 + 1] = reg[registerNumber2 + 1]

            elseif instruct == 5 then
                --sys calls
                local call = binaryToDecimal(memRead((pc * 4) + 3))
                local reg1 = binaryToDecimal(memRead((pc * 4) + 4))

                if call == 1 then
                    print(reg[reg1 + 1])
                else

                end
            elseif instruct == 6 then
                --jmp
                local target = binaryToDecimal(memRead((pc * 4) + 3))
                pc = target
                jumped = true
            elseif instruct == 255 then
                print("program complete")
                break
            end

            if not jumped then
                pc = pc + 1
            end
        else
            print("program complete")
            break
        end
    end
end

function assemble(casm)
    local instructions = {}
    local output = ""
    local amt = 0
    local labels = {}
    local startAdr = nil
    local adr = 0

    for instruction in string.gmatch(casm, "[^;\n]+") do
        instruction = string.gsub(instruction, "^%s*(.-)%s*$", "%1")
        local label = string.match(instruction, "^(%w+):$")

        if label then
            labels[label] = adr
            if label == "START" then
                startAdr = adr
            end
            --output = output.."00000110"..decimalToBinary(adr).."0000000000000000 "
        else
            table.insert(instructions, instruction)
            amt = amt + 1
            adr = adr + 4
        end
    end

    for i = 1, amt do
        local current = instructions[i]
        local inst = string.match(current, "^(%S+)")

        if inst == "MOV" then
            local reg1, value1 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*(%S+)")
            reg1 = reg1:gsub("r", "")
            reg1 = decimalToBinary(reg1)
            value1 = decimalToBinary(value1)
            output = output .. "00000001" .. reg1 .. value1 .. "00000000"
        elseif inst == "ADD" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(reg1:gsub("r", ""))
            reg2 = decimalToBinary(reg2:gsub("r", ""))
            reg3 = decimalToBinary(reg3:gsub("r", ""))
            output = output .. "00000010" .. reg1 .. reg2 .. reg3
        elseif inst == "SUB" then
            local reg1, reg2, reg3 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*,%s*(%S+)")
            reg1 = decimalToBinary(reg1:gsub("r", ""))
            reg2 = decimalToBinary(reg2:gsub("r", ""))
            reg3 = decimalToBinary(reg3:gsub("r", ""))
            output = output .. "00000011" .. reg1 .. reg2 .. reg3
        elseif inst == "CPY" then
            local reg1, reg2 = string.match(current, "^%S+%s+([^,%s]+)%s*,%s*([^,%s]+)%s*")
            reg1 = decimalToBinary(reg1:gsub("r", ""))
            reg2 = decimalToBinary(reg2:gsub("r", ""))
            output = output .. "00000100" .. reg1 .. reg2 .. "00000000"
        elseif inst == "SYS" then
            local call = string.match(current, "^%S+%s+(%S+)")
            output = output .. "00000101"
            if call == "PRINT" then
                local reg1 = string.match(current, "^%S+%s+%S+%s+(%S+)")
                reg1 = decimalToBinary(reg1:gsub("r", ""))
                output = output .. "00000001" .. reg1 .. "00000000"
            else
            end
        elseif inst == "JMP" then
            local label = string.match(current, "^%S+%s+(%S+)")
            local target = labels[label]
            output = output.."00000110"..decimalToBinary(target / 4).."0000000000000000"
        elseif inst == "END" then
            output = output .. "11111111000000000000000000000000"
        else

        end
    end
    for name, address in pairs(labels) do --temp
        print(name, address)
    end
    return output, startAdr
end
