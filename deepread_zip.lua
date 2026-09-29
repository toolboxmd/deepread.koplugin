-- Minimal zip writer with stored (uncompressed) entries, enough for an EPUB. KOReader's
-- own zip module changed name and API between releases (ffi/zipwriter in v2025.04,
-- ffi/archiver later), so the plugin writes the format itself.

local bit = require("bit")

local CRC_TABLE = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        c = bit.band(c, 1) == 1 and bit.bxor(0xEDB88320, bit.rshift(c, 1)) or bit.rshift(c, 1)
    end
    CRC_TABLE[i] = c
end

local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = bit.bxor(CRC_TABLE[bit.band(bit.bxor(c, data:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.bnot(c)
end

-- Little-endian unsigned integer of the given byte width.
local function le(n, width)
    local bytes = {}
    for i = 1, width do
        bytes[i] = string.char(bit.band(bit.rshift(n, 8 * (i - 1)), 0xFF))
    end
    return table.concat(bytes)
end

local Zip = {}

-- entries: { {name, data}, ... } in archive order. Returns the zip as a string.
function Zip.build(entries)
    local d = os.date("*t")
    local dos_time = le(d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2), 2)
    local dos_date = le((d.year - 1980) * 512 + d.month * 32 + d.day, 2)
    local body, central, offset = {}, {}, 0
    for _, entry in ipairs(entries) do
        local name, data = entry[1], entry[2]
        -- Shared by both headers: time, date, crc, sizes, name length, extra length.
        local fields = dos_time .. dos_date .. le(crc32(data), 4) .. le(#data, 4) .. le(#data, 4)
            .. le(#name, 2) .. le(0, 2)
        local header = "PK\3\4" .. le(20, 2) .. le(0, 2) .. le(0, 2) .. fields .. name
        table.insert(body, header)
        table.insert(body, data)
        -- Version made by, needed, flags, method, fields, then comment length, disk,
        -- internal and external attributes, and where the local header starts.
        table.insert(central, "PK\1\2" .. le(20, 2) .. le(20, 2) .. le(0, 2) .. le(0, 2) .. fields
            .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4) .. le(offset, 4) .. name)
        offset = offset + #header + #data
    end
    local directory = table.concat(central)
    table.insert(body, directory)
    table.insert(body, "PK\5\6" .. le(0, 2) .. le(0, 2) .. le(#entries, 2) .. le(#entries, 2)
        .. le(#directory, 4) .. le(offset, 4) .. le(0, 2))
    return table.concat(body)
end

return Zip
