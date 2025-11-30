'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

return view.extend({
    load: function() {
        return Promise.all([
            L.resolveDefault(fs.exec('/usr/bin/pgrep', ['-f', 'Plex Media Server']), null),
            L.resolveDefault(fs.exec('/bin/sh', ['-c', '. /etc/config/plexmediaserver; echo $plex_version']), {})
        ]);
    },

    render: function(data) {
        var isRunning = (data[0] && data[0].code === 0);

        var m, s, o;

        m = new form.Map('plexmediaserver', _('Plex Media Server'), _('Configuration and status monitoring for the Plex Media Server.'));

        s = m.section(form.TypedSection, 'main', _('General Settings'));
        s.anonymous = true;
        s.addremove = false;

        s.tab('general', _('General'));
        s.tab('paths', _('Storage Paths'));
        s.tab('update', _('Updates & Maintenance'));

        // === TAB: GENERAL ===

        // Status Field
        o = s.taboption('general', form.DummyValue, '_status', _('Service Status'));
        o.cfgvalue = function() {
            return isRunning
                ? E('span', { 'style': 'color:green; font-weight:bold; line-height: 20px; vertical-align: middle;' }, _('Running'))
                : E('span', { 'style': 'color:red; font-weight:bold; line-height: 20px; vertical-align: middle;' }, _('Stopped'));
        };

        // Enabled Flag
        o = s.taboption('general', form.Flag, 'enabled', _('Enable Autostart'));
        o.rmempty = false;
        o.write = function(section_id, value) {
            // Handle enable/disable logic via init script calls
            var action = (value == '1') ? 'enable' : 'disable';
            // We define the promise chain to update config + run command
            return this.super('write', [section_id, value]).then(function() {
                return fs.exec('/etc/init.d/plexmediaserver', [action]);
            }).then(function() {
                if (value == '1') return fs.exec('/etc/init.d/plexmediaserver', ['start']);
                else return fs.exec('/etc/init.d/plexmediaserver', ['stop']);
            }).then(function() {
                ui.addNotification(null, E('p', _('Service state changed. Refreshing...')));
                window.setTimeout(function() { location.reload(); }, 2000);
            });
        };

        // Plex Claim Code (From your previous request)
        o = s.taboption('general', form.Value, 'plex_claim_code', _('Plex Claim Code'));
        o.description = _('Optional. Use a claim code from https://plex.tv/claim to associate this server with your Plex account. This is only required for the first run.');
        o.password = true;
        o.placeholder = 'claim-xxxxxxxxxxxxxxxxxxxx';

        // Version Display
        o = s.taboption('general', form.DummyValue, 'plex_version', _('Detected Version'));
        o.description = _('The version currently auto-detected by the startup script.');

        // Force Version
        o = s.taboption('general', form.Value, 'plex_force_version', _('Force Specific Version'));
        o.description = _('Manually specify a version folder name to use (found in tmp directory). Leave empty to auto-detect highest version.');

        // === TAB: PATHS ===

        o = s.taboption('paths', form.Value, 'plex_browser_root', _('Browser Root'));
        o.description = _('Mountpoint of the USB HDD containing the Plex library. Leave empty to auto-detect.');
        o.placeholder = '/mnt/sda1';

        o = s.taboption('paths', form.Value, 'plex_library_dir', _('Library Directory'));
        o.description = _('Path to the main Plex library data. Defaults to the Browser Root path appended with /.plex/Library.');

        o = s.taboption('paths', form.Value, 'plex_application_support_dir', _('Application Support Dir'));
        o.description = _('Where metadata is stored. Defaults to the Library Directory path appended with /Application Support.');

        o = s.taboption('paths', form.Value, 'plex_compressed_archive_path', _('Compressed Archive Path'));
        o.description = _('Location of plexmediaserver.sqfs or .txz. Defaults to the Library Directory path appended with /Application/plexmediaserver.sqfs.');

        o = s.taboption('paths', form.Value, 'plex_tmp_dir', _('Temp Directory'));
        o.description = _('RAM location where Plex is decompressed. Default: /tmp/plexmediaserver.');

        // === TAB: UPDATES & MAINTENANCE ===

        o = s.taboption('update', form.Value, 'plex_force_update_download_url', _('Custom Update URL'));
        o.description = _('Override the automatic download URL for Plex updates.');

        // Check Update Button
        o = s.taboption('update', form.Button, '_check_update', _('Check for Updates'));
        o.inputtitle = _('Check Now');
        o.inputstyle = 'apply';
        o.onclick = function() {
            ui.showModal(_('Checking for updates...'), [
                E('p', { 'class': 'spinning' }, _('Executing check_update routine...'))
            ]);

            return fs.exec('/etc/init.d/plexmediaserver', ['check_update']).then(function(res) {
                ui.showModal(_('Update Check Result'), [
                    E('pre', {}, [ res.stdout || res.stderr || _('No output returned.') ]),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
                    ])
                ]);
            }).catch(function(e) {
                ui.addNotification(null, E('p', _('Error checking update: ') + e.message));
                ui.hideModal();
            });
        };

        // Perform Update Button
        o = s.taboption('update', form.Button, '_do_update', _('Perform Update'));
        o.inputtitle = _('Update Plex');
        o.inputstyle = 'action';
        o.description = _('Downloads and repacks the latest version. This may take several minutes.');
        o.onclick = function() {
            if (!confirm(_('Are you sure you want to perform an update? This might take a while.'))) return;

            ui.addNotification(null, E('p', _('Update started in background. Please wait...')));
            // Run in background using nohup or & equivalent via shell
            return fs.exec('/bin/sh', ['-c', '/etc/init.d/plexmediaserver update > /dev/null 2>&1 &']);
        };

        // Reset Config Button
        o = s.taboption('update', form.Button, '_do_reset', _('Reset Config'));
        o.inputtitle = _('Wipe Config');
        o.inputstyle = 'reset';
        o.description = _('WARNING: Wipes the Plex Media Server config and regenerates it from scratch.');
        o.onclick = function() {
            if (!confirm(_('WARNING: This will wipe your Plex configuration! Are you sure?'))) return;

            return fs.exec('/etc/init.d/plexmediaserver', ['reset']).then(function() {
                location.reload();
            });
        };

        return m.render();
    }
});