-- Article Markdown to XHTML with KOReader's bundled renderer.

local Markdown = require("apps/filemanager/lib/md")

local M = {}

-- There is no math renderer on the device, so \( x \) and \[ x \] become plain x.
function M.stripMath(text)
    text = text:gsub("\\%[%s*(.-)%s*\\%]", "%1")
    text = text:gsub("\\%(%s*(.-)%s*\\%)", "%1")
    return text
end

-- XHTML for the article's EPUB.
function M.toXhtml(text)
    -- md.lua passes raw text through, so "x<y" would open a tag. Escaping before
    -- rendering is safe because md.lua never escapes anything itself.
    text = M.stripMath(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
    local ok, html = pcall(Markdown.renderString, text, { tag = "div" })
    if not ok or type(html) ~= "string" then
        return "<pre>" .. text .. "</pre>"
    end
    -- md.lua leaves void elements open, which XML does not allow.
    return (html:gsub("<(hr)>", "<%1/>"):gsub("<(img [^>]-)/?>", "<%1/>"))
end

return M
