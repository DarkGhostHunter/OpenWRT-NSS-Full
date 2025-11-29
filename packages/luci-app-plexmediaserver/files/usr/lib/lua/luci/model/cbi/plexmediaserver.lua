local fs = require "nixio.fs"
local sys = require "luci.sys"
local i18n = require "luci.i18n"
local uci = require "luci.model.uci".cursor()
local _ = i18n.translate

-- === SELF-HEALING CONFIGURATION ===
-- Ensure the config file exists
if not fs.access("/etc/config/plexmediaserver") then
    fs.writefile("/etc/config/plexmediaserver", "")
end

-- Ensure a section of type 'main' exists (matches init.d script logic)
-- The init script uses "uci add plexmediaserver main", which creates an anonymous section of type 'main'
local has_section = uci:get_first("plexmediaserver", "main")
if not has_section then
    uci:add("plexmediaserver", "main")
    uci:commit("plexmediaserver")
end

-- === MAP DEFINITION ===
m = Map("plexmediaserver", _("Plex Media Server"), _("Configuration and status monitoring for the Plex Media Server."))

-- Use TypedSection because the init script creates an anonymous section of type 'main'
s = m:section(TypedSection, "main", _("General Settings"))
s.anonymous = true  -- Hide the generated section ID
s.addremove = false -- Disable adding/removing multiple instances

-- Tab definitions
s:tab("general", _("General"))
s:tab("paths", _("Storage Paths"))
s:tab("update", _("Updates & Maintenance"))

-- === TAB: GENERAL ===

-- Service Status Indicator
dummy = s:taboption("general", DummyValue, "_status", _("Service Status"))
dummy.rawhtml = true
function dummy.cfgvalue(self, section)
    local is_running = sys.call("pgrep -f 'Plex Media Server' >/dev/null") == 0
    -- Added line-height and vertical-align to fix visual alignment issues
    if is_running then
        return "<span style=\"color:green; font-weight:bold; line-height: 20px; vertical-align: middle;\">" .. _("Running") .. "</span>"
    else
        return "<span style=\"color:red; font-weight:bold; line-height: 20px; vertical-align: middle;\">" .. _("Stopped") .. "</span>"
    end
end

-- Enable/Disable (Standard Service Control)
o = s:taboption("general", Flag, "enabled", _("Enable Autostart"))
o.rmempty = false
o.write = function(self, section, value)
    if value == "1" then
        sys.call("/etc/init.d/plexmediaserver enable")
        sys.call("/etc/init.d/plexmediaserver start")
    else
        sys.call("/etc/init.d/plexmediaserver stop")
        sys.call("/etc/init.d/plexmediaserver disable")
    end
    Flag.write(self, section, value)
end

-- Current Version Display
ver = s:taboption("general", DummyValue, "plex_version", _("Detected Version"))
ver.description = _("The version currently auto-detected by the startup script.")

-- Force Version
force_ver = s:taboption("general", Value, "plex_force_version", _("Force Specific Version"))
force_ver.description = _("Manually specify a version folder name to use (found in tmp directory). Leave empty to auto-detect highest version.")

-- Plex Claim Code
claim = s:taboption("general", Value, "plex_claim_code", _("Plex Claim Code"))
claim.description = _("Optional. Use a claim code from https://plex.tv/claim to associate this server with your Plex account. This is only required for the first run.")
claim.password = true -- Hides the code as asterisks
claim.placeholder = "claim-xxxxxxxxxxxxxxxxxxxx"

-- === TAB: PATHS ===
browser_root = s:taboption("paths", Value, "plex_browser_root", _("Browser Root"))
browser_root.description = _("Mountpoint of the USB HDD containing the Plex library. Leave empty to auto-detect.")
browser_root.placeholder = "/mnt/sda1"

lib_dir = s:taboption("paths", Value, "plex_library_dir", _("Library Directory"))
-- Cleaned up description to remove bash-style variable syntax
lib_dir.description = _("Path to the main Plex library data. Defaults to the 'Browser Root' path appended with /.plex/Library.")

app_support = s:taboption("paths", Value, "plex_application_support_dir", _("Application Support Dir"))
-- Cleaned up description to remove bash-style variable syntax
app_support.description = _("Where metadata is stored. Defaults to the 'Library Directory' path appended with /Application Support.")

archive_path = s:taboption("paths", Value, "plex_compressed_archive_path", _("Compressed Archive Path"))
-- Cleaned up description to remove bash-style variable syntax
archive_path.description = _("Location of plexmediaserver.sqfs or .txz. Defaults to the 'Library Directory' path appended with /Application/plexmediaserver.sqfs.")

tmp_dir = s:taboption("paths", Value, "plex_tmp_dir", _("Temp Directory"))
tmp_dir.description = _("RAM location where Plex is decompressed. Default: /tmp/plexmediaserver.")


-- === TAB: UPDATES & MAINTENANCE ===

-- Update URL
dl_url = s:taboption("update", Value, "plex_force_update_download_url", _("Custom Update URL"))
dl_url.description = _("Override the automatic download URL for Plex updates.")

-- Action: Check Update
btn_check = s:taboption("update", Button, "_check_update", _("Check for Updates"))
btn_check.inputtitle = _("Check Now")
btn_check.rawhtml = true
btn_check.write = function(self, section)
    local result = sys.exec("/etc/init.d/plexmediaserver check_update")
    if result and #result > 0 then
        self.description = string.format("<pre>%s</pre>", result)
    else
        self.description = _("Check completed. See system log for details.")
    end
end

-- Action: Perform Update
btn_upd = s:taboption("update", Button, "_do_update", _("Perform Update"))
btn_upd.inputtitle = _("Update Plex")
btn_upd.rawhtml = true
btn_upd.description = _("Downloads and repacks the latest version. This may take several minutes.")
btn_upd.write = function(self, section)
    sys.call("/etc/init.d/plexmediaserver update > /dev/null 2>&1 &")
    self.description = "<span style='color:green'>" .. _("Update process started in background. Please wait.") .. "</span>"
end

-- Action: Reset
btn_reset = s:taboption("update", Button, "_do_reset", _("Reset Config"))
btn_reset.inputtitle = _("Wipe Config")
btn_reset.description = _("WARNING: Wipes the Plex Media Server config and regenerates it from scratch.")
btn_reset.write = function(self, section)
    sys.call("/etc/init.d/plexmediaserver reset")
    self.description = _("Configuration reset.")
end

return m