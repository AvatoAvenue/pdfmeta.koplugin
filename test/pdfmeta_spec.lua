require("test/mocks")

-- Make xmpparser available without the plugin's package.path manipulation
package.path = package.path .. ";./lib/?.lua"
local XMPParser = require("xmpparser")

-- ---------------------------------------------------------------------------
-- XMPParser unit tests
-- ---------------------------------------------------------------------------

describe("XMPParser.parseCalibreFields", function()

    -- Minimal XMP as Calibre actually writes it
    local SAMPLE_XMP = [[
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:calibre="http://calibre.kovidgoyal.net/2009/metadata"
        dc:language="es"
        calibre:series="Fundación"
        calibre:series_index="1.0">
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
    ]]

    -- XMP with dc:language inside an rdf:Alt list (another common form)
    local SAMPLE_XMP_LANG_LIST = [[
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:calibre="http://calibre.kovidgoyal.net/2009/metadata"
        calibre:series="Dune"
        calibre:series_index="2.0">
      <dc:language>
        <rdf:Alt>
          <rdf:li xml:lang="x-default">en</rdf:li>
        </rdf:Alt>
      </dc:language>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
    ]]

    local SAMPLE_XMP_ENTITIES = [[
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:calibre="http://calibre.kovidgoyal.net/2009/metadata"
        calibre:series="Tom &amp; Jerry Adventures"
        calibre:series_index="3.0">
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
    ]]

    it("parses series, series_index and language from attribute-style XMP", function()
        local meta = XMPParser.parseCalibreFields(SAMPLE_XMP)
        assert.equals("Fundación", meta.series)
        assert.equals(1.0,        meta.series_index)
        assert.equals("es",       meta.language)
    end)

    it("parses series_index as a number", function()
        local meta = XMPParser.parseCalibreFields(SAMPLE_XMP)
        assert.is_number(meta.series_index)
    end)

    it("parses dc:language from rdf:Alt list", function()
        local meta = XMPParser.parseCalibreFields(SAMPLE_XMP_LANG_LIST)
        assert.equals("Dune", meta.series)
        assert.equals(2.0,    meta.series_index)
        assert.equals("en",   meta.language)
    end)

    it("decodes XML entities in series name", function()
        local meta = XMPParser.parseCalibreFields(SAMPLE_XMP_ENTITIES)
        assert.equals("Tom & Jerry Adventures", meta.series)
    end)

    it("returns empty table for nil input", function()
        local meta = XMPParser.parseCalibreFields(nil)
        assert.is_table(meta)
        assert.is_nil(meta.series)
        assert.is_nil(meta.series_index)
        assert.is_nil(meta.language)
    end)

    it("returns empty table when no calibre fields present", function()
        local xmp = [[<?xpacket begin="" id="x"?><x:xmpmeta xmlns:x="adobe:ns:meta/"></x:xmpmeta><?xpacket end="w"?>]]
        local meta = XMPParser.parseCalibreFields(xmp)
        assert.is_nil(meta.series)
        assert.is_nil(meta.language)
    end)
end)

-- ---------------------------------------------------------------------------
-- PdfMeta integration: file scanning
-- ---------------------------------------------------------------------------

describe("PdfMeta file scanning", function()
    local test_root = "/tmp/pdfmeta_test"
    local subdir    = test_root .. "/sub"
    local PdfMeta   = require("main")

    before_each(function()
        os.execute("rm -rf " .. string.format("%q", test_root))
        os.execute("mkdir -p " .. string.format("%q", subdir))

        -- Create dummy PDF files (empty content is fine for path scanning)
        for _, p in ipairs({
            test_root .. "/book1.pdf",
            test_root .. "/book2.pdf",
            subdir    .. "/subbook.pdf",
            test_root .. "/notapdf.txt",  -- should be ignored
        }) do
            local f = io.open(p, "w")
            f:write("dummy")
            f:close()
        end
    end)

    after_each(function()
        os.execute("rm -rf " .. string.format("%q", test_root))
    end)

    it("finds PDFs in current folder only (non-recursive)", function()
        local files = PdfMeta:scanForPdfFiles(test_root, false)
        assert.equals(2, #files)
    end)

    it("finds PDFs recursively including subdirectories", function()
        local files = PdfMeta:scanForPdfFiles(test_root, true)
        assert.equals(3, #files)
    end)

    it("returns empty list when no PDFs exist", function()
        os.execute("rm -f " .. string.format("%q", test_root) .. "/*.pdf")
        os.execute("rm -f " .. string.format("%q", subdir)    .. "/*.pdf")
        local files = PdfMeta:scanForPdfFiles(test_root, true)
        assert.equals(0, #files)
    end)

    it("detects subdirectories correctly", function()
        assert.is_true(PdfMeta:hasSubdirectories(test_root))
        assert.is_false(PdfMeta:hasSubdirectories(subdir))
    end)
end)
