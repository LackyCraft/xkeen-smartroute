'use strict';
'require view';
'require ui';
'require poll';
'require xkeen-smartroute as sr';

// Shared "boxed" look for the page's three top-level blocks (add profile /
// add custom domain / existing profiles) -- LuCI's own .cbi-section doesn't
// draw a visible boundary by default, which is exactly why these used to
// read as one continuous blob instead of three separate things.
var BOX_STYLE = 'border:1px solid var(--border-color-medium,#ccc);border-radius:6px;padding:1em;margin-bottom:1.25em';

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.listServers(),
			sr.rpc.listCategories(),
			sr.rpc.listCustomCategories(),
			sr.rpc.listProfiles(),
			sr.rpc.listLanDevices(),
			sr.rpc.getPings(),
			sr.rpc.listCustomLists(),
			sr.rpc.getCurrent(),
			sr.rpc.getActivity()
		]);
	},

	handleAddCustomDomain: function (ev) {
		var nameInput = document.getElementById('sr-cd-name');
		var domInput = document.getElementById('sr-cd-domains');
		var name = nameInput.value.trim();
		var domainsRaw = domInput.value.trim();
		if (!name || !domainsRaw) return;

		// Sanitize client-side too, and tell the user when it actually
		// changed something -- pasting "https://2ip.ru/some/path" and
		// having it silently become "2ip.ru" on save is easy to miss
		// otherwise, and the raw-URL version never matches real traffic.
		var sanitizedList = domainsRaw.split(',').map(function (d) { return sr.sanitizeDomain(d.trim()); }).filter(Boolean);
		var domains = sanitizedList.join(',');
		if (domains !== domainsRaw.split(',').map(function (d) { return d.trim(); }).filter(Boolean).join(',')) {
			ui.addNotification(null, E('p', {}, sr.T('domains_sanitized_note') + domains), 'info');
		}

		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.addCustomDomain(name, domains).then(L.bind(function (res) {
			btn.disabled = false;
			if (res && res.error === 'list_already_exists') {
				ui.addNotification(null, E('p', {}, sr.T('domains_list_already_exists')), 'error');
				return;
			}
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, res.error), 'error');
				return;
			}
			ui.addNotification(null, E('p', {}, sr.T('add_btn') + ': ' + res.file), 'info');
			nameInput.value = '';
			domInput.value = '';
			this.refreshDomainSourceOptions(name, res.file);
			return this.reloadCustomLists();
		}, this));
	},

	refreshDomainSourceOptions: function (key, file) {
		var sel = document.getElementById('sr-domain-source');
		if (!sel) return;
		var opt = E('option', { 'value': 'custom::' + file }, '[custom] ' + key);
		sel.appendChild(opt);
		sel.value = 'custom::' + file;
	},

	// --- domain list management: view/add/remove individual domains, or
	// delete a whole list. Separate from the "add a new list" form above --
	// that one only ever creates brand-new lists (rejects a name that
	// already exists), this is where you touch an existing one.
	reloadCustomLists: function () {
		var view = this;
		return sr.rpc.listCustomLists().then(function (lists) {
			view.customLists = lists || [];
			view.renderCustomLists();
		});
	},

	handleToggleCustomList: function (key) {
		this.customListExpanded = this.customListExpanded || {};
		this.customListExpanded[key] = !this.customListExpanded[key];
		this.renderCustomLists();
	},

	handleDeleteCustomList: function (key, label) {
		if (!confirm(sr.T('domains_delete_list_confirm').replace('%s', label))) return;
		var view = this;
		return sr.rpc.deleteCustomList(key).then(function () { return view.reloadCustomLists(); });
	},

	handleAddDomainToList: function (key, ev) {
		var input = document.querySelector('input[data-add-domain-for="' + CSS.escape(key) + '"]');
		var raw = input.value.trim();
		if (!raw) return;
		var domain = sr.sanitizeDomain(raw);
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.addDomainToList(key, domain).then(function () {
			btn.disabled = false;
			input.value = '';
			return view.reloadCustomLists();
		});
	},

	handleRemoveDomainFromList: function (key, domain) {
		var view = this;
		return sr.rpc.removeDomainFromList(key, domain).then(function () { return view.reloadCustomLists(); });
	},

	renderCustomLists: function () {
		var view = this;
		var container = document.getElementById('sr-custom-lists');
		if (!container) return;
		container.innerHTML = '';
		var lists = view.customLists || [];

		if (!lists.length) {
			container.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('domains_no_lists')));
			return;
		}

		lists.forEach(function (l) {
			var isOpen = !!(view.customListExpanded && view.customListExpanded[l.key]);
			var label = sr.lang() === 'en' ? (l.label_en || l.key) : (l.label_ru || l.key);

			var toggle = E('a', { 'href': '#', 'style': 'font-weight:bold;text-decoration:none' },
				(isOpen ? '▾ ' : '▸ ') + label + ' — ' + l.domains.length);
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); view.handleToggleCustomList(l.key); });

			var deleteBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, sr.T('delete_btn'));
			deleteBtn.addEventListener('click', function () { view.handleDeleteCustomList(l.key, label); });

			var card = E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:.5em' }, [
				E('div', { 'style': 'display:flex;align-items:center;gap:1em' }, [
					toggle,
					E('div', { 'style': 'margin-left:auto' }, [deleteBtn])
				])
			]);

			if (isOpen) {
				var list = E('div', { 'style': 'margin:.5em 0 0 .5em' });
				l.domains.forEach(function (d) {
					var rmBtn = E('button', { 'class': 'cbi-button cbi-button-remove', 'style': 'padding:.1em .5em;font-size:.85em' }, '×');
					rmBtn.addEventListener('click', function () { view.handleRemoveDomainFromList(l.key, d); });
					list.appendChild(E('div', { 'style': 'display:flex;align-items:center;gap:.5em;padding:.15em 0' }, [d, rmBtn]));
				});
				var addRow = E('div', { 'style': 'display:flex;gap:.5em;margin-top:.5em;max-width:24em' }, [
					E('input', { 'type': 'text', 'class': 'cbi-input-text', 'data-add-domain-for': l.key, 'placeholder': sr.T('domains_add_domain_placeholder') }),
					E('button', { 'class': 'cbi-button' }, sr.T('add_btn'))
				]);
				addRow.lastChild.addEventListener('click', function (ev) { view.handleAddDomainToList(l.key, ev); });
				list.appendChild(addRow);
				card.appendChild(list);
			}

			container.appendChild(card);
		});
	},

	// --- server picker: grouped by subscription, collapsible, mirrors the
	// same card pattern the Subscriptions page uses -- picking a server for
	// a profile out of a single flat list of 100+ entries across several
	// subscriptions was the actual usability problem being solved here, not
	// just cosmetics.
	pingLabel: function (tag) {
		var ms = (this.pings || {})[tag];
		if (ms === null || ms === undefined) return sr.T('ping_timeout');
		if (typeof ms === 'number') return ms + ' ms';
		return '—';
	},

	groupServersBySubscription: function (servers) {
		var groups = {};
		var order = [];
		servers.forEach(function (s) {
			var key = s.subscription || '';
			if (!groups[key]) { groups[key] = []; order.push(key); }
			groups[key].push(s);
		});
		return order.map(function (key) { return { label: key, servers: groups[key] }; });
	},

	handleToggleServerGroup: function (label) {
		this.serverGroupExpanded = this.serverGroupExpanded || {};
		this.serverGroupExpanded[label] = !this.serverGroupExpanded[label];
		this.renderServerPicker();
	},

	renderServerPicker: function () {
		var view = this;
		var box = document.getElementById('sr-server-picker');
		if (!box) return;
		box.innerHTML = '';
		var servers = view.servers || [];
		var mode = document.getElementById('sr-mode') ? document.getElementById('sr-mode').value : 'fixed';

		if (!servers.length) {
			box.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('need_servers_first')));
			return;
		}

		// Keep whatever was already checked across a re-render (mode switch,
		// group expand/collapse) instead of losing the user's picks.
		var previouslyChecked = {};
		box.querySelectorAll('input[name="sr-server-choice"]:checked').forEach(function (i) { previouslyChecked[i.value] = true; });

		var groups = view.groupServersBySubscription(servers);
		groups.forEach(function (g) {
			var isOpen = !!(view.serverGroupExpanded && view.serverGroupExpanded[g.label]);
			var toggle = E('a', { 'href': '#', 'style': 'font-weight:bold;text-decoration:none;display:block;margin:.5em 0 .25em' },
				(isOpen ? '▾ ' : '▸ ') + (g.label || sr.T('sub_no_subscriptions')) + ' — ' + g.servers.length + ' ' + sr.T('sub_servers_word'));
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); view.handleToggleServerGroup(g.label); });
			box.appendChild(toggle);

			if (!isOpen) return;
			var list = E('div', { 'style': 'margin:0 0 .5em .5em' });
			g.servers.forEach(function (s) {
				var input = E('input', {
					'type': mode === 'fixed' ? 'radio' : 'checkbox',
					'name': 'sr-server-choice',
					'value': s.tag
				});
				input.checked = !!previouslyChecked[s.tag];
				list.appendChild(E('label', { 'style': 'display:flex;align-items:center;gap:.4em;padding:.15em 0' }, [
					input, sr.renderName(s.name), ' (', s.address, ':', String(s.port), ', ', s.protocol, ', ', view.pingLabel(s.tag), ')'
				]));
			});
			box.appendChild(list);
		});
	},

	handleModeChange: function () {
		document.getElementById('sr-server-picker-label').textContent =
			document.getElementById('sr-mode').value === 'fixed' ? sr.T('pick_server') : sr.T('pick_servers');
		this.renderServerPicker();
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

	handleSaveProfile: function (ev) {
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

	// save_profile already upserts by name (genroute.sh just overwrites
	// $SR_PROFILES_DIR/<name>.json) -- the only missing piece for "editing"
	// was ever a frontend one: loading an existing profile's fields back
	// into the add-profile form instead of re-entering everything by hand.
	// Saving under the same name then replaces it in place.
	handleEditProfile: function (name) {
		var view = this;
		var p = (this.profiles || []).filter(function (x) { return x.name === name; })[0];
		if (!p) return;

		document.getElementById('sr-profile-name').value = p.name;
		var srcType = (p.domain_source && p.domain_source.type) || 'any';
		document.getElementById('sr-domain-source').value =
			srcType === 'geosite' ? 'geosite::' + p.domain_source.value
				: srcType === 'custom' ? 'custom::' + p.domain_source.file
				: 'any::';
		document.getElementById('sr-mode').value = p.mode;
		this.handleModeChange();

		var tags = p.mode === 'fixed' ? [p.fixed_server] : (p.servers || []);
		this.serverGroupExpanded = this.serverGroupExpanded || {};
		tags.forEach(function (t) {
			var s = view.serverForTag(t);
			if (s) view.serverGroupExpanded[s.subscription || ''] = true;
		});
		this.renderServerPicker();
		tags.forEach(function (t) {
			var input = document.querySelector('input[name="sr-server-choice"][value="' + CSS.escape(t) + '"]');
			if (input) input.checked = true;
		});

		(p.devices || []).forEach(function (d) { view.addDeviceCheckbox(d, d, true); });

		window.scrollTo({ top: 0, behavior: 'smooth' });
		ui.addNotification(null, E('p', {}, sr.T('edit_loaded_note')), 'info');
	},

	reloadProfilesTable: function () {
		return sr.rpc.listProfiles().then(L.bind(function (profiles) {
			this.profiles = profiles || [];
			this.renderProfilesTable(this.profiles);
		}, this));
	},

	// Refreshes just the two fast-changing signals behind the "online now"
	// dot -- which tag each profile currently resolves to, and which tags
	// have carried traffic in the last few seconds -- without re-fetching
	// the whole page's data (servers/profiles/etc change rarely by
	// comparison). Re-renders only the profiles table, so an open pool
	// expander (profileTargetExpanded) survives the refresh the same way it
	// already does across reloadProfilesTable/handleToggleProfileTarget.
	pollActivity: function () {
		var view = this;
		return Promise.all([sr.rpc.getCurrent(), sr.rpc.getActivity()]).then(function (data) {
			view.current = data[0] || {};
			view.activeTags = {};
			(data[1] || []).forEach(function (t) { view.activeTags[t] = true; });
			if (view.profiles) view.renderProfilesTable(view.profiles);
		});
	},

	serverForTag: function (tag) {
		return (this.servers || []).filter(function (x) { return x.tag === tag; })[0] || { tag: tag, name: tag };
	},

	// Small colored dot: green + glow while the given outbound tag has
	// carried traffic in the last few seconds (this.activeTags, refreshed by
	// pollActivity), grey otherwise. Grey covers both "genuinely idle" and
	// "no data yet" -- there's no third state worth the extra complexity,
	// since the tooltip already explains what green means.
	activityDot: function (tag) {
		var active = !!(tag && this.activeTags && this.activeTags[tag]);
		return E('span', {
			'title': sr.T(active ? 'activity_online' : 'activity_idle'),
			'style': 'display:inline-block;width:.6em;height:.6em;border-radius:50%;margin-right:.4em;' +
				(active ? 'background:#2ecc71;box-shadow:0 0 4px #2ecc71' : 'background:var(--border-color-medium,#bbb)')
		});
	},

	handleToggleProfileTarget: function (name) {
		this.profileTargetExpanded = this.profileTargetExpanded || {};
		this.profileTargetExpanded[name] = !this.profileTargetExpanded[name];
		this.reloadProfilesTable();
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
			var domainsParts = [];
			if (srcType === 'geosite') domainsParts.push('geosite:' + p.domain_source.value);
			else if (srcType === 'custom') domainsParts.push(p.domain_source.file);
			else domainsParts.push(sr.T('domain_source_any'));
			if ((p.devices || []).length) domainsParts.push('📱 ' + p.devices.join(', '));

			var targetNode;
			if (p.mode === 'fixed') {
				targetNode = E('span', {}, [view.activityDot(p.fixed_server), sr.renderName(view.serverForTag(p.fixed_server).name)]);
			} else {
				var tags = p.servers || [];
				var currentTag = (view.current && view.current[p.name]) || '';
				var isOpen = !!(view.profileTargetExpanded && view.profileTargetExpanded[p.name]);
				var toggle = E('a', { 'href': '#', 'style': 'text-decoration:none' },
					(isOpen ? '▾ ' : '▸ ') + tags.length + ' ' + sr.T('sub_servers_word') + ' (auto)');
				toggle.addEventListener('click', function (ev) { ev.preventDefault(); view.handleToggleProfileTarget(p.name); });
				var children = [];
				if (currentTag) {
					children.push(E('div', { 'style': 'margin-bottom:.25em' }, [view.activityDot(currentTag), sr.renderName(view.serverForTag(currentTag).name)]));
				}
				children.push(toggle);
				if (isOpen) {
					var list = E('div', { 'style': 'margin:.35em 0 0 .5em' });
					tags.forEach(function (t) {
						list.appendChild(E('div', { 'style': 'padding:.1em 0' }, [view.activityDot(t), sr.renderName(view.serverForTag(t).name)]));
					});
					children.push(list);
				}
				targetNode = E('span', {}, children);
			}

			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, p.name),
				E('td', { 'class': 'td' }, domainsParts.join(' · ')),
				E('td', { 'class': 'td' }, targetNode),
				E('td', { 'class': 'td', 'style': 'display:flex;gap:.4em' }, [
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(view, function () { return view.handleEditProfile(p.name); })
					}, sr.T('edit_btn')),
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(view, function () { return view.handleDeleteProfile(p.name); })
					}, sr.T('delete_btn'))
				])
			]));
		});

		container.appendChild(table);
	},

	render: function (data) {
		var view = this;
		this.servers = data[0] || [];
		var categories = data[1] || [];
		var customCategories = data[2] || [];
		this.profiles = data[3] || [];
		var profiles = this.profiles;
		var lanDevices = data[4] || [];
		this.pings = data[5] || {};
		this.customLists = data[6] || [];
		this.current = data[7] || {};
		this.activeTags = {};
		(data[8] || []).forEach(function (t) { view.activeTags[t] = true; });
		this.serverGroupExpanded = {};
		this.customListExpanded = {};

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
		modeSelect.addEventListener('change', function () { view.handleModeChange(); });

		var addProfileBox = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('add_profile_title')),
			E('p', {}, sr.T('profiles_intro')),

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
				'click': ui.createHandlerFn(view, 'handleSaveProfile')
			}, sr.T('save_profile_btn'))
		]);

		var customDomainBox = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('custom_domain_title')),
			E('p', {}, sr.T('custom_domain_intro')),
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
		]);

		var manageDomainsBox = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('domains_manage_title')),
			E('p', {}, sr.T('domains_manage_intro')),
			E('div', { 'id': 'sr-custom-lists' })
		]);

		var existingBox = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('existing_profiles')),
			E('div', { 'id': 'sr-profiles-table' })
		]);

		var root = E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_profiles')),

			addProfileBox,
			customDomainBox,
			manageDomainsBox,
			existingBox
		]);

		requestAnimationFrame(function () {
			view.renderServerPicker();
			view.buildDevicePicker(lanDevices);
			view.renderProfilesTable(profiles);
			view.renderCustomLists();
		});

		// Live "online now" dot: poll.js ties this to the page's own
		// lifecycle (paused when the browser tab is hidden, stopped when
		// LuCI navigates away), so it doesn't need its own manual
		// start/stop bookkeeping the way a raw setInterval would.
		// activityInterval in gateway/activity.go is 3s -- polling from here
		// at the same cadence means a dot lights up about as fast as the
		// gateway itself can possibly know about it.
		poll.add(function () { return view.pollActivity(); }, 3);

		return root;
	}
});
