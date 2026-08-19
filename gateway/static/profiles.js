'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var st = {
		servers: [], profiles: [], pings: {}, customLists: [], current: {}, activeTags: {},
		serverGroupExpanded: {}, customListExpanded: {}, profileTargetExpanded: {}
	};

	function pingLabel(tag) {
		var ms = st.pings[tag];
		if (ms === null || ms === undefined) return T('ping_timeout');
		if (typeof ms === 'number') return ms + ' ms';
		return '—';
	}

	function serverForTag(tag) {
		return st.servers.filter(function (x) { return x.tag === tag; })[0] || { tag: tag, name: tag };
	}

	function activityDot(tag) {
		var active = !!(tag && st.activeTags[tag]);
		return E('span', { title: T(active ? 'activity_online' : 'activity_idle'), class: 'sr-dot ' + (active ? 'sr-dot-ok' : '') });
	}

	function groupServersBySubscription(servers) {
		var groups = {}, order = [];
		servers.forEach(function (s) {
			var key = s.subscription || '';
			if (!groups[key]) { groups[key] = []; order.push(key); }
			groups[key].push(s);
		});
		return order.map(function (key) { return { label: key, servers: groups[key] }; });
	}

	function renderServerPicker() {
		var box = document.getElementById('sr-server-picker');
		if (!box) return;
		var previouslyChecked = {};
		box.querySelectorAll('input[name="sr-server-choice"]:checked').forEach(function (i) { previouslyChecked[i.value] = true; });
		box.innerHTML = '';
		var mode = document.getElementById('sr-mode') ? document.getElementById('sr-mode').value : 'fixed';

		if (!st.servers.length) { box.appendChild(E('p', { class: 'sr-desc' }, T('need_servers_first'))); return; }

		groupServersBySubscription(st.servers).forEach(function (g) {
			var isOpen = !!st.serverGroupExpanded[g.label];
			var toggle = E('a', { href: '#', style: 'font-weight:700;display:block;margin:6px 0 3px' },
				(isOpen ? '▾ ' : '▸ ') + (g.label || T('sub_no_subscriptions')) + ' — ' + g.servers.length + ' ' + T('sub_servers_word'));
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.serverGroupExpanded[g.label] = !st.serverGroupExpanded[g.label]; renderServerPicker(); });
			box.appendChild(toggle);
			if (!isOpen) return;
			var list = E('div', { style: 'margin:0 0 6px 8px' });
			g.servers.forEach(function (s) {
				var input = E('input', { type: mode === 'fixed' ? 'radio' : 'checkbox', name: 'sr-server-choice', value: s.tag });
				input.checked = !!previouslyChecked[s.tag];
				list.appendChild(E('label', { class: 'sr-row', style: 'padding:2px 0' }, [
					input, SR.renderName(s.name), ' (' + s.address + ':' + s.port + ', ' + s.protocol + ', ' + pingLabel(s.tag) + ')'
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
				targetNode = E('span', {}, [activityDot(p.fixed_server), SR.renderName(serverForTag(p.fixed_server).name)]);
			} else {
				var tags = p.servers || [];
				var currentTag = st.current[p.name] || '';
				var isOpen = !!st.profileTargetExpanded[p.name];
				var toggle = E('a', { href: '#' }, (isOpen ? '▾ ' : '▸ ') + tags.length + ' ' + T('sub_servers_word') + ' (auto)');
				toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.profileTargetExpanded[p.name] = !st.profileTargetExpanded[p.name]; renderProfilesTable(); });
				var children = [];
				if (currentTag) children.push(E('div', { style: 'margin-bottom:3px' }, [activityDot(currentTag), SR.renderName(serverForTag(currentTag).name)]));
				children.push(toggle);
				if (isOpen) {
					var list = E('div', { style: 'margin:4px 0 0 8px' });
					tags.forEach(function (t) { list.appendChild(E('div', { style: 'padding:1px 0' }, [activityDot(t), SR.renderName(serverForTag(t).name)])); });
					children.push(list);
				}
				targetNode = E('span', {}, children);
			}

			table.appendChild(E('tr', {}, [
				E('td', {}, p.name), E('td', {}, domainsParts.join(' · ')), E('td', {}, targetNode),
				E('td', { class: 'sr-row' }, [
					E('button', { class: 'sr-btn sr-btn-sm', click: function () { handleEditProfile(p.name); } }, T('edit_btn')),
					E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove', click: function () { api.deleteProfile(p.name).then(reloadProfilesTable); } }, T('delete_btn'))
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

	function handleEditProfile(name) {
		var p = st.profiles.filter(function (x) { return x.name === name; })[0];
		if (!p) return;
		document.getElementById('sr-profile-name').value = p.name;
		var srcType = (p.domain_source && p.domain_source.type) || 'any';
		document.getElementById('sr-domain-source').value = srcType === 'geosite' ? 'geosite::' + p.domain_source.value
			: srcType === 'custom' ? 'custom::' + p.domain_source.file : 'any::';
		document.getElementById('sr-mode').value = p.mode;
		document.getElementById('sr-server-picker-label').textContent = p.mode === 'fixed' ? T('pick_server') : T('pick_servers');
		renderServerPicker();

		var tags = p.mode === 'fixed' ? [p.fixed_server] : (p.servers || []);
		tags.forEach(function (t) {
			var s = serverForTag(t);
			if (s) st.serverGroupExpanded[s.subscription || ''] = true;
		});
		renderServerPicker();
		tags.forEach(function (t) {
			var input = document.querySelector('input[name="sr-server-choice"][value="' + CSS.escape(t) + '"]');
			if (input) input.checked = true;
		});

		(p.devices || []).forEach(function (d) { addDeviceCheckbox(d, d, true); });
		document.getElementById('sr-ip-ranges').value = (p.ip_ranges || []).join('\n');
		window.scrollTo({ top: 0, behavior: 'smooth' });
		SR.toast(T('edit_btn') + ' ' + name, 'info');
	}

	function handleSaveProfile(ev) {
		var name = document.getElementById('sr-profile-name').value.trim();
		var mode = document.getElementById('sr-mode').value;
		var srcRaw = document.getElementById('sr-domain-source').value;
		var chosen = Array.prototype.slice.call(document.querySelectorAll('input[name="sr-server-choice"]:checked')).map(function (i) { return i.value; });
		var devices = Array.prototype.slice.call(document.querySelectorAll('input[name="sr-device-choice"]:checked')).map(function (i) { return i.value; });
		var ipRangesRaw = document.getElementById('sr-ip-ranges').value.trim();
		var ip_ranges = ipRangesRaw ? ipRangesRaw.split(/[\s,]+/).map(function (s) { return s.trim(); }).filter(Boolean) : [];
		var badIp = ip_ranges.filter(function (s) { return !/^[0-9a-fA-F.:]+(\/\d{1,3})?$/.test(s); })[0];
		if (badIp) { SR.toast(T('ip_ranges_invalid') + ': ' + badIp, 'error'); return; }
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
			return reloadProfilesTable();
		});
	}

	function handleAddManualDevice() {
		var input = document.getElementById('sr-device-manual');
		var val = input.value.trim();
		if (!val) return;
		if (!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(val)) { SR.toast(T('devices_manual_invalid'), 'error'); return; }
		addDeviceCheckbox(val, val, true);
		input.value = '';
	}

	// --- custom domain lists ---
	function reloadCustomLists() { return api.listCustomLists().then(function (lists) { st.customLists = lists || []; renderCustomLists(); }); }

	function renderCustomLists() {
		var container = document.getElementById('sr-custom-lists');
		if (!container) return;
		container.innerHTML = '';
		if (!st.customLists.length) { container.appendChild(E('p', { class: 'sr-desc' }, T('domains_no_lists'))); return; }

		st.customLists.forEach(function (l) {
			var isOpen = !!st.customListExpanded[l.key];
			var label = SR.lang() === 'en' ? (l.label_en || l.key) : (l.label_ru || l.key);
			var toggle = E('a', { href: '#', style: 'font-weight:700' }, (isOpen ? '▾ ' : '▸ ') + label + ' — ' + l.domains.length);
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.customListExpanded[l.key] = !st.customListExpanded[l.key]; renderCustomLists(); });
			var deleteBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove' }, T('delete_btn'));
			deleteBtn.addEventListener('click', function () {
				if (!confirm(T('domains_delete_list_confirm').replace('%s', label))) return;
				api.deleteCustomList(l.key).then(reloadCustomLists);
			});
			var card = E('div', { class: 'sr-card', style: 'margin-bottom:.5em' }, [E('div', { class: 'sr-row-between' }, [toggle, deleteBtn])]);

			if (isOpen) {
				var list = E('div', { style: 'margin:8px 0 0 4px' });
				l.domains.forEach(function (d) {
					var rmBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove', style: 'padding:1px 8px' }, '×');
					rmBtn.addEventListener('click', function () { api.removeDomainFromList(l.key, d).then(reloadCustomLists); });
					list.appendChild(E('div', { class: 'sr-row', style: 'padding:2px 0' }, [d, rmBtn]));
				});
				var addInput = E('input', { type: 'text', class: 'sr-input', style: 'max-width:220px' , placeholder: T('domains_add_domain_placeholder') });
				var addBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('add_btn'));
				addBtn.addEventListener('click', function () {
					var raw = addInput.value.trim();
					if (!raw) return;
					api.addDomainToList(l.key, SR.sanitizeDomain(raw)).then(function () { addInput.value = ''; reloadCustomLists(); });
				});
				list.appendChild(E('div', { class: 'sr-row', style: 'margin-top:6px;max-width:24em' }, [addInput, addBtn]));
				card.appendChild(list);
			}
			container.appendChild(card);
		});
	}

	function handleAddCustomDomain() {
		var nameInput = document.getElementById('sr-cd-name'), domInput = document.getElementById('sr-cd-domains');
		var name = nameInput.value.trim(), domainsRaw = domInput.value.trim();
		if (!name || !domainsRaw) return;
		var sanitizedList = domainsRaw.split(',').map(function (d) { return SR.sanitizeDomain(d.trim()); }).filter(Boolean);
		var domains = sanitizedList.join(',');
		if (domains !== domainsRaw.split(',').map(function (d) { return d.trim(); }).filter(Boolean).join(',')) SR.toast(T('domains_sanitized_note') + domains, 'info');

		api.addCustomDomain(name, domains).then(function (res) {
			if (res && res.error === 'list_already_exists') { SR.toast(T('domains_list_already_exists'), 'error'); return; }
			if (res && res.error) { SR.toast(res.error, 'error'); return; }
			SR.toast(T('add_btn') + ': ' + res.file, 'info');
			var sel = document.getElementById('sr-domain-source');
			if (sel) { sel.appendChild(E('option', { value: 'custom::' + res.file }, '[custom] ' + name)); sel.value = 'custom::' + res.file; }
			nameInput.value = ''; domInput.value = '';
			return reloadCustomLists();
		});
	}

	function render(container) {
		container.innerHTML = '';
		st.serverGroupExpanded = {}; st.customListExpanded = {}; st.profileTargetExpanded = {};

		var domainSourceSelect = E('select', { class: 'sr-select', id: 'sr-domain-source' }, [E('option', { value: 'any::' }, T('domain_source_any'))]);
		var modeSelect = E('select', { class: 'sr-select', id: 'sr-mode' }, [
			E('option', { value: 'fixed' }, T('mode_fixed')), E('option', { value: 'balancer' }, T('mode_balancer'))
		]);
		modeSelect.addEventListener('change', function () {
			document.getElementById('sr-server-picker-label').textContent = modeSelect.value === 'fixed' ? T('pick_server') : T('pick_servers');
			renderServerPicker();
		});

		var addProfileBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('add_profile_title')), E('p', { class: 'sr-desc' }, T('profiles_intro')),
			E('label', { class: 'sr-label' }, T('profile_name')),
			E('input', { type: 'text', id: 'sr-profile-name', class: 'sr-input', style: 'max-width:320px', placeholder: T('profile_name_placeholder') }),
			E('label', { class: 'sr-label' }, T('domain_source')), domainSourceSelect,
			E('label', { class: 'sr-label' }, T('mode_label')), modeSelect,
			E('label', { class: 'sr-label', id: 'sr-server-picker-label' }, T('pick_server')),
			E('div', { id: 'sr-server-picker' }),
			E('label', { class: 'sr-label' }, T('devices_title')),
			E('p', { class: 'sr-desc' }, T('devices_intro')),
			E('div', { class: 'sr-row', style: 'max-width:28em' }, [
				E('input', { type: 'text', id: 'sr-device-manual', class: 'sr-input', placeholder: T('devices_manual_placeholder') }),
				E('button', { class: 'sr-btn sr-btn-sm', click: handleAddManualDevice }, T('devices_manual_add'))
			]),
			E('div', { id: 'sr-device-picker' }),
			E('label', { class: 'sr-label' }, T('ip_ranges_title')),
			E('p', { class: 'sr-desc' }, T('ip_ranges_intro')),
			E('textarea', { id: 'sr-ip-ranges', class: 'sr-textarea', rows: '4', style: 'max-width:28em', placeholder: T('ip_ranges_placeholder') }),
			E('div', { style: 'margin-top:10px' }, [E('button', { class: 'sr-btn sr-btn-primary', click: handleSaveProfile }, T('save_profile_btn'))])
		]);

		var customDomainBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('custom_domain_title')), E('p', { class: 'sr-desc' }, T('custom_domain_intro')),
			E('input', { type: 'text', id: 'sr-cd-name', class: 'sr-input', style: 'max-width:320px;margin-bottom:6px', placeholder: T('custom_list_name_placeholder') }),
			E('input', { type: 'text', id: 'sr-cd-domains', class: 'sr-input', style: 'margin-bottom:6px', placeholder: T('custom_domains_placeholder') }),
			E('button', { class: 'sr-btn', click: handleAddCustomDomain }, T('add_btn'))
		]);

		var manageDomainsBox = E('div', { class: 'sr-card' }, [E('h3', {}, T('domains_manage_title')), E('div', { id: 'sr-custom-lists' })]);
		var existingBox = E('div', { class: 'sr-card' }, [E('h3', {}, T('existing_profiles')), E('div', { id: 'sr-profiles-table' })]);

		container.appendChild(E('div', {}, [E('h1', { class: 'sr-page-title' }, T('nav_profiles')), addProfileBox, customDomainBox, manageDomainsBox, existingBox]));

		Promise.all([api.listServers(), api.listCategories(), api.listCustomCategories(), api.listProfiles(), api.listLanDevices(), api.getPings(), api.listCustomLists(), api.getCurrent(), api.getActivity()])
			.then(function (data) {
				st.servers = data[0] || [];
				var categories = data[1] || [], customCategories = data[2] || [];
				st.profiles = data[3] || [];
				var lanDevices = data[4] || [];
				st.pings = data[5] || {};
				st.customLists = data[6] || [];
				st.current = data[7] || {};
				st.activeTags = {};
				(data[8] || []).forEach(function (t) { st.activeTags[t] = true; });

				var geositeGroup = E('optgroup', { label: T('domain_source_geosite') },
					categories.map(function (c) { return E('option', { value: 'geosite::' + c.key }, SR.lang() === 'en' ? c.label_en : c.label_ru); }));
				var customGroup = E('optgroup', { label: T('domain_source_custom') },
					customCategories.map(function (c) { return E('option', { value: 'custom::' + c.file }, SR.lang() === 'en' ? c.label_en : c.label_ru); }));
				domainSourceSelect.appendChild(geositeGroup);
				domainSourceSelect.appendChild(customGroup);

				renderServerPicker();
				buildDevicePicker(lanDevices);
				renderProfilesTable();
				renderCustomLists();

				(function pollLoop() {
					pollActivity().then(function () { setTimeout(pollLoop, 3000); }, function () { setTimeout(pollLoop, 3000); });
				})();
			});
	}

	renderers.profiles = render;
})();
