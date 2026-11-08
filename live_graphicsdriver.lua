local driver = {
    name = "love",
    width = 320,
    height = 180,
    scale = 1,
    pixels = {},
    shown = {},
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

function driver.blit(x, y, w, h, fetch)
    if not w or not h or w <= 0 or h <= 0 then
        return false
    end
    local index = 0
    for row = 0, h - 1 do
        for column = 0, w - 1 do
            local r, g, b = fetch(index)
            driver.pixel(x + column, y + row, r, g, b)
            index = index + 1
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

function driver.present()
    driver.painted = false
    driver.frames = driver.frames + 1
    driver.shown = driver.pixels
    driver.shownFill = driver.fill

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

local function viewport()
    local winW = love.graphics.getWidth and love.graphics.getWidth() or 0
    local winH = love.graphics.getHeight and love.graphics.getHeight() or 0
    if winW <= 0 or winH <= 0 then
        return nil
    end

    local scaleX, scaleY = winW / driver.width, winH / driver.height
    if driver.scaling == "fill" then
        return { scaleX = scaleX, scaleY = scaleY, offsetX = 0, offsetY = 0,
            winW = winW, winH = winH, mode = "fill" }
    end

    local scale
    if driver.scaling == "fit" then
        scale = math.min(scaleX, scaleY)
    else
        scale = math.floor(math.min(scaleX, scaleY))
        if scale < 1 then

            scale = math.min(scaleX, scaleY)
        end
    end

    return {
        scaleX = scale,
        scaleY = scale,
        offsetX = math.floor((winW - driver.width * scale) / 2),
        offsetY = math.floor((winH - driver.height * scale) / 2),
        winW = winW,
        winH = winH,
        mode = driver.scaling or "integer",
    }
end

driver.viewport = viewport

function driver.setScaling(mode)
    if mode ~= "integer" and mode ~= "fit" and mode ~= "fill" then
        return false
    end
    driver.scaling = mode
    return true
end

function driver.setFilter(kind)
    kind = kind or "nearest"
    if kind ~= "nearest" and kind ~= "linear" then
        return false
    end
    driver.filter = kind
    if driver.image and driver.image.setFilter then
        driver.image:setFilter(kind, kind)
    end
    return true
end

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

    local vp = viewport()
    if not vp then
        return driver.frames
    end
    driver.scale = vp.scaleX
    driver.offsetX = vp.offsetX
    driver.offsetY = vp.offsetY
    love.graphics.draw(driver.image, vp.offsetX, vp.offsetY, 0, vp.scaleX, vp.scaleY)
    return driver.frames
end

function driver.reset()
    driver.pixels = {}
    driver.shown = driver.pixels
    driver.dirty = {}
    driver.shownDirty = {}
    driver.content = {}
    driver.shownContent = {}
    driver.fillOnGpu = {}
    driver.fill = 0
    driver.shownFill = 0
    driver.committed = false
    driver.painted = false
    driver.frames = 0
    if driver.data and driver.data.setPixel then
        for y = 0, driver.height - 1 do
            for x = 0, driver.width - 1 do
                driver.data:setPixel(x, y, 0, 0, 0, 1)
            end
        end
        if driver.image and driver.image.replacePixels then
            driver.image:replacePixels(driver.data)
        end
    end
    return true
end

function driver.setMode(width, height)
    width = math.floor(tonumber(width) or 0)
    height = math.floor(tonumber(height) or 0)
    if width < 8 or height < 8 or width > 640 or height > 480 then
        return false, "canvas must be between 8 and 640 wide and 8 and 480 high"
    end

    driver.width = width
    driver.height = height
    driver.tileColumns = math.ceil(width / TILE)
    driver.tileRows = math.ceil(height / TILE)
    driver.pixels = {}
    driver.shown = driver.pixels
    driver.dirty = {}
    driver.shownDirty = {}
    driver.content = {}
    driver.shownContent = {}
    driver.fillOnGpu = {}
    driver.fill = 0
    driver.shownFill = 0
    driver.committed = false
    driver.painted = false
    driver.frames = 0

    if hasScreen() then
        local ok, made = pcall(love.image.newImageData, width, height)
        if ok then
            driver.data = made
            local madeImage, image = pcall(love.graphics.newImage, driver.data)
            if madeImage then
                driver.image = image
                if driver.image.setFilter then
                    local kind = driver.filter or "nearest"
                    driver.image:setFilter(kind, kind)
                end
            else
                driver.error = tostring(image)
                driver.image = nil
            end
        else
            driver.error = tostring(made)
            driver.image = nil
        end
    end

    return true
end

function driver.attach(options)
    options = options or {}
    driver.scaling = options.scaling or driver.scaling or "integer"
    driver.filter = options.filter or driver.filter or "nearest"

    local ok, why = driver.setMode(options.width or driver.width, options.height or driver.height)
    if not ok then
        print("graphics: " .. tostring(why) .. ", using 320x180")
        driver.setMode(320, 180)
    end

    if hasScreen() then
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
