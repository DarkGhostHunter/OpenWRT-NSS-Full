'use strict';
'require dom';
'require view';
'require poll';
'require fs';
'require ui';
'require uci';
'require form';

/*
	button handling
*/
function handleAction(ev) {
    if (ev === 'restart' || ev === 'start' || ev === 'stop' || ev === 'reclaim') {
        const map = document.querySelector('.cbi-map');

        document.querySelectorAll('.cbi-page-actions button').forEach(function (btn) {
            btn.disabled = true;
            btn.blur();
        });

        return dom.callClassMethod(map, 'save')
            .then(L.bind(ui.changes.apply, ui.changes))
            .then(function () {
                return fs.exec('/etc/init.d/plexmediaserver', [ev]);
            })
            .then(function () {
                var msg = _('Command executed successfully.');
                if (ev === 'start') msg = _('Service started.');
                if (ev === 'stop') msg = _('Service stopped.');
                if (ev === 'restart') msg = _('Service restarted.');
                if (ev === 'reclaim') msg = _('Ownership reclaimed recursively.');

                ui.addNotification(null, E('p', msg));

                if (ev === 'stop' || ev === 'reclaim') {
                    document.querySelectorAll('.cbi-page-actions button').forEach(function (btn) {
                        btn.disabled = false;
                    });
                    poll.start();
                } else {
                    window.setTimeout(function() { location.reload(); }, 3000);
                }
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', _('Error executing command: ') + e.message), 'error');
                document.querySelectorAll('.cbi-page-actions button').forEach(function (btn) {
                    btn.disabled = false;
                });
            });
    }
}

return view.extend({
    load: function () {
        return Promise.all([
            // 0: Check process status
            L.resolveDefault(fs.exec('/usr/bin/pgrep', ['-f', 'Plex Media Server']), null),
            // 1: Get Version from config
            L.resolveDefault(fs.exec('/bin/sh', ['-c', '. /etc/config/plexmediaserver; echo $version']), {}),
            // 2: Get LAN IP for URL generation
            L.resolveDefault(fs.exec_direct('/sbin/ip', ['-4', 'addr', 'show', 'br-lan']), null),
            // 3: Check if Installed (using new is_installed command)
            L.resolveDefault(fs.exec('/etc/init.d/plexmediaserver', ['is_installed']), {}),
            // 4: Check if Browser Root Exists (using new check_browser_root command)
            L.resolveDefault(fs.exec('/etc/init.d/plexmediaserver', ['check_browser_root']), {}),
            // 5: Check Browser Root Ownership (kept as shell command since it returns specific data, not just bool)
            L.resolveDefault(fs.exec('/bin/sh', ['-c', '. /etc/config/plexmediaserver; if [ -n "$browser_root" ] && [ -d "$browser_root" ]; then stat -c "%u:%g" "$browser_root"; fi']), {}),
            uci.load('plexmediaserver')
        ]);
    },
    render: function (data) {
        var isRunning = (data[0] && data[0].code === 0);
        var plexVersion = (data[1] && data[1].stdout) ? data[1].stdout.trim() : '-';
        // is_installed returns 0 on success, so code===0 means installed
        var isInstalled = (data[3] && data[3].code === 0);
        // check_browser_root returns 0 on success
        var isBrowserRootExists = (data[4] && data[4].code === 0);
        var currentOwner = (data[5] && data[5].stdout) ? data[5].stdout.trim() : '0:0';

        // Get Configured User/Group (default to 0:0 if empty)
        var confUser = uci.get(data[6], 'main', 'run_user') || '0';
        var confGroup = uci.get(data[6], 'main', 'run_group') || '0';
        var targetOwner = confUser + ':' + confGroup;

        var isOwnerMismatch = (currentOwner !== targetOwner && isBrowserRootExists);
        var isRootUser = (confUser === '0' || confUser === 'root');

        // Extract IP for link
        var lanIp = '192.168.1.1'; // fallback
        if (data[2]) {
            var match = data[2].match(/inet\s+(\d+\.\d+\.\d+\.\d+)/);
            if (match) lanIp = match[1];
        }
        var plexUrl = 'http://' + lanIp + ':32400/web';

        let m, s, o;

        m = new form.Map('plexmediaserver', _('Plex Media Server'), _('Configuration and status monitoring for the Plex Media Server.'));

        /*
            poll runtime information
        */
        poll.add(function () {
            // FIX: If not installed or Root missing, stop the poller from overwriting status
            if (!isInstalled || !isBrowserRootExists) return;

            return fs.exec('/usr/bin/pgrep', ['-f', 'Plex Media Server']).then(function (res) {
                const status = document.getElementById('status');
                const running = (res && res.code === 0);

                if (status) {
                    if (running) {
                        status.textContent = _('Running');
                        status.style.color = 'green';
                        status.style.fontWeight = 'bold';
                        status.classList.remove('spinning');

                        // Update button states dynamically if needed
                        var btnStart = document.querySelector('button[title="Start Service"]');
                        var btnStop = document.querySelector('button[title="Stop Service"]');
                        if(btnStart) btnStart.disabled = true;
                        if(btnStop) btnStop.disabled = false;
                    } else {
                        status.textContent = _('Stopped');
                        status.style.color = 'red';
                        status.style.fontWeight = 'bold';

                        // Update button states dynamically if needed
                        var btnStart = document.querySelector('button[title="Start Service"]');
                        var btnStop = document.querySelector('button[title="Stop Service"]');
                        if(btnStart) btnStart.disabled = false;
                        if(btnStop) btnStop.disabled = true;
                    }
                }
            });
        }, 5);

        // Log Poller
        poll.add(function() {
            var logEl = document.getElementById('widget.cbid.plexmediaserver.main._log');
            if (logEl) {
                return fs.exec('/sbin/logread', ['-e', 'plexmediaserver', '-l', '100']).then(function(res) {
                    if (res.code === 0 && res.stdout) {
                        logEl.value = res.stdout;
                        logEl.scrollTop = logEl.scrollHeight;
                    }
                });
            }
        }, 5);

        /*
            runtime information (Section 1 - Custom Render)
        */
        s = m.section(form.NamedSection, 'main');
        s.render = L.bind(function (view, section_id) {
            // Status Logic
            var statusHTML;
            if (!isInstalled) {
                statusHTML = E('span', { 'style': 'color:orange; font-weight:bold;' }, _('Not Installed - Please Run Update'));
            } else if (!isBrowserRootExists) {
                statusHTML = E('span', { 'style': 'color:red; font-weight:bold;' }, _('Error: Browser Root directory not found. Please mount your drive.'));
            } else {
                statusHTML = isRunning
                    ? E('span', { 'style': 'color:green; font-weight:bold;' }, _('Running'))
                    : E('span', { 'style': 'color:red; font-weight:bold;' }, _('Stopped'));
            }

            // Ownership Warning
            var ownerHTML = '-';
            if (isBrowserRootExists) {
                if (isOwnerMismatch) {
                    ownerHTML = E('span', { 'style': 'color:orange; font-weight:bold;' },
                        _('Mismatch! Root is owned by ') + currentOwner + _(', configured for ') + targetOwner);
                } else {
                    ownerHTML = E('span', { 'style': 'color:green;' }, _('Correct (') + currentOwner + ')');
                }
            }

            return E('div', { 'class': 'cbi-section' }, [
                E('h3', _('Information')),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title', 'style': 'margin-bottom:-5px;padding-top:0rem;' }, _('Status')),
                    E('div', { 'class': 'cbi-value-field', 'id': 'status', 'style': 'margin-bottom:-5px;' }, statusHTML)
                ]),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title', 'style': 'margin-bottom:-5px;padding-top:0rem;' }, _('Permissions')),
                    E('div', { 'class': 'cbi-value-field', 'style': 'margin-bottom:-5px;' }, ownerHTML)
                ]),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title', 'style': 'margin-bottom:-5px;padding-top:0rem;' }, _('Version')),
                    E('div', { 'class': 'cbi-value-field', 'id': 'version', 'style': 'margin-bottom:-5px;color:#37c;' }, plexVersion)
                ]),
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title', 'style': 'margin-bottom:-5px;padding-top:0rem;' }, _('Web Interface')),
                    E('div', { 'class': 'cbi-value-field', 'style': 'margin-bottom:-5px;' },
                        E('a', { 'href': plexUrl, 'target': '_blank', 'rel': 'noreferrer noopener' }, plexUrl)
                    )
                ])
            ]);
        }, o, this);

        /*
            tabbed config section (Section 2 - Settings)
        */
        s = m.section(form.NamedSection, 'main', 'plexmediaserver', _('Settings'));
        s.addremove = false;
        s.anonymous = true;
        s.tab('general', _('General Settings'));
        s.tab('paths', _('Storage Paths'));
        s.tab('update', _('Updates & Maintenance'));
        s.tab('log', _('Log'));

        /*
            general settings tab
        */
        o = s.taboption('general', form.Flag, 'enabled', _('Enable Autostart'), _('Enables the service to start automatically on boot.'));
        o.rmempty = false;
        o.write = function(section_id, value) {
            var action = (value == '1') ? 'enable' : 'disable';
            return Promise.resolve(this.super('write', [section_id, value]))
                .then(function() {
                    return fs.exec('/etc/init.d/plexmediaserver', [action]);
                });
        };

        o = s.taboption('general', form.Value, 'run_user', _('Run as User (ID)'), _('The user ID to run Plex as. Set to 0 for root.'));
        o.placeholder = '0';
        o.datatype = 'uinteger';
        o.rmempty = true;

        o = s.taboption('general', form.Value, 'run_group', _('Run as Group (ID)'), _('The group ID to run Plex as. Set to 0 for root.'));
        o.placeholder = '0';
        o.datatype = 'uinteger';
        o.rmempty = true;

        o = s.taboption('general', form.Value, 'claim_code', _('Plex Claim Code'), _('Optional. Use a claim code from <a href="https://plex.tv/claim" target="_blank">plex.tv/claim</a>. Required for first run only.'));
        o.password = true;
        o.placeholder = 'claim-xxxxxxxxxxxxxxxxxxxx';

        o = s.taboption('general', form.Value, 'force_version', _('Force Specific Version'), _('Manually specify a version folder name to use (found in tmp directory). Leave empty to auto-detect highest version.'));
        o.rmempty = true;

        /*
            Paths Tab
        */
        o = s.taboption('paths', form.Value, 'browser_root', _('Browser Root'), _('Mountpoint of the USB HDD containing the Plex library. Leave empty to auto-detect.'));
        o.placeholder = '/mnt/sda1';

        // Auto-fill logic
        o.validate = function(section_id, value) {
            if (value) {
                var root = value.replace(/\/+$/, '');
                var id_pfx = 'widget.cbid.plexmediaserver.' + section_id + '.';
                var defaults = {
                    'library_dir': '/.plex/Library',
                    'application_support_dir': '/.plex/Library/Application Support',
                    'compressed_archive_path': '/.plex/Library/Application/plexmediaserver.sqfs'
                };
                for (var key in defaults) {
                    var el = document.getElementById(id_pfx + key);
                    if (el && el.value === '') {
                        el.value = root + defaults[key];
                        el.dispatchEvent(new Event('change', { bubbles: true }));
                        el.dispatchEvent(new Event('blur', { bubbles: true }));
                    }
                }
            }
            return true;
        };

        o = s.taboption('paths', form.Value, 'library_dir', _('Library Directory'), _('Path to the main Plex library data. Defaults to the Browser Root path appended with /.plex/Library.'));
        o = s.taboption('paths', form.Value, 'application_support_dir', _('Application Support Dir'), _('Where metadata is stored. Defaults to the Library Directory path appended with /Application Support.'));
        o = s.taboption('paths', form.Value, 'compressed_archive_path', _('Compressed Archive Path'), _('Location of plexmediaserver.sqfs or .txz. Defaults to the Library Directory path appended with /Application/plexmediaserver.sqfs.'));

        // Reclaim Button
        o = s.taboption('paths', form.Button, '_do_reclaim', _('Reclaim Ownership'));
        o.inputtitle = _('Reclaim Now');
        o.inputstyle = 'apply';

        if (isRootUser) {
            o.disabled = true;
            o.inputtitle = _('Not Needed (Root)');
            o.description = _('There is no point on using Reclaim if the user that runs Plex Media Server is root, since it has access to all files, but its internal library data will be owned by root.');
        } else {
            o.description = _('Recursively changes ownership of the Browser Root to the configured User/Group.');
            if (!isBrowserRootExists) {
                o.inputtitle = _('Root Missing');
                o.disabled = true;
            }
        }

        o.onclick = function() {
            if (!confirm(_('This will run chown -R on your entire Browser Root. This may take a while depending on file count. Continue?'))) return;
            ui.addNotification(null, E('p', _('Reclaiming ownership...')));
            return handleAction('reclaim');
        };

        /*
            Update Tab
        */
        o = s.taboption('update', form.Value, 'force_update_download_url', _('Custom Update URL'), _('Override the automatic download URL for Plex updates.'));

        // Maintenance Buttons
        o = s.taboption('update', form.Button, '_check_update', _('Check for Updates'));
        o.inputtitle = _('Check Now');
        o.inputstyle = 'apply';
        o.onclick = function() {
            ui.showModal(_('Checking for updates...'), [ E('p', { 'class': 'spinning' }, _('Executing check_update routine...')) ]);
            return fs.exec('/etc/init.d/plexmediaserver', ['check_update']).then(function(res) {
                ui.showModal(_('Update Check Result'), [
                    E('pre', {}, [ res.stdout || res.stderr || _('No output returned.') ]),
                    E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Close')) ])
                ]);
            }).catch(function(e) { ui.addNotification(null, E('p', _('Error checking update: ') + e.message)); ui.hideModal(); });
        };

        o = s.taboption('update', form.Button, '_do_update', _('Perform Update'), _('Downloads and repacks the latest version. This may take several minutes.'));
        o.inputtitle = _('Update Plex');
        o.inputstyle = 'action';
        // Add visual emphasis if not installed
        if (!isInstalled) {
            o.inputstyle = 'save'; // Highlights green usually
            o.description = _('Plex is NOT installed. Click here to download and install it.');
        }

        o.onclick = function() {
            if (!confirm(_('Are you sure you want to perform an update? This might take a while.'))) return;
            ui.addNotification(null, E('p', _('Update started in background. Please wait...')));
            return fs.exec('/bin/sh', ['-c', '/etc/init.d/plexmediaserver update > /dev/null 2>&1 &'])
                .then(function() {
                    // Reload page after a delay to check for installation status
                    window.setTimeout(function() { location.reload(); }, 15000);
                });
        };

        o = s.taboption('update', form.Button, '_do_reset', _('Reset Config'), _('WARNING: Wipes the Plex Media Server config and regenerates it from scratch.'));
        o.inputtitle = _('Wipe Config');
        o.inputstyle = 'reset';
        o.onclick = function() {
            if (!confirm(_('WARNING: This will wipe your Plex configuration! Are you sure?'))) return;
            return fs.exec('/etc/init.d/plexmediaserver', ['reset']).then(function() { location.reload(); });
        };

        /*
            Log Tab
        */
        o = s.taboption('log', form.TextValue, '_log');
        o.rows = 20;
        o.wrap = 'off';
        o.readonly = true;
        o.cfgvalue = function() { return _('Loading logs...'); };
        o.write = function() {};

        /*
            Page Actions (Section 3 - Footer Buttons)
        */
        s = m.section(form.NamedSection, 'main');
        s.render = L.bind(function () {
            // FIX: If installed and root exists, buttons should be enabled regardless of running state
            // But specific buttons should be toggleable based on state (Start vs Stop)

            var isLocked = !isInstalled || !isBrowserRootExists;

            // Logic:
            // Stop: Disabled if locked OR NOT running
            // Start: Disabled if locked OR running
            // Restart: Disabled if locked (always enabled if unlocked, to force restart)

            var btnStopState = isLocked || !isRunning;
            var btnStartState = isLocked || isRunning;
            var btnRestartState = isLocked;

            return E('div', { 'class': 'cbi-page-actions' }, [
                E('button', {
                    'class': 'btn cbi-button cbi-button-negative important',
                    'style': 'float:none;margin-right:.4em;',
                    'title': 'Stop Service',
                    'disabled': btnStopState,
                    'click': function () { return handleAction('stop'); }
                }, [_('Stop')]),
                E('button', {
                    'class': 'btn cbi-button cbi-button-apply important',
                    'style': 'float:none;margin-right:.4em;',
                    'title': 'Start Service',
                    'disabled': btnStartState,
                    'click': function () { return handleAction('start'); }
                }, [_('Start')]),
                E('button', {
                    'class': 'btn cbi-button cbi-button-positive important',
                    'style': 'float:none;margin-right:.4em;',
                    'title': 'Save & Restart',
                    'disabled': btnRestartState,
                    'click': function () { return handleAction('restart'); }
                }, [_('Save & Restart')])
            ])
        });

        return m.render();
    }
});