'use strict';
'require view';
'require ui';
'require poll';
'require xkeen-smartroute as sr';

var BOX_STYLE = 'border:1px solid var(--border-color-medium,#ccc);border-radius:6px;padding:1em;margin-bottom:1.25em';

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.listServers(),
			sr.rpc.getPings(),
			sr.rpc.getDoublevpnConfig(),
			sr.rpc.getActivity()
		]);
	},

	pingLabel: function (tag) {
		var ms = (this.pings || {})[tag];
		if (ms === null || ms === undefined) return sr.T('ping_timeout');
		if (typeof ms === 'number') return ms + ' ms';
		return '—';
	},

	serverForTag: function (tag) {
		return (this.servers || []).filter(function (x) { return x.tag === tag; })[0] || { tag: tag, name: tag };
	},

	activityDot: function (tag) {
		var active = !!(tag && this.activeTags && this.activeTags[tag]);
		return E('span', {
			'title': sr.T(active ? 'activity_online' : 'activity_idle'),
			'style': 'display:inline-block;width:.6em;height:.6em;border-radius:50%;margin-right:.4em;' +
				(active ? 'background:#2ecc71;box-shadow:0 0 4px #2ecc71' : 'background:var(--border-color-medium,#bbb)')
		});
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
		var box = document.getElementById('sr-dv-server-picker');
		if (!box) return;
		box.innerHTML = '';
		var servers = view.servers || [];

		if (!servers.length) {
			box.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('need_servers_first')));
			return;
		}

		if (!view._picked) view._picked = {};

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
				var input = E('input', { 'type': 'checkbox', 'name': 'sr-dv-server-choice', 'value': s.tag });
				input.checked = !!view._picked[s.tag];
				input.addEventListener('change', function () {
					if (input.checked) view._picked[s.tag] = true; else delete view._picked[s.tag];
				});
				list.appendChild(E('label', { 'style': 'display:flex;align-items:center;gap:.4em;padding:.15em 0' }, [
					input, sr.renderName(s.name), ' (', s.address, ':', String(s.port), ', ', s.protocol, ', ', view.pingLabel(s.tag), ')'
				]));
			});
			box.appendChild(list);
		});
	},

	// "Участники группы": every server actually saved in the pool (not the
	// editor's checkboxes above -- this reflects saved/active state, same
	// pattern as the Profiles page's "existing profiles" table), with the
	// currently-picked gateway badged and its live activity dot.
	renderMembers: function () {
		var view = this;
		var box = document.getElementById('sr-dv-members');
		if (!box) return;
		box.innerHTML = '';
		var poolTags = (this.current && this.current.servers) || [];
		if (!poolTags.length) {
			box.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('dv_pool_members_empty')));
			return;
		}
		var gateway = this.current.current && this.current.current.gateway;

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, sr.T('col_server')),
				E('th', { 'class': 'th' }, sr.T('col_address')),
				E('th', { 'class': 'th' }, sr.T('col_ping')),
				E('th', { 'class': 'th' }, '')
			])
		]);
		poolTags.forEach(function (tag) {
			var s = view.serverForTag(tag);
			var isGateway = tag === gateway;
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [isGateway ? view.activityDot(tag) : view.activityDot(null), sr.renderName(s.name)]),
				E('td', { 'class': 'td' }, s.address ? (s.address + ':' + s.port) : '—'),
				E('td', { 'class': 'td' }, view.pingLabel(tag)),
				E('td', { 'class': 'td' }, isGateway ? E('span', {
					'style': 'display:inline-block;padding:.1em .6em;border-radius:999px;font-size:.78em;font-weight:bold;background:rgba(79,140,255,0.16);color:#4f8cff'
				}, sr.T('dv_gateway_badge')) : '')
			]));
		});
		box.appendChild(table);
	},

	handleToggleEnabled: function (ev) {
		var enabled = ev.target.checked;
		var view = this;
		ev.target.disabled = true;
		return sr.rpc.setDoublevpnEnabled(enabled).then(function () {
			ev.target.disabled = false;
			ui.addNotification(null, E('p', {}, sr.T('dv_toggle_saved_ok')), 'info');
			return view.reload();
		});
	},

	reload: function () {
		var view = this;
		return sr.rpc.getDoublevpnConfig().then(function (cfg) {
			view.current = cfg || { enabled: false, servers: [], current: {} };
			view.renderMembers();
		});
	},

	pollActivity: function () {
		var view = this;
		return sr.rpc.getActivity().then(function (active) {
			view.activeTags = {};
			(active || []).forEach(function (t) { view.activeTags[t] = true; });
			view.renderMembers();
		});
	},

	handleSavePool: function (ev) {
		// Read from this._picked, not the DOM -- the picker only renders
		// checkboxes for currently-expanded subscription groups, so
		// querying for ":checked" silently drops every selection made in a
		// group the user has since collapsed. this._picked is kept in sync
		// with every checkbox's own change event regardless of which
		// groups are open, so it's the only complete source of truth.
		var chosen = Object.keys(this._picked || {});

		var enabled = document.getElementById('sr-dv-enabled').checked;
		if (enabled && !chosen.length) {
			ui.addNotification(null, E('p', {}, sr.T('dv_need_pool_warning')), 'error');
		}

		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.setDoublevpnServers(JSON.stringify(chosen)).then(L.bind(function () {
			btn.disabled = false;
			ui.addNotification(null, E('p', {}, sr.T('dv_saved_ok')), 'info');
			return this.reload();
		}, this));
	},

	render: function (data) {
		var view = this;
		this.servers = data[0] || [];
		this.pings = data[1] || {};
		this.current = data[2] || { enabled: false, servers: [], current: {} };
		this.activeTags = {};
		(data[3] || []).forEach(function (t) { view.activeTags[t] = true; });
		this._picked = {};
		(this.current.servers || []).forEach(function (t) { view._picked[t] = true; });
		this.serverGroupExpanded = {};
		(this.current.servers || []).forEach(function (t) {
			var s = view.serverForTag(t);
			if (s) view.serverGroupExpanded[s.subscription || ''] = true;
		});

		var enabledToggle = E('input', { 'type': 'checkbox', 'id': 'sr-dv-enabled' });
		enabledToggle.checked = !!this.current.enabled;
		enabledToggle.addEventListener('change', function (ev) { view.handleToggleEnabled(ev); });

		var box = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('app_name') + ' — ' + sr.T('nav_doublevpn')),
			E('p', {}, sr.T('dv_intro')),

			E('label', { 'style': 'display:flex;align-items:center;gap:.5em;font-weight:bold;margin:1em 0' }, [
				enabledToggle, sr.T('dv_enabled_label')
			]),

			E('label', {}, sr.T('dv_pool_label')),
			E('p', { 'class': 'cbi-value-description', 'style': 'margin:.25em 0' }, sr.T('dv_pool_intro')),
			E('div', { 'id': 'sr-dv-server-picker', 'style': 'margin:.25em 0 1em' }),

			E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': ui.createHandlerFn(view, 'handleSavePool')
			}, sr.T('dv_save_btn'))
		]);

		var membersBox = E('div', { 'style': BOX_STYLE }, [
			E('h3', { 'style': 'margin-top:0' }, sr.T('dv_pool_members_title')),
			E('div', { 'id': 'sr-dv-members' })
		]);

		var root = E('div', {}, [sr.langSwitchButton(), box, membersBox]);

		requestAnimationFrame(function () {
			view.renderServerPicker();
			view.renderMembers();
		});

		poll.add(function () { return view.pollActivity(); }, 3);

		return root;
	}
});
