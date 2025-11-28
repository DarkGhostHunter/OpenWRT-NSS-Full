module("luci.controller.plexmediaserver", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/plexmediaserver") then
        return
    end

    -- entry(path, target, title, order)
    local page = entry({"admin", "services", "plexmediaserver"}, cbi("plexmediaserver"), _("Plex Media Server"), 90)
    page.dependent = true
end