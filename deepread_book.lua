-- Deep Read books on disk: the launcher, one EPUB per article, and a hidden sidecar
-- per article holding what the service needs to continue it.

local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local DeepReadCover = require("deepread_cover")
local DeepReadMarkdown = require("deepread_markdown")
local Zip = require("deepread_zip")

local Book = {
    FOLDER = "Deep Read",
    LAUNCHER = "Deep Read.epub",
}

local function xmlEscape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local CONTAINER = [[
<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

-- Writes an EPUB 2 with a single text file. One file keeps the article one continuous
-- flow: crengine starts every spine item on a new page, which would leave a part-empty
-- page at each chunk boundary. Written to a .tmp and renamed, so a failure never
-- leaves a broken book behind.
local function writeEpub(path, meta, body_html, cover_png)
    local title = xmlEscape(meta.title)
    -- The mimetype entry must come first and be stored uncompressed; every entry is.
    local entries = {
        { "mimetype", "application/epub+zip" },
        { "META-INF/container.xml", CONTAINER },
        { "OEBPS/content.opf", string.format([[
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:creator>Deep Read</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="bookid">%s</dc:identifier>
    %s
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
    %s
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]], title, xmlEscape(meta.id),
            cover_png and [[<meta name="cover" content="cover-image"/>]] or "",
            cover_png and [[<item id="cover-image" href="cover.png" media-type="image/png"/>]] or "") },
        { "OEBPS/toc.ncx", string.format([[
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="%s"/></head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    <navPoint id="content" playOrder="1"><navLabel><text>%s</text></navLabel><content src="content.xhtml"/></navPoint>
  </navMap>
</ncx>
]], xmlEscape(meta.id), title, title) },
        { "OEBPS/content.xhtml", string.format([[
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title>%s</head>
<body>
%s
</body>
</html>
]], title, meta.css and ("<style>" .. meta.css .. "</style>") or "", body_html) },
    }
    if cover_png then
        table.insert(entries, { "OEBPS/cover.png", cover_png })
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(Zip.build(entries))
    f:close()
    if not ok then
        os.remove(tmp)
        return false
    end
    return os.rename(tmp, path)
end

function Book.folder(home)
    return home:gsub("/+$", "") .. "/" .. Book.FOLDER
end

function Book.isLauncher(path)
    return path:sub(-#(Book.FOLDER .. "/" .. Book.LAUNCHER)) == Book.FOLDER .. "/" .. Book.LAUNCHER
end

-- The launcher page mirrors the website's start page. Its links go to the website, so a
-- reader without the plugin still lands somewhere useful; main.lua intercepts them.
Book.LAUNCHER_LINK = "https://deepread.toolbox.md/"
local LAUNCHER_VERSION = "2" -- bump to rewrite existing launchers with a new page
local LAUNCHER_CSS = [[
.start { margin-top: 5em; text-align: center; }
h1 { font-size: 2.6em; font-weight: bold; margin: 0; text-align: center; }
p { text-indent: 0; }
.tagline { font-style: italic; color: #555555; margin: 0.8em 0 2.2em 0; text-align: center; }
a { color: inherit; text-decoration: none; }
.field { border: 1px solid #555555; padding: 0.8em 1em; margin: 0 0 0.6em 0; text-align: left; color: #666666; }
.read { border: 1px solid #000000; padding: 0.7em 1em; margin: 0 auto; width: 5em; text-align: center; font-weight: bold; }
]]

local function markerPath(folder)
    return folder .. "/." .. Book.LAUNCHER .. ".version"
end

-- False for a launcher written by an older version of the plugin.
function Book.launcherIsCurrent(home)
    local f = io.open(markerPath(Book.folder(home)), "rb")
    local version = f and f:read("*a")
    if f then f:close() end
    return version == LAUNCHER_VERSION
end

-- Creates <home>/Deep Read/Deep Read.epub, and rewrites an older launcher when
-- may_rewrite is set (never while the launcher could be open in the reader).
function Book.ensureLauncher(home, cover_path, may_rewrite)
    local folder = Book.folder(home)
    local path = folder .. "/" .. Book.LAUNCHER
    if lfs.attributes(path, "mode") == "file" and (not may_rewrite or Book.launcherIsCurrent(home)) then
        return path
    end
    if lfs.attributes(folder, "mode") ~= "directory" and not lfs.mkdir(folder) then return end
    local cover
    local f = io.open(cover_path, "rb")
    if f then
        cover = f:read("*a")
        f:close()
    end
    local link = Book.LAUNCHER_LINK
    if writeEpub(path, { title = "Deep Read", id = "deepread-launcher", css = LAUNCHER_CSS }, [[
<div class="start">
<h1>Deep Read</h1>
<p class="tagline">One topic. As deep as you care to read.</p>
<p class="field"><a href="]] .. link .. [[#topic">What do you want to understand?</a></p>
<p class="read"><a href="]] .. link .. [[#read">Read</a></p>
</div>]], cover) then
        f = io.open(markerPath(folder), "wb")
        if f then
            f:write(LAUNCHER_VERSION)
            f:close()
        end
    end
    return path
end

-- A new file name in the Deep Read folder for this topic.
function Book.newArticlePath(folder, topic)
    -- The suffix keeps a "." in the topic from being taken for an extension.
    local name = util.getSafeFilename(topic .. ".epub", folder, 80):gsub("%.epub$", ""):gsub("^%.+", "")
    local path = folder .. "/" .. name .. ".epub"
    local n = 2
    while lfs.attributes(path, "mode") do
        path = string.format("%s/%s (%d).epub", folder, name, n)
        n = n + 1
    end
    return path
end

-- Hidden next to the book, so the file browser does not list it.
local function sidecarPath(path)
    local dir, file = util.splitFilePathName(path)
    return dir .. "." .. file .. ".deepread.lua"
end

-- The article's state ({id, topic, turns = {{text, asked}}, built}) or nil if this
-- book is not a Deep Read article. built is how many turns the EPUB holds.
function Book.loadState(path)
    local sidecar = sidecarPath(path)
    if lfs.attributes(sidecar, "mode") ~= "file" then return end
    local settings = LuaSettings:open(sidecar)
    local state = settings:readSetting("article")
    if type(state) == "table" and type(state.turns) == "table" then return state end
end

function Book.saveState(path, state)
    local settings = LuaSettings:open(sidecarPath(path))
    settings:saveSetting("article", state)
    settings:flush()
end

function Book.write(path, state)
    local texts = {}
    for i, turn in ipairs(state.turns) do
        texts[i] = turn.text
    end
    local title = Book.title(state)
    -- A cover that fails to render must not cost the reader a chunk.
    local ok, cover = pcall(DeepReadCover.png, title)
    return writeEpub(path, { title = title, id = state.id },
        DeepReadMarkdown.toXhtml(table.concat(texts, "\n\n")), ok and cover or nil)
end

-- The article's own heading (the first chunk opens with "# Title"), else the topic.
function Book.title(state)
    local first = state.turns[1] and state.turns[1].text or ""
    local heading = first:match("^%s*#%s+([^\n]+)")
    heading = heading and heading:gsub("[*_`]", ""):gsub("%s+$", "")
    return heading ~= "" and heading or state.topic
end

return Book
