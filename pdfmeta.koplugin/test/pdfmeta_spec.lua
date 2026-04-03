require("test/mocks")

package.path = package.path .. ";./lib/?.lua"
local CalibreMetadata = require("calibremetadata")

-- ---------------------------------------------------------------------------
-- CalibreMetadata.parseJSON
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.parseJSON", function()

    it("parses series, series_index and languages", function()
        local json = [[
[
  {
    "lpath": "Author/Book.pdf",
    "series": "Foundation",
    "series_index": 1.0,
    "languages": ["es"],
    "authors": ["Isaac Asimov"]
  }
]
        ]]
        local records = CalibreMetadata.parseJSON(json)
        assert.is_table(records)
        assert.equals(1, #records)
        assert.equals("Foundation", records[1].series)
        assert.equals(1.0,          records[1].series_index)
        assert.equals("es",         records[1].languages[1])
    end)

    it("parses multiple records", function()
        local json = [[
[
  {"lpath": "a.pdf", "series": "Dune",       "series_index": 1},
  {"lpath": "b.pdf", "series": "Foundation", "series_index": 2}
]
        ]]
        local records = CalibreMetadata.parseJSON(json)
        assert.equals(2, #records)
        assert.equals("Dune",       records[1].series)
        assert.equals("Foundation", records[2].series)
    end)

    it("parses multiple languages and keeps all entries", function()
        local json = [[[ {"lpath": "a.pdf", "languages": ["de", "es"]} ]]]
        local records = CalibreMetadata.parseJSON(json)
        assert.equals("de", records[1].languages[1])
        assert.equals("es", records[1].languages[2])
    end)

    it("handles unicode escape sequences", function()
        local json = [[[ {"series": "Fundaci\u00f3n"} ]]]
        local records = CalibreMetadata.parseJSON(json)
        assert.equals("Fundaci\xC3\xB3n", records[1].series)
    end)

    it("returns nil for empty input", function()
        local result, err = CalibreMetadata.parseJSON("")
        assert.is_nil(result)
        assert.is_string(err)
    end)

    it("returns nil for nil input", function()
        local result = CalibreMetadata.parseJSON(nil)
        assert.is_nil(result)
    end)

    it("handles null values without crashing or creating nil holes", function()
        local json = [[[ {"flag": true, "missing": false, "nothing": null} ]]]
        local records = CalibreMetadata.parseJSON(json)
        assert.is_table(records)
        assert.is_true(records[1].flag)
        assert.is_false(records[1].missing)
        assert.is_nil(records[1].nothing)
    end)

    it("drops null entries inside arrays without creating holes", function()
        local json = [[[ {"languages": ["es", null, "de"]} ]]]
        local records = CalibreMetadata.parseJSON(json)
        local langs = records[1].languages
        assert.equals(2, #langs)
        assert.equals("es", langs[1])
        assert.equals("de", langs[2])
    end)

end)

-- ---------------------------------------------------------------------------
-- CalibreMetadata.findRecord
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.findRecord", function()

    local records = {
        { lpath = "Asimov/Foundation.pdf",   series = "Foundation", series_index = 1 },
        { lpath = "Herbert/Dune.pdf",         series = "Dune",       series_index = 1 },
        { lpath = "Herbert/Dune Messiah.pdf", series = "Dune",       series_index = 2 },
    }

    it("finds a record by filename", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Asimov/Foundation.pdf")
        assert.is_not_nil(rec)
        assert.equals("Foundation", rec.series)
    end)

    it("distinguishes records that share only a directory name", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Herbert/Dune Messiah.pdf")
        assert.is_not_nil(rec)
        assert.equals(2, rec.series_index)
    end)

    it("returns nil when no record matches", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Unknown/Other.pdf")
        assert.is_nil(rec)
    end)

    it("returns nil for an empty records table", function()
        local rec = CalibreMetadata.findRecord({}, "/books/Asimov/Foundation.pdf")
        assert.is_nil(rec)
    end)

end)

-- ---------------------------------------------------------------------------
-- CalibreMetadata.findSidecar
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.findSidecar", function()

    local base    = "/tmp/pdfmeta_sidecar_test"
    local subdir  = base .. "/Author"
    local sidecar = base .. "/.metadata.calibre"

    before_each(function()
        os.execute("mkdir -p " .. string.format("%q", subdir))
        local f = assert(io.open(sidecar, "w"))
        f:write("[]"); f:close()
    end)

    after_each(function()
        os.execute("rm -rf " .. string.format("%q", base))
    end)

    it("finds sidecar in the PDF's own directory", function()
        local local_sidecar = subdir .. "/.metadata.calibre"
        local f = assert(io.open(local_sidecar, "w"))
        f:write("[]"); f:close()
        assert.equals(local_sidecar,
            CalibreMetadata.findSidecar(subdir .. "/Book.pdf"))
    end)

    it("finds sidecar one level up when not present locally", function()
        assert.equals(sidecar,
            CalibreMetadata.findSidecar(subdir .. "/Book.pdf"))
    end)

    it("returns nil when no sidecar exists anywhere", function()
        os.remove(sidecar)
        assert.is_nil(CalibreMetadata.findSidecar(subdir .. "/Book.pdf"))
    end)

end)

-- ---------------------------------------------------------------------------
-- CalibreMetadata.getMetadata 
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.getMetadata", function()

    local base   = "/tmp/pdfmeta_e2e_test"
    local subdir = base .. "/Asimov"

    before_each(function()
        os.execute("mkdir -p " .. string.format("%q", subdir))
    end)

    after_each(function()
        os.execute("rm -rf " .. string.format("%q", base))
    end)

    local function writeSidecar(content)
        local f = assert(io.open(base .. "/.metadata.calibre", "w"))
        f:write(content); f:close()
    end

    local function touchPdf(name)
        local path = subdir .. "/" .. name
        local f = assert(io.open(path, "w"))
        f:write("dummy"); f:close()
        return path
    end

    it("returns series, series_index and language", function()
        writeSidecar([[
[{"lpath":"Asimov/Foundation.pdf","series":"Foundation","series_index":1.0,"languages":["es"]}]
        ]])
        local meta = CalibreMetadata.getMetadata(touchPdf("Foundation.pdf"))
        assert.equals("Foundation", meta.series)
        assert.equals(1.0,          meta.series_index)
        assert.equals("es",         meta.language)
    end)

    it("takes the first non-'und' language when multiple are present", function()
        writeSidecar([[
[{"lpath":"Asimov/Foundation.pdf","series":"Foundation","series_index":1,"languages":["de","es"]}]
        ]])
        local meta = CalibreMetadata.getMetadata(touchPdf("Foundation.pdf"))
        assert.equals("de", meta.language)
    end)

    it("skips 'und' language codes", function()
        writeSidecar([[
[{"lpath":"Asimov/Foundation.pdf","series":"Foundation","series_index":1,"languages":["und","es"]}]
        ]])
        local meta = CalibreMetadata.getMetadata(touchPdf("Foundation.pdf"))
        assert.equals("es", meta.language)
    end)

    it("returns empty table when no sidecar exists", function()
        local meta = CalibreMetadata.getMetadata(subdir .. "/NoSidecar.pdf")
        assert.is_table(meta)
        assert.is_nil(meta.series)
        assert.is_nil(meta.language)
    end)

    it("returns empty table when PDF is not in the sidecar", function()
        writeSidecar([[[ {"lpath": "Asimov/Other.pdf", "series": "X"} ]]])
        local meta = CalibreMetadata.getMetadata(subdir .. "/Foundation.pdf")
        assert.is_nil(meta.series)
    end)

    it("returns series_index as a number", function()
        writeSidecar([[
[{"lpath":"Asimov/Foundation.pdf","series":"Foundation","series_index":3}]
        ]])
        local meta = CalibreMetadata.getMetadata(touchPdf("Foundation.pdf"))
        assert.is_number(meta.series_index)
        assert.equals(3, meta.series_index)
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
        for _, p in ipairs({
            test_root .. "/book1.pdf",
            test_root .. "/book2.pdf",
            subdir    .. "/subbook.pdf",
            test_root .. "/notapdf.txt",
        }) do
            local f = io.open(p, "w"); f:write("dummy"); f:close()
        end
    end)

    after_each(function()
        os.execute("rm -rf " .. string.format("%q", test_root))
    end)

    it("finds PDFs in the current folder only (non-recursive)", function()
        assert.equals(2, #PdfMeta:scanForPdfFiles(test_root, false))
    end)

    it("finds PDFs recursively including subdirectories", function()
        assert.equals(3, #PdfMeta:scanForPdfFiles(test_root, true))
    end)

    it("returns an empty list when no PDFs exist", function()
        os.execute("rm -f " .. string.format("%q", test_root) .. "/*.pdf")
        os.execute("rm -f " .. string.format("%q", subdir)    .. "/*.pdf")
        assert.equals(0, #PdfMeta:scanForPdfFiles(test_root, true))
    end)

    it("detects subdirectories correctly", function()
        assert.is_true(PdfMeta:hasSubdirectories(test_root))
        assert.is_false(PdfMeta:hasSubdirectories(subdir))
    end)

end)
