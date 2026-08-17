'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.listServers(),
			sr.rpc.listCategories(),
			sr.rpc.listCustomCategories(),
			sr.rpc.listProfiles(),
			sr.rpc.listLanDevices()
		]);
	},

	handleAddCustomDomain: function (ev) {
		var nameInput = document.getElementById('sr-cd-name');
		var domInput = document.getElementById('sr-cd-domains');
		var name = nameInput.value.trim();
		var domains = domInput.value.trim();
		if (!name || !domains) return;

		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.addCustomDomain(name, domains).then(L.bind(function (res) {
			btn.disabled = false;
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, res.error), 'error');
				return;
			}
			ui.addNotification(null, E('p', {}, sr.T('add_btn') + ': ' + res.file), 'info');
			nameInput.value = '';
			domInput.value = '';
			this.refreshDomainSourceOptions(name, res.file);
		}, this));
	},

	refreshDomainSourceOptions: function (key, file) {
		var sel = document.getElementById('sr-domain-source');
		if (!sel) return;
		var opt = E('option', { 'value': 'custom::' + file }, '[custom] ' + key);
		sel.appendChild(opt);
		sel.value = 'custom::' + file;
	},

	buildServerCheckboxes: function (servers, mode) {
		var box = document.getElementById('sr-server-picker');
		box.innerHTML = '';
		if (!servers.length) {
			box.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('need_servers_first')));
			return;
		}
		servers.forEach(function (s) {
			var input = E('input', {
				'type': mode === 'fixed' ? 'radio' : 'checkbox',
				'name': 'sr-server-choice',
				'value': s.tag
			});
			box.appendChild(E('label', { 'style': 'display:block' }, [
				input, ' ', s.name, ' (', s.address, ', ', s.protocol, ')'
			]));
		});
	},

	handleModeChange: function (servers, ev) {
		var mode = ev.target.value;
		document.getElementById('sr-server-picker-label').textContent =
			mode === 'fixed' ? sr.T('pick_server') : sr.T('pick_servers');
		this.buildServerCheckboxes(servers, mode);
	},

	// Device-based routing (Policy-Based Routing by device): a checklist of
	// devices currently seen on the LAN (DHCP leases + ARP table, via
	// list_lan_devices), plus a manual IP/CIDR entry for anything not
	// currently on the network (or a whole subnet). Both feed the same
	// checkbox list so save just reads whatever's checked, regardless of
	// where the entry came from.
	deviceIpLabel: function (d) {
		var parts = [d.ip];
		if (d.hostname) parts.push('(' + d.hostname + (d.mac ? ', ' + d.mac : '') + ')');
		else if (d.mac) parts.push('(' + d.mac + ')');
		return parts.join(' ');
	},

	addDeviceCheckbox: function (ip, label, checked) {
		var box = document.getElementById('sr-device-picker');
		if (!box) return;
		var existing = box.querySelector('input[value="' + CSS.escape(ip) + '"]');
		if (existing) { existing.checked = true; return; }
		var input = E('input', { 'type': 'checkbox', 'name': 'sr-device-choice', 'value': ip });
		input.checked = !!checked;
		box.appendChild(E('label', { 'style': 'display:block' }, [input, ' ', label]));
	},

	buildDevicePicker: function (devices) {
		var box = document.getElementById('sr-device-picker');
		box.innerHTML = '';
		if (!devices.length) {
			box.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('devices_none_detected')));
			return;
		}
		var view = this;
		devices.forEach(function (d) { view.addDeviceCheckbox(d.ip, view.deviceIpLabel(d), false); });
	},

	handleAddManualDevice: function (ev) {
		var input = document.getElementById('sr-device-manual');
		var val = input.value.trim();
		if (!val) return;
		// IPv4 address or CIDR only -- matches what genroute.sh itself
		// accepts server-side; catching the typo here beats a save-time
		// error round-trip.
		if (!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(val)) {
			ui.addNotification(null, E('p', {}, sr.T('devices_manual_invalid')));
			return;
		}
		this.addDeviceCheckbox(val, val, true);
		input.value = '';
	},

	handleSaveProfile: function (servers, ev) {
		var name = document.getElementById('sr-profile-name').value.trim();
		var mode = document.getElementById('sr-mode').value;
		var srcRaw = document.getElementById('sr-domain-source').value;
		var chosen = Array.prototype.slice.call(
			document.querySelectorAll('input[name="sr-server-choice"]:checked')
		).map(function (i) { return i.value; });
		var devices = Array.prototype.slice.call(
			document.querySelectorAll('input[name="sr-device-choice"]:checked')
		).map(function (i) { return i.value; });

		if (!name) { ui.addNotification(null, E('p', {}, sr.T('profile_name'))); return; }
		if (!chosen.length) { ui.addNotification(null, E('p', {}, sr.T('need_servers_first'))); return; }

		var domain_source;
		if (srcRaw.indexOf('any::') === 0) {
			domain_source = { type: 'any' };
		} else if (srcRaw.indexOf('geosite::') === 0) {
			domain_source = { type: 'geosite', value: srcRaw.slice('geosite::'.length) };
		} else {
			domain_source = { type: 'custom', file: srcRaw.slice('custom::'.length) };
		}

		if (domain_source.type === 'any' && !devices.length) {
			ui.addNotification(null, E('p', {}, sr.T('devices_no_domain_warning')));
			return;
		}

		var profile = { name: name, domain_source: domain_source, mode: mode, devices: devices };
		if (mode === 'fixed') profile.fixed_server = chosen[0];
		else profile.servers = chosen;

		var btn = ev.target;
		btn.disabled = true;
		btn.textContent = sr.T('saving');

		return sr.rpc.saveProfile(JSON.stringify(profile)).then(L.bind(function (res) {
			btn.disabled = false;
			btn.textContent = sr.T('save_profile_btn');
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, sr.T('save_failed') + ': ' + (res.detail || res.error)), 'error');
				return;
			}
			ui.addNotification(null, E('p', {}, sr.T('saved_ok')), 'info');
			return this.reloadProfilesTable();
		}, this));
	},

	handleDeleteProfile: function (name) {
		return sr.rpc.deleteProfile(name).then(L.bind(function () {
			return this.reloadProfilesTable();
		}, this));
	},

	reloadProfilesTable: function () {
		return sr.rpc.listProfiles().then(L.bind(function (profiles) {
			this.renderProfilesTable(profiles || []);
		}, this));
	},

	renderProfilesTable: function (profiles) {
		var view = this;
		var container = document.getElementById('sr-profiles-table');
		container.innerHTML = '';

		if (!profiles.length) {
			container.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('no_profiles')));
			return;
		}

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, sr.T('profile_name')),
				E('th', { 'class': 'th' }, sr.T('col_domains')),
				E('th', { 'class': 'th' }, sr.T('col_target')),
				E('th', { 'class': 'th' }, '')
			])
		]);

		profiles.forEach(function (p) {
			var srcType = (p.domain_source && p.domain_source.type) || 'any';
			var domainsLabel = srcType === 'geosite' ? 'geosite:' + p.domain_source.value
				: srcType === 'custom' ? p.domain_source.file
				: sr.T('domain_source_any');
			if ((p.devices || []).length) {
				domainsLabel += ' [' + p.devices.join(', ') + ']';
			}
			var targetLabel = p.mode === 'fixed'
				? p.fixed_server
				: (p.servers || []).join(', ') + ' (leastPing)';

			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, p.name),
				E('td', { 'class': 'td' }, domainsLabel),
				E('td', { 'class': 'td' }, targetLabel),
				E('td', { 'class': 'td' }, E('button', {
					'class': 'cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(view, function () { return view.handleDeleteProfile(p.name); })
				}, sr.T('delete_btn')))
			]));
		});

		container.appendChild(table);
	},

	render: function (data) {
		var view = this;
		var servers = data[0] || [];
		var categories = data[1] || [];
		var customCategories = data[2] || [];
		var profiles = data[3] || [];
		var lanDevices = data[4] || [];

		var domainSourceSelect = E('select', { 'class': 'cbi-input-select', 'id': 'sr-domain-source' }, [
			E('option', { 'value': 'any::' }, sr.T('domain_source_any')),
			E('optgroup', { 'label': sr.T('domain_source_geosite') },
				categories.map(function (c) {
					return E('option', { 'value': 'geosite::' + c.key }, sr.lang() === 'en' ? c.label_en : c.label_ru);
				})),
			E('optgroup', { 'label': sr.T('domain_source_custom') },
				customCategories.map(function (c) {
					return E('option', { 'value': 'custom::' + c.file }, sr.lang() === 'en' ? c.label_en : c.label_ru);
				}))
		]);

		var modeSelect = E('select', { 'class': 'cbi-input-select', 'id': 'sr-mode' }, [
			E('option', { 'value': 'fixed' }, sr.T('mode_fixed')),
			E('option', { 'value': 'balancer' }, sr.T('mode_balancer'))
		]);
		modeSelect.addEventListener('change', function (ev) { view.handleModeChange(servers, ev); });

		var root = E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_profiles')),
			E('p', {}, sr.T('profiles_intro')),

			E('div', { 'class': 'cbi-section' }, [
				E('label', {}, sr.T('profile_name')),
				E('input', {
					'type': 'text', 'id': 'sr-profile-name', 'class': 'cbi-input-text',
					'style': 'display:block;width:100%;max-width:320px;margin:.25em 0 1em',
					'placeholder': sr.T('profile_name_placeholder')
				}),

				E('label', {}, sr.T('domain_source')),
				E('div', { 'style': 'margin:.25em 0 1em' }, [domainSourceSelect]),

				E('label', {}, sr.T('mode_label')),
				E('div', { 'style': 'margin:.25em 0 1em' }, [modeSelect]),

				E('label', { 'id': 'sr-server-picker-label' }, sr.T('pick_server')),
				E('div', { 'id': 'sr-server-picker', 'style': 'margin:.25em 0 1em' }),

				E('label', {}, sr.T('devices_title')),
				E('p', { 'class': 'cbi-value-description', 'style': 'margin:.25em 0' }, sr.T('devices_intro')),
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;max-width:28em;margin:.25em 0 .5em' }, [
					E('input', {
						'type': 'text', 'id': 'sr-device-manual', 'class': 'cbi-input-text',
						'placeholder': sr.T('devices_manual_placeholder')
					}),
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(view, 'handleAddManualDevice')
					}, sr.T('devices_manual_add'))
				]),
				E('div', { 'id': 'sr-device-picker', 'style': 'margin:.25em 0 1em' }),

				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': ui.createHandlerFn(view, function (ev) { return view.handleSaveProfile(servers, ev); })
				}, sr.T('save_profile_btn'))
			]),

			E('h3', {}, sr.T('custom_domain_title')),
			E('p', {}, sr.T('custom_domain_intro')),
			E('div', { 'class': 'cbi-section' }, [
				E('input', {
					'type': 'text', 'id': 'sr-cd-name', 'class': 'cbi-input-text',
					'style': 'width:100%;max-width:320px;display:block;margin-bottom:.5em',
					'placeholder': sr.T('custom_list_name_placeholder')
				}),
				E('input', {
					'type': 'text', 'id': 'sr-cd-domains', 'class': 'cbi-input-text',
					'style': 'width:100%;max-width:640px;display:block;margin-bottom:.5em',
					'placeholder': sr.T('custom_domains_placeholder')
				}),
				E('button', {
					'class': 'cbi-button',
					'click': ui.createHandlerFn(view, 'handleAddCustomDomain')
				}, sr.T('add_btn'))
			]),

			E('h3', {}, sr.T('existing_profiles')),
			E('div', { 'id': 'sr-profiles-table' })
		]);

		requestAnimationFrame(function () {
			view.buildServerCheckboxes(servers, 'fixed');
			view.buildDevicePicker(lanDevices);
			view.renderProfilesTable(profiles);
		});

		return root;
	}
});
