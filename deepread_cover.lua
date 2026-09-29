-- Title covers for article books, drawn on the device in the launcher cover's style
-- (deepread_cover.png): rules at top and bottom, the title, a short rule, a byline.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")

local W, H = 600, 800
local TEXT_X, TEXT_W = 60, 480
local TITLE_MAX_H = 440 -- about five lines at the smallest size
local TITLE_SIZES = { 72, 60, 50, 42, 36 }

local Cover = {}

-- Font:getFace() scales sizes to the screen's DPI, but the cover is a fixed 600x800.
local function textBox(text, font, px)
    local scale = Device.screen:scaleBySize(1000) / 1000
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace(font, px / scale),
        width = TEXT_W,
        alignment = "center",
    }
end

-- The cover as PNG bytes. TextBoxWidget wraps the title and falls back to other bundled
-- fonts for scripts Noto Serif lacks.
function Cover.png(title)
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    bb:paintRect(40, 40, 520, 7, Blitbuffer.COLOR_BLACK)
    bb:paintRect(40, 754, 520, 7, Blitbuffer.COLOR_BLACK)

    local title_box
    for _, px in ipairs(TITLE_SIZES) do
        if title_box then title_box:free() end
        title_box = textBox(title, "NotoSerif-Bold.ttf", px)
        if title_box:getSize().h <= TITLE_MAX_H then break end
    end
    local byline = textBox("Deep Read", "NotoSerif-Italic.ttf", 30)
    local title_h, byline_h = title_box:getSize().h, byline:getSize().h
    local y = math.floor((H - (title_h + 40 + 4 + 36 + byline_h)) / 2)
    title_box:paintTo(bb, TEXT_X, y)
    y = y + title_h + 40
    bb:paintRect(220, y, 160, 4, Blitbuffer.COLOR_BLACK)
    byline:paintTo(bb, TEXT_X, y + 4 + 36)
    title_box:free()
    byline:free()

    -- writePNG only writes to a file.
    local tmp = DataStorage:getDataDir() .. "/deepread-cover.png"
    bb:writePNG(tmp)
    bb:free()
    local f = io.open(tmp, "rb")
    if not f then return end
    local png = f:read("*a")
    f:close()
    os.remove(tmp)
    return png
end

return Cover
