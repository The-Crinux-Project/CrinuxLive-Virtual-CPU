local loadChunk = loadstring or load

local FLAG_BYTES = { Z = 0, N = 9, O = 10 }
for i = 1, 8 do FLAG_BYTES["f" .. i] = i end

local function loadModule(name)
    if not (love and love.filesystem and love.filesystem.read) then
        return nil
    end
    local source, err = love.filesystem.read(name)
    if not source then
        print("assembler: could not read " .. name .. (err and (" (" .. tostring(err) .. ")") or ""))
        return nil
    end
    local chunk, loadErr = loadChunk(source, "@" .. name)
    if not chunk then
        print("assembler: syntax error in " .. name .. ": " .. tostring(loadErr))
        return nil
    end
    local ok, mod = pcall(chunk)
    if not ok then
        print("assembler: error while loading " .. name .. ": " .. tostring(mod))
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
        sysBus = loadModule("sbus.lua")
    end
    return sysBus
end

local function readSource(filename)
    if not (love and love.filesystem and love.filesystem.read) then
        return nil, "no filesystem"
    end
    return love.filesystem.read(filename)
end

local S

local function asmError(message, line)
    if line then
        message = "line " .. line .. ": " .. message
    end
    S.errors[#S.errors + 1] = message
end

local function symbolIdFor(name, line)
    if not S.symbols[name] then
        if S.nextSymbol > 255 then
            asmError("too many symbols, the max is 255", line)
            return nil
        end

        S.symbols[name] = {
            id = S.nextSymbol,
            defined = false,
            line = line
        }
        S.nextSymbol = S.nextSymbol + 1
    end

    return S.symbols[name].id
end

local function codeSymbolId(name, line, what)
    local symbol = S.symbols[name]
    if symbol and symbol.kind == "data" then
        asmError(name .. " is a data label, " .. what .. " needs a code label", line)
        return nil
    end
    return symbolIdFor(name, line)
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
    if FLAG_BYTES[name] == nil then
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
    if FLAG_BYTES[flagName] ~= nil then
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

    local known = S.symbols[token]
    if known and known.kind == "data" then
        asmError("sys arguments cannot be data labels, load the address into a register with load16 first: " .. token, line)
        return nil
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
        if FLAG_BYTES[token] ~= nil or ({ z = 1, n = 1, o = 1 })[token] ~= nil then
            asmError("cmp and arithmetic take registers and values, not flags; use jf or jnf to test a flag: " .. token, line)
        else
            asmError("a literal operand here must be 0 to 127 (one byte); load larger values into a register first: " .. token, line)
        end
        return nil
    end

    return string.format("0x%X", 0x80 + number)
end
local function syscallFor(name)
    if not bus() then
        return nil
    end

    local callName = name
    local opcode = tonumber(name)
    if opcode then
        for busName, busOpcode in pairs(bus().calls) do
            if busOpcode == opcode then
                callName = busName
                break
            end
        end
        if not callName then
            return nil
        end
        local kind = (bus().argKinds and bus().argKinds[callName]) or "value"
        return { callName, opcode, kind }
    end

    local id = bus().calls[callName]
    if not id then
        return nil
    end
    local kind = (bus().argKinds and bus().argKinds[callName]) or "value"
    return { callName, id, kind }
end

local DATA_OPS = { data = true, db = true, include = true, image = true, sprite = true }

local function emitData(value)
    S.data[#S.data + 1] = string.format("%02X", value % 256)
    S.dataLength = S.dataLength + 1
end

local function emitData16(value)
    emitData(value % 256)
    emitData(math.floor(value / 256) % 256)
end

local function emitData32(value)
    emitData16(value % 65536)
    emitData16(math.floor(value / 65536) % 65536)
end

local function directiveArgument(text, op, line)
    local rest = text:match("^%w+%s+(.*)$")
    if not rest or rest == "" then
        asmError(op .. " needs an argument: " .. text, line)
        return nil
    end
    return rest:match('^"(.*)"$') or rest
end

local function decodeImage(filename, line)
    if not (love and love.image and love.image.newImageData) then
        asmError("sprite needs love.image to decode " .. filename .. " (or use include for raw bytes)", line)
        return nil
    end
    local ok, data = pcall(love.image.newImageData, filename)
    if not ok or not data then
        asmError("could not read " .. filename .. (ok and "" or (": " .. tostring(data))), line)
        return nil
    end
    return data
end

local function runDataDirective(op, text, line)
    if op == "data" or op == "db" then
        local rest = directiveArgument(text, op, line)
        if not rest then return end
        for token in rest:gmatch("[^,%s]+") do
            local value = tonumber(token)
            if not value or value % 1 ~= 0 or value < 0 or value > 255 then
                asmError(op .. " takes bytes, 0 to 255, got " .. token, line)
            else
                emitData(value)
            end
        end
        return
    end

    if op == "include" then
        local name = directiveArgument(text, op, line)
        if not name then return end
        local bytes, err = readSource(name)
        if not bytes then
            asmError("include could not read " .. name .. (err and (": " .. tostring(err)) or ""), line)
            return
        end
        for i = 1, #bytes do
            emitData(bytes:byte(i))
        end
        return
    end

    local name = directiveArgument(text, op, line)
    if not name then return end
    local data = decodeImage(name, line)
    if not data then return end

    local width = data:getWidth()
    local height = data:getHeight()
    emitData32(width)
    emitData32(height)
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local r, g, b = data:getPixel(x, y)
            emitData(math.floor((r or 0) * 255 + 0.5))
            emitData(math.floor((g or 0) * 255 + 0.5))
            emitData(math.floor((b or 0) * 255 + 0.5))
        end
    end
end

local function byteCount(text)
    local count = 0
    for token in text:gmatch("%S+") do
        local digits = token:gsub("^0[xX]", "")
        if #digits % 2 == 1 then
            digits = "0" .. digits
        end
        count = count + #digits / 2
    end
    return math.floor(count)
end

local function assembleText(source)
    S.symbols = {}
    S.nextSymbol = 1
    S.errors = {}
    S.image = ""
    S.data = {}
    S.dataLength = 0
    S.ic = 1

    local rows = {}
    local pending = {}
    local lineNumber = 0
    for line in source:gmatch("[^\r\n]+") do
        lineNumber = lineNumber + 1
        local clean = line:match("^[^;]*")
        clean = clean:match("^%s*(.-)%s*$")

        if clean ~= "" then
            local label = clean:match("^([%a_][%w_]*):$")
            if label then
                local id = symbolIdFor(label, lineNumber)
                if id then
                    if S.symbols[label].defined then
                        asmError("duplicate label: " .. label, lineNumber)
                    else
                        S.symbols[label].defined = true
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

    for index = 1, #rows do
        local row = rows[index]
        local op = row.text:match("^%w+")
        if DATA_OPS[op] then
            for i = 1, #row.labels do
                local name = row.labels[i]
                local symbol = S.symbols[name]
                if symbol.kind == "code" then
                    asmError("label " .. name .. " marks an instruction and cannot also mark data", row.line)
                else
                    symbol.kind = "data"
                    symbol.offset = S.dataLength
                end
            end
            runDataDirective(op, row.text, row.line)
        end
    end

    local sawEnd = false

    while S.ic <= #rows do
        local row = rows[S.ic]

        local instruction = row.text
        local line = row.line
        local operation = instruction:match("^%w+")
        local isDataRow = DATA_OPS[operation] == true

        for i = 1, #row.labels do
            local name = row.labels[i]
            local symbol = S.symbols[name]
            if isDataRow then
                if symbol.kind == "code" then
                    asmError("label " .. name .. " marks an instruction and cannot also mark data", line)
                end

            elseif symbol.kind == "data" then
                asmError("label " .. name .. " marks data and cannot also label an instruction", line)
            else
                symbol.kind = "code"
                S.image = S.image .. "15 " .. string.format("%02X", symbol.id) .. " 00 00 "
            end
        end

        if isDataRow then

            S.ic = S.ic + 1
        elseif operation == "load" then
            local register, value = instruction:match("^load%s+(r%d+)%s*,%s*(%S+)%s*$")
            if not register or not value then
                asmError("invalid load instruction: " .. instruction, line)
            else
                local registerByte = regNumber(register, line)
                local number = tonumber(value)
                if not number or number % 1 ~= 0 or number < 0 or number > 255 then
                    asmError("load takes a value from 0 to 255: " .. instruction, line)
                elseif registerByte then
                    S.image = S.image .. "01 " .. string.format("%X", registerByte) .. " " .. string.format("0x%X", number) .. " 00 "
                end
            end
            S.ic = S.ic + 1
        elseif operation == "add" then
            local destination, left, right = instruction:match("^add%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                asmError("invalid add instruction: " .. instruction, line)
            else
                local destinationByte = regNumber(destination, line)
                local leftByte = arithOperand(left, line)
                local rightByte = arithOperand(right, line)
                if destinationByte and leftByte and rightByte then
                    S.image = S.image .. "02 " .. string.format("%X", destinationByte) .. " " .. leftByte .. " " .. rightByte .. " "
                end
            end
            S.ic = S.ic + 1
        elseif operation == "sub" then
            local destination, left, right = instruction:match("^sub%s+(r%d+)%s*,%s*(%S+)%s*,%s*(%S+)$")
            if not destination then
                asmError("invalid sub instruction: " .. instruction, line)
            else
                local destinationByte = regNumber(destination, line)
                local leftByte = arithOperand(left, line)
                local rightByte = arithOperand(right, line)
                if destinationByte and leftByte and rightByte then
                    S.image = S.image .. "03 " .. string.format("%X", destinationByte) .. " " .. leftByte .. " " .. rightByte .. " "
                end
            end
            S.ic = S.ic + 1

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

                    S.image = S.image .. "12 " .. string.format("%02X", call[2]) .. " " ..
                        string.format("%02X", encoded[1]) .. " 00 "
                elseif not bad and #tokens > 1 then
                    for i = 1, #tokens do
                        S.image = S.image .. "17 " .. string.format("%02X", encoded[i]) .. " 00 00 "
                    end
                    S.image = S.image .. "12 " .. string.format("%02X", call[2]) .. " 00 " ..
                        string.format("%02X", #tokens) .. " "
                elseif not bad then
                    S.image = S.image .. "12 " .. string.format("%02X", call[2]) .. " 00 00 "
                end

                S.ic = S.ic + 1
            end
        elseif operation == "call" then
            local target = instruction:match("^call%s+([%a_][%w_]*)$")
            if not target then
                asmError("invalid call instruction: " .. instruction, line)
            else
                local id = codeSymbolId(target, line, "call")
                if id then
                    S.image = S.image .. "10 " .. string.format("%02X", id) .. " 00 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "cmp" then
            local left, right = instruction:match("^cmp%s+(%S+)%s*,%s*(%S+)$")
            if not left or not right then
                asmError("invalid cmp instruction: " .. instruction, line)
            else
                local leftOperand = operand(left, line)
                local rightOperand = operand(right, line)
                if leftOperand and rightOperand then
                    S.image = S.image .. "04 " .. leftOperand .. " " .. rightOperand .. " 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "ret" then
            if instruction ~= "ret" then
                asmError("ret takes no arguments: " .. instruction, line)
            else
                S.image = S.image .. "11 00 00 00 "
            end
            S.ic = S.ic + 1

        elseif operation == "jmp" then
            local target = instruction:match("^jmp%s+([%a_][%w_]*)$")
            if not target then
                asmError("invalid target for jmp: " .. instruction, line)
            else
                local id = codeSymbolId(target, line, "jmp")
                if id then
                    S.image = S.image .. "07 " .. string.format("%02X", id) .. " 00 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "jf" then
            local flag, target = instruction:match("^jf%s+(%S+)%s*,%s*([%a_][%w_]*)$")
            if not flag or not target then
                asmError("invalid jf, use jf <flag>, <label>: " .. instruction, line)
            else
                local flagOperand = flagByte(flag, line)
                local id = codeSymbolId(target, line, "jf")
                if flagOperand and id then
                    S.image = S.image .. "08 " .. flagOperand .. " " .. string.format("%02X", id) .. " 00 "
                end
            end
            S.ic = S.ic + 1
        elseif operation == "jnf" then
            local flag, target = instruction:match("^jnf%s+(%S+)%s*,%s*([%a_][%w_]*)$")
            if not flag or not target then
                asmError("invalid jnf, use jnf <flag>, <label>: " .. instruction, line)
            else
                local flagOperand = flagByte(flag, line)
                local id = codeSymbolId(target, line, "jnf")
                if flagOperand and id then
                    S.image = S.image .. "09 " .. flagOperand .. " " .. string.format("%02X", id) .. " 00 "
                end
            end
            S.ic = S.ic + 1
        elseif operation == "read32" then
            local address, register = instruction:match("^read32%s+(%S+)%s*,%s*(%S+)%s*$")
            if not address or not register then
                asmError("invalid read32 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    S.image = S.image .. "05 " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "write32" then
            local address, register = instruction:match("^write32%s+(%S+)%s*,%s*(%S+)$")
            if not address or not register then
                asmError("invalid write32 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    S.image = S.image .. "06 " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "read8" then
            local address, register = instruction:match("^read8%s+(%S+)%s*,%s*(%S+)%s*$")
            if not address or not register then
                asmError("invalid read8 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    S.image = S.image .. "0A " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "write8" then
            local address, register = instruction:match("^write8%s+(%S+)%s*,%s*(%S+)$")
            if not address or not register then
                asmError("invalid write8 instruction: " .. instruction, line)
            else
                local addressOperand = operand(address, line)
                local registerByte = regNumber(register, line)
                if addressOperand and registerByte then
                    S.image = S.image .. "0B " .. addressOperand .. " " .. string.format("%X", registerByte) .. " 00 "
                end
            end
            S.ic = S.ic + 1

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
                    S.image = S.image .. "0D " .. operandByte .. " 00 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "load16" then
            local register, value = instruction:match("^load16%s+(r%d+)%s*,%s*(%S+)$")
            if not register or not value then
                asmError("invalid load16 instruction, use load16 r1, 49152: " .. instruction, line)
            else
                local registerByte = regNumber(register, line)
                local number = tonumber(value)
                if not number then

                    local symbol = S.symbols[value]
                    if symbol and symbol.kind == "data" then
                        number = symbol.offset
                    end
                end
                if not number or number % 1 ~= 0 or number < 0 or number > 65535 then
                    asmError("load16 takes 0 to 65535 or a data label: " .. instruction, line)
                elseif registerByte then
                    S.image = S.image .. "14 " .. string.format("%X", registerByte) .. " " ..
                        string.format("%02X", math.floor(number / 256) % 256) .. " " ..
                        string.format("%02X", number % 256) .. " "
                end
            end
            S.ic = S.ic + 1

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
                    S.image = S.image .. "0E " .. operandByte .. " 00 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "pop" then
            local target = instruction:match("^pop%s+(%S+)$")
            if not target or not target:match("^[rR]%d+$") then
                asmError("pop takes a register, use pop r1: " .. instruction, line)
            else
                local register = regNumber(target, line)
                if register then
                    S.image = S.image .. "0F " .. string.format("%02X", register) .. " 00 00 "
                end
            end
            S.ic = S.ic + 1

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
                    S.image = S.image .. "0C " .. flagOperand .. " " .. string.format("%02X", stateByte) .. " 00 "
                end
            end
            S.ic = S.ic + 1

        elseif operation == "end" then
            if instruction ~= "end" then
                asmError("end takes no arguments: " .. instruction, line)
            else
                S.image = S.image .. "13 00 00 00 "
                sawEnd = true
            end
            S.ic = S.ic + 1

        else
            asmError("unknown operation: " .. tostring(operation) .. " in: " .. instruction, line)
            S.ic = S.ic + 1
        end
    end

    for i = 1, #pending do
        S.image = S.image .. "15 " .. string.format("%02X", S.symbols[pending[i]].id) .. " 00 00 "
    end

    if not sawEnd then
        asmError("missing end")
    end

    for name, symbol in pairs(S.symbols) do
        if not symbol.defined then
            asmError("undefined label: " .. name, symbol.line)
        end
    end

    if #S.errors > 0 then
        for i = 1, #S.errors do
            print("assembler error: " .. S.errors[i])
        end
        return nil
    end

    local codeLength = byteCount(S.image)
    local header = string.format("%02X %02X %02X %02X ",
        codeLength % 256, math.floor(codeLength / 256) % 256,
        S.dataLength % 256, math.floor(S.dataLength / 256) % 256)

    return header .. S.image .. table.concat(S.data, " ")
end

function M.assemble(input)
    if type(input) ~= "string" then
        return nil, { "assemble needs source text or a .casm filename" }
    end

    local source = input
    local err
    if not input:find("\n") and input:match("^[%w_%-]+%.casm$") then
        source, err = readSource(input)
        if not source then
            local message = "could not read " .. input .. (err and (": " .. tostring(err)) or "")
            print("assembler error: " .. message)
            return nil, { message }
        end
    end

    S = {
        image = "",
        errors = {},
        symbols = {},
        nextSymbol = 1,
        ic = 1,
    }

    local image = assembleText(source)
    local errs = S.errors
    S = nil

    if not image then
        return nil, errs
    end

    print("assembler has completed successfully. " .. M.size(image) .. " bytes")
    return image, errs
end

function M.assembleFile(filename)
    return M.assemble(filename)
end

function M.size(image)
    return byteCount(tostring(image))
end

function M.info(image)
    local text = tostring(image)
    local bytes = byteCount(text)
    local first = text:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if not first then
        return nil, "not a program image"
    end
    local function val(token)
        return tonumber(token:gsub("^0[xX]", ""), 16) or 0
    end
    local a, b, c, d = text:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    local codeLength = val(a) + val(b) * 256
    local dataLength = val(c) + val(d) * 256
    if codeLength + dataLength + 4 ~= bytes then
        return nil, "header says " .. (codeLength + dataLength + 4) .. " bytes but the image is " .. bytes
    end
    return { code = codeLength, data = dataLength, total = bytes, instructions = codeLength / 4 }
end

function M.instructions(image)
    return M.size(image) / 4
end

M.flags = FLAG_BYTES

return M
