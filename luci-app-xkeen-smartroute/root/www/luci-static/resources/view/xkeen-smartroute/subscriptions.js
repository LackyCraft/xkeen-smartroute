'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.listSubscriptions(),
			sr.rpc.listServers(),
			sr.rpc.getPings(),
			sr.rpc.getRefreshHours(),
			sr.rpc.getHealth()
		]);
	},

	handleGenerateHwid: function (ev) {
		var hwidInput = document.getElementById('sr-sub-hwid');
		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.randomHwid().then(function (res) {
			btn.disabled = false;
			if (res && res.hwid) hwidInput.value = res.hwid;
		});
	},

	handleToggleAdvanced: function (ev) {
		var box = document.getElementById('sr-sub-advanced');
		var hidden = box.style.display === 'none';
		box.style.display = hidden ? 'block' : 'none';
		ev.target.textContent = (hidden ? '▾ ' : '▸ ') + sr.T('sub_advanced_toggle');
	},

	handleImport: function (ev) {
		var urlInput = document.getElementById('sr-sub-url');
		var labelInput = document.getElementById('sr-sub-label');
		var clientSelect = document.getElementById('sr-sub-client');
		var osInput = document.getElementById('sr-sub-os');
		var localeInput = document.getElementById('sr-sub-locale');
		var modelInput = document.getElementById('sr-sub-model');
		var verInput = document.getElementById('sr-sub-ver');
		var hwidInput = document.getElementById('sr-sub-hwid');
		var btn = ev.target;
		var url = urlInput.value.trim();
		var label = labelInput.value.trim() || 'sub';
		var client = clientSelect ? clientSelect.value : 'smartroute';

		if (!url) return;

		btn.disabled = true;
		btn.textContent = sr.T('sub_importing');

		return sr.rpc.importSubscription(
			url, label, client,
			osInput.value.trim(), localeInput.value.trim(), modelInput.value.trim(),
			verInput.value.trim(), hwidInput.value.trim()
		).then(L.bind(function (res) {
			btn.disabled = false;
			btn.textContent = sr.T('sub_import_btn');
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, sr.T('sub_import_failed') + ': ' + (res.detail || res.error)), 'error');
				return;
			}
			ui.addNotification(null, E('p', {}, sr.T('sub_imported_ok')), 'info');
			urlInput.value = '';
			return this.reloadAll();
		}, this));
	},

	handleSaveRefreshHours: function (ev) {
		var input = document.getElementById('sr-refresh-hours');
		var hours = input.value.trim();
		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.setRefreshHours(hours).then(function (res) {
			btn.disabled = false;
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, res.detail || res.error), 'error');
				return;
			}
			ui.addNotification(null, E('p', {}, sr.T('refresh_saved_ok')), 'info');
		});
	},

	handleRefreshAllNow: function (ev) {
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		btn.textContent = sr.T('sub_refreshing_one');
		view.refreshingAll = true;
		view.renderSubscriptions();
		return sr.rpc.refreshNow().then(function () {
			ui.addNotification(null, E('p', {}, sr.T('refresh_now_started')), 'info');
			return view.pollAndRerender(8, 4000).then(function () {
				view.refreshingAll = false;
				btn.disabled = false;
				btn.textContent = sr.T('refresh_now_btn');
				view.renderSubscriptions();
			});
		});
	},

	handlePingAll: function (ev) {
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		btn.textContent = sr.T('pinging');
		view.pingingAll = true;
		view.renderSubscriptions();
		return sr.rpc.pingServers().then(function () {
			ui.addNotification(null, E('p', {}, sr.T('sub_ping_started')), 'info');
			return view.pollAndRerender(10, 3000).then(function () {
				view.pingingAll = false;
				btn.disabled = false;
				btn.textContent = sr.T('sub_ping_all_btn');
				view.renderSubscriptions();
			});
		});
	},

	handleRefreshSubscription: function (label, ev) {
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		btn.textContent = sr.T('sub_refreshing_one');
		view.refreshingLabels = view.refreshingLabels || {};
		view.refreshingLabels[label] = true;
		view.renderSubscriptions();
		return sr.rpc.refreshSubscription(label).then(function () {
			return view.pollAndRerender(8, 4000).then(function () {
				delete view.refreshingLabels[label];
				btn.disabled = false;
				btn.textContent = sr.T('refresh_btn');
				view.renderSubscriptions();
			});
		});
	},

	handlePingSubscription: function (label, ev) {
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		btn.textContent = sr.T('pinging');
		view.pingingLabels = view.pingingLabels || {};
		view.pingingLabels[label] = true;
		view.renderSubscriptions();
		return sr.rpc.pingSubscription(label).then(function () {
			return view.pollAndRerender(8, 3000).then(function () {
				delete view.pingingLabels[label];
				btn.disabled = false;
				btn.textContent = sr.T('ping_btn');
				view.renderSubscriptions();
			});
		});
	},

	handleDeleteSubscription: function (label) {
		if (!confirm(sr.T('sub_delete_confirm').replace('%s', label))) return;
		var view = this;
		return sr.rpc.deleteSubscription(label).then(function () {
			return view.reloadAll();
		});
	},

	handleToggleExpand: function (label) {
		this.expanded = this.expanded || {};
		this.expanded[label] = !this.expanded[label];
		this.renderSubscriptions();
	},

	// Backgrounded ping/refresh calls have no "done" signal to wait on --
	// poll the cheap read-only endpoints a handful of times and re-render as
	// data arrives, then stop. Good enough feedback without blocking the UI
	// on an operation that (for a big subscription) can take minutes.
	pollAndRerender: function (times, intervalMs) {
		var view = this;
		var i = 0;
		function tick() {
			return Promise.all([sr.rpc.listSubscriptions(), sr.rpc.listServers(), sr.rpc.getPings(), sr.rpc.getHealth()]).then(function (data) {
				view.subscriptions = data[0] || [];
				view.servers = data[1] || [];
				view.pings = data[2] || {};
				view.health = data[3] || {};
				view.renderSubscriptions();
				i++;
				if (i >= times) return;
				return new Promise(function (resolve) { setTimeout(resolve, intervalMs); }).then(tick);
			});
		}
		return tick();
	},

	reloadAll: function () {
		var view = this;
		return Promise.all([sr.rpc.listSubscriptions(), sr.rpc.listServers(), sr.rpc.getPings(), sr.rpc.getHealth()]).then(function (data) {
			view.subscriptions = data[0] || [];
			view.servers = data[1] || [];
			view.pings = data[2] || {};
			view.health = data[3] || {};
			view.renderSubscriptions();
		});
	},

	pingLabel: function (tag) {
		var ms = (this.pings || {})[tag];
		if (ms === null || ms === undefined) return sr.T('ping_timeout');
		if (typeof ms === 'number') return ms + ' ms';
		return '—';
	},

	// healthAge: "checked_at" -> a short "Xм назад"/"Xm ago" string. This can
	// be a *long* time for a tag health.json is still carrying from before
	// the last Xray restart (see gateway/failover.go's persistHealth --
	// merged forward across restarts on purpose, not dropped), so showing
	// this next to the alive/dead dot is what tells the user "this verdict
	// might be stale, not just present".
	healthAge: function (checkedAt) {
		if (!checkedAt) return '';
		var ms = Date.now() - new Date(checkedAt).getTime();
		if (!(ms >= 0)) return '';
		var mins = Math.floor(ms / 60000);
		if (mins < 1) return sr.lang() === 'en' ? 'just now' : 'только что';
		if (mins < 60) return mins + (sr.lang() === 'en' ? 'm ago' : 'м назад');
		var hours = Math.floor(mins / 60);
		return hours + (sr.lang() === 'en' ? 'h ago' : 'ч назад');
	},

	// healthLabel: a colored dot + word + age, from smartroute-gateway's real
	// observatory data (see xkeen-smartroute.js's callGetHealth) -- a tag
	// absent from the map hasn't been reached by observatory's probe sweep
	// yet (still sparse for a while after every Xray restart), which is a
	// genuinely different state from "confirmed dead" and shown as such.
	healthLabel: function (tag) {
		var h = (this.health || {})[tag];
		if (!h) return E('span', { 'style': 'color:var(--color-text-secondary,#888)' }, '○ ' + sr.T('health_unknown'));
		var age = this.healthAge(h.checked_at);
		var ageSpan = age ? E('span', { 'style': 'color:var(--color-text-secondary,#888);font-size:.9em' }, ' (' + age + ')') : '';
		if (h.alive) return E('span', {}, [E('span', { 'style': 'color:#2e7d32' }, '● ' + sr.T('health_alive')), ageSpan]);
		return E('span', {}, [E('span', { 'style': 'color:#c62828' }, '● ' + sr.T('health_dead')), ageSpan]);
	},

	renderSubscriptions: function () {
		var view = this;
		var container = document.getElementById('sr-subscriptions-list');
		if (!container) return;
		var subs = view.subscriptions || [];
		var servers = view.servers || [];
		container.innerHTML = '';

		if (!subs.length) {
			container.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('sub_no_subscriptions')));
			return;
		}

		subs.forEach(function (s) {
			var isOpen = !!(view.expanded && view.expanded[s.label]);
			var subServers = servers.filter(function (srv) { return srv.subscription === s.label; });
			var isPinging = !!(view.pingingAll || (view.pingingLabels && view.pingingLabels[s.label]));
			var isRefreshing = !!(view.refreshingAll || (view.refreshingLabels && view.refreshingLabels[s.label]));

			var refreshBtn = E('button', { 'class': 'cbi-button' }, sr.T('refresh_btn'));
			refreshBtn.addEventListener('click', function (ev) { view.handleRefreshSubscription(s.label, ev); });
			var pingBtn = E('button', { 'class': 'cbi-button' }, sr.T('ping_btn'));
			pingBtn.addEventListener('click', function (ev) { view.handlePingSubscription(s.label, ev); });
			var deleteBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, sr.T('delete_btn'));
			deleteBtn.addEventListener('click', function () { view.handleDeleteSubscription(s.label); });

			var labelParts = [(isOpen ? '▾ ' : '▸ ') + s.label + ' — ' + s.server_count + ' ' + sr.T('sub_servers_word')];
			var toggle = E('a', { 'href': '#', 'style': 'font-weight:bold;text-decoration:none' }, labelParts);
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); view.handleToggleExpand(s.label); });

			var headerRow = [toggle];
			if (isPinging || isRefreshing) {
				headerRow.push(E('span', { 'style': 'margin-left:.5em' }, sr.spinner()));
				headerRow.push(E('span', { 'class': 'cbi-value-description', 'style': 'margin-left:.35em' },
					isRefreshing ? sr.T('sub_refreshing_one') : sr.T('pinging')));
			}

			var card = E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:.75em' }, [
				E('div', { 'style': 'display:flex;align-items:center;gap:1em;flex-wrap:wrap' }, [
					E('div', {}, headerRow),
					E('div', { 'style': 'margin-left:auto;display:flex;gap:.5em' }, [refreshBtn, pingBtn, deleteBtn])
				])
			]);

			if (isOpen) {
				var table = E('table', { 'class': 'table cbi-section-table', 'style': 'margin-top:.5em' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, sr.T('col_server')),
						E('th', { 'class': 'th' }, sr.T('col_address')),
						E('th', { 'class': 'th' }, sr.T('col_protocol')),
						E('th', { 'class': 'th' }, sr.T('col_ping')),
						E('th', { 'class': 'th' }, sr.T('col_health'))
					])
				]);
				if (!subServers.length) {
					table.appendChild(E('tr', { 'class': 'tr' }, [E('td', { 'class': 'td', 'colspan': '5' }, sr.T('no_servers'))]));
				}
				subServers.forEach(function (srv) {
					// While a ping run for this subscription (or all of them)
					// is in flight, ping.json isn't updated until the whole
					// run finishes -- showing whatever value was cached
					// *before* the run reads as a final, current result
					// instead of "still checking". A spinner is honest about
					// which one it actually is.
					var pingCell = isPinging ? sr.spinner() : view.pingLabel(srv.tag);
					table.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, sr.renderName(srv.name)),
						E('td', { 'class': 'td' }, srv.address + ':' + srv.port),
						E('td', { 'class': 'td' }, srv.protocol),
						E('td', { 'class': 'td' }, pingCell),
						E('td', { 'class': 'td' }, view.healthLabel(srv.tag))
					]));
				});
				card.appendChild(table);
			}

			container.appendChild(card);
		});
	},

	render: function (data) {
		var view = this;
		this.subscriptions = data[0] || [];
		this.servers = data[1] || [];
		this.pings = data[2] || {};
		var refreshHours = data[3] || 12;
		this.health = data[4] || {};
		this.expanded = {};

		var clientSelect = E('select', { 'id': 'sr-sub-client', 'class': 'cbi-input-select', 'style': 'display:block;max-width:320px;margin:.25em 0' },
			sr.CLIENT_PRESETS.map(function (c) {
				return E('option', { 'value': c.key }, c.key === 'smartroute' ? c.label + ' (' + (sr.lang() === 'en' ? 'default' : 'по умолчанию') + ')' : c.label);
			})
		);

		var osSelectDatalist = E('datalist', { 'id': 'sr-sub-os-list' },
			sr.DEVICE_OS_OPTIONS.map(function (o) { return E('option', { 'value': o }); })
		);
		var modelDatalist = E('datalist', { 'id': 'sr-sub-model-list' },
			sr.DEVICE_MODEL_OPTIONS.map(function (o) { return E('option', { 'value': o }); })
		);
		var verDatalist = E('datalist', { 'id': 'sr-sub-ver-list' },
			sr.DEVICE_VER_OPTIONS.map(function (o) { return E('option', { 'value': o }); })
		);

		var advancedBox = E('div', { 'id': 'sr-sub-advanced', 'style': 'display:none;margin:.5em 0;padding:.75em;border:1px solid var(--border-color-medium,#ccc);border-radius:4px' }, [
			E('label', {}, sr.T('sub_device_os_label')),
			E('input', {
				'type': 'text', 'id': 'sr-sub-os', 'class': 'cbi-input-text', 'list': 'sr-sub-os-list',
				'style': 'display:block;max-width:320px;margin:.25em 0 .75em', 'placeholder': 'XKeen SmartRoute'
			}),
			osSelectDatalist,
			E('label', {}, sr.T('sub_locale_label')),
			E('input', { 'type': 'text', 'id': 'sr-sub-locale', 'class': 'cbi-input-text', 'style': 'display:block;max-width:320px;margin:.25em 0 .75em', 'placeholder': 'ru' }),
			E('label', {}, sr.T('sub_model_label')),
			E('input', {
				'type': 'text', 'id': 'sr-sub-model', 'class': 'cbi-input-text', 'list': 'sr-sub-model-list',
				'style': 'display:block;max-width:320px;margin:.25em 0 .75em', 'placeholder': 'iPhone 15 Pro'
			}),
			modelDatalist,
			E('label', {}, sr.T('sub_ver_label')),
			E('input', {
				'type': 'text', 'id': 'sr-sub-ver', 'class': 'cbi-input-text', 'list': 'sr-sub-ver-list',
				'style': 'display:block;max-width:320px;margin:.25em 0 .75em', 'placeholder': '17.5'
			}),
			verDatalist,
			E('label', {}, sr.T('sub_hwid_label')),
			E('div', { 'style': 'display:flex;gap:.5em;max-width:480px' }, [
				E('input', { 'type': 'text', 'id': 'sr-sub-hwid', 'class': 'cbi-input-text', 'style': 'flex:1' }),
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, 'handleGenerateHwid') }, sr.T('sub_hwid_generate'))
			])
		]);

		var addBox = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, sr.T('sub_add_title')),
			E('p', {}, sr.T('sub_intro')),
			E('input', {
				'type': 'text', 'id': 'sr-sub-url', 'class': 'cbi-input-text',
				'style': 'width:100%;max-width:640px;display:block;margin-bottom:.5em',
				'placeholder': sr.T('sub_url_placeholder')
			}),
			E('input', {
				'type': 'text', 'id': 'sr-sub-label', 'class': 'cbi-input-text',
				'style': 'width:100%;max-width:320px;display:block;margin-bottom:.5em',
				'placeholder': sr.T('sub_label_placeholder')
			}),
			E('label', {}, sr.T('sub_client_label')),
			E('div', { 'style': 'margin:.25em 0' }, [clientSelect]),
			E('p', { 'class': 'cbi-value-description' }, sr.T('sub_client_hint')),
			E('a', {
				'href': '#', 'style': 'display:inline-block;margin:.25em 0 .75em',
				'click': function (ev) { ev.preventDefault(); view.handleToggleAdvanced(ev); }
			}, '▸ ' + sr.T('sub_advanced_toggle')),
			advancedBox,
			E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': ui.createHandlerFn(view, 'handleImport')
			}, sr.T('sub_import_btn'))
		]);

		var refreshBox = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, sr.T('refresh_settings_title')),
			E('label', {}, sr.T('refresh_interval_label')),
			E('div', { 'style': 'display:flex;gap:.5em;max-width:320px;margin:.25em 0 .75em' }, [
				E('input', { 'type': 'number', 'id': 'sr-refresh-hours', 'class': 'cbi-input-text', 'min': '1', 'style': 'flex:1', 'value': String(refreshHours) }),
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, 'handleSaveRefreshHours') }, sr.T('refresh_save_btn'))
			]),
			E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, 'handleRefreshAllNow') }, sr.T('refresh_now_btn'))
		]);

		var root = E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_subscriptions')),

			addBox,
			refreshBox,

			E('div', { 'style': 'display:flex;align-items:center;gap:1em;margin-top:1em' }, [
				E('h3', { 'style': 'margin:0' }, sr.T('sub_subscriptions_title')),
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, 'handlePingAll') }, sr.T('sub_ping_all_btn'))
			]),
			E('div', { 'id': 'sr-subscriptions-list', 'style': 'margin-top:.5em' })
		]);

		requestAnimationFrame(function () { view.renderSubscriptions(); });

		return root;
	}
});
