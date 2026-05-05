local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local WallpaperFetch = WidgetContainer:extend{
    name = "wallpaperfetch",
    is_doc_only = false,
}

local function notify(text)
    UIManager:show(InfoMessage:new({ text = text, timeout = 2 }))
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function ensure_dir(path)
    os.execute("mkdir -p " .. shell_quote(path))
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

local function read_pending_count(path)
    local lines = read_lines(path)
    local pending = nil
    for _, line in ipairs(lines) do
        local n = line:match("^PENDING%s+(%d+)$")
        if n then
            pending = tonumber(n)
        end
    end
    return pending
end

local function read_conf(path)
    local conf = {}
    local f = io.open(path, "r")
    if not f then
        return conf
    end
    for line in f:lines() do
        local k, v = line:match('^([A-Z_]+)="(.*)"$')
        if k then
            conf[k] = v
        end
    end
    f:close()
    return conf
end

local function write_conf(path, conf)
    local order = {
        "API_KEY_FILE", "DOWNLOAD_DIR", "QUERY", "CATEGORIES", "PURITY",
        "SORTING", "ORDER", "ATLEAST", "RATIOS", "COLORS", "TOP_RANGE", "TARGET_COUNT", "COLLECTION_NAME", "COLLECTION_USERNAME",
    }
    local lines = {
        '# API key file next to this config.',
        'API_KEY_FILE="' .. (conf.API_KEY_FILE or "__PLUGIN_DIR__/scripts/wallhaven.cred") .. '"',
        "",
        '# Default output folder on Kobo storage.',
        'DOWNLOAD_DIR="' .. (conf.DOWNLOAD_DIR or "/mnt/onboard/.pluginwallpapers") .. '"',
        "",
    }
    local written = { API_KEY_FILE = true, DOWNLOAD_DIR = true }
    for _, k in ipairs(order) do
        if not written[k] and conf[k] ~= nil then
            lines[#lines + 1] = k .. '="' .. conf[k] .. '"'
            written[k] = true
        end
    end
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return true
end

local function notify_smart(line)
    local msg = line:gsub("^[A-Z]+%s+", "")
    if msg:find("placeholder", 1, true) or msg:find("API key", 1, true) then
        notify(_("API key issue: edit scripts/wallhaven.cred"))
        return
    end
    if msg:find("429", 1, true) or msg:find("rate limit", 1, true) then
        notify(_("Rate limit hit. Wait a bit, then retry."))
        return
    end
    if msg:find("timeout", 1, true) or msg:find("timed out", 1, true) then
        notify(_("Network timeout. Check connection and retry."))
        return
    end
    if msg:find("DNS", 1, true) or msg:find("Network", 1, true) then
        notify(_("Network/DNS issue. Check Wi-Fi and internet."))
        return
    end
    if msg:find("No HTTP client found", 1, true) then
        notify(_("Missing HTTP client on device (curl/wget)."))
        return
    end
    if msg:find("No results", 1, true) then
        notify(_("No results. Broaden filters in Configure Search."))
        return
    end
    if msg:find("Collection name not set", 1, true) then
        notify(_("Set Collection name in Configure Search first."))
        return
    end
    if msg:find("Collection username not set", 1, true) then
        notify(_("Set Collection username in Configure Search first."))
        return
    end
    if msg:find("Collection not found", 1, true) then
        notify(_("Collection label not found. Check exact collection name."))
        return
    end
    if msg:find("download image files", 1, true) then
        notify(_("Image CDN download failed. Try again later."))
        return
    end
    notify(msg)
end

local function flip_bit_3str(v, idx)
    v = (v or "000")
    if #v < 3 then v = "000" end
    local a, b, c = v:sub(1, 1), v:sub(2, 2), v:sub(3, 3)
    local t = { a, b, c }
    t[idx] = (t[idx] == "1") and "0" or "1"
    return table.concat(t)
end

local function bit_is_on(v, idx)
    v = v or "000"
    if #v < 3 then
        return false
    end
    return v:sub(idx, idx) == "1"
end

function WallpaperFetch:startStatusPolling(status_file)
    self._status_file = status_file
    self._status_seen = 0
    self._status_active = true
    self._pending_total = nil

    local function poll()
        if not self._status_active then
            return
        end
        local lines = read_lines(self._status_file)
        while self._status_seen < #lines do
            self._status_seen = self._status_seen + 1
            local line = lines[self._status_seen]
            if line:match("^PROGRESS ") then
                local n, wid = line:match("^PROGRESS%s+([^%s]+)%s+(.+)$")
                if n and wid then
                    notify(_("Downloaded") .. " " .. n .. ": " .. wid)
                end
            elseif line:match("^PENDING ") then
                local p = line:match("^PENDING%s+(%d+)$")
                if p then
                    self._pending_total = tonumber(p)
                end
            elseif line:match("^WARN ") then
                notify_smart(line)
            elseif line:match("^ERROR ") then
                notify_smart(line)
                self._status_active = false
            elseif line:match("^DONE ") then
                local saved, failed = line:match("^DONE%s+(%d+)%s+(%d+)$")
                if saved and failed then
                    local target = nil
                    if self._pending_total ~= nil then
                        target = tostring(self._pending_total)
                    else
                        target = read_conf((self.path or "plugins/wallpaperfetch.koplugin") .. "/scripts/wallpapers.conf").TARGET_COUNT or "1"
                    end
                    if tonumber(saved) == 0 and tonumber(failed) == 0 and self._pending_total ~= nil and self._pending_total == 0 then
                        notify(_("All collection items are already present."))
                        self._status_active = false
                        return
                    end
                    if tonumber(failed) and tonumber(failed) > 0 then
                        notify(_("Finished with warnings: ") .. saved .. "/" .. target .. ", failed: " .. failed)
                    else
                        notify(_("Finished: ") .. saved .. "/" .. target)
                    end
                else
                    notify(_("Finished"))
                end
                self._status_active = false
            end
        end

        if self._status_active then
            UIManager:scheduleIn(1, poll)
        end
    end

    UIManager:scheduleIn(1, poll)
end

function WallpaperFetch:startSingleStatusPolling(status_file, success_text)
    local seen = 0
    local ticks = 0
    local active = true

    local function poll()
        if not active then
            return
        end
        local lines = read_lines(status_file)
        while seen < #lines do
            seen = seen + 1
            local line = lines[seen]
            if line:match("^ERROR ") then
                notify(_("Error: ") .. line:gsub("^ERROR%s+", ""))
                active = false
            elseif line:match("^DONE") then
                notify(success_text)
                active = false
            elseif line:match("^WARN ") then
                notify_smart(line)
            end
        end
        ticks = ticks + 1
        if active and ticks > 10 then
            notify(_("Warning: no status update received"))
            active = false
        end
        if active then
            UIManager:scheduleIn(1, poll)
        end
    end

    UIManager:scheduleIn(1, poll)
end

function WallpaperFetch:init()
    logger.info("wallpaperfetch: init")
    self.ui.menu:registerToMainMenu(self)
end

function WallpaperFetch:addToMainMenu(menu_items)
    logger.info("wallpaperfetch: addToMainMenu")
    local plugin_path = self.path or "plugins/wallpaperfetch.koplugin"
    local logs_dir = plugin_path .. "/logs"
    local fetch_script = plugin_path .. "/scripts/fetch_wallpapers.sh"
    local sync_script = plugin_path .. "/scripts/sync_collection.sh"
    local setdir_script = plugin_path .. "/scripts/set_download_dir.sh"
    local fetch_status = logs_dir .. "/fetch.status"
    local fetch_log = logs_dir .. "/fetch.log"
    local setdir_status = logs_dir .. "/setdir.status"
    local setdir_log = logs_dir .. "/setdir.log"
    local sync_status = logs_dir .. "/sync.status"
    local sync_log = logs_dir .. "/sync.log"
    local conf_path = plugin_path .. "/scripts/wallpapers.conf"

    local function edit_text(title, key, default_value)
        local conf = read_conf(conf_path)
        self.cfg_dialog = InputDialog:new{
            title = title,
            input = conf[key] or default_value or "",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(self.cfg_dialog)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            conf[key] = self.cfg_dialog:getInputText() or ""
                            UIManager:close(self.cfg_dialog)
                            if write_conf(conf_path, conf) then
                                notify(_("Saved ") .. key)
                            else
                                notify(_("Error: could not write config"))
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(self.cfg_dialog)
        self.cfg_dialog:onShowKeyboard()
    end

    local function edit_target_count()
        local conf = read_conf(conf_path)
        self.count_dialog = InputDialog:new{
            title = _("Images per run (1-50)"),
            input = conf.TARGET_COUNT or "1",
            input_type = "number",
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(self.count_dialog)
                        end,
                    },
                    {
                        text = _("Save"),
                        is_enter_default = true,
                        callback = function()
                            local raw = self.count_dialog:getInputText() or "1"
                            local n = tonumber(raw) or 1
                            if n < 1 then n = 1 end
                            if n > 50 then n = 50 end
                            conf.TARGET_COUNT = tostring(math.floor(n))
                            UIManager:close(self.count_dialog)
                            if write_conf(conf_path, conf) then
                                notify(_("Images per run set to ") .. conf.TARGET_COUNT)
                            else
                                notify(_("Error: could not write config"))
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(self.count_dialog)
        self.count_dialog:onShowKeyboard()
    end

    menu_items.wallpaperfetch = {
        text = _("Wallpaper Fetch"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("1) Sync"),
                callback = function()
                    ensure_dir(logs_dir)
                    os.execute("rm -f " .. shell_quote(sync_status))
                    local scan_ok = os.execute("sh " .. sync_script .. " " .. shell_quote(sync_status) .. " " .. shell_quote(sync_log) .. " --scan-only >>" .. shell_quote(sync_log) .. " 2>&1")
                    if not scan_ok then
                        self:startStatusPolling(sync_status)
                        notify(_("Collection scan failed"))
                        return
                    end

                    local pending = read_pending_count(sync_status) or 0
                    if pending > 20 then
                        UIManager:show(ConfirmBox:new{
                            text = _("Download all? (There are ") .. tostring(pending) .. _(" wallpapers to be downloaded)"),
                            ok_text = _("Download"),
                            ok_callback = function()
                                os.execute("rm -f " .. shell_quote(sync_status))
                                local ok = os.execute("sh " .. sync_script .. " " .. shell_quote(sync_status) .. " " .. shell_quote(sync_log) .. " >>" .. shell_quote(sync_log) .. " 2>&1 &")
                                if not ok then
                                    notify(_("Error: could not start collection sync"))
                                    return
                                end
                                self:startStatusPolling(sync_status)
                                notify(_("Collection sync started"))
                            end,
                        })
                        return
                    end

                    os.execute("rm -f " .. shell_quote(sync_status))
                    local ok = os.execute("sh " .. sync_script .. " " .. shell_quote(sync_status) .. " " .. shell_quote(sync_log) .. " >>" .. shell_quote(sync_log) .. " 2>&1 &")
                    if not ok then
                        notify(_("Error: could not start collection sync"))
                        return
                    end
                    self:startStatusPolling(sync_status)
                    notify(_("Collection sync started"))
                end,
            },
            {
                text = _("2) Edit Sync Settings"),
                sub_item_table = {
                    {
                        text = _("Collection name"),
                        callback = function() edit_text(_("Collection name (exact label)"), "COLLECTION_NAME", "") end,
                    },
                    {
                        text = _("Collection username"),
                        callback = function() edit_text(_("Collection owner username"), "COLLECTION_USERNAME", "") end,
                    },
                },
            },
            {
                text = _("3) Manual Search"),
                sub_item_table = {
                    {
                        text_func = function()
                            local conf = read_conf(conf_path)
                            return _("Images per run: ") .. (conf.TARGET_COUNT or "1")
                        end,
                        callback = function()
                            edit_target_count()
                        end,
                    },
                    {
                        text = _("Fetch Wallpapers"),
                        callback = function()
                            ensure_dir(logs_dir)
                            os.execute("rm -f " .. shell_quote(fetch_status))
                            local ok = os.execute("sh " .. fetch_script .. " --auto-run " .. shell_quote(fetch_status) .. " " .. shell_quote(fetch_log) .. " >>" .. shell_quote(fetch_log) .. " 2>&1 &")
                            if not ok then
                                notify(_("Error: could not start wallpaper fetch"))
                                return
                            end
                            self:startStatusPolling(fetch_status)
                            notify(_("Wallpaper fetch started"))
                        end,
                    },
                    {
                        text = _("Set Download Folder"),
                        callback = function()
                            local default_path = "/mnt/onboard/.pluginwallpapers"
                            self.dir_dialog = InputDialog:new{
                                title = _("Download folder"),
                                input = default_path,
                                buttons = {
                                    {
                                        {
                                            text = _("Cancel"),
                                            callback = function()
                                                UIManager:close(self.dir_dialog)
                                            end,
                                        },
                                        {
                                            text = _("Save"),
                                            is_enter_default = true,
                                            callback = function()
                                                local new_path = self.dir_dialog:getInputText()
                                                UIManager:close(self.dir_dialog)
                                                ensure_dir(logs_dir)
                                                os.execute("rm -f " .. shell_quote(setdir_status))
                                                local ok = os.execute("sh " .. setdir_script .. " " .. shell_quote(new_path) .. " " .. shell_quote(setdir_status) .. " " .. shell_quote(setdir_log) .. " >>" .. shell_quote(setdir_log) .. " 2>&1 &")
                                                if not ok then
                                                    notify(_("Error: could not start folder update"))
                                                    return
                                                end
                                                self:startSingleStatusPolling(setdir_status, _("Download folder updated"))
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(self.dir_dialog)
                            self.dir_dialog:onShowKeyboard()
                        end,
                    },
                    {
                        text = _("Configure Search"),
                        sub_item_table = {
                            {
                                text = _("Query"),
                                callback = function() edit_text(_("Search query"), "QUERY", "") end,
                            },
                            {
                                text = _("Sorting"),
                                callback = function() edit_text(_("Sorting (date_added/relevance/random/views/favorites/toplist)"), "SORTING", "date_added") end,
                            },
                            {
                                text = _("Order"),
                                callback = function() edit_text(_("Order (desc/asc)"), "ORDER", "desc") end,
                            },
                            {
                                text = _("Min resolution"),
                                callback = function() edit_text(_("ATLEAST (example 1264x1680)"), "ATLEAST", "") end,
                            },
                            {
                                text = _("Ratio"),
                                callback = function() edit_text(_("RATIOS (example 4x3, 16x9)"), "RATIOS", "4x3") end,
                            },
                            {
                                text = _("Color"),
                                callback = function() edit_text(_("COLORS (hex, e.g. 0066cc)"), "COLORS", "") end,
                            },
                            {
                                text = _("Top range"),
                                callback = function() edit_text(_("TOP_RANGE (1d/3d/1w/1M/3M/6M/1y)"), "TOP_RANGE", "1M") end,
                            },
                            {
                                text = _("Categories"),
                                sub_item_table = {
                                    {
                                        text = _("General"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).CATEGORIES or "111", 1)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.CATEGORIES = flip_bit_3str(c.CATEGORIES or "111", 1)
                                            if write_conf(conf_path, c) then notify(_("Saved CATEGORIES")) end
                                        end,
                                    },
                                    {
                                        text = _("Anime"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).CATEGORIES or "111", 2)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.CATEGORIES = flip_bit_3str(c.CATEGORIES or "111", 2)
                                            if write_conf(conf_path, c) then notify(_("Saved CATEGORIES")) end
                                        end,
                                    },
                                    {
                                        text = _("People"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).CATEGORIES or "111", 3)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.CATEGORIES = flip_bit_3str(c.CATEGORIES or "111", 3)
                                            if write_conf(conf_path, c) then notify(_("Saved CATEGORIES")) end
                                        end,
                                    },
                                },
                            },
                            {
                                text = _("Purity"),
                                sub_item_table = {
                                    {
                                        text = _("SFW"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).PURITY or "100", 1)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.PURITY = flip_bit_3str(c.PURITY or "100", 1)
                                            if write_conf(conf_path, c) then notify(_("Saved PURITY")) end
                                        end,
                                    },
                                    {
                                        text = _("Sketchy"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).PURITY or "100", 2)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.PURITY = flip_bit_3str(c.PURITY or "100", 2)
                                            if write_conf(conf_path, c) then notify(_("Saved PURITY")) end
                                        end,
                                    },
                                    {
                                        text = _("NSFW"),
                                        checked_func = function()
                                            return bit_is_on(read_conf(conf_path).PURITY or "100", 3)
                                        end,
                                        callback = function()
                                            local c = read_conf(conf_path)
                                            c.PURITY = flip_bit_3str(c.PURITY or "100", 3)
                                            if write_conf(conf_path, c) then notify(_("Saved PURITY")) end
                                        end,
                                    },
                                },
                            },
                        },
                    },
                },
            },
        },
    }
end

return WallpaperFetch
