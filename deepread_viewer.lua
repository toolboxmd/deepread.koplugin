-- Full-screen paged reader for one Deep Read article. When the reader reaches the
-- second-to-last page it asks for the next chunk in the background and appends it.

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local Screen = Device.screen

local Api = require("deepread_api")
local DeepReadMarkdown = require("deepread_markdown")

local NEXT_WORDS = 350
local MAX_TURNS = 79 -- the service refuses an 80th turn

local CSS = [[
@page { margin: 0; }
body { margin: 0; padding: 0; line-height: 1.45; }
h1, h2, h3 { margin: 0.8em 0 0.4em 0; }
p { margin: 0 0 0.7em 0; text-align: justify; }
ul, ol { margin: 0 0 0.7em 0; padding-left: 1.4em; }
blockquote { margin: 0.7em 0; padding-left: 0.8em; border-left: 2px solid #888; }
pre, code { font-family: monospace; }
]]

local DeepReadViewer = InputContainer:extend{
    topic = nil,
    article_id = nil,
    server = nil,
    turns = nil, -- { {text = ..., asked = ...}, ... } exactly as the service expects them back
    on_out_of_credit = nil,
    covers_fullscreen = true,
}

function DeepReadViewer:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            ForwardAtEnd = { { Device.input.group.PgFwd } },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            -- ScrollHtmlWidget turns pages on north/south swipes and taps; east/west swipes
            -- and taps it cannot use (last page) reach us.
            Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.scroll_widget.dimen end } },
            Tap = { GestureRange:new{ ges = "tap", range = function() return self.scroll_widget.dimen end } },
        }
    end

    local title_bar = TitleBar:new{
        width = screen_w,
        align = "left",
        with_bottom_line = true,
        title = self.topic,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local padding = Size.padding.large
    self.scroll_widget = ScrollHtmlWidget:new{
        html_body = self:articleHtml(),
        css = CSS,
        width = screen_w - 2 * padding,
        height = screen_h - title_bar:getHeight() - padding,
        dialog = self,
        scroll_callback = function() self:onPageChanged() end,
    }

    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            title_bar,
            FrameContainer:new{
                padding = 0,
                padding_left = padding,
                padding_right = padding,
                padding_top = padding,
                bordersize = 0,
                self.scroll_widget,
            },
        },
    }
    -- A short first chunk may already leave us on the second-to-last page.
    UIManager:nextTick(function() self:onPageChanged() end)
end

function DeepReadViewer:articleHtml()
    local texts = {}
    for i, turn in ipairs(self.turns) do
        texts[i] = turn.text
    end
    return DeepReadMarkdown.toHtml(table.concat(texts, "\n\n"))
end

function DeepReadViewer:pages()
    local box = self.scroll_widget.htmlbox_widget
    return box.page_number, box.page_count
end

function DeepReadViewer:onPageChanged()
    if not self.scroll_widget or self.closed then return end
    local page, count = self:pages()
    if page >= count - 1 then
        self:fetchNext()
    end
    if page >= count and self.fetching then
        self:showWaiting()
    end
end

function DeepReadViewer:fetchNext()
    if self.fetching or self.stopped or #self.turns >= MAX_TURNS then return end
    self.fetching = true
    local request = {
        id = self.article_id,
        topic = self.topic,
        turns = self.turns,
        words = NEXT_WORDS,
    }
    self.cancel_fetch = Api.fetchInBackground(self.server, request, function(result, err)
        self.fetching = false
        self.cancel_fetch = nil
        self:hideWaiting()
        if self.closed then return end
        if result then
            table.insert(self.turns, { text = result.text, asked = result.asked })
            self:appendRendered()
        else
            self:showError(err)
        end
    end)
end

-- Re-lay out the whole article (MuPDF has no append) and stay on the same page.
function DeepReadViewer:appendRendered()
    local sw = self.scroll_widget
    local box = sw.htmlbox_widget
    local page = box.page_number
    box:free()
    box:setContent(self:articleHtml(), CSS, sw.default_font_size)
    box:setPageNumber(math.min(page, box.page_count))
    sw.v_scroll_bar.enable = box.page_count > 1
    sw:_updateScrollBar() -- also calls onPageChanged, which may queue the next chunk
    UIManager:setDirty(self, function() return "ui", sw.dimen end)
end

function DeepReadViewer:showWaiting()
    if self.waiting then return end
    self.waiting = InfoMessage:new{
        text = _("Writing what comes next…"),
        dismiss_callback = function() self.waiting = nil end,
    }
    UIManager:show(self.waiting)
end

function DeepReadViewer:hideWaiting()
    if self.waiting then
        UIManager:close(self.waiting)
        self.waiting = nil
    end
end

function DeepReadViewer:showError(err)
    if err and err.kind == "out_of_credit" then
        self.stopped = true
        UIManager:show(InfoMessage:new{ text = _("Deep Read is out of reading credit for now.") })
        return
    end
    local text = err and err.kind == "network"
        and _("Could not reach Deep Read to continue the article.")
        or _("Deep Read could not continue the article.")
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Retry"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function() self:fetchNext() end)
        end,
    })
end

function DeepReadViewer:onForwardAtEnd()
    -- Only reached when ScrollHtmlWidget could not turn the page: we are on the last one.
    if self.fetching then
        self:showWaiting()
    elseif not self.stopped then
        self:fetchNext()
        if self.fetching then self:showWaiting() end
    end
    return true
end

function DeepReadViewer:onSwipe(arg, ges)
    local direction = ges.direction
    if direction == "west" then
        if not self.scroll_widget:onScrollDown() then self:onForwardAtEnd() end
        return true
    elseif direction == "east" then
        self.scroll_widget:onScrollUp()
        return true
    end
end

function DeepReadViewer:onTap(arg, ges)
    -- Forward taps on the last page land here; backward ones on page 1 are ignored.
    if ges.pos.x >= Screen:getWidth() / 2 then
        return self:onForwardAtEnd()
    end
    return true
end

function DeepReadViewer:onClose()
    self.closed = true
    if self.cancel_fetch then
        self.cancel_fetch()
        self.cancel_fetch = nil
    end
    self:hideWaiting()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    return true
end

return DeepReadViewer
