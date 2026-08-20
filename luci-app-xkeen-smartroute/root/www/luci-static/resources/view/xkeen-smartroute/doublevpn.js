'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

var BOX_STYLE = 'border:1px solid var(--border-color-medium,#ccc);border-radius:6px;padding:1em;margin-bottom:1.25em';

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.listServers(),
			sr.rpc.getPings(),
			sr.rpc.getDoublevpnConfig()
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

		var previouslyChecked = {};
		box.querySelectorAll('input[name="sr-dv-server-choice"]:checked').forEach(function (i) { previouslyChecked[i.value] = true; });
		if (!view._picked) view._picked = {};
		Object.keys(previouslyChecked).forEach(function (t) { view._picked[t] = true; });

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

	renderCurrent: function () {
		var box = document.getElementById('sr-dv-current');
		if (!box) return;
		box.innerHTML = '';
		var cur = this.current || {};
		var lines = [];
		if (!cur.enabled) {
			lines.push(E('div', {}, sr.T('dv_current_off')));
		} else {
			lines.push(E('div', {}, [
				E('strong', {}, sr.T('dv_current_gateway') + ': '),
				cur.gateway ? sr.renderName(this.serverForTag(cur.gateway).name) : document.createTextNode(sr.T('dv_current_none'))
			]));
			lines.push(E('div', { 'style': 'margin-top:.25em;color:var(--color-text-secondary,#888)' },
				(cur.pool_size || 0) + ' ' + sr.T('dv_pool_size')));
		}
		box.appendChild(E('div', {}, lines));
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
			view.renderCurrent();
		});
	},

	handleSavePool: function (ev) {
		var chosen = Array.prototype.slice.call(
			document.querySelectorAll('input[name="sr-dv-server-choice"]:checked')
		).map(function (i) { return i.value; });

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

			E('div', { 'id': 'sr-dv-current', 'style': 'margin:0 0 1em;padding:.75em;background:var(--background-color-medium,#f5f5f5);border-radius:4px' }),

			E('label', {}, sr.T('dv_pool_label')),
			E('p', { 'class': 'cbi-value-description', 'style': 'margin:.25em 0' }, sr.T('dv_pool_intro')),
			E('div', { 'id': 'sr-dv-server-picker', 'style': 'margin:.25em 0 1em' }),

			E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': ui.createHandlerFn(view, 'handleSavePool')
			}, sr.T('dv_save_btn'))
		]);

		var root = E('div', {}, [sr.langSwitchButton(), box]);

		requestAnimationFrame(function () {
			view.renderServerPicker();
			view.renderCurrent();
		});

		return root;
	}
});
