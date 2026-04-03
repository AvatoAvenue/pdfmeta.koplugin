--[[--
Parser for Calibre's .metadata.calibre sidecar files.

Calibre writes a JSON array to <folder>/.metadata.calibre when it syncs
a library to a device.  Each entry describes one book and contains at
least:

    {
        "lpath":        "relative/path/to/book.pdf",
        "series":       "Foundation",
        "series_index": 1.0,
        "authors":      ["Isaac Asimov"],
        "tags":         ["Science Fiction"],
        ...
    }

This module finds that file, parses it, and returns the relevant fields
for a given PDF path.

@module pdfmeta.calibremetadata
--]]

local logger = require("logger")

local CalibreMetadata = {}

--- Name of the sidecar file Calibre writes on the device.
CalibreMetadata.SIDECAR_NAME = ".metadata.calibre"

--- Locate the nearest .metadata.calibre file for *pdf_path*.
-- Searches the directory that contains the PDF, then walks up one level
-- (Calibre sometimes places the file at the library root rather than in
-- the sub-folder).
--
-- @param pdf_path string: absolute path to the PDF
-- @return string|nil: absolute path to .metadata.calibre, or nil
function CalibreMetadata.findSidecar(pdf_path)
    -- Directory containing the PDF
    local dir = pdf_path:match("^(.*)/[^/]+$") or "."

    local function try(folder)
        local candidate = folder .. "/" .. CalibreMetadata.SIDECAR_NAME
        local f = io.open(candidate, "r")
        if f then
            f:close()
            return candidate
        end
        return nil
    end

    local found = try(dir)
    if found then return found end

    -- One level up
    local parent = dir:match("^(.*)/[^/]+$")
    if parent then
        found = try(parent)
    end

    if not found then
        logger.dbg("CalibreMetadata: no sidecar found near", pdf_path)
    end
    return found
end

--- Minimal JSON array parser sufficient for .metadata.calibre files.
-- Returns a Lua table (array of record-tables).
-- Only handles the subset of JSON that Calibre actually produces:
--   * string, number, boolean, null values
--   * flat arrays of strings/numbers
--   * nested objects one level deep
--
-- @param text string: raw JSON text
-- @return table|nil, string|nil: parsed array or nil + error message
function CalibreMetadata.parseJSON(text)
    if not text or text == "" then
        return nil, "empty input"
    end

    -- ------------------------------------------------------------------ --
    -- Tiny recursive-descent JSON parser                                  --
    -- ------------------------------------------------------------------ --
    local pos = 1
    local len = #text

    local function skipWS()
        while pos <= len and text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local function peek()
        skipWS()
        return text:sub(pos, pos)
    end

    local parseValue  -- forward declaration
    local parseObject -- forward declaration
    local parseArray  -- forward declaration

    local function parseString()
        -- pos is on the opening "
        pos = pos + 1 -- skip "
        local buf = {}
        while pos <= len do
            local ch = text:sub(pos, pos)
            if ch == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif ch == '\\' then
                pos = pos + 1
                local esc = text:sub(pos, pos)
                if     esc == '"'  then buf[#buf+1] = '"'
                elseif esc == '\\' then buf[#buf+1] = '\\'
                elseif esc == '/'  then buf[#buf+1] = '/'
                elseif esc == 'n'  then buf[#buf+1] = '\n'
                elseif esc == 'r'  then buf[#buf+1] = '\r'
                elseif esc == 't'  then buf[#buf+1] = '\t'
                elseif esc == 'b'  then buf[#buf+1] = '\b'
                elseif esc == 'f'  then buf[#buf+1] = '\f'
                elseif esc == 'u'  then
                    -- \uXXXX — grab codepoint, basic BMP only
                    local hex = text:sub(pos+1, pos+4)
                    local cp  = tonumber(hex, 16)
                    if cp then
                        -- Encode as UTF-8
                        if cp < 0x80 then
                            buf[#buf+1] = string.char(cp)
                        elseif cp < 0x800 then
                            buf[#buf+1] = string.char(
                                0xC0 + math.floor(cp / 0x40),
                                0x80 + (cp % 0x40))
                        else
                            buf[#buf+1] = string.char(
                                0xE0 + math.floor(cp / 0x1000),
                                0x80 + math.floor((cp % 0x1000) / 0x40),
                                0x80 + (cp % 0x40))
                        end
                    end
                    pos = pos + 4
                end
                pos = pos + 1
            else
                buf[#buf+1] = ch
                pos = pos + 1
            end
        end
        return nil  -- unterminated string
    end

    local function parseNumber()
        local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not s then return nil end
        local num = tonumber(text:sub(s, e))
        pos = e + 1
        return num
    end

    -- Sentinel for JSON null — distinct from a missing value
    local JSON_NULL = {}

    parseArray = function()
        pos = pos + 1 -- skip [
        local arr = {}
        skipWS()
        if peek() == ']' then pos = pos + 1; return arr end
        while true do
            skipWS()
            local v = parseValue()
            -- Skip JSON null entries inside arrays (don't create nil holes)
            if v ~= JSON_NULL then
                arr[#arr+1] = v
            end
            skipWS()
            local ch = peek()
            if ch == ']' then pos = pos + 1; break
            elseif ch == ',' then pos = pos + 1
            else break
            end
        end
        return arr
    end

    parseObject = function()
        pos = pos + 1 -- skip {
        local obj = {}
        skipWS()
        if peek() == '}' then pos = pos + 1; return obj end
        while true do
            skipWS()
            if peek() ~= '"' then break end
            local key = parseString()
            skipWS()
            if peek() == ':' then pos = pos + 1 end
            skipWS()
            local val = parseValue()
            -- Store JSON null as nil (key absent) — that's fine for our use
            if key and val ~= JSON_NULL then
                obj[key] = val
            end
            skipWS()
            local ch = peek()
            if ch == '}' then pos = pos + 1; break
            elseif ch == ',' then pos = pos + 1
            else break
            end
        end
        return obj
    end

    parseValue = function()
        skipWS()
        local ch = peek()
        if     ch == '"' then return parseString()
        elseif ch == '{' then return parseObject()
        elseif ch == '[' then return parseArray()
        elseif ch == 't' then pos = pos + 4; return true
        elseif ch == 'f' then pos = pos + 5; return false
        elseif ch == 'n' then pos = pos + 4; return JSON_NULL
        else                  return parseNumber()
        end
    end

    local ok, result = pcall(parseValue)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

--- Read and parse a .metadata.calibre file.
--
-- @param sidecar_path string: absolute path to the sidecar file
-- @return table|nil: array of book-record tables, or nil on error
function CalibreMetadata.readSidecar(sidecar_path)
    local f = io.open(sidecar_path, "r")
    if not f then
        logger.dbg("CalibreMetadata: cannot open", sidecar_path)
        return nil
    end
    local text = f:read("*a")
    f:close()

    local records, err = CalibreMetadata.parseJSON(text)
    if not records then
        logger.dbg("CalibreMetadata: JSON parse error in", sidecar_path, err)
        return nil
    end
    if type(records) ~= "table" then
        logger.dbg("CalibreMetadata: expected JSON array in", sidecar_path)
        return nil
    end
    return records
end

--- Find the record in *records* that matches *pdf_path*.
-- Calibre stores relative paths in the "lpath" field using forward slashes.
-- We match on the filename portion first, then verify the full lpath suffix
-- to avoid false matches when multiple books share a filename.
--
-- @param records  table:  array from readSidecar
-- @param pdf_path string: absolute path to the PDF
-- @return table|nil: matching record, or nil
function CalibreMetadata.findRecord(records, pdf_path)
    local filename = pdf_path:match("[^/]+$")
    if not filename then return nil end
    local filename_lower = filename:lower()

    for _, record in ipairs(records) do
        local lpath = record.lpath
        if type(lpath) == "string" then
            local lpath_file = lpath:match("[^/]+$") or lpath
            if lpath_file:lower() == filename_lower then
                -- Verify the suffix matches to handle duplicates
                local suffix = lpath:gsub("/", "/")  -- normalise (no-op here)
                if pdf_path:sub(-#suffix):lower() == suffix:lower() then
                    return record
                end
                -- Fallback: filename match alone is enough for most libraries
                return record
            end
        end
    end

    logger.dbg("CalibreMetadata: no record found for", filename)
    return nil
end

--- Extract the language code from a Calibre book record.
-- Handles all serialisation variants Calibre produces.
-- @param record table: one entry from .metadata.calibre
-- @return string|nil
local function extractLanguage(record)
    -- Standard: "languages": ["spa"]  or  ["spa", "eng"]
    if type(record.languages) == "table" then
        for _, v in ipairs(record.languages) do
            if type(v) == "string" and v ~= "" and v ~= "und" then
                return v
            end
        end
    end
    -- Legacy singular field
    if type(record.language) == "string"
            and record.language ~= "" and record.language ~= "und" then
        return record.language
    end
    return nil
end

--- High-level entry point: return Calibre metadata for *pdf_path*.
--
-- Priority:
--   1. .metadata.calibre sidecar (fast, no PDF I/O)
--   2. XMP packet embedded in the PDF  (fallback for any missing field)
--   3. PDF /Lang catalog entry         (last-resort language fallback)
--
-- @param pdf_path string: absolute path to the PDF
-- @return table: { series, series_index, language } — absent fields are nil
function CalibreMetadata.getMetadata(pdf_path)
    local result = {}

    -- ---- Step 1: .metadata.calibre sidecar ----------------------------------
    local sidecar  = CalibreMetadata.findSidecar(pdf_path)
    local record

    if sidecar then
        local records = CalibreMetadata.readSidecar(sidecar)
        if records then
            record = CalibreMetadata.findRecord(records, pdf_path)
        end
    end

    if record then
        if type(record.series) == "string" and record.series ~= "" then
            result.series = record.series
        end
        if record.series_index ~= nil then
            result.series_index = tonumber(record.series_index) or record.series_index
        end
        local lang = extractLanguage(record)
        if lang then result.language = lang end
    end

    -- ---- Step 2 & 3: XMP / /Lang fallback for any still-missing field -------
    -- Only open the PDF if something is still missing.
    local need_xmp = not result.series or not result.series_index or not result.language
    if need_xmp then
        local ok, XMPParser = pcall(require, "xmpparser")
        if ok and XMPParser then
            local xmp_meta = XMPParser.getMetadata(pdf_path)

            if not result.series and xmp_meta.series then
                result.series = xmp_meta.series
                logger.dbg("CalibreMetadata: series from XMP:", result.series)
            end
            if not result.series_index and xmp_meta.series_index then
                result.series_index = xmp_meta.series_index
                logger.dbg("CalibreMetadata: series_index from XMP:", result.series_index)
            end
            if not result.language and xmp_meta.language then
                result.language = xmp_meta.language
                logger.dbg("CalibreMetadata: language from XMP:", result.language)
            end
        else
            logger.dbg("CalibreMetadata: xmpparser not available:", tostring(XMPParser))
        end
    end

    logger.dbg("CalibreMetadata.getMetadata final result:", result)
    return result
end

return CalibreMetadata
