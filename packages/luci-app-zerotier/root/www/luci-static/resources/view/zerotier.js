'use strict';
'require form';
'require view';
'require uci';

return view.extend({
    render: function() {
        var m, s, o;

        // 1. Map the 'zerotier' configuration file
        m = new form.Map('zerotier', _('ZeroTier'),
            _('ZeroTier creates a virtual network between hosts. Join a network to enable private, encrypted connectivity.'));

        // -----------------------------------------------------------------------
        // Global Settings (Named Section: 'global')
        // -----------------------------------------------------------------------
        s = m.section(form.NamedSection, 'global', 'zerotier', _('Global Settings'));
        s.anonymous = true;
        s.addremove = false;

        // Option: enabled (0/1)
        o = s.option(form.Flag, 'enabled', _('Enabled'));
        o.default = o.disabled;
        o.rmempty = false;

        // Option: port (default 9993)
        o = s.option(form.Value, 'port', _('Port'), _('ZeroTier listening port (default 9993). Set to 0 for random.'));
        o.datatype = 'port';
        o.placeholder = '9993';
        o.optional = true;

        // Option: secret (Client secret)
        o = s.option(form.Value, 'secret', _('Client Secret'), _('Leave blank to generate a secret on first run.'));
        o.password = true;
        o.optional = true;

        // Advanced paths (collapsible or just optional)
        o = s.option(form.Value, 'config_path', _('Persistent Config Path'), _('Directory for persistent configuration (e.g. /etc/zerotier).'));
        o.placeholder = '/etc/zerotier';
        o.optional = true;

        o = s.option(form.Flag, 'copy_config_path', _('Copy Config'), _('Copy configuration to memory to avoid flash writes.'));
        o.optional = true;

        o = s.option(form.Value, 'local_conf_path', _('Local Config File'), _('Path to local.conf file for advanced options.'));
        o.placeholder = '/etc/zerotier.conf';
        o.optional = true;


        // -----------------------------------------------------------------------
        // Network Configurations (Typed Section: 'network')
        // -----------------------------------------------------------------------
        s = m.section(form.TypedSection, 'network', _('ZeroTier Networks'),
            _('Join one or more ZeroTier networks by entering their 16-digit Network ID.'));
        s.anonymous = true; // We don't need to name the UCI sections (e.g. 'earth') explicitly in the UI
        s.addremove = true; // Allow adding/removing networks

        // Option: id (The Network ID)
        o = s.option(form.Value, 'id', _('Network ID'), _('16-character Network ID from ZeroTier Central.'));
        o.rmempty = false;
        o.validate = function(section_id, value) {
            if (!value || !value.match(/^[0-9a-fA-F]{16}$/)) {
                return _('Must be a valid 16-character Network ID');
            }
            return true;
        };

        // Option: allow_managed (Allow ZeroTier to assign IP addresses)
        o = s.option(form.Flag, 'allow_managed', _('Auto-Assign IP'), _('Allow ZeroTier to assign managed IP addresses.'));
        o.default = o.enabled;

        // Option: allow_global (Allow Global IPs)
        o = s.option(form.Flag, 'allow_global', _('Allow Global IPs'), _('Allow setting global/public IP addresses.'));
        o.default = o.disabled;

        // Option: allow_default (Allow Default Route)
        o = s.option(form.Flag, 'allow_default', _('Allow Default Route'), _('Allow overriding the default route (Full Tunnel).'));
        o.default = o.disabled;

        // Option: allow_dns (Allow DNS)
        o = s.option(form.Flag, 'allow_dns', _('Allow DNS'), _('Allow accepting DNS configuration from the controller.'));
        o.default = o.disabled;

        return m.render();
    }
});