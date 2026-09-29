--[[--
Deep Read: pick a topic and read one continuous article that is written as you read.

Deep Read is a folder in the library. Opening its launcher book asks for a topic and
creates an article book, which KOReader's own reader opens. While the article is open,
the next chunk is fetched in the background before the reader gets near the end, and
the book is rewritten and reloaded in place.

@module koplugin.DeepRead
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

-- Plugin modules must be required here: the plugin folder is only on package.path
-- while KOReader loads this file.
local Api = require("deepread_api")
local Book = require("deepread_book")
local has_config, config = pcall(require, "deepread_configuration")
if not has_config or type(config) ~= "table" then config = {} end

local DEFAULT_SERVER = "https://deepread.toolbox.md"
local FIRST_WORDS = 450
local NEXT_WORDS = 500
local PREFETCH_PAGES_LEFT = 3 -- fetch once this many pages or fewer remain after the current one
local MAX_TOPIC_CHARS = 200
local MAX_TURNS = 79 -- the service refuses an 80th turn

-- A reload replaces the ReaderUI and every plugin instance, so what must outlive one
-- instance lives here, keyed by book path.
local fetching = {} -- book path -> cancel function of the background request
local stopped = {} -- book path -> true once the service is out of credit
local waiting -- the "Writing what comes next…" message, while shown
local reload_started -- {at, turns} of the reload in progress, for the timing log

-- getHomeFolder() only exists in newer KOReader; this is what both releases use.
local function homeFolder()
    return G_reader_settings:readSetting("home_dir") or filemanagerutil.getDefaultDir()
end

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

local function closeWaiting()
    if waiting then
        UIManager:close(waiting)
        waiting = nil
    end
end

local function showOutOfCredit()
    UIManager:show(InfoMessage:new{ text = _("Deep Read is out of reading credit for now.") })
end

-- The Deep Read instance of the open reader, if it is showing this book.
local function openArticle(path)
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    if reader and reader.document and reader.document.file == path and reader.deepread then
        return reader.deepread
    end
end

local DeepRead = WidgetContainer:extend{
    name = "deepread",
    is_doc_only = false,
}

function DeepRead:init()
    self.server = config.server or DEFAULT_SERVER
    -- Plugins start before the file browser lists the folder, so a fresh install shows
    -- the launcher straight away.
    self.launcher = Book.ensureLauncher(homeFolder(), self.path .. "/deepread_cover.png")
    self.ui.menu:registerToMainMenu(self)
end

function DeepRead:addToMainMenu(menu_items)
    menu_items.deepread = {
        text = _("Deep Read"),
        sorting_hint = "tools",
        callback = function() self:askTopic() end,
    }
end

function DeepRead:onReaderReady()
    local path = self.ui.document.file
    if Book.isLauncher(path) then
        UIManager:nextTick(function() self:askTopic() end)
        return
    end
    self.state = Book.loadState(path)
    if not self.state then return end
    self.book = path
    if reload_started then
        logger.info(string.format("deepread: reload with %d chunks took %d ms",
            reload_started.turns, time.to_ms(time.since(reload_started.at))))
        reload_started = nil
    end
    -- On an article, reaching the end means waiting for the next chunk, not the end of
    -- the book. Only this ReaderUI's status module is replaced, and it dies with it.
    self.ui.status.onEndOfBook = function()
        self:onArticleEnd()
        return true
    end
    if (self.state.built or 0) < #self.state.turns then
        -- A chunk arrived while the book was closed or busy. Rebuild on the first page
        -- turn, not now: other modules still have startup work queued against this
        -- document (v2025.04's statistics crashes if it is reloaded under them).
        self.rebuild_pending = self.ui:getCurrentPage()
    else
        self:checkAhead(self.ui:getCurrentPage())
    end
end

function DeepRead:onPageUpdate(page)
    if not self.state then return end
    if self.rebuild_pending then
        -- The page the rebuild was deferred on; startup also sends PageUpdate for it.
        if page ~= self.rebuild_pending then self:rebuild() end
    else
        self:checkAhead(page)
    end
end

function DeepRead:checkAhead(page)
    if self.ui.document:getPageCount() - page <= PREFETCH_PAGES_LEFT then
        self:fetchNext()
    end
end

function DeepRead:fetchNext()
    local path = self.book
    if fetching[path] or stopped[path] or #self.state.turns >= MAX_TURNS then return end
    local request = {
        id = self.state.id,
        topic = self.state.topic,
        turns = self.state.turns,
        words = NEXT_WORDS,
    }
    fetching[path] = Api.fetchInBackground(self.server, request, function(result, err)
        fetching[path] = nil
        DeepRead.onChunk(path, result, err)
    end)
end

-- Runs when a chunk arrives, whether or not its book is still open.
function DeepRead.onChunk(path, result, err)
    if not result then
        closeWaiting()
        if err and err.kind == "out_of_credit" then
            stopped[path] = true
            showOutOfCredit()
            return
        end
        UIManager:show(ConfirmBox:new{
            text = err and err.kind == "network"
                and _("Could not reach Deep Read to continue the article.")
                or _("Deep Read could not continue the article."),
            ok_text = _("Retry"),
            ok_callback = function()
                NetworkMgr:runWhenOnline(function()
                    local article = openArticle(path)
                    if article then article:fetchNext() end
                end)
            end,
        })
        return
    end
    local state = Book.loadState(path)
    if not state then return end -- the book was deleted meanwhile
    table.insert(state.turns, { text = result.text, asked = result.asked })
    Book.saveState(path, state)
    local article = openArticle(path)
    if not article then
        if Book.write(path, state) then
            state.built = #state.turns
            Book.saveState(path, state)
        end
        return
    end
    article.state = state
    -- Reloading closes menus, but not dialogs such as a dictionary lookup: wait for the
    -- next page turn instead of pulling the book from under one.
    if waiting or UIManager:getTopmostVisibleWidget() == article.ui then
        article:rebuild()
    else
        article.rebuild_pending = article.ui:getCurrentPage()
    end
end

-- Rewrite the EPUB with every turn and reopen it at the same place.
function DeepRead:rebuild()
    self.rebuild_pending = nil
    closeWaiting()
    local state = self.state
    reload_started = { at = time.now(), turns = #state.turns }
    self.ui:reloadDocument(function(path)
        if Book.write(path, state) then
            state.built = #state.turns
            Book.saveState(path, state)
        end
    end, true)
end

function DeepRead:onArticleEnd()
    if stopped[self.book] then
        showOutOfCredit()
        return
    elseif #self.state.turns >= MAX_TURNS then
        UIManager:show(InfoMessage:new{ text = _("This article is as long as Deep Read can make it.") })
        return
    end
    self:fetchNext()
    if fetching[self.book] and not waiting then
        waiting = InfoMessage:new{
            text = _("Writing what comes next…"),
            dismiss_callback = function() waiting = nil end,
        }
        UIManager:show(waiting)
    end
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
    local state = {
        id = string.format("koreader-%d-%04d", os.time(), math.random(0, 9999)),
        topic = topic,
        turns = {},
    }
    local request = { id = state.id, topic = topic, turns = {}, words = FIRST_WORDS }
    -- Given a plain string, Trapper shows a small box in the bottom-left corner. Given a
    -- displayed InfoMessage, it cancels on the message's dismissal and leaves closing to us.
    local thinking = InfoMessage:new{
        text = _("Thinking about where to begin…") .. "\n\n" .. _("Tap to cancel."),
    }
    UIManager:show(thinking)
    UIManager:forceRePaint()
    local completed, result, err = Trapper:dismissableRunInSubprocess(function()
        return Api.next(self.server, request)
    end, thinking)
    if not completed then return end -- the reader dismissed the message, which closed it
    thinking.dismiss_callback = nil -- closing would otherwise report a cancel to Trapper
    UIManager:close(thinking)

    if result then
        state.turns[1] = { text = result.text, asked = result.asked }
        local path = Book.newArticlePath(Book.folder(homeFolder()), topic)
        if not Book.write(path, state) then
            UIManager:show(InfoMessage:new{ text = _("Deep Read could not save the article.") })
            return
        end
        state.built = 1
        Book.saveState(path, state)
        UIManager:nextTick(function()
            if self.ui.document then
                self.ui:switchDocument(path)
            else
                require("apps/reader/readerui"):showReader(path)
            end
        end)
    elseif err and err.kind == "out_of_credit" then
        showOutOfCredit()
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
