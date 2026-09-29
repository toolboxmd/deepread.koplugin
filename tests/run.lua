-- Plain LuaJIT checks for the parts that do not need KOReader.
-- Usage: luajit tests/run.lua [path/to/koreader/.../lib/md.lua] [zip-output-path]
-- Needs lua-cjson for the JSON the real service sends.

package.path = "./?.lua;" .. package.path
local md_path = arg[1]

local stub = setmetatable({}, { __index = function(t) return t end, __call = function(t) return t end })
for _, name in ipairs({ "ui/uimanager", "logger", "ltn12", "socket", "socket.http",
                        "socket.url", "socketutil", "ssl", "ssl.https" }) do
    package.preload[name] = function() return stub end
end
-- md.lua only needs orderedPairs from ffi/util.
package.preload["ffi/util"] = function()
    return { orderedPairs = function(t)
        local keys = {}
        for k in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys)
        local i = 0
        return function() i = i + 1; return keys[i], t[keys[i]] end
    end }
end
local cjson = require("cjson")
package.preload["json"] = function() return { decode = cjson.decode, encode = cjson.encode } end
package.preload["apps/filemanager/lib/md"] = function()
    if md_path then return dofile(md_path) end
    return { renderString = function(s) return s end }
end

local Api = require("deepread_api")
local DeepReadMarkdown = require("deepread_markdown")
local Zip = require("deepread_zip")

local failures = 0
local function check(name, ok, detail)
    print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("  " .. tostring(detail))))
    if not ok then failures = failures + 1 end
end

-- Event stream in the service's own format (captured from the live API).
local stream = table.concat({
    "event: thinking\ndata: {}\n\n",
    'event: delta\ndata: {"text":"# How"}\n\n',
    'event: delta\ndata: {"text":" Lighthouses\\n\\nA beam"}\n\n',
    'event: done\ndata: {"asked":200,"words":233,"cost":0.0028864,"cached":1152,"prompt":1621}\n\n',
})
local r, err = Api.parseEventStream(stream)
check("parses deltas", r and r.text == "# How Lighthouses\n\nA beam", r and r.text or err and err.message)
check("keeps asked from done", r and r.asked == 200, r and r.asked)
check("keeps words and cost", r and r.words == 233 and math.abs(r.cost - 0.0028864) < 1e-9)

r = Api.parseEventStream((stream:gsub("\n", "\r\n")))
check("accepts CRLF", r and r.text == "# How Lighthouses\n\nA beam")

r, err = Api.parseEventStream('event: delta\ndata: {"text":"half"}\n\nevent: error\ndata: {"message":"The writer stopped unexpectedly."}\n\n')
check("error event is a server error", not r and err.kind == "server" and err.message == "The writer stopped unexpectedly.")

r, err = Api.parseEventStream('event: delta\ndata: {"text":"cut off"}\n\n')
check("missing done is a server error", not r and err.kind == "server")

r, err = Api.parseEventStream("")
check("empty body is a server error", not r and err.kind == "server")

local live = io.open("tests/live_sample.sse")
if live then
    r, err = Api.parseEventStream(live:read("*a"))
    live:close()
    check("parses captured live stream", r and #r.text > 100 and r.asked == 200, err and err.message)
end

check("inline math", DeepReadMarkdown.stripMath("speed \\( v = d / t \\) here") == "speed v = d / t here")
check("display math", DeepReadMarkdown.stripMath("see\n\\[\nE = mc^2\n\\]\nok") == "see\nE = mc^2\nok")
check("two inline spans", DeepReadMarkdown.stripMath("\\(a\\) and \\(b\\)") == "a and b")
check("leaves other backslashes", DeepReadMarkdown.stripMath("C:\\path") == "C:\\path")

-- CRC-32 check value for "123456789" is 0xCBF43926, at bytes 15-18 of the local header.
local zip = Zip.build({ { "mimetype", "123456789" } })
check("zip starts with a local header", zip:sub(1, 4) == "PK\3\4")
check("zip crc32", zip:sub(15, 18) == "\38\57\244\203", ("%q"):format(zip:sub(15, 18)))
check("zip stores the data", zip:find("mimetype123456789", 1, true) == 31)
check("zip ends with the directory end record", zip:sub(-22, -19) == "PK\5\6")
if arg[2] then
    local f = assert(io.open(arg[2], "wb"))
    f:write(Zip.build({ { "mimetype", "application/epub+zip" }, { "a/b.txt", ("x"):rep(70000) } }))
    f:close()
end

if md_path then
    local html = DeepReadMarkdown.toXhtml("# Title\n\nSome *text* with \\( x^2 \\).")
    check("renders heading", html:find("<h1>Title</h1>", 1, true), html)
    check("renders emphasis", html:find("<em>text</em>", 1, true), html)
    check("math shown as plain text", html:find("x^2", 1, true) and not html:find("\\(", 1, true), html)
    html = DeepReadMarkdown.toXhtml("if x<y & y>z")
    check("escapes < and &", html:find("x&lt;y &amp; y>z", 1, true), html)
    html = DeepReadMarkdown.toXhtml("one\n\n---\n\ntwo")
    check("closes void elements", html:find("<hr/>", 1, true) and not html:find("<hr>", 1, true), html)
else
    print("skip Markdown rendering (no md.lua path given)")
end

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
