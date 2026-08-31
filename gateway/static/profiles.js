'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var st = {
		servers: [], profiles: [], pings: {}, lanDevices: [], current: {}, activeTags: {},
		serverGroupExpanded: {}, profileTargetExpanded: {}, picked: {}
	};

	// pingLabel/serverForTag/activityDot/groupServersBySubscription now live
	// in the shared app.js module (SR.*) -- see its own comment for why.

	// Reads/writes st.picked, never the DOM -- the picker only renders
	// <input> elements for currently-expanded subscription groups, so a
	// server checked in a group the user has since collapsed has no
	// element left to query at the next re-render or at save time.
	// st.picked is kept in sync by each checkbox's own change event below
	// regardless of which groups are open, so it's the only complete
	// source of truth (same pattern doublevpn.js uses for its pool picker).
	function renderServerPicker() {
		var box = document.getElementById('sr-server-picker');
		if (!box) return;
		box.innerHTML = '';
		var mode = document.getElementById('sr-mode') ? document.getElementById('sr-mode').value : 'fixed';

		if (!st.servers.length) { box.appendChild(E('p', { class: 'sr-desc' }, T('need_servers_first'))); return; }

		SR.groupServersBySubscription(st.servers).forEach(function (g) {
			var isOpen = !!st.serverGroupExpanded[g.label];
			var toggle = E('a', { href: '#', style: 'font-weight:700;display:block;margin:6px 0 3px' },
				(isOpen ? '▾ ' : '▸ ') + (g.label || T('sub_no_subscriptions')) + ' — ' + g.servers.length + ' ' + T('sub_servers_word'));
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.serverGroupExpanded[g.label] = !st.serverGroupExpanded[g.label]; renderServerPicker(); });
			box.appendChild(toggle);
			if (!isOpen) return;
			var list = E('div', { style: 'margin:0 0 6px 8px' });
			g.servers.forEach(function (s) {
				var input = E('input', { type: mode === 'fixed' ? 'radio' : 'checkbox', name: 'sr-server-choice', value: s.tag });
				input.checked = !!st.picked[s.tag];
				input.addEventListener('change', function () {
					if (mode === 'fixed') {
						// Only one fixed_server is ever saved -- reset
						// rather than accumulate, so a later save can't
						// pick up a stale tag from a since-collapsed group.
						st.picked = {};
						if (input.checked) st.picked[s.tag] = true;
					} else if (input.checked) {
						st.picked[s.tag] = true;
					} else {
						delete st.picked[s.tag];
					}
				});
				list.appendChild(E('label', { class: 'sr-row', style: 'padding:2px 0' }, [
					input, SR.renderName(s.name), ' (' + s.address + ':' + s.port + ', ' + s.protocol + ', ' + SR.pingLabel(s.tag, st.pings) + ')'
				]));
			});
			box.appendChild(list);
		});
	}

	function deviceIpLabel(d) {
		var parts = [d.ip];
		if (d.hostname) parts.push('(' + d.hostname + (d.mac ? ', ' + d.mac : '') + ')');
		else if (d.mac) parts.push('(' + d.mac + ')');
		return parts.join(' ');
	}

	function addDeviceCheckbox(ip, label, checked) {
		var box = document.getElementById('sr-device-picker');
		if (!box) return;
		var existing = box.querySelector('input[value="' + CSS.escape(ip) + '"]');
		if (existing) { existing.checked = true; return; }
		var input = E('input', { type: 'checkbox', name: 'sr-device-choice', value: ip });
		input.checked = !!checked;
		box.appendChild(E('label', { style: 'display:block;padding:2px 0' }, [input, ' ', label]));
	}

	function buildDevicePicker(devices) {
		var box = document.getElementById('sr-device-picker');
		if (!box) return;
		box.innerHTML = '';
		if (!devices.length) { box.appendChild(E('p', { class: 'sr-desc' }, T('devices_none_detected'))); return; }
		devices.forEach(function (d) { addDeviceCheckbox(d.ip, deviceIpLabel(d), false); });
	}

	function reloadProfilesTable() {
		return api.listProfiles().then(function (profiles) { st.profiles = profiles || []; renderProfilesTable(); });
	}

	function pollActivity() {
		return Promise.all([api.getCurrent(), api.getActivity()]).then(function (data) {
			st.current = data[0] || {};
			st.activeTags = {};
			(data[1] || []).forEach(function (t) { st.activeTags[t] = true; });
			if (st.profiles.length) renderProfilesTable();
		});
	}

	function renderProfilesTable() {
		var container = document.getElementById('sr-profiles-table');
		if (!container) return;
		container.innerHTML = '';
		if (!st.profiles.length) { container.appendChild(E('p', { class: 'sr-desc' }, T('no_profiles'))); return; }

		var table = E('table', { class: 'sr-table' }, [E('tr', {}, [E('th', {}, T('profile_name')), E('th', {}, T('col_domains')), E('th', {}, T('col_target')), E('th', {}, '')])]);
		var tagOwners = SR.buildTagOwners(st.profiles, st.current);
		function sharedWith(p, tag) { return (tagOwners[tag] || []).filter(function (n) { return n !== p.name; }); }

		st.profiles.forEach(function (p) {
			var srcType = (p.domain_source && p.domain_source.type) || 'any';
			var ipRanges = p.ip_ranges || [];
			var domainsParts = [];
			if (srcType === 'geosite') domainsParts.push('geosite:' + p.domain_source.value);
			else if (srcType === 'custom') domainsParts.push(p.domain_source.file);
			else if (!ipRanges.length) domainsParts.push(T('domain_source_any'));
			if ((p.devices || []).length) domainsParts.push('📱 ' + p.devices.join(', '));
			if (ipRanges.length) domainsParts.push('🌐 ' + ipRanges.join(', '));

			var targetNode;
			if (p.mode === 'fixed') {
				targetNode = E('span', {}, [SR.activityDot(p.fixed_server, st.activeTags, sharedWith(p, p.fixed_server)), SR.renderName(SR.serverForTag(p.fixed_server, st.servers).name)]);
			} else {
				var tags = p.servers || [];
				var currentTag = st.current[p.name] || '';
				var isOpen = !!st.profileTargetExpanded[p.name];
				var toggle = E('a', { href: '#' }, (isOpen ? '▾ ' : '▸ ') + tags.length + ' ' + T('sub_servers_word') + ' (auto)');
				toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.profileTargetExpanded[p.name] = !st.profileTargetExpanded[p.name]; renderProfilesTable(); });
				var children = [];
				if (currentTag) children.push(E('div', { style: 'margin-bottom:3px' }, [SR.activityDot(currentTag, st.activeTags, sharedWith(p, currentTag)), SR.renderName(SR.serverForTag(currentTag, st.servers).name)]));
				children.push(toggle);
				if (isOpen) {
					var list = E('div', { style: 'margin:4px 0 0 8px' });
					tags.forEach(function (t) { list.appendChild(E('div', { style: 'padding:1px 0' }, [SR.activityDot(t, st.activeTags), SR.renderName(SR.serverForTag(t, st.servers).name)])); });
					children.push(list);
				}
				targetNode = E('span', {}, children);
			}

			table.appendChild(E('tr', {}, [
				E('td', {}, p.name), E('td', {}, domainsParts.join(' · ')), E('td', {}, targetNode),
				E('td', { class: 'sr-row' }, [
					E('button', { class: 'sr-btn sr-btn-sm', click: function () { handleEditProfile(p.name); } }, T('edit_btn')),
					E('button', {
						class: 'sr-btn sr-btn-sm sr-btn-remove', click: function () {
							if (!confirm(T('profile_delete_confirm').replace('%s', p.name))) return;
							api.deleteProfile(p.name).then(function (res) {
								if (res && res.error) { SR.toast(T('status_action_failed') + ': ' + (res.detail || res.error), 'error'); return; }
								SR.toast(T('profile_deleted_ok'), 'info');
								return reloadProfilesTable();
							});
						}
					}, T('delete_btn'))
				])
			]));

			var removed = p.removed_servers || [];
			if (removed.length) {
				table.appendChild(E('tr', {}, [E('td', { colspan: '4', class: 'sr-warning-row' },
					'⚠ ' + removed.map(function (r) { return r.name || r.tag; }).join(', ') + ' — ' + T('profile_removed_servers_label'))]));
			}
		});
		container.appendChild(table);
	}

	// --- add/edit modal ---

	function handleEditProfile(name) {
		var p = st.profiles.filter(function (x) { return x.name === name; })[0];
		if (p) openProfileModal(p);
	}

	// Fetches geosite/custom categories fresh on every open (not just once at
	// page load) -- the Domains tab can add a new custom list at any time,
	// and this modal is the only place that dropdown appears, so there's no
	// other moment to refresh it from.
	function openProfileModal(existing) {
		Promise.all([api.listCategories(), api.listCustomCategories()]).then(function (data) {
			var categories = data[0] || [], customCategories = data[1] || [];
			st.serverGroupExpanded = {};
			st.picked = {};

			var domainSourceSelect = E('select', { class: 'sr-select', id: 'sr-domain-source' }, [E('option', { value: 'any::' }, T('domain_source_any'))]);
			domainSourceSelect.appendChild(E('optgroup', { label: T('domain_source_geosite') },
				categories.map(function (c) { return E('option', { value: 'geosite::' + c.key }, SR.lang() === 'en' ? c.label_en : c.label_ru); })));
			domainSourceSelect.appendChild(E('optgroup', { label: T('domain_source_custom') },
				customCategories.map(function (c) { return E('option', { value: 'custom::' + c.file }, SR.lang() === 'en' ? c.label_en : c.label_ru); })));

			var modeSelect = E('select', { class: 'sr-select', id: 'sr-mode' }, [
				E('option', { value: 'fixed' }, T('mode_fixed')), E('option', { value: 'balancer' }, T('mode_balancer'))
			]);
			modeSelect.addEventListener('change', function () {
				document.getElementById('sr-server-picker-label').textContent = modeSelect.value === 'fixed' ? T('pick_server') : T('pick_servers');
				// Switching to "fixed" only ever saves one server
				// (chosen[0]) -- trim any carried-over multi-selection
				// down to one now, so the single radio left checked after
				// render matches what save would actually use.
				if (modeSelect.value === 'fixed') {
					var keys = Object.keys(st.picked);
					if (keys.length > 1) { st.picked = {}; st.picked[keys[0]] = true; }
				}
				renderServerPicker();
			});

			var form = E('div', {}, [
				E('p', { class: 'sr-desc' }, T('profiles_intro')),
				E('label', { class: 'sr-label' }, T('profile_name')),
				E('input', { type: 'text', id: 'sr-profile-name', class: 'sr-input', placeholder: T('profile_name_placeholder') }),
				E('label', { class: 'sr-label' }, T('domain_source')), domainSourceSelect,
				E('label', { class: 'sr-label' }, T('mode_label')), modeSelect,
				E('label', { class: 'sr-label', id: 'sr-server-picker-label' }, T('pick_server')),
				E('div', { id: 'sr-server-picker' }),
				E('label', { class: 'sr-label' }, T('devices_title')),
				E('p', { class: 'sr-desc' }, T('devices_intro')),
				E('div', { class: 'sr-row' }, [
					E('input', { type: 'text', id: 'sr-device-manual', class: 'sr-input', placeholder: T('devices_manual_placeholder') }),
					E('button', { class: 'sr-btn sr-btn-sm', click: handleAddManualDevice }, T('devices_manual_add'))
				]),
				E('div', { id: 'sr-device-picker' }),
				E('label', { class: 'sr-label' }, T('ip_ranges_title')),
				E('p', { class: 'sr-desc' }, T('ip_ranges_intro')),
				E('textarea', { id: 'sr-ip-ranges', class: 'sr-textarea', rows: '4', placeholder: T('ip_ranges_placeholder') }),
				E('div', { class: 'sr-row', style: 'margin-top:6px' }, [
					E('input', { type: 'file', id: 'sr-ip-ranges-file', accept: '.bat,.txt', style: 'display:none', change: handleLoadBatFile }),
					E('button', { class: 'sr-btn sr-btn-sm', click: function () { document.getElementById('sr-ip-ranges-file').click(); } }, T('ip_ranges_load_bat_btn'))
				]),
				E('div', { class: 'sr-modal-actions' }, [
					E('button', { class: 'sr-btn sr-btn-primary', click: handleSaveProfile }, T('save_profile_btn')),
					E('button', { class: 'sr-btn', click: function () { SR.modal.close(); } }, T('modal_cancel'))
				])
			]);

			SR.modal.open(existing ? T('edit_btn') + ': ' + existing.name : T('add_profile_title'), form);

			renderServerPicker();
			buildDevicePicker(st.lanDevices);

			if (existing) {
				document.getElementById('sr-profile-name').value = existing.name;
				var srcType = (existing.domain_source && existing.domain_source.type) || 'any';
				domainSourceSelect.value = srcType === 'geosite' ? 'geosite::' + existing.domain_source.value
					: srcType === 'custom' ? 'custom::' + existing.domain_source.file : 'any::';
				modeSelect.value = existing.mode;
				document.getElementById('sr-server-picker-label').textContent = existing.mode === 'fixed' ? T('pick_server') : T('pick_servers');

				var tags = existing.mode === 'fixed' ? [existing.fixed_server] : (existing.servers || []);
				tags.forEach(function (t) {
					st.picked[t] = true;
					var s = SR.serverForTag(t, st.servers);
					if (s) st.serverGroupExpanded[s.subscription || ''] = true;
				});
				renderServerPicker();

				(existing.devices || []).forEach(function (d) { addDeviceCheckbox(d, d, true); });
				document.getElementById('sr-ip-ranges').value = (existing.ip_ranges || []).join('\n');
			}
		});
	}

	function handleSaveProfile(ev) {
		var name = document.getElementById('sr-profile-name').value.trim();
		var mode = document.getElementById('sr-mode').value;
		var srcRaw = document.getElementById('sr-domain-source').value;
		var chosen = Object.keys(st.picked);
		var devices = Array.prototype.slice.call(document.querySelectorAll('input[name="sr-device-choice"]:checked')).map(function (i) { return i.value; });
		var ipRangesRaw = document.getElementById('sr-ip-ranges').value;
		var parsedRanges = SR.parseIpRanges(ipRangesRaw);
		if (parsedRanges.errors.length) { SR.toast(T('ip_ranges_invalid') + ': ' + parsedRanges.errors.join(', '), 'error'); return; }
		var ip_ranges = parsedRanges.entries;
		if (!name) { SR.toast(T('profile_name'), 'error'); return; }
		if (!chosen.length) { SR.toast(T('need_servers_first'), 'error'); return; }

		var domain_source;
		if (srcRaw.indexOf('any::') === 0) domain_source = { type: 'any' };
		else if (srcRaw.indexOf('geosite::') === 0) domain_source = { type: 'geosite', value: srcRaw.slice('geosite::'.length) };
		else domain_source = { type: 'custom', file: srcRaw.slice('custom::'.length) };

		if (domain_source.type === 'any' && !devices.length && !ip_ranges.length) { SR.toast(T('devices_no_domain_warning'), 'error'); return; }

		var profile = { name: name, domain_source: domain_source, mode: mode, devices: devices, ip_ranges: ip_ranges };
		if (mode === 'fixed') profile.fixed_server = chosen[0]; else profile.servers = chosen;

		var btn = ev.target; btn.disabled = true; btn.textContent = T('saving');
		api.saveProfile(JSON.stringify(profile)).then(function (res) {
			btn.disabled = false; btn.textContent = T('save_profile_btn');
			if (res && res.error) { SR.toast(T('save_failed') + ': ' + (res.detail || res.error), 'error'); return; }
			SR.toast(T('saved_ok'), 'info');
			SR.modal.close();
			return reloadProfilesTable();
		});
	}

	// handleLoadBatFile: dumps the picked file's raw text into the ip_ranges
	// textarea (appended, not replacing whatever's already typed there) --
	// no upload, no server round-trip, just a local FileReader. Parsing/
	// validation happens uniformly at save time via SR.parseIpRanges, same
	// as text typed by hand, so a malformed .bat surfaces the same error.
	function handleLoadBatFile(ev) {
		var file = ev.target.files && ev.target.files[0];
		if (!file) return;
		var reader = new FileReader();
		reader.onload = function () {
			var textarea = document.getElementById('sr-ip-ranges');
			var existing = textarea.value.replace(/\s+$/, '');
			var text = String(reader.result || '');
			textarea.value = existing ? existing + '\n' + text : text;
		};
		reader.readAsText(file);
		ev.target.value = '';
	}

	function handleAddManualDevice() {
		var input = document.getElementById('sr-device-manual');
		var val = input.value.trim();
		if (!val) return;
		if (!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(val)) { SR.toast(T('devices_manual_invalid'), 'error'); return; }
		addDeviceCheckbox(val, val, true);
		input.value = '';
	}

	function render(container) {
		container.innerHTML = '';
		st.serverGroupExpanded = {}; st.profileTargetExpanded = {};

		var toolbar = E('div', { class: 'sr-page-toolbar' }, [
			E('h1', { class: 'sr-page-title', style: 'margin:0' }, T('nav_profiles')),
			E('button', { class: 'sr-btn sr-btn-primary', click: function () { openProfileModal(null); } }, T('add_profile_btn'))
		]);
		var existingBox = E('div', { class: 'sr-card' }, [E('h3', {}, T('existing_profiles')), E('div', { id: 'sr-profiles-table' })]);

		container.appendChild(E('div', {}, [toolbar, existingBox]));

		Promise.all([api.listServers(), api.listProfiles(), api.listLanDevices(), api.getPings(), api.getCurrent(), api.getActivity()])
			.then(function (data) {
				st.servers = data[0] || [];
				st.profiles = data[1] || [];
				st.lanDevices = data[2] || [];
				st.pings = data[3] || {};
				st.current = data[4] || {};
				st.activeTags = {};
				(data[5] || []).forEach(function (t) { st.activeTags[t] = true; });

				renderProfilesTable();

				// Skips the real getCurrent/getActivity fetch (each an
				// api.* call -> a fresh `sh`-exec of the 26KB rpcd script)
				// while this section isn't the visible one or the browser
				// tab itself is backgrounded -- the "online now" dot has no
				// reason to stay live for a page nobody can see. Always
				// reschedules regardless, so the very next tick notices on
				// its own once visible again, no separate resume needed.
				(function pollLoop() {
					if (!SR.sectionVisible('profiles')) { setTimeout(pollLoop, 3000); return; }
					pollActivity().then(function () { setTimeout(pollLoop, 3000); }, function () { setTimeout(pollLoop, 3000); });
				})();
			});
	}

	renderers.profiles = render;
})();
