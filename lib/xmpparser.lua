--[[--
XMP metadata parser for PDF files.

Extracts Calibre-specific metadata (series, series_index, language) from
the XMP packet embedded in a PDF without loading the entire file into memory.

@module pdfmeta.xmpparser
--]]

local logger = require("logger")

local XMPParser = {}

--- Read a chunk from the beginning and end of a file.
-- For PDFs up to ~200MB, the XMP packet is almost always in the first
-- 512 KB (written by Calibre right after the PDF header / catalog).
-- If not found there we also check the last 512 KB as a fallback.
local CHUNK_SIZE = 512 * 1024 -- 512 KB

--- Extract the raw XMP packet string from a PDF file.
-- Reads only the first and (if needed) last CHUNK_SIZE bytes so that
-- large files are never fully loaded into memory.
--
-- @param pdf_path string: absolute path to the PDF file
-- @return string|nil: raw XMP XML string, or nil if not found
function XMPParser.extractRawXMP(pdf_path)
    local f = io.open(pdf_path, "rb")
    if not f then
        logger.dbg("XMPParser: cannot open file", pdf_path)
        return nil
    end

    -- Try the first chunk
    local head = f:read(CHUNK_SIZE)
    local xmp = head and head:match("(<x:xmpmeta.->%s*<%?xpacket%s+end.->)")
    if not xmp then
        -- Also try a simpler boundary used by some PDF writers
        xmp = head and head:match("(<%?xpacket%s+begin.->.-<%?xpacket%s+end.->)")
    end

    if not xmp then
        -- Fall back: check the last chunk
        local size = f:seek("end", 0)
        local tail_start = math.max(0, size - CHUNK_SIZE)
        f:seek("set", tail_start)
        local tail = f:read(CHUNK_SIZE)
        xmp = tail and tail:match("(<x:xmpmeta.->%s*<%?xpacket%s+end.->)")
        if not xmp then
            xmp = tail and tail:match("(<%?xpacket%s+begin.->.-<%?xpacket%s+end.->)")
        end
    end

    f:close()

    if not xmp then
        logger.dbg("XMPParser: no XMP packet found in", pdf_path)
    end

    return xmp
end

--- Extract a simple element value from XMP XML using pattern matching.
-- Handles both  <ns:Tag>value</ns:Tag>  and  <ns:Tag rdf:parseType="...">value</ns:Tag>.
--
-- @param xmp string: raw XMP XML
-- @param ns  string: namespace prefix, e.g. "calibre" or "dc"
-- @param tag string: element name, e.g. "series"
-- @return string|nil
local function extractElement(xmp, ns, tag)
    -- Simple open/close tag
    local pattern = "<" .. ns .. ":" .. tag .. "[^>]*>%s*(.-)%s*</" .. ns .. ":" .. tag .. ">"
    local value = xmp:match(pattern)
    if value and value ~= "" then
        return value
    end
    return nil
end

--- Extract a value from an rdf:Alt / rdf:Seq / rdf:Bag list (takes first item).
--
-- @param xmp string: raw XMP XML
-- @param ns  string: namespace prefix
-- @param tag string: element name
-- @return string|nil
local function extractListElement(xmp, ns, tag)
    -- Find the outer element first
    local outer = xmp:match("<" .. ns .. ":" .. tag .. "[^>]*>(.-)</" .. ns .. ":" .. tag .. ">")
    if not outer then return nil end
    -- Grab the first rdf:li
    local item = outer:match("<rdf:li[^>]*>%s*(.-)%s*</rdf:li>")
    return item ~= "" and item or nil
end

--- Decode basic XML character entities.
--
-- @param s string
-- @return string
local function decodeEntities(s)
    if not s then return s end
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    -- Numeric entities (decimal)
    s = s:gsub("&#(%d+);", function(n)
        return string.char(tonumber(n))
    end)
    return s
end

--- Parse Calibre metadata fields from a raw XMP string.
--
-- @param xmp string: raw XMP XML string
-- @return table: { series, series_index, language } — missing fields are nil
function XMPParser.parseCalibreFields(xmp)
    if not xmp then return {} end

    local result = {}

    -- calibre:series  (plain element)
    local series = extractElement(xmp, "calibre", "series")
    if series then
        result.series = decodeEntities(series)
    end

    -- calibre:series_index  (plain element, numeric)
    local series_index = extractElement(xmp, "calibre", "series_index")
    if series_index then
        result.series_index = tonumber(series_index) or series_index
    end

    -- dc:language — may be a plain element or inside rdf:Alt / rdf:Seq
    local language = extractElement(xmp, "dc", "language")
    if not language then
        language = extractListElement(xmp, "dc", "language")
    end
    if language then
        result.language = decodeEntities(language)
    end

    logger.dbg("XMPParser.parseCalibreFields result:", result)
    return result
end

--- High-level entry point: open a PDF and return its Calibre metadata.
--
-- @param pdf_path string: absolute path to the PDF
-- @return table: { series, series_index, language } — missing fields are nil
function XMPParser.getMetadata(pdf_path)
    local xmp = XMPParser.extractRawXMP(pdf_path)
    if not xmp then return {} end
    return XMPParser.parseCalibreFields(xmp)
end

return XMPParser
