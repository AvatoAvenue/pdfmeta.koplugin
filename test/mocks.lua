-- Mocks for KOReader modules used by pdfmeta.koplugin tests

package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local files = {}
            local handle = io.popen(string.format("ls -A %q", path))
            if handle then
                for entry in handle:lines() do
                    table.insert(files, entry)
                end
                handle:close()
            end
            local i = 0
            return function()
                i = i + 1
                return files[i]
            end
        end,
        attributes = function(path)
            local safe = path:gsub('"', '\\"')
            local stat = io.popen(string.format('stat -c "%%F" "%s" 2>/dev/null', safe))
            if stat then
                local mode = stat:read("*l")
                stat:close()
                if mode == "directory" then
                    return { mode = "directory" }
                elseif mode then
                    return { mode = "file" }
                end
            end
            return nil
        end,
        mkdir = function(path)
            os.execute(string.format("mkdir -p %q", path))
            return true
        end,
    }
end

package.preload["ui/trapper"] = function()
    return {
        info                    = function() return true end,
        confirm                 = function() return true end,
        clear                   = function() end,
        wrap                    = function(_, fn) if fn then fn() end end,
        dismissableRunInSubprocess = function(_, fn) return true, fn() end,
        setPausedText           = function() end,
    }
end

package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end

package.preload["docsettings"] = function()
    return {
        openSettingsFile = function()
            return {
                readSetting        = function() return {} end,
                saveSetting        = function() end,
                flushCustomMetadata = function() end,
            }
        end,
        open = function()
            return {
                saveSetting = function() end,
                flush       = function() end,
            }
        end,
    }
end

package.preload["ui/event"] = function()
    return { new = function() return {} end }
end

package.preload["apps/filemanager/filemanager"] = function()
    return {
        instance = {
            file_chooser = { path = "/tmp/pdfmeta_test" },
        },
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function() return {} end }
end

package.preload["ui/uimanager"] = function()
    return {
        show           = function() end,
        broadcastEvent = function() end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local mt = {}
    mt.__index = mt
    function mt:extend(tbl)
        setmetatable(tbl, self)
        return tbl
    end
    return setmetatable({}, mt)
end

package.preload["ffi/util"] = function()
    return {
        template = function(str) return str end,
        realpath = function(path) return path end,
        sleep    = function() end,
    }
end

package.preload["logger"] = function()
    return {
        dbg = function() end,
        err = function() end,
    }
end

package.preload["gettext"] = function()
    return function(str) return str end
end
