--[[--
XMP metadata parser for PDF files.

Extracts Calibre-specific metadata (series, series_index, language) from
the XMP packet embedded in a PDF without loading the entire file into memory.

Handles all known serialisation forms Calibre and PDF producers use:

  Attribute form (compact RDF):
    <rdf:Description calibre:series="X" calibre:series_index="1" dc:language="es" .../>

  Element form with rdf:Bag / rdf:Seq / rdf:Alt:
    <dc:language><rdf:Bag><rdf:li>es</rdf:li></rdf:Bag></dc:language>

  Plain element form:
    <dc:language>es</dc:language>
    <calibre:series>Foundation</calibre:series>

@module pdfmeta.xmpparser
--]]

local logger = require("logger")

local XMPParser = {}

local CHUNK_SIZE = 512 * 1024 -- 512 KB

-- ---------------------------------------------------------------------------
-- XMP packet extraction
-- ---------------------------------------------------------------------------

--- Extract the raw XMP packet string from a PDF file.
-- Reads only the first and (if needed) last CHUNK_SIZE bytes.
--
-- @param pdf_path string
-- @return string|nil
function XMPParser.extractRawXMP(pdf_path)
    local f = io.open(pdf_path, "rb")
    if not f then
        logger.dbg("XMPParser: cannot open", pdf_path)
        return nil
    end

    local function findXMP(chunk)
        if not chunk then return nil end

        -- Find start marker: <?xpacket begin= ...
        -- or <x:xmpmeta  (some producers omit the outer xpacket wrapper)
        local s1, e1 = chunk:find("<%?xpacket%s+begin")
        local s2, e2 = chunk:find("<x:xmpmeta")
        local start_pos = nil
        if s1 and s2 then
            start_pos = math.min(s1, s2)
        else
            start_pos = s1 or s2
        end
        if not start_pos then return nil end

        -- Find end marker: <?xpacket end=
        local end_marker = chunk:find("<%?xpacket%s+end", start_pos)
        if not end_marker then return nil end

        -- Advance past the end marker to include the full closing PI
        local close = chunk:find("%?>", end_marker)
        local end_pos = close and (close + 1) or (#chunk)

        return chunk:sub(start_pos, end_pos)
    end

    local head = f:read(CHUNK_SIZE)
    local xmp  = findXMP(head)

    if not xmp then
        local size = f:seek("end", 0)
        local tail_start = math.max(0, size - CHUNK_SIZE)
        f:seek("set", tail_start)
        xmp = findXMP(f:read(CHUNK_SIZE))
    end

    f:close()

    if not xmp then
        logger.dbg("XMPParser: no XMP packet found in", pdf_path)
    end
    return xmp
end

-- ---------------------------------------------------------------------------
-- Low-level XML helpers
-- ---------------------------------------------------------------------------

--- Decode basic XML character entities.
local function decodeEntities(s)
    if not s then return s end
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    s = s:gsub("&#(%d+);",  function(n) return string.char(tonumber(n)) end)
    s = s:gsub("&#x(%x+);", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

--- Trim leading/trailing whitespace.
local function trim(s)
    return s and s:match("^%s*(.-)%s*$") or s
end

-- ---------------------------------------------------------------------------
-- Field extraction — three strategies, tried in order
-- ---------------------------------------------------------------------------

--[[
Strategy 1: Attribute-style compact RDF.
  <rdf:Description ... calibre:series="Foundation" calibre:series_index="1.0"
                       dc:language="es" ...>
--]]
local function extractAttribute(xmp, ns, tag)
    -- namespace URI may appear as a different prefix; try both the known
    -- short prefix and any prefix bound to the namespace URI.
    -- For our purposes the prefix IS always "calibre" or "dc" in Calibre output.
    local pattern = ns .. ":" .. tag .. '%s*=%s*"([^"]*)"'
    local v = xmp:match(pattern)
    if not v then
        pattern = ns .. ":" .. tag .. "%s*=%s*'([^']*)'"
        v = xmp:match(pattern)
    end
    if v and v ~= "" then return decodeEntities(v) end
    return nil
end

--[[
Strategy 2: Plain element value.
  <calibre:series>Foundation</calibre:series>
  <dc:language>es</dc:language>
--]]
local function extractElement(xmp, ns, tag)
    local pattern = "<" .. ns .. ":" .. tag .. "[^>]*>%s*(.-)%s*</" .. ns .. ":" .. tag .. ">"
    local v = trim(xmp:match(pattern))
    -- Reject values that look like nested XML
    if v and v ~= "" and not v:find("^<") then
        return decodeEntities(v)
    end
    return nil
end

--[[
Strategy 3: Element containing rdf:Bag / rdf:Seq / rdf:Alt.
  <dc:language><rdf:Bag><rdf:li>es</rdf:li></rdf:Bag></dc:language>
  <dc:language><rdf:Alt><rdf:li xml:lang="x-default">es</rdf:li></rdf:Alt></dc:language>
  Returns the first non-empty rdf:li value.
--]]
local function extractListElement(xmp, ns, tag)
    -- Find the outer element block
    local outer = xmp:match("<" .. ns .. ":" .. tag .. "[^>]*>(.-)</" .. ns .. ":" .. tag .. ">")
    if not outer then return nil end
    -- Grab each rdf:li and return the first non-empty one
    for item in outer:gmatch("<rdf:li[^>]*>%s*(.-)%s*</rdf:li>") do
        item = trim(item)
        if item and item ~= "" and not item:find("^<") then
            return decodeEntities(item)
        end
    end
    return nil
end

--- Try all three strategies for a given namespace:tag.
local function extract(xmp, ns, tag)
    return extractAttribute(xmp, ns, tag)
        or extractListElement(xmp, ns, tag)
        or extractElement(xmp, ns, tag)
end

-- ---------------------------------------------------------------------------
-- PDF document-level language (/Lang entry)
-- ---------------------------------------------------------------------------

--[[
Some PDFs store the language in the document catalog as:
  /Lang (es)   or   /Lang (es-ES)
This is NOT XMP but is a reliable fallback for PDFs that have no dc:language
in their XMP.  We scan for it in the same head/tail chunk we already have.
--]]

--- Extract /Lang entry from raw PDF bytes.
-- @param pdf_path string
-- @return string|nil  e.g. "es", "en", "de"
function XMPParser.extractPDFLang(pdf_path)
    local f = io.open(pdf_path, "rb")
    if not f then return nil end

    local function findLang(chunk)
        if not chunk then return nil end
        -- /Lang (es)  /Lang (en-US)  /Lang(de)
        local lang = chunk:match("/Lang%s*%(([^%)]+)%)")
        if lang and lang ~= "" then
            -- Normalise: take only the primary subtag (e.g. "es" from "es-ES")
            return lang:match("^([a-zA-Z]+)")
        end
        return nil
    end

    local head = f:read(CHUNK_SIZE)
    local lang = findLang(head)

    if not lang then
        local size = f:seek("end", 0)
        f:seek("set", math.max(0, size - CHUNK_SIZE))
        lang = findLang(f:read(CHUNK_SIZE))
    end

    f:close()
    return lang
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Normalise an XMP string so that all patterns work across line boundaries.
-- Lua's '.' does not match '\n', so multi-line element content is invisible
-- to patterns like '(.-)'.  We collapse all whitespace runs (including
-- newlines) into a single space, which is safe because XMP/XML treats all
-- whitespace as equivalent in mixed content.
local function normaliseWS(s)
    -- Replace every sequence of whitespace (including \r, \n, \t) with a
    -- single space, then trim the ends.
    return s:gsub("%s+", " ")
end

--- Parse Calibre metadata fields from a raw XMP string.
-- Returns a table with series, series_index, language (nil if not found).
--
-- @param xmp string
-- @return table
function XMPParser.parseCalibreFields(xmp)
    if not xmp then return {} end

    -- Normalise whitespace so multi-line elements are matched by (.-) patterns.
    local flat = normaliseWS(xmp)

    local result = {}

    -- series
    local series = extract(flat, "calibre", "series")
    if series then result.series = series end

    -- series_index
    local si = extract(flat, "calibre", "series_index")
    if si then result.series_index = tonumber(si) or si end

    -- dc:language — try all three strategies; collect ALL rdf:li values and
    -- take the first one that is not "und" (indeterminate).
    -- We override extractListElement here to return ALL items so we can pick
    -- the best one (e.g. prefer "es" over "de" if the PDF has both).
    -- For now we just take the first non-"und" entry, which matches Calibre's
    -- own behaviour (it uses languages[0]).
    local lang = extract(flat, "dc", "language")
    if lang and lang ~= "und" and lang ~= "" then
        result.language = lang
    end

    logger.dbg("XMPParser.parseCalibreFields:", result)
    return result
end

--- High-level entry point: open a PDF and return its Calibre/XMP metadata
-- plus the PDF-level /Lang entry as a final language fallback.
--
-- @param pdf_path string
-- @return table  { series, series_index, language }
function XMPParser.getMetadata(pdf_path)
    local result = {}

    local xmp = XMPParser.extractRawXMP(pdf_path)
    if xmp then
        result = XMPParser.parseCalibreFields(xmp)
    end

    -- Language fallback: PDF /Lang entry
    if not result.language then
        local pdf_lang = XMPParser.extractPDFLang(pdf_path)
        if pdf_lang and pdf_lang ~= "" then
            result.language = pdf_lang
            logger.dbg("XMPParser: language from /Lang entry:", pdf_lang)
        end
    end

    return result
end

return XMPParser
