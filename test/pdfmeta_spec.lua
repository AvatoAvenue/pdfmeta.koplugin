require("test/mocks")

package.path = package.path .. ";./lib/?.lua"
local CalibreMetadata = require("calibremetadata")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Write text to a temp file and return its path.
local function writeTmp(name, content)
    local path = "/tmp/pdfmeta_test_" .. name
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
end

local function removeTmp(path)
    os.remove(path)
end

-- ---------------------------------------------------------------------------
-- CalibreMetadata.parseJSON
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.parseJSON", function()

    it("parses a minimal book record", function()
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

    it("handles unicode escape sequences", function()
        local json = [[[ {"series": "Fundaci\u00f3n"} ]]]
        local records = CalibreMetadata.parseJSON(json)
        -- ó is U+00F3; encoded as UTF-8: 0xC3 0xB3
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

    it("parses boolean and null values without crashing", function()
        local json = [[[ {"flag": true, "missing": false, "nothing": null} ]]]
        local records = CalibreMetadata.parseJSON(json)
        assert.is_table(records)
        assert.is_true(records[1].flag)
        assert.is_false(records[1].missing)
        assert.is_nil(records[1].nothing)
    end)

end)

-- ---------------------------------------------------------------------------
-- CalibreMetadata.findRecord
-- ---------------------------------------------------------------------------

describe("CalibreMetadata.findRecord", function()

    local records = {
        { lpath = "Asimov/Foundation.pdf",      series = "Foundation", series_index = 1 },
        { lpath = "Herbert/Dune.pdf",            series = "Dune",       series_index = 1 },
        { lpath = "Herbert/Dune Messiah.pdf",    series = "Dune",       series_index = 2 },
    }

    it("finds a record by filename", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Asimov/Foundation.pdf")
        assert.is_not_nil(rec)
        assert.equals("Foundation", rec.series)
    end)

    it("finds the correct record when filenames differ only by directory", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Herbert/Dune Messiah.pdf")
        assert.is_not_nil(rec)
        assert.equals(2, rec.series_index)
    end)

    it("returns nil when no record matches", function()
        local rec = CalibreMetadata.findRecord(records, "/books/Unknown/Other.pdf")
        assert.is_nil(rec)
    end)

    it("returns nil for empty records table", function()
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
        -- Write a dummy sidecar at library root
        local f = assert(io.open(sidecar, "w"))
        f:write("[]")
        f:close()
    end)

    after_each(function()
        os.execute("rm -rf " .. string.format("%q", base))
    end)

    it("finds sidecar in the same directory as the PDF", function()
        -- Put another sidecar directly in subdir
        local local_sidecar = subdir .. "/.metadata.calibre"
        local f = assert(io.open(local_sidecar, "w"))
        f:write("[]")
        f:close()
        local found = CalibreMetadata.findSidecar(subdir .. "/Book.pdf")
        assert.equals(local_sidecar, found)
    end)

    it("finds sidecar one level up when not present locally", function()
        local found = CalibreMetadata.findSidecar(subdir .. "/Book.pdf")
        assert.equals(sidecar, found)
    end)

    it("returns nil when no sidecar exists anywhere", function()
        os.remove(sidecar)
        local found = CalibreMetadata.findSidecar(subdir .. "/Book.pdf")
        assert.is_nil(found)
    end)

end)

-- ---------------------------------------------------------------------------
-- CalibreMetadata.getMetadata  (end-to-end)
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

    it("returns series, series_index and language from sidecar", function()
        local sidecar_path = base .. "/.metadata.calibre"
        local f = assert(io.open(sidecar_path, "w"))
        f:write([[
[
  {
    "lpath": "Asimov/Foundation.pdf",
    "series": "Foundation",
    "series_index": 1.0,
    "languages": ["es"]
  }
]
        ]])
        f:close()

        -- Create a dummy PDF so lfs could find it (path only needed)
        local pdf_path = subdir .. "/Foundation.pdf"
        local pf = assert(io.open(pdf_path, "w"))
        pf:write("dummy")
        pf:close()

        local meta = CalibreMetadata.getMetadata(pdf_path)
        assert.equals("Foundation", meta.series)
        assert.equals(1.0,          meta.series_index)
        assert.equals("es",         meta.language)
    end)

    it("returns empty table when no sidecar exists", function()
        local meta = CalibreMetadata.getMetadata(subdir .. "/NoSidecar.pdf")
        assert.is_table(meta)
        assert.is_nil(meta.series)
    end)

    it("returns empty table when PDF not listed in sidecar", function()
        local sidecar_path = base .. "/.metadata.calibre"
        local f = assert(io.open(sidecar_path, "w"))
        f:write([[[ {"lpath": "Asimov/Other.pdf", "series": "X"} ]]])
        f:close()

        local meta = CalibreMetadata.getMetadata(subdir .. "/Foundation.pdf")
        assert.is_table(meta)
        assert.is_nil(meta.series)
    end)

    it("series_index is returned as a number", function()
        local sidecar_path = base .. "/.metadata.calibre"
        local f = assert(io.open(sidecar_path, "w"))
        f:write([[[ {"lpath": "Asimov/Foundation.pdf", "series": "Foundation", "series_index": 3} ]]])
        f:close()

        local pdf_path = subdir .. "/Foundation.pdf"
        local pf = assert(io.open(pdf_path, "w"))
        pf:write("dummy")
        pf:close()

        local meta = CalibreMetadata.getMetadata(pdf_path)
        assert.is_number(meta.series_index)
        assert.equals(3, meta.series_index)
    end)

end)

-- ---------------------------------------------------------------------------
-- PdfMeta integration: file scanning (unchanged)
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
