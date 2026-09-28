-- Article Markdown to HTML with KOReader's bundled renderer.

local Markdown = require("apps/filemanager/lib/md")

local M = {}

-- There is no math renderer on the device, so \( x \) and \[ x \] become plain x.
function M.stripMath(text)
    text = text:gsub("\\%[%s*(.-)%s*\\%]", "%1")
    text = text:gsub("\\%(%s*(.-)%s*\\%)", "%1")
    return text
end

function M.toHtml(text)
    -- md.lua passes raw text through, so "x<y" would open a tag. Escaping before
    -- rendering is safe because md.lua never escapes anything itself.
    text = M.stripMath(text or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
    local ok, html = pcall(Markdown.renderString, text, { tag = "div" })
    if ok and type(html) == "string" then
        return html
    end
    return "<pre>" .. text .. "</pre>"
end

return M
