--[[--
Parser for Calibre's .metadata.calibre sidecar files.

NOTE: requires plugins/calibre.koplugin/metadata.lua to include "languages"
in its used_metadata list so the field is preserved in the sidecar. In the repository is my modded version, but be advised i will not check constantly if they fixed a bug :D

@module pdfmeta.calibremetadata
--]]

local logger = require("logger")

local CalibreMetadata = {}

CalibreMetadata.SIDECAR_NAME = ".metadata.calibre"

--- Locate the nearest .metadata.calibre for *pdf_path*.
-- Checks the PDF's own directory first, then one level up (Calibre places
-- the file at the library root when books are in sub-folders).
--
-- @param pdf_path string
-- @return string|nil  absolute path to sidecar, or nil
function CalibreMetadata.findSidecar(pdf_path)
    local dir = pdf_path:match("^(.*)/[^/]+$") or "."

    local function try(folder)
        local candidate = folder .. "/" .. CalibreMetadata.SIDECAR_NAME
        local f = io.open(candidate, "r")
        if f then f:close(); return candidate end
    end

    local found = try(dir)
    if found then return found end

    local parent = dir:match("^(.*)/[^/]+$")
    if parent then found = try(parent) end

    if not found then
        logger.dbg("CalibreMetadata: no sidecar found near", pdf_path)
    end
    return found
end

--- Minimal JSON parser for .metadata.calibre files.
-- Handles strings, numbers, booleans, null, nested arrays and objects.
--
-- @param text string
-- @return table|nil, string|nil
function CalibreMetadata.parseJSON(text)
    if not text or text == "" then
        return nil, "empty input"
    end

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

    local parseValue, parseObject, parseArray  -- forward declarations

    local function parseString()
        pos = pos + 1  -- skip opening "
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
                    local cp = tonumber(text:sub(pos+1, pos+4), 16)
                    if cp then
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
        return nil  -- unterminated
    end

    local function parseNumber()
        local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not s then return nil end
        local num = tonumber(text:sub(s, e))
        pos = e + 1
        return num
    end

    local JSON_NULL = {}  -- sentinel distinct from nil

    parseArray = function()
        pos = pos + 1  -- skip [
        local arr = {}
        skipWS()
        if peek() == ']' then pos = pos + 1; return arr end
        while true do
            local v = parseValue()
            if v ~= JSON_NULL then arr[#arr+1] = v end  -- drop nulls
            skipWS()
            local ch = peek()
            if     ch == ']' then pos = pos + 1; break
            elseif ch == ',' then pos = pos + 1
            else break
            end
        end
        return arr
    end

    parseObject = function()
        pos = pos + 1  -- skip {
        local obj = {}
        skipWS()
        if peek() == '}' then pos = pos + 1; return obj end
        while true do
            if peek() ~= '"' then break end
            local key = parseString()
            skipWS()
            if peek() == ':' then pos = pos + 1 end
            local val = parseValue()
            if key and val ~= JSON_NULL then obj[key] = val end
            skipWS()
            local ch = peek()
            if     ch == '}' then pos = pos + 1; break
            elseif ch == ',' then pos = pos + 1
            else break
            end
        end
        return obj
    end

    parseValue = function()
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
    if not ok then return nil, tostring(result) end
    return result, nil
end

--- Read and parse the .metadata.calibre file.
--
-- @param sidecar_path string
-- @return table|nil
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

--- Find the record matching *pdf_path* inside *records*.
-- Matches on filename, then verifies the full lpath suffix to handle
-- libraries with identically named books in different sub-folders.
--
-- @param records  table
-- @param pdf_path string
-- @return table|nil
function CalibreMetadata.findRecord(records, pdf_path)
    local filename = pdf_path:match("[^/]+$")
    if not filename then return nil end
    local filename_lower = filename:lower()

    for _, record in ipairs(records) do
        local lpath = record.lpath
        if type(lpath) == "string" then
            local lpath_file = lpath:match("[^/]+$") or lpath
            if lpath_file:lower() == filename_lower then
                if pdf_path:sub(-#lpath):lower() == lpath:lower() then
                    return record
                end
                return record  -- filename match is sufficient for most cases
            end
        end
    end

    logger.dbg("CalibreMetadata: no record found for", filename)
    return nil
end

--- Return Calibre metadata for *pdf_path* from the nearest .metadata.calibre.
--
-- @param pdf_path string
-- @return table  { series, series_index, language } — absent fields are nil
function CalibreMetadata.getMetadata(pdf_path)
    local result = {}

    local sidecar = CalibreMetadata.findSidecar(pdf_path)
    if not sidecar then return result end

    local records = CalibreMetadata.readSidecar(sidecar)
    if not records then return result end

    local record = CalibreMetadata.findRecord(records, pdf_path)
    if not record then return result end

    if type(record.series) == "string" and record.series ~= "" then
        result.series = record.series
    end
    if record.series_index ~= nil then
        result.series_index = tonumber(record.series_index) or record.series_index
    end
    -- "languages" is an array; take the first valid entry.
    if type(record.languages) == "table" then
        for _, v in ipairs(record.languages) do
            if type(v) == "string" and v ~= "" and v ~= "und" then
                result.language = v
                break
            end
        end
    end

    logger.dbg("CalibreMetadata.getMetadata:", result)
    return result
end

return CalibreMetadata
