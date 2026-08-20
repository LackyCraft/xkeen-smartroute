'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var st = {
		servers: [], pings: {}, current: { enabled: false, servers: [], current: {} }, picked: {},
		serverGroupExpanded: {}, activeTags: {}
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
		var box = document.getElementById('sr-dv-server-picker');
		if (!box) return;
		box.innerHTML = '';
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
				var input = E('input', { type: 'checkbox', name: 'sr-dv-server-choice', value: s.tag });
				input.checked = !!st.picked[s.tag];
				input.addEventListener('change', function () {
					if (input.checked) st.picked[s.tag] = true; else delete st.picked[s.tag];
				});
				list.appendChild(E('label', { class: 'sr-row', style: 'padding:2px 0' }, [
					input, SR.renderName(s.name), ' (' + s.address + ':' + s.port + ', ' + s.protocol + ', ' + pingLabel(s.tag) + ')'
				]));
			});
			box.appendChild(list);
		});
	}

	function renderCurrent() {
		var box = document.getElementById('sr-dv-current');
		if (!box) return;
		box.innerHTML = '';
		var cur = st.current || {};
		if (!cur.enabled) {
			box.appendChild(E('div', {}, T('dv_current_off')));
			return;
		}
		box.appendChild(E('div', {}, [
			E('strong', {}, T('dv_current_gateway') + ': '),
			cur.gateway ? E('span', {}, [activityDot(cur.gateway), SR.renderName(serverForTag(cur.gateway).name)]) : document.createTextNode(T('dv_current_none'))
		]));
		box.appendChild(E('div', { style: 'margin-top:4px;color:var(--text-dim)' }, (cur.pool_size || 0) + ' ' + T('dv_pool_size')));
	}

	// "Участники группы": every server currently saved in the pool (not just
	// the checkboxes in the editor above -- this reflects what's actually
	// saved/active, same "existing X" pattern as the Profiles tab's table),
	// with the currently-picked gateway badged and its live activity dot.
	function renderMembers() {
		var box = document.getElementById('sr-dv-members');
		if (!box) return;
		box.innerHTML = '';
		var poolTags = (st.current && st.current.servers) || [];
		if (!poolTags.length) {
			box.appendChild(E('p', { class: 'sr-desc' }, T('dv_pool_members_empty')));
			return;
		}
		var gateway = st.current.current && st.current.current.gateway;

		var table = E('table', { class: 'sr-table' }, [E('tr', {}, [
			E('th', {}, T('col_server')), E('th', {}, T('col_address')), E('th', {}, T('col_ping')), E('th', {}, '')
		])]);
		poolTags.forEach(function (tag) {
			var s = serverForTag(tag);
			var isGateway = tag === gateway;
			table.appendChild(E('tr', {}, [
				E('td', {}, [isGateway ? activityDot(tag) : E('span', { class: 'sr-dot' }), SR.renderName(s.name)]),
				E('td', {}, s.address ? (s.address + ':' + s.port) : '—'),
				E('td', {}, pingLabel(tag)),
				E('td', {}, isGateway ? E('span', { class: 'sr-badge' }, T('dv_gateway_badge')) : '')
			]));
		});
		box.appendChild(table);
	}

	function pollActivity() {
		return api.getActivity().then(function (active) {
			st.activeTags = {};
			(active || []).forEach(function (t) { st.activeTags[t] = true; });
			renderCurrent();
			renderMembers();
		});
	}

	function reload() {
		return api.getDoublevpnConfig().then(function (cfg) {
			st.current = cfg || { enabled: false, servers: [], current: {} };
			renderCurrent();
			renderMembers();
		});
	}

	function handleToggleEnabled(ev) {
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		api.setDoublevpnEnabled(enabled).then(function () {
			ev.target.disabled = false;
			SR.toast(T('dv_toggle_saved_ok'), 'info');
			return reload();
		});
	}

	function handleSavePool(ev) {
		// Read from st.picked, not the DOM -- the picker only renders
		// checkboxes for currently-expanded subscription groups, so
		// querying document for ":checked" silently drops every selection
		// made in a group the user has since collapsed. st.picked is kept
		// in sync with every checkbox's own change event regardless of
		// which groups are open, so it's the only complete source of truth.
		var chosen = Object.keys(st.picked);
		var enabled = document.getElementById('sr-dv-enabled').checked;
		if (enabled && !chosen.length) SR.toast(T('dv_need_pool_warning'), 'error');

		var btn = ev.target;
		btn.disabled = true;
		api.setDoublevpnServers(JSON.stringify(chosen)).then(function () {
			btn.disabled = false;
			SR.toast(T('dv_saved_ok'), 'info');
			return reload();
		});
	}

	function render(container) {
		container.innerHTML = '';
		st.picked = {}; st.serverGroupExpanded = {};

		var enabledToggle = E('input', { type: 'checkbox', id: 'sr-dv-enabled', change: handleToggleEnabled });

		var box = E('div', { class: 'sr-card' }, [
			E('h1', { class: 'sr-page-title', style: 'margin:0 0 8px' }, T('nav_doublevpn')),
			E('p', { class: 'sr-desc' }, T('dv_intro')),

			E('label', { class: 'sr-row', style: 'font-weight:700;gap:8px;margin:16px 0' }, [enabledToggle, T('dv_enabled_label')]),

			E('div', { id: 'sr-dv-current', class: 'sr-stat' }),

			E('label', { class: 'sr-label' }, T('dv_pool_label')),
			E('p', { class: 'sr-desc' }, T('dv_pool_intro')),
			E('div', { id: 'sr-dv-server-picker' }),

			E('button', { class: 'sr-btn sr-btn-primary', click: handleSavePool }, T('dv_save_btn'))
		]);

		var membersBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('dv_pool_members_title')),
			E('div', { id: 'sr-dv-members' })
		]);

		container.appendChild(E('div', {}, [box, membersBox]));

		Promise.all([api.listServers(), api.getPings(), api.getDoublevpnConfig(), api.getActivity()]).then(function (data) {
			st.servers = data[0] || [];
			st.pings = data[1] || {};
			st.current = data[2] || { enabled: false, servers: [], current: {} };
			st.activeTags = {};
			(data[3] || []).forEach(function (t) { st.activeTags[t] = true; });
			(st.current.servers || []).forEach(function (t) { st.picked[t] = true; });
			(st.current.servers || []).forEach(function (t) {
				var s = serverForTag(t);
				if (s) st.serverGroupExpanded[s.subscription || ''] = true;
			});
			document.getElementById('sr-dv-enabled').checked = !!st.current.enabled;
			renderServerPicker();
			renderCurrent();
			renderMembers();

			(function pollLoop() {
				pollActivity().then(function () { setTimeout(pollLoop, 3000); }, function () { setTimeout(pollLoop, 3000); });
			})();
		});
	}

	renderers.doublevpn = render;
})();
