-- Live request through Api.next with real LuaSocket and LuaSec, outside KOReader.
-- Spends real credit unless the request is invalid. Usage:
--   luajit tests/live.lua [server] [proxy-url] [topic]
-- An empty topic makes the service answer 400 without writing anything.
package.path = "./?.lua;" .. package.path
local cjson = require("cjson")
local ltn12 = require("ltn12")
package.preload["json"] = function() return { decode = cjson.decode, encode = cjson.encode } end
package.preload["logger"] = function() return { warn = print, dbg = function() end } end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        table_sink = function(t) return ltn12.sink.table(t) end,
    }
end
for _, name in ipairs({ "ui/uimanager", "ffi/util" }) do
    package.preload[name] = function() return {} end
end

local server, proxy, topic = arg[1] or "https://deepread.toolbox.md", arg[2], arg[3] or ""
if proxy and proxy ~= "" then require("socket.http").PROXY = proxy end
local Api = require("deepread_api")
local r, err = Api.next(server, { id = "koplugin-dev", topic = topic, turns = {}, words = 120 })
if r then
    print(string.format("ok asked=%s words=%s cost=%s chars=%d", r.asked, r.words, r.cost, #r.text))
    print(r.text:sub(1, 200))
else
    print("error", err.kind, err.message)
end
