'use strict';
'require view';
'require fs';
'require ui';
'require form';
'require network';

return view.extend({
    /**
     * Diagnostic wrapper to catch errors and pass them to render()
     * instead of crashing the view with a red box.
     */
    safeExec: function(promise, name) {
        return promise.then(function(res) {
            return { result: res, error: null, name: name };
        }).catch(function(e) {
            console.error('Tailscale View Error [' + name + ']:', e);
            var msg = e.message || e;
            if (typeof msg === 'string' && msg.includes('Permission denied')) {
                msg += ' (Check /usr/share/rpcd/acl.d/ permissions and restart rpcd)';
            }
            return { result: null, error: msg, name: name };
        });
    },

    load: function() {
        return Promise.all([
            this.safeExec(fs.exec('/usr/sbin/tailscale', ['status']), 'Tailscale Status'),
            this.safeExec(fs.exec('/usr/sbin/tailscale', ['ip', '-4']), 'Tailscale IP'),
            this.safeExec(network.getWANNetworks(), 'Detect WAN')
        ]);
    },

    render: function(data) {
        // Extract wrapped results
        var statusRes = data[0];
        var ipRes = data[1];
        var wanRes = data[2];

        // --- Process Data ---
        var statusOutput = (statusRes.result && statusRes.result.stdout)
            ? statusRes.result.stdout
            : (statusRes.error ? 'Error: ' + statusRes.error : 'Tailscale is stopped or not installed.');

        var ipOutput = (ipRes.result && ipRes.result.stdout) ? ipRes.result.stdout.trim() : '-';

        var wanNetworks = (wanRes.result) ? wanRes.result : [];
        var wanDevice = 'eth0';
        if (wanNetworks.length > 0) {
            var dev = wanNetworks[0].getDevice();
            if (dev) wanDevice = dev.getName();
        }

        var m, s, o;

        m = new form.Map('tailscale', _('Tailscale'), _('Configure the Tailscale coordination server connection.'));

        /* * TAB: Status
         */
        s = m.section(form.NamedSection, '_status', 'status', _('Status'));
        s.anonymous = true;
        s.render = function () {
            // Check if we need to authenticate
            var authLink = null;
            var authRegex = /(https:\/\/login.tailscale.com\/a\/[a-zA-Z0-9]+)/;
            var match = statusOutput.match(authRegex);
            if (match) {
                authLink = match[1];
            }

            return E('div', { 'class': 'cbi-section' }, [
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, _('Tailscale IP')),
                    E('div', { 'class': 'cbi-value-field' }, ipOutput)
                ]),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, _('Status')),
                    E('div', { 'class': 'cbi-value-field' }, [
                        E('pre', {}, statusOutput)
                    ])
                ]),
                authLink ? E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, _('Auth Required')),
                    E('div', { 'class': 'cbi-value-field' }, [
                        E('a', { 'class': 'btn cbi-button cbi-button-apply', 'href': authLink, 'target': '_blank' }, _('Authenticate Device'))
                    ])
                ]) : ''
            ]);
        };

        /* * TAB: General Settings
         */
        s = m.section(form.NamedSection, 'settings', 'settings', _('Settings'));
        s.addremove = false;
        s.tab('general', _('General Settings'));
        s.tab('performance', _('Performance (Kernel 6.6+)'));
        s.tab('diagnostics', _('Diagnostics'));

        // -- General Tab --
        o = s.taboption('general', form.Flag, 'enable', _('Enable'), _('Enable the Tailscale daemon.'));
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'port', _('Port'), _('UDP port to listen on. Default: 41641'));
        o.datatype = 'port';
        o.placeholder = '41641';
        o.rmempty = false;

        o = s.taboption('general', form.ListValue, 'fw_mode', _('Firewall Mode'), _('Firewall configuration mode. OpenWrt 22.03+ usually requires nftables.'));
        o.value('nftables', 'nftables');
        o.value('iptables', 'iptables');
        o.default = 'nftables';

        o = s.taboption('general', form.Value, 'state_file', _('State File'), _('Location of the Tailscale state file.'));
        o.default = '/etc/tailscale/tailscaled.state';

        o = s.taboption('general', form.Flag, 'log_stderr', _('Log to Stderr'));
        o.default = '1';

        // -- Performance Tab --
        o = s.taboption('performance', form.DummyValue, '_perf_info');
        o.rawhtml = true;
        o.default = '<div class="cbi-value-description">' +
            _('Optimize throughput on OpenWrt 24.10+ (Kernel 6.6). These settings enable UDP Generic Receive Offload (GRO) on your WAN interface.') +
            '<br/><strong>' + _('Detected WAN Device:') + ' ' + wanDevice + '</strong></div>';

        o = s.taboption('performance', form.Flag, 'udp_gro_enable', _('Enable UDP GRO Forwarding'), _('Sets <code>rx-udp-gro-forwarding on</code> and <code>rx-gro-list off</code>.'));
        o.write = function(section_id, value) {
            if (value == '1') {
                return Promise.all([
                    fs.exec('/usr/sbin/ethtool', ['-K', wanDevice, 'rx-gro-list', 'off']),
                    fs.exec('/usr/sbin/ethtool', ['-K', wanDevice, 'rx-udp-gro-forwarding', 'on'])
                ]);
            } else {
                return Promise.all([
                    fs.exec('/usr/sbin/ethtool', ['-K', wanDevice, 'rx-gro-list', 'on']),
                    fs.exec('/usr/sbin/ethtool', ['-K', wanDevice, 'rx-udp-gro-forwarding', 'off'])
                ]);
            }
        };

        // -- Diagnostics Tab --
        o = s.taboption('diagnostics', form.DummyValue, '_diag_log');
        o.rawhtml = true;

        var diagHtml = '<div class="alert-message warning"><strong>Diagnostic Log:</strong><br/><ul>';
        data.forEach(function(d) {
            var status = d.error ? '<span style="color:red">FAILED</span>' : '<span style="color:green">OK</span>';
            var detail = d.error ? d.error : 'Success';
            diagHtml += '<li>' + d.name + ': ' + status + ' (' + detail + ')</li>';
        });
        diagHtml += '</ul></div>';
        o.default = diagHtml;


        return m.render();
    },

    handleSaveApply: function(ev, mode) {
        return this.super('handleSaveApply', arguments).then(function() {
            return fs.exec('/etc/init.d/tailscale', ['restart']);
        });
    }
});