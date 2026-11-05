-- runheadless.lua - assemble and run a casm program without love
-- usage: lua runheadless.lua main.casm [frames]
-- frames run at a virtual 60 fps, so wait and the scheduler behave the same
-- way they do inside love no matter how fast the host machine is.

local target = (arg and arg[1]) or "main.casm"
local frames = tonumber(arg and arg[2]) or 600

love = {
    filesystem = {
        read = function(name)
            local f = io.open(name, "rb")
            if not f then
                return nil, "no such file"
            end
            local source = f:read("*a")
            f:close()
            return source
        end,
    },
    timer = {
        getTime = function() return os.clock() end,
        sleep = function() end,
    },
}

CASM_NO_AUTORUN = true
dofile("main.lua")

local now = 0
casm.setClock(function() return now end)

if not casm.loadFile(target) then
    print("load failed")
    os.exit(1)
end

for frame = 1, frames do
    now = now + 1 / 60
    if not casm.step(0.008) then
        print("halted after " .. frame .. " frames")
        break
    end
end

print("frames done")
