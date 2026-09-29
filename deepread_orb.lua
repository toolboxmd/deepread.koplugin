-- The website's thinking orb (makeOrb in deepread/public/app.js): 150 dots on a
-- Fibonacci sphere, turning slowly, nearer dots larger and darker. E-ink cannot animate
-- smoothly, so it steps twice a second and refreshes only the orb with the fast waveform.
-- Tapping calls dismiss_callback, so Trapper can use it as its cancellable message.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local STEP = 0.5 -- seconds between frames
local POINTS = {}
for i = 0, 149 do
    local y = 1 - 2 * (i + 0.5) / 150
    local r, a = math.sqrt(1 - y * y), i * 2.39996
    POINTS[i + 1] = { math.cos(a) * r, y, math.sin(a) * r }
end
local TILT_COS, TILT_SIN = math.cos(0.45), math.sin(0.45)

local Orb = InputContainer:extend{
    text = nil,
    hint = nil, -- smaller-looking second line, such as "Tap to cancel."
    dismiss_callback = nil,
    modal = true,
}

function Orb:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(16)
    local width = math.floor(screen_w * 0.8)
    self.size = Screen:scaleBySize(120)
    self.label = TextBoxWidget:new{
        text = self.hint and (self.text .. "\n" .. self.hint) or self.text,
        face = Font:getFace("infofont"),
        width = width - 2 * pad,
        alignment = "center",
    }
    local h = pad + self.size + pad + self.label:getSize().h + pad
    self.dimen = Geom:new{ x = math.floor((screen_w - width) / 2), y = math.floor((screen_h - h) / 2), w = width, h = h }
    self.orb_rect = Geom:new{ x = self.dimen.x + math.floor((width - self.size) / 2), y = self.dimen.y + pad,
        w = self.size, h = self.size }
    self.label_pos = { x = self.dimen.x + pad, y = self.orb_rect.y + self.size + pad }
    self.angle = 0.6
    local everywhere = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = everywhere } } }
    end
    if Device:hasKeys() then
        self.key_events = { AnyKey = { { Device.input.group.Any } } }
    end
    self.step = function()
        self.angle = self.angle + 0.7 * STEP -- the website's resting speed, in radians a second
        UIManager:setDirty(self, function() return "fast", self.orb_rect end)
        UIManager:scheduleIn(STEP, self.step)
    end
end

function Orb:paintTo(bb)
    local box = self.dimen
    bb:paintRect(box.x, box.y, box.w, box.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(box.x, box.y, box.w, box.h, Size.border.window, Blitbuffer.COLOR_BLACK, Size.radius.window)
    local half = self.size / 2
    local cx, cy, radius = self.orb_rect.x + half, self.orb_rect.y + half, half * 0.84
    local dot = self.size / 38 -- the website draws a 38 px orb with dots up to about 1 px
    local ca, sa = math.cos(self.angle), math.sin(self.angle)
    local dots = {}
    for i, p in ipairs(POINTS) do
        local x, y, z = p[1], p[2], p[3]
        local x1, z1 = x * ca + z * sa, -x * sa + z * ca
        dots[i] = { cx + x1 * radius, cy + (y * TILT_COS - z1 * TILT_SIN) * radius, (y * TILT_SIN + z1 * TILT_COS + 1) / 2 }
    end
    -- Far dots first: opaque paint has no alpha blending to hide the overlaps.
    table.sort(dots, function(a, b) return a[3] < b[3] end)
    for _, d in ipairs(dots) do
        local depth = d[3]
        local r = math.floor(dot * (0.35 + 0.6 * depth) + 0.5)
        if r >= 1 then
            local alpha = 0.06 + 0.7 * depth * depth
            bb:paintCircle(math.floor(d[1]), math.floor(d[2]), r, Blitbuffer.Color8(math.floor(255 * (1 - alpha))))
        end
    end
    self.label:paintTo(bb, self.label_pos.x, self.label_pos.y)
end

function Orb:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    UIManager:scheduleIn(STEP, self.step)
    return true
end

function Orb:onCloseWidget()
    UIManager:unschedule(self.step)
    self.label:free()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function Orb:dismiss()
    local callback = self.dismiss_callback
    UIManager:close(self)
    if callback then callback() end
    return true
end

Orb.onTap = Orb.dismiss
Orb.onAnyKey = Orb.dismiss

return Orb
