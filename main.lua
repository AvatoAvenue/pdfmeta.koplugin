--[[--
Plugin for KOReader to import Calibre metadata from .metadata.calibre sidecar
files as KOReader Custom Metadata.

Reads the .metadata.calibre JSON file written by Calibre when it syncs a
library to a device, and writes series, series_index and language into
KOReader's custom_metadata.lua (inside the book's .sdr folder) so they
appear in "Book information" just like properties set by long-pressing a
field.

@module koplugin.PdfMeta
--]]

local plugin_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = package.path .. ";" .. plugin_path .. "?.lua;" .. plugin_path .. "lib/?.lua"

local Dispatcher      = require("dispatcher")
local DocSettings     = require("docsettings")
local Event           = require("ui/event")
local FileManager     = require("apps/filemanager/filemanager")
local InfoMessage     = require("ui/widget/infomessage")
local Trapper         = require("ui/trapper")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil         = require("ffi/util")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local T               = ffiUtil.template
local _               = require("gettext")

local CalibreMetadata = require("calibremetadata")

-- Name of the custom metadata file KOReader reads, located inside book.sdr/
local CUSTOM_METADATA_FILENAME = "custom_metadata.lua"

local PdfMeta = WidgetContainer:extend({
    name = "pdfmeta",
})

-- ---------------------------------------------------------------------------
-- Dispatcher / menu
-- ---------------------------------------------------------------------------

function PdfMeta:onDispatcherRegisterActions()
    Dispatcher:registerAction(
        "pdfmeta_action",
        {
            category = "none",
            event    = "PdfMeta",
            title    = _("Extract PDF Calibre Meta"),
            general  = true,
        }
    )
end

function PdfMeta:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function PdfMeta:addToMainMenu(menu_items)
    menu_items.pdf_meta = {
        text         = _("Extract PDF Calibre Meta"),
        sorting_hint = "more_tools",
        callback     = function()
            self:onPdfMeta()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Serialize a Lua value to a string (subset: strings, numbers, booleans,
-- flat tables with string keys). Sufficient for custom_metadata.lua.
local function serialize(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "string" then
        return string.format("%q", val)
    elseif t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "table" then
        local inner = indent .. "    "
        local parts = {}
        local keys = {}
        for k in pairs(val) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local v = val[k]
            local key_str = type(k) == "string"
                and string.format("[%q]", k)
                or  string.format("[%s]", tostring(k))
            parts[#parts + 1] = inner .. key_str .. " = " .. serialize(v, inner) .. ","
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

--- Read an existing custom_metadata.lua and return its data table, or {}.
local function readCustomMetadata(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local chunk = load(content)
    if not chunk then return {} end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

--- Write data to custom_metadata.lua (write to .tmp then rename).
local function writeCustomMetadata(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write("-- KOReader custom metadata\nreturn ")
    f:write(serialize(data))
    f:write("\n")
    f:close()
    return os.rename(tmp, path)
end

--- Ensure a directory exists.
local function ensureDir(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
end

-- ---------------------------------------------------------------------------
-- Core: process a single PDF file
-- ---------------------------------------------------------------------------

--- Import Calibre metadata for *pdf_file* into its custom_metadata.lua.
--
-- @param pdf_file string: absolute path to the PDF
-- @return boolean: true on success (including "nothing to do")
function PdfMeta:processFile(pdf_file)
    logger.dbg("PdfMeta -> processFile", pdf_file)

    local meta = CalibreMetadata.getMetadata(pdf_file)

    if not meta.series and not meta.series_index and not meta.language then
        logger.dbg("PdfMeta -> no Calibre metadata found for", pdf_file)
        return true
    end

    logger.dbg("PdfMeta -> processFile meta:", meta)

    -- Locate (or create) the .sdr sidecar directory for this book.
    -- DocSettings:getSidecarDir() returns e.g. /path/to/Book.sdr
    local sdr_dir = DocSettings:getSidecarDir(pdf_file)
    ensureDir(sdr_dir)

    local custom_metadata_path = sdr_dir .. "/" .. CUSTOM_METADATA_FILENAME

    -- Read existing custom_metadata.lua — may not exist yet.
    -- KOReader's format: { custom_props = {...}, doc_props = {...} }
    local data = readCustomMetadata(custom_metadata_path)
    if type(data.custom_props) ~= "table" then
        data.custom_props = {}
    end
    if type(data.doc_props) ~= "table" then
        data.doc_props = {}
    end

    -- Merge: only overwrite fields we actually have from Calibre.
    if meta.series       then data.custom_props.series       = meta.series       end
    if meta.series_index then data.custom_props.series_index = meta.series_index end
    if meta.language     then data.custom_props.language     = meta.language     end

    local ok = writeCustomMetadata(custom_metadata_path, data)
    if not ok then
        logger.dbg("PdfMeta -> failed to write", custom_metadata_path)
        return false
    end

    logger.dbg("PdfMeta -> wrote", custom_metadata_path)
    return true
end

-- ---------------------------------------------------------------------------
-- Folder scanning
-- ---------------------------------------------------------------------------

function PdfMeta:scanForPdfFiles(folder, recursive)
    logger.dbg("PdfMeta -> scanForPdfFiles", folder, "recursive:", recursive)

    local pdf_files = {}

    for entry in lfs.dir(folder) do
        if entry == "." or entry == ".." then goto continue end

        local full_path = folder .. "/" .. entry
        local attr      = lfs.attributes(full_path)

        if not attr or (attr.mode ~= "directory" and attr.mode ~= "file") then
            goto continue
        end

        if attr.mode == "directory" and recursive then
            if entry:lower():match("%.sdr$") then goto continue end

            local sub = self:scanForPdfFiles(full_path, recursive)
            for _, f in ipairs(sub) do
                table.insert(pdf_files, f)
            end

        elseif attr.mode == "file" and entry:lower():match("%.pdf$") then
            table.insert(pdf_files, full_path)
        end

        ::continue::
    end

    return pdf_files
end

function PdfMeta:hasSubdirectories(folder)
    for entry in lfs.dir(folder) do
        if entry ~= "." and entry ~= ".." then
            local attr = lfs.attributes(folder .. "/" .. entry)
            if attr and attr.mode == "directory" and not entry:lower():match("%.sdr$") then
                return true
            end
        end
    end
    return false
end

function PdfMeta:processAllPdfs(folder, recursive)
    logger.dbg("PdfMeta -> processAllPdfs", folder, "recursive:", recursive)

    Trapper:setPausedText(
        _("Do you want to abort extraction?"),
        _("Abort"),
        _("Don't abort")
    )

    local doNotAbort = Trapper:info(_("Scanning for PDF files..."))
    if not doNotAbort then
        Trapper:clear()
        return
    end

    local pdf_files = self:scanForPdfFiles(folder, recursive)

    if #pdf_files == 0 then
        Trapper:info(_("No PDF files found."))
        return
    end

    logger.dbg("PdfMeta -> processAllPdfs found", #pdf_files, "files")

    local successes = 0

    for idx, file_path in ipairs(pdf_files) do
        local real_path = ffiUtil.realpath(file_path)

        doNotAbort = Trapper:info(
            T(_("Importing metadata...\n%1 / %2"), idx, #pdf_files),
            true
        )
        if not doNotAbort then
            Trapper:clear()
            return
        end

        local complete, success = Trapper:dismissableRunInSubprocess(function()
            return self:processFile(real_path)
        end)

        if complete and success then
            successes = successes + 1
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", real_path))
            UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
        end
    end

    Trapper:clear()
    UIManager:show(InfoMessage:new({
        text = T(
            _("Calibre metadata import complete.\nSuccessfully imported %1 / %2"),
            successes,
            #pdf_files
        ),
    }))
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function PdfMeta:onPdfMeta()
    local current_folder
    if FileManager.instance then
        current_folder = FileManager.instance.file_chooser.path
    elseif self.ui and self.ui.document and self.ui.document.file then
        current_folder = require("util").splitFilePathName(self.ui.document.file)
    else
        return
    end

    Trapper:wrap(function()
        local go_on = Trapper:confirm(
            _([[
This will import Calibre metadata (series, series index, language)
from the .metadata.calibre file in the current directory into each
book's KOReader sidecar, so they appear in "Book information".

Once import has started you can abort at any moment by tapping
the screen.

It is recommended to keep the device plugged in during import.]]),
            _("Cancel"),
            _("Continue")
        )
        if not go_on then return end

        local recursive = false
        if self:hasSubdirectories(current_folder) then
            recursive = Trapper:confirm(
                _("Subfolders detected.\nAlso import metadata for PDFs in subdirectories?"),
                _("Here only"),
                _("Here and under")
            )
        end

        Trapper:clear()
        self:processAllPdfs(current_folder, recursive)
    end)
end

return PdfMeta
