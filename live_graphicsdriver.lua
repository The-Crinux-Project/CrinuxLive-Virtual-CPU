-- live_graphicsdriver.lua - lua driver, not metal
local driver = {
    name = "love",
    width = 320,
    height = 180,
    scale = 1,
    pixels = {},        -- back buffer, the vm draws here
    shown = {},         -- front buffer, the display scans this
    shownFill = 0,
    fill = 0,
    dirty = {},
    shownDirty = {},
    content = {},
    shownContent = {},
    fillOnGpu = {},
    tileColumns = 0,
    tileRows = 0,
    attached = false,
    committed = false,
    headless = false,
    data = nil,
    image = nil,
    frames = 0,
    painted = false,
}

local TILE = 16

local previousDraw

local function pack(r, g, b)
    return ((r or 0) % 256) * 65536 + ((g or 0) % 256) * 256 + ((b or 0) % 256)
end

local function hasScreen()
    return love and love.graphics and love.image
        and love.image.newImageData and love.graphics.newImage
        and love.graphics.draw
end

function driver.tile(x, y)
    return math.floor(y / TILE) * driver.tileColumns + math.floor(x / TILE) + 1
end

function driver.clear(r, g, b)
    driver.painted = true
    driver.fill = pack(r, g, b)
    local pixels = driver.pixels
    for index in pairs(pixels) do
        pixels[index] = nil
    end
    local total = driver.tileColumns * driver.tileRows
    for tile = 1, total do
        driver.dirty[tile] = true
    end
    return true
end

function driver.pixel(x, y, r, g, b)
    x = math.floor(x or 0)
    y = math.floor(y or 0)
    if x < 0 or y < 0 or x >= driver.width or y >= driver.height then
        return false
    end
    driver.painted = true
    driver.pixels[y * driver.width + x + 1] = pack(r, g, b)
    local tile = driver.tile(x, y)
    driver.dirty[tile] = true
    driver.content[tile] = true
    return true
end

function driver.rect(x, y, w, h, r, g, b)
    x = math.floor(x or 0)
    y = math.floor(y or 0)
    w = math.floor(w or 0)
    h = math.floor(h or 0)
    for row = y, y + h - 1 do
        for column = x, x + w - 1 do
            driver.pixel(column, row, r, g, b)
        end
    end
    return true
end

function driver.get(x, y)
    x = math.floor(x or 0)
    y = math.floor(y or 0)
    if x < 0 or y < 0 or x >= driver.width or y >= driver.height then
        return nil
    end
    local index = y * driver.width + x + 1
    if driver.committed then
        return driver.shown[index] or driver.shownFill
    end
    return driver.pixels[index] or driver.fill
end

-- page flip: the frame the vm just finished becomes the one on screen
function driver.present()
    driver.painted = false
    driver.frames = driver.frames + 1
    local back = driver.shown
    for index in pairs(back) do
        back[index] = nil
    end
    driver.shown = driver.pixels
    driver.shownFill = driver.fill
    driver.pixels = back
    driver.fill = 0
    local nextDirty = driver.shownDirty
    driver.shownDirty = driver.dirty
    driver.dirty = nextDirty
    for tile in pairs(nextDirty) do
        nextDirty[tile] = nil
    end
    local nextContent = driver.shownContent
    driver.shownContent = driver.content
    driver.content = nextContent
    for tile in pairs(nextContent) do
        nextContent[tile] = nil
    end
    driver.committed = true
    return driver.frames
end

-- vblank: push the tiles that changed and draw the front buffer
function driver.flush()
    if driver.headless or not driver.image or not driver.committed then
        return driver.frames
    end

    local width = love.graphics.getWidth and love.graphics.getWidth() or 0
    local height = love.graphics.getHeight and love.graphics.getHeight() or 0
    if width <= 0 or height <= 0 then
        return driver.frames
    end

    local dirty = false
    for tile in pairs(driver.shownDirty) do
        local fresh = driver.shownContent[tile] or driver.fillOnGpu[tile] ~= driver.shownFill
        if fresh then
            dirty = true
            local zero = tile - 1
            local left = (zero % driver.tileColumns) * TILE
            local top = math.floor(zero / driver.tileColumns) * TILE
            local right = math.min(left + TILE - 1, driver.width - 1)
            local bottom = math.min(top + TILE - 1, driver.height - 1)
            for row = top, bottom do
                for column = left, right do
                    local color = driver.shown[row * driver.width + column + 1] or driver.shownFill
                    driver.data:setPixel(column, row,
                        math.floor(color / 65536) % 256 / 255,
                        math.floor(color / 256) % 256 / 255,
                        color % 256 / 255, 1)
                end
            end
            if driver.shownContent[tile] then
                driver.fillOnGpu[tile] = false
            else
                driver.fillOnGpu[tile] = driver.shownFill
            end
        end
    end

    for tile in pairs(driver.shownDirty) do
        driver.shownDirty[tile] = nil
    end
    for tile in pairs(driver.shownContent) do
        driver.shownContent[tile] = nil
    end

    if dirty and driver.image.replacePixels then
        driver.image:replacePixels(driver.data)
    end

    driver.scale = math.max(1, math.floor(math.min(width / driver.width, height / driver.height)))
    local offsetX = math.floor((width - driver.width * driver.scale) / 2)
    local offsetY = math.floor((height - driver.height * driver.scale) / 2)
    love.graphics.draw(driver.image, offsetX, offsetY, 0, driver.scale, driver.scale)
    return driver.frames
end

function driver.attach(options)
    options = options or {}
    driver.width = options.width or driver.width
    driver.height = options.height or driver.height
    driver.tileColumns = math.ceil(driver.width / TILE)
    driver.tileRows = math.ceil(driver.height / TILE)
    driver.pixels = {}
    driver.shown = {}
    driver.dirty = {}
    driver.shownDirty = {}
    driver.content = {}
    driver.shownContent = {}
    driver.fillOnGpu = {}
    driver.fill = 0
    driver.shownFill = 0
    driver.committed = false
    driver.painted = false

    driver.width = math.floor(driver.width)
    driver.height = math.floor(driver.height)
    if driver.width < 8 or driver.height < 8 or driver.width > 640 or driver.height > 480 then
        driver.width = 320
        driver.height = 180
    end

    if hasScreen() then
        local ok, made = pcall(love.image.newImageData, driver.width, driver.height)
        if ok then
            driver.data = made
            local madeImage, image = pcall(love.graphics.newImage, driver.data)
            if madeImage then
                driver.image = image
                if driver.image.setFilter then
                    driver.image:setFilter("nearest", "nearest")
                end
            else
                driver.error = tostring(image)
            end
        else
            driver.error = tostring(made)
        end
        driver.headless = driver.image == nil
        previousDraw = love.draw
        love.draw = function(...)
            if previousDraw then
                previousDraw(...)
            end
            driver.flush()
        end
    else
        driver.headless = true
    end

    driver.attached = true
    return driver
end

function driver.detach()
    if not driver.attached then
        return false
    end
    if type(love) == "table" then
        love.draw = previousDraw
    end
    driver.attached = false
    return true
end

return driver
