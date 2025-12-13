'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require rpc';

return view.extend({
    // Helper to check installation status
    checkInstalled: function() {
        return fs.stat('/mnt/sda1/.webapps/pairdrop.sqfs').then(function(res) {
            return true; // File exists
        }).catch(function() {
            return false; // File does not exist or permission denied
        });
    },

    // Helper to check running status (simplified check for mount)
    checkRunning: function() {
        return fs.exec('/bin/mount').then(function(res) {
            if (!res || res.code !== 0) return false;
            return res.stdout.indexOf('/www/pairdrop') !== -1;
        }).catch(function() {
            return false; // Command failed or permission denied
        });
    },

    handleServiceAction: function(action) {
        var init = '/etc/init.d/pairdrop';
        var p;

        ui.showModal(_('Processing'), [
            E('p', { 'class': 'spinning' }, _('Executing service action: ' + action + '...')),
            E('p', _('This may take a while if downloading files.'))
        ]);

        if (action === 'reinstall') {
            p = fs.exec(init, ['reinstall']);
        } else if (action === 'uninstall') {
            p = fs.exec(init, ['uninstall']);
        } else {
            p = fs.exec(init, [action]);
        }

        return p.then(function(res) {
            ui.hideModal();
            if (res && res.code !== 0) {
                ui.addNotification(null, E('p', _('Action failed') + ': ' + (res.stderr || res.stdout || _('Unknown Error'))), 'error');
            } else {
                ui.addNotification(null, E('p', _('Action completed successfully.')), 'success');
                // Refresh page to update button states
                window.location.reload();
            }
        }).catch(function(e) {
            ui.hideModal();
            ui.addNotification(null, E('p', _('Error') + ': ' + e.message), 'error');
        });
    },

    load: function() {
        return Promise.all([
            this.checkInstalled(),
            this.checkRunning(),
            uci.load('pairdrop').catch(function() { return null; })
        ]);
    },

    render: function(data) {
        var isInstalled = data[0];
        var isRunning = data[1];

        var m, s, o;

        m = new form.Map('pairdrop', _('PairDrop Settings'), _('Configure the PairDrop file sharing service.'));

        s = m.section(form.NamedSection, 'main', 'pairdrop', _('Configuration'));
        s.anonymous = true;

        // Enabled Toggle
        o = s.option(form.Flag, 'enabled', _('Enable Service'));
        o.rmempty = false;

        // Port
        o = s.option(form.Value, 'port', _('Port'));
        o.datatype = 'port';
        o.default = '3000';

        // Versions
        o = s.option(form.Value, 'node_version', _('Node.js Version'));
        o.description = _('Specify Node.js version (e.g., v20.10.0). Leave empty for default.');
        o.placeholder = 'v20.10.0';

        o = s.option(form.Value, 'pairdrop_version', _('PairDrop Version'));
        o.description = _('Specify PairDrop version tag (e.g., v1.10.7). Leave empty for latest.');

        // --- Actions Section (Merged into main) ---
        o = s.option(form.DummyValue, '_divider');
        o.rawhtml = true;
        o.default = '<h3 style="margin-top: 20px; border-bottom: 1px solid #ccc; padding-bottom: 5px;">' + _('Service Control') + '</h3>';

        // Status Display
        var statusText = isInstalled ? _('Installed') : _('Not Installed');
        var statusColor = isInstalled ? 'green' : 'red';
        if (isInstalled && isRunning) {
            statusText += ' (' + _('Running') + ')';
        } else if (isInstalled) {
            statusText += ' (' + _('Stopped') + ')';
        }

        o = s.option(form.DummyValue, '_status', _('Status'));
        o.rawhtml = true;
        o.default = '<span style="color:' + statusColor + '; font-weight:bold">' + statusText + '</span>';

        // Action Buttons
        o = s.option(form.DummyValue, '_actions', _('Actions'));
        o.rawhtml = true;
        o.render = L.bind(function() {
            var buttons = [];

            // Install Button (Only if not installed)
            if (!isInstalled) {
                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-action',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'install')
                }, _('Install')));
            }

            // Start Button (Only if installed and not running)
            if (isInstalled && !isRunning) {
                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-apply',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'start')
                }, _('Start')));
            }

            // Stop/Restart (Only if running)
            if (isRunning) {
                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-reset',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'stop')
                }, _('Stop')));

                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-neutral',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'restart')
                }, _('Restart')));
            }

            // Reinstall (Only if installed)
            if (isInstalled) {
                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-negative',
                    'style': 'margin-left: 10px;',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'reinstall')
                }, _('Force Reinstall')));

                // Uninstall (Only if installed)
                buttons.push(E('button', {
                    'class': 'btn cbi-button cbi-button-negative',
                    'click': ui.createHandlerFn(this, 'handleServiceAction', 'uninstall')
                }, _('Uninstall')));
            }

            return E('div', { 'class': 'cbi-value-field' }, buttons);
        }, this);

        return m.render();
    }
});