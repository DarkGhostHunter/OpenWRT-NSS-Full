local fs = require "nixio.fs"
local sys = require "luci.sys"

-- Define the Map linking to /etc/config/plexmediaserver
m = Map("plexmediaserver", _("Plex Media Server"), _("Configuration and status monitoring for the Plex Media Server."))

-- The init script creates a section named 'main'
s = m:section(NamedSection, "main", "plexmediaserver", _("General Settings"))
s.anonymous = false
s.addremove = false

-- Tab definitions
s:tab("general", _("General"))
s:tab("paths", _("Storage Paths"))
s:tab("update", _("Updates & Maintenance"))

-- === TAB: GENERAL ===

-- Service Status Indicator
dummy = s:taboption("general", DummyValue, "_status", _("Service Status"))
dummy.template = "cbi/value"
dummy.value = sys.call("pgrep -f 'Plex Media Server' >/dev/null") == 0 
    and "<span style='color:green; font-weight:bold'>" .. _("Running") .. "</span>" 
    or "<span style='color:red; font-weight:bold'>" .. _("Stopped") .. "</span>"

-- Enable/Disable (Standard Service Control)
-- This controls the init.d enable/disable symlinks
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

-- Current Version Display (Read-only)
ver = s:taboption("general", DummyValue, "plex_version", _("Detected Version"))
ver.description = _("The version currently auto-detected by the startup script.")

-- Force Version
force_ver = s:taboption("general", Value, "plex_force_version", _("Force Specific Version"))
force_ver.description = _("Manually specify a version folder name to use (found in tmp directory). Leave empty to auto-detect highest version.")


-- === TAB: PATHS ===
-- Descriptions taken from the script comments

browser_root = s:taboption("paths", Value, "plex_browser_root", _("Browser Root"))
browser_root.description = _("Mountpoint of the USB HDD containing the Plex library. Leave empty to auto-detect.")
browser_root.placeholder = "/mnt/sda1"

lib_dir = s:taboption("paths", Value, "plex_library_dir", _("Library Directory"))
lib_dir.description = _("Path to the main Plex library data. Defaults to ${Browser Root}/.plex/Library.")

app_support = s:taboption("paths", Value, "plex_application_support_dir", _("Application Support Dir"))
app_support.description = _("Where metadata is stored. Defaults to ${Library Dir}/Application Support.")

archive_path = s:taboption("paths", Value, "plex_compressed_archive_path", _("Compressed Archive Path"))
archive_path.description = _("Location of plexmediaserver.sqfs or .txz. Defaults to ${Library Dir}/Application/plexmediaserver.sqfs.")

tmp_dir = s:taboption("paths", Value, "plex_tmp_dir", _("Temp Directory"))
tmp_dir.description = _("RAM location where Plex is decompressed. Default: /tmp/plexmediaserver.")


-- === TAB: UPDATES & MAINTENANCE ===

-- Update URL
dl_url = s:taboption("update", Value, "plex_force_update_download_url", _("Custom Update URL"))
dl_url.description = _("Override the automatic download URL for Plex updates.")

-- Action: Check Update
btn_check = s:taboption("update", Button, "_check_update", _("Check for Updates"))
btn_check.inputtitle = _("Check Now")
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
btn_upd.description = _("Downloads and repacks the latest version. This may take several minutes.")
btn_upd.write = function(self, section)
    -- Running in background to prevent timeout
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