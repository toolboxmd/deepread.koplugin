-- Client for the Deep Read service: POST /api/next, read the whole event stream,
-- return the chunk. Requests run in a forked subprocess so the UI never blocks.

local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_http = require("socket.http")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local ssl = require("ssl")
local https = require("ssl.https")

local Api = {
    -- The model can think for a while before the first word, and a chunk streams for
    -- tens of seconds, so the total budget is generous.
    block_timeout = 60,
    total_timeout = 180,
}

-- Split a text/event-stream body into its events and fold them into a result.
-- Returns {text, asked, words, cost} or nil, {kind = "server", message = ...}.
function Api.parseEventStream(body, decode)
    decode = decode or json.decode
    body = (body or ""):gsub("\r\n", "\n")
    local parts, done, failure = {}, nil, nil
    for block in (body .. "\n\n"):gmatch("(.-)\n\n") do
        local event, data = "message", {}
        for line in block:gmatch("[^\n]+") do
            local field, value = line:match("^(%a+):%s?(.*)$")
            if field == "event" then
                event = value
            elseif field == "data" then
                table.insert(data, value)
            end
        end
        if #data > 0 then
            local ok, payload = pcall(decode, table.concat(data, "\n"))
            if not ok or type(payload) ~= "table" then
                payload = {}
            end
            if event == "delta" and type(payload.text) == "string" then
                table.insert(parts, payload.text)
            elseif event == "done" then
                done = payload
            elseif event == "error" then
                failure = payload.message or "The writer stopped unexpectedly."
            end
        end
    end
    if failure or not done then
        return nil, { kind = "server", message = failure or "The writer stopped before finishing." }
    end
    return {
        text = table.concat(parts),
        asked = tonumber(done.asked),
        words = tonumber(done.words),
        cost = tonumber(done.cost),
    }
end

-- ssl.https refuses to work while socket.http.PROXY is set, and socket.http would send
-- an https request to the proxy in cleartext. So with a proxy we open a CONNECT tunnel
-- ourselves and hand socket.http a connection that already speaks TLS.
local function proxiedConnection(proxy)
    local auth = ""
    if proxy.user and proxy.password then
        local mime = require("mime")
        auth = "Proxy-Authorization: Basic " .. mime.b64(proxy.user .. ":" .. proxy.password) .. "\r\n"
    end
    return function()
        local conn = { sock = socket.tcp() }
        -- Everything we do not override goes to the current socket (plain, then TLS).
        setmetatable(conn, { __index = function(_, name)
            return function(self, ...)
                local sock = self.sock
                return sock[name](sock, ...)
            end
        end })
        function conn:connect(host, port)
            local ok, err = self.sock:connect(proxy.host, proxy.port)
            if not ok then return nil, err end
            ok, err = self.sock:send(string.format(
                "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n%s\r\n", host, port, host, port, auth))
            if not ok then return nil, err end
            local status = self.sock:receive("*l")
            if not status or not status:match("^HTTP/%d%.%d 2%d%d") then
                return nil, "proxy refused the tunnel: " .. tostring(status)
            end
            repeat
                local line = self.sock:receive("*l")
                if not line then return nil, "proxy closed the tunnel" end
            until line == ""
            local tls
            tls, err = ssl.wrap(self.sock, {
                mode = "client", protocol = "any",
                options = { "all", "no_sslv2", "no_sslv3" }, verify = "none",
            })
            if not tls then return nil, err end
            tls:sni(host)
            tls:settimeout(Api.block_timeout)
            ok, err = tls:dohandshake()
            if not ok then return nil, err end
            self.sock = tls
            return 1
        end
        return conn
    end
end

local function currentProxy()
    local proxy = socket_http.PROXY
    if type(proxy) ~= "string" or proxy == "" then return nil end
    local parsed = socket_url.parse(proxy, { scheme = "http" })
    if not parsed or not parsed.host then return nil end
    parsed.port = tonumber(parsed.port) or 3128
    return parsed
end

-- Blocking request. Call it inside a subprocess, not on the UI thread.
-- Returns the chunk, or nil and {kind = "out_of_credit" | "network" | "server", message}.
function Api.next(server, request)
    local body = json.encode(request)
    local sink = {}
    local reqt = {
        url = server:gsub("/+$", "") .. "/api/next",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "text/event-stream",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(sink),
    }
    socketutil:set_timeout(Api.block_timeout, Api.total_timeout)

    local transport = https
    local proxy = currentProxy()
    local saved_proxy = socket_http.PROXY
    if reqt.url:match("^http:") then
        transport = socket_http -- plain http honours the proxy by itself
    elseif proxy then
        transport = socket_http
        reqt.create = proxiedConnection(proxy)
        reqt.port = 443
        socket_http.PROXY = nil
    end
    local ok, res, code = pcall(transport.request, reqt)
    socket_http.PROXY = saved_proxy
    socketutil:reset_timeout()

    if not ok or not res then
        logger.warn("deepread: request failed", ok and code or res)
        return nil, { kind = "network", message = tostring(ok and code or res) }
    end
    local text = table.concat(sink)
    if code == 402 then
        return nil, { kind = "out_of_credit" }
    elseif code ~= 200 then
        local okj, err = pcall(json.decode, text)
        local message = okj and type(err) == "table" and err.error or ("HTTP " .. tostring(code))
        return nil, { kind = "server", message = message }
    end
    return Api.parseEventStream(text)
end

-- Run Api.next in a subprocess without blocking or trapping input, so the reader can keep
-- turning pages. on_done(result, err) runs on the UI thread. Returns a cancel function.
function Api.fetchInBackground(server, request, on_done)
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local result, err = Api.next(server, request)
        ffiutil.writeToFD(write_fd, buffer.encode({ result = result, err = err }), true)
    end, true)
    if not pid then
        UIManager:nextTick(function() on_done(nil, { kind = "server", message = tostring(read_fd) }) end)
        return function() end
    end

    local poll
    local finished = false
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(1, reap)
        end
    end
    local function cancel()
        if finished then return end
        finished = true
        UIManager:unschedule(poll)
        ffiutil.terminateSubProcess(pid)
        -- Reading drains the pipe so a child stuck in write() can exit, and closes our end.
        ffiutil.readAllFromFD(read_fd)
        UIManager:scheduleIn(1, reap)
    end
    poll = function()
        local exited = ffiutil.isSubProcessDone(pid)
        if not exited and ffiutil.getNonBlockingReadSize(read_fd) == 0 then
            UIManager:scheduleIn(0.5, poll)
            return
        end
        finished = true
        local ok, out = pcall(buffer.decode, ffiutil.readAllFromFD(read_fd))
        if not exited then UIManager:scheduleIn(1, reap) end
        if ok and type(out) == "table" and (out.result or out.err) then
            on_done(out.result, out.err)
        else
            on_done(nil, { kind = "server", message = "The request ended without a reply." })
        end
    end
    UIManager:scheduleIn(0.5, poll)
    return cancel
end

return Api
