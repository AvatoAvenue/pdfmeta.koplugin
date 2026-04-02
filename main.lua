--[[--
Plugin for KOReader to extract Calibre metadata from PDF files as Custom Metadata.

Reads the XMP packet embedded by Calibre and writes series, series_index and
language into KOReader's DocSettings so they appear in the book browser just
like natively supported fields.

@module koplugin.PdfMeta
--]]

local plugin_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
-- Añadir la carpeta raíz y lib/ a la ruta de búsqueda
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

local XMPParser = require("xmpparser")   -- ¡Corregido!

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
-- Core: process a single PDF file
-- ---------------------------------------------------------------------------

--- Extract Calibre metadata from *pdf_file* and write it to DocSettings.
--
-- @param pdf_file string: absolute path to the PDF
-- @return boolean: true on success
function PdfMeta:processFile(pdf_file)
    logger.dbg("PdfMeta -> processFile", pdf_file)

    local meta = XMPParser.getMetadata(pdf_file)

    -- Nothing useful found — still counts as "processed without error"
    if not meta.series and not meta.series_index and not meta.language then
        logger.dbg("PdfMeta -> processFile: no Calibre XMP fields found in", pdf_file)
        return true
    end

    logger.dbg("PdfMeta -> processFile meta", meta)

    -- Keys must match KOReader's internal property names
    local new_props = {}
    if meta.series       then new_props.series       = meta.series       end
    if meta.series_index then new_props.series_index = meta.series_index end
    if meta.language     then new_props.language     = meta.language     end

    -- Abrir la configuración del documento
    local doc_settings = DocSettings:open(pdf_file)
    if not doc_settings then
        logger.dbg(T(_("PdfMeta: failed to open DocSettings for: %1"), pdf_file))
        return false
    end

    -- Leer los metadatos personalizados existentes
    local custom_props = doc_settings:readSetting("custom_props") or {}
    
    -- Guardar una copia de los valores originales por si se quiere revertir
    -- (opcional: almacenar en otra clave, por ejemplo "custom_props_backup")
    -- Por ahora solo los guardamos en la clave "custom_props_original" para depuración
    local original = {}
    for key in pairs(new_props) do
        original[key] = custom_props[key]
    end
    doc_settings:saveSetting("custom_props_original", original)

    -- Fusionar los nuevos valores
    for key, value in pairs(new_props) do
        custom_props[key] = value
    end
    doc_settings:saveSetting("custom_props", custom_props)
    
    -- Escribir los cambios al archivo .sdr/metadata.lua
    doc_settings:flush()

    return true
end

-- ---------------------------------------------------------------------------
-- Folder scanning
-- ---------------------------------------------------------------------------

--- Recursively (or not) collect .pdf files under *folder*.
--
-- @param folder    string
-- @param recursive boolean
-- @return table: list of absolute paths
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

--- Return true when *folder* contains at least one non-sidecar subdirectory.
--
-- @param folder string
-- @return boolean
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

--- Process all PDFs in *folder*, with optional recursion and Trapper UI.
--
-- @param folder    string
-- @param recursive boolean
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
            T(_("Extracting metadata...\n%1 / %2"), idx, #pdf_files),
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
            _("PDF metadata extraction complete.\nSuccessfully extracted %1 / %2"),
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
This will extract Calibre metadata (series, series index, language)
from PDF files in the current directory.

Once extraction has started you can abort at any moment by tapping
the screen.

It is recommended to keep the device plugged in during extraction.]]),
            _("Cancel"),
            _("Continue")
        )
        if not go_on then return end

        local recursive = false
        if self:hasSubdirectories(current_folder) then
            recursive = Trapper:confirm(
                _("Subfolders detected.\nAlso extract metadata from PDFs in subdirectories?"),
                _("Here only"),
                _("Here and under")
            )
        end

        Trapper:clear()
        self:processAllPdfs(current_folder, recursive)
    end)
end

return PdfMeta