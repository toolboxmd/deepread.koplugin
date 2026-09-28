--[[--
Deep Read: pick a topic and read one continuous article that is written as you read.

@module koplugin.DeepRead
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Plugin modules must be required here: the plugin folder is only on package.path
-- while KOReader loads this file.
local Api = require("deepread_api")
local DeepReadViewer = require("deepread_viewer")
local has_config, config = pcall(require, "deepread_configuration")
if not has_config or type(config) ~= "table" then config = {} end

local DEFAULT_SERVER = "https://deepread.toolbox.md"
local FIRST_WORDS = 450
local MAX_TOPIC_CHARS = 200

-- Cut to a number of characters, not bytes, so a multibyte character is never split.
local function truncateChars(text, max)
    local count, stop = 0, #text
    for pos in text:gmatch("()[^\128-\191]") do
        count = count + 1
        if count > max then
            stop = pos - 1
            break
        end
    end
    return text:sub(1, stop)
end

local DeepRead = WidgetContainer:extend{
    name = "deepread",
    is_doc_only = false,
}

function DeepRead:init()
    self.server = config.server or DEFAULT_SERVER
    self.ui.menu:registerToMainMenu(self)
end

function DeepRead:addToMainMenu(menu_items)
    menu_items.deepread = {
        text = _("Deep Read"),
        sorting_hint = "tools",
        callback = function() self:askTopic() end,
    }
end

function DeepRead:askTopic()
    local dialog
    dialog = InputDialog:new{
        title = _("Deep Read"),
        input = self.last_topic,
        input_hint = _("What would you like to read about?"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Read"),
                is_enter_default = true,
                callback = function()
                    local topic = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if topic == "" then return end
                    UIManager:close(dialog)
                    self.last_topic = topic
                    self:start(truncateChars(topic, MAX_TOPIC_CHARS))
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function DeepRead:start(topic)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:fetchFirst(topic) end)
    end)
end

-- Runs inside Trapper:wrap, so the subprocess wait can yield to the UI loop.
function DeepRead:fetchFirst(topic)
    local request = {
        id = string.format("koreader-%d-%04d", os.time(), math.random(0, 9999)),
        topic = topic,
        turns = {},
        words = FIRST_WORDS,
    }
    local completed, result, err = Trapper:dismissableRunInSubprocess(function()
        return Api.next(self.server, request)
    end, _("Thinking…"))
    if not completed then return end -- the reader dismissed the message

    if result then
        UIManager:show(DeepReadViewer:new{
            topic = topic,
            article_id = request.id,
            server = self.server,
            turns = { { text = result.text, asked = result.asked } },
        })
    elseif err and err.kind == "out_of_credit" then
        UIManager:show(InfoMessage:new{ text = _("Deep Read is out of reading credit for now.") })
    else
        UIManager:show(ConfirmBox:new{
            text = err and err.kind == "network"
                and _("Could not reach Deep Read.")
                or _("Deep Read could not start the article."),
            ok_text = _("Retry"),
            ok_callback = function() self:start(topic) end,
        })
    end
end

return DeepRead
