'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var st = { subscriptions: [], servers: [], pings: {}, health: {}, expanded: {}, pingingLabels: {}, refreshingLabels: {} };

	function pingLabel(tag) {
		var ms = st.pings[tag];
		if (ms === null || ms === undefined) return T('ping_timeout');
		if (typeof ms === 'number') return ms + ' ms';
		return '—';
	}

	function healthAge(checkedAt) {
		if (!checkedAt) return '';
		var ms = Date.now() - new Date(checkedAt).getTime();
		if (!(ms >= 0)) return '';
		var mins = Math.floor(ms / 60000);
		if (mins < 1) return SR.lang() === 'en' ? 'just now' : 'только что';
		if (mins < 60) return mins + (SR.lang() === 'en' ? 'm ago' : 'м назад');
		return Math.floor(mins / 60) + (SR.lang() === 'en' ? 'h ago' : 'ч назад');
	}

	function healthLabel(tag) {
		var h = st.health[tag];
		if (!h) return E('span', { style: 'color:var(--text-dim)' }, '○ ' + T('health_unknown'));
		var age = healthAge(h.checked_at);
		var ageSpan = age ? E('span', { style: 'color:var(--text-dim);font-size:.85em' }, ' (' + age + ')') : '';
		return E('span', {}, [E('span', { style: 'color:' + (h.alive ? 'var(--accent-2)' : 'var(--bad)') }, '● ' + T(h.alive ? 'health_alive' : 'health_dead')), ageSpan]);
	}

	function reloadAll() {
		return Promise.all([api.listSubscriptions(), api.listServers(), api.getPings(), api.getHealth()]).then(function (d) {
			st.subscriptions = d[0] || []; st.servers = d[1] || []; st.pings = d[2] || {}; st.health = d[3] || {};
			renderList();
		});
	}

	function pollAndRerender(times, intervalMs) {
		var i = 0;
		function tick() {
			return reloadAll().then(function () {
				i++;
				if (i >= times) return;
				return new Promise(function (r) { setTimeout(r, intervalMs); }).then(tick);
			});
		}
		return tick();
	}

	function renderList() {
		var container = document.getElementById('sr-subscriptions-list');
		if (!container) return;
		container.innerHTML = '';
		if (!st.subscriptions.length) { container.appendChild(E('p', { class: 'sr-desc' }, T('sub_no_subscriptions'))); return; }

		st.subscriptions.forEach(function (s) {
			var isOpen = !!st.expanded[s.label];
			var subServers = st.servers.filter(function (srv) { return srv.subscription === s.label; });
			var isPinging = !!(st.pingingAll || st.pingingLabels[s.label]);
			var isRefreshing = !!(st.refreshingAll || st.refreshingLabels[s.label]);

			var refreshBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('refresh_btn'));
			refreshBtn.addEventListener('click', function (ev) { handleRefreshSubscription(s.label, ev); });
			var pingBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('ping_btn'));
			pingBtn.addEventListener('click', function (ev) { handlePingSubscription(s.label, ev); });
			var deleteBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove' }, T('delete_btn'));
			deleteBtn.addEventListener('click', function () { handleDeleteSubscription(s.label); });

			var toggle = E('a', { href: '#', style: 'font-weight:700' }, (isOpen ? '▾ ' : '▸ ') + s.label + ' — ' + s.server_count + ' ' + T('sub_servers_word'));
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.expanded[s.label] = !st.expanded[s.label]; renderList(); });

			var headerRow = [toggle];
			if (isPinging || isRefreshing) headerRow.push(E('span', { style: 'margin-left:.5em' }, SR.spinner()));

			var card = E('div', { class: 'sr-card', style: 'margin-bottom:.6em' }, [
				E('div', { class: 'sr-row-between' }, [E('div', { class: 'sr-row' }, headerRow), E('div', { class: 'sr-row' }, [refreshBtn, pingBtn, deleteBtn])])
			]);

			if (isOpen) {
				var table = E('table', { class: 'sr-table', style: 'margin-top:.5em' }, [
					E('tr', {}, [E('th', {}, T('col_server')), E('th', {}, T('col_address')), E('th', {}, T('col_protocol')), E('th', {}, T('col_ping')), E('th', {}, T('col_health'))])
				]);
				if (!subServers.length) table.appendChild(E('tr', {}, [E('td', { colspan: '5' }, T('no_servers'))]));
				subServers.forEach(function (srv) {
					var pingCell = isPinging ? SR.spinner() : pingLabel(srv.tag);
					table.appendChild(E('tr', {}, [
						E('td', {}, SR.renderName(srv.name)), E('td', {}, srv.address + ':' + srv.port),
						E('td', {}, srv.protocol), E('td', {}, pingCell), E('td', {}, healthLabel(srv.tag))
					]));
				});
				card.appendChild(table);
			}
			container.appendChild(card);
		});
	}

	function handleRefreshSubscription(label, ev) {
		var btn = ev.target; btn.disabled = true; btn.textContent = T('sub_refreshing_one');
		st.refreshingLabels[label] = true; renderList();
		api.refreshSubscription(label).then(function () {
			return pollAndRerender(8, 4000).then(function () { delete st.refreshingLabels[label]; btn.disabled = false; btn.textContent = T('refresh_btn'); renderList(); });
		});
	}
	function handlePingSubscription(label, ev) {
		var btn = ev.target; btn.disabled = true; btn.textContent = T('pinging');
		st.pingingLabels[label] = true; renderList();
		api.pingSubscription(label).then(function () {
			return pollAndRerender(8, 3000).then(function () { delete st.pingingLabels[label]; btn.disabled = false; btn.textContent = T('ping_btn'); renderList(); });
		});
	}
	function handleDeleteSubscription(label) {
		if (!confirm(T('sub_delete_confirm').replace('%s', label))) return;
		api.deleteSubscription(label).then(reloadAll);
	}

	function handleImport(ev) {
		var urlInput = document.getElementById('sr-sub-url'), labelInput = document.getElementById('sr-sub-label');
		var clientSelect = document.getElementById('sr-sub-client');
		var url = urlInput.value.trim(), label = labelInput.value.trim() || 'sub';
		var client = clientSelect ? clientSelect.value : 'smartroute';
		if (!url) return;
		var btn = ev.target; btn.disabled = true; btn.textContent = T('sub_importing');
		api.importSubscription(
			url, label, client,
			document.getElementById('sr-sub-os').value.trim(), document.getElementById('sr-sub-locale').value.trim(),
			document.getElementById('sr-sub-model').value.trim(), document.getElementById('sr-sub-ver').value.trim(),
			document.getElementById('sr-sub-hwid').value.trim()
		).then(function (res) {
			btn.disabled = false; btn.textContent = T('sub_import_btn');
			if (res && res.error) { SR.toast(T('sub_import_failed') + ': ' + (res.detail || res.error), 'error'); return; }
			SR.toast(T('sub_imported_ok'), 'info');
			urlInput.value = '';
			return reloadAll();
		});
	}

	function render(container) {
		container.innerHTML = '';

		var clientSelect = E('select', { id: 'sr-sub-client', class: 'sr-select', style: 'max-width:320px' },
			SR.CLIENT_PRESETS.map(function (c) { return E('option', { value: c.key }, c.key === 'smartroute' ? c.label + ' (' + (SR.lang() === 'en' ? 'default' : 'по умолчанию') + ')' : c.label); }));

		var advancedBox = E('div', { id: 'sr-sub-advanced', style: 'display:none;margin-top:8px;padding:10px;border:1px solid var(--border);border-radius:8px' }, [
			E('label', { class: 'sr-label' }, T('sub_device_os_label')),
			E('input', { type: 'text', id: 'sr-sub-os', class: 'sr-input', style: 'max-width:320px', placeholder: 'XKeen SmartRoute' }),
			E('label', { class: 'sr-label' }, T('sub_locale_label')),
			E('input', { type: 'text', id: 'sr-sub-locale', class: 'sr-input', style: 'max-width:320px', placeholder: 'ru' }),
			E('label', { class: 'sr-label' }, T('sub_model_label')),
			E('input', { type: 'text', id: 'sr-sub-model', class: 'sr-input', style: 'max-width:320px', placeholder: 'iPhone 15 Pro' }),
			E('label', { class: 'sr-label' }, T('sub_ver_label')),
			E('input', { type: 'text', id: 'sr-sub-ver', class: 'sr-input', style: 'max-width:320px', placeholder: '17.5' }),
			E('label', { class: 'sr-label' }, T('sub_hwid_label')),
			E('div', { class: 'sr-row', style: 'max-width:480px' }, [
				E('input', { type: 'text', id: 'sr-sub-hwid', class: 'sr-input', style: 'flex:1' }),
				E('button', { class: 'sr-btn sr-btn-sm', click: function (ev) {
					var hwidInput = document.getElementById('sr-sub-hwid'); ev.target.disabled = true;
					api.randomHwid().then(function (res) { ev.target.disabled = false; if (res && res.hwid) hwidInput.value = res.hwid; });
				} }, T('sub_hwid_generate'))
			])
		]);

		var advToggle = E('a', { href: '#', style: 'display:inline-block;margin:6px 0' }, '▸ ' + T('sub_advanced_toggle'));
		advToggle.addEventListener('click', function (ev) {
			ev.preventDefault();
			var hidden = advancedBox.style.display === 'none';
			advancedBox.style.display = hidden ? 'block' : 'none';
			advToggle.textContent = (hidden ? '▾ ' : '▸ ') + T('sub_advanced_toggle');
		});

		var addBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('sub_add_title')),
			E('p', { class: 'sr-desc' }, T('sub_intro')),
			E('input', { type: 'text', id: 'sr-sub-url', class: 'sr-input', style: 'margin-bottom:6px', placeholder: T('sub_url_placeholder') }),
			E('input', { type: 'text', id: 'sr-sub-label', class: 'sr-input', style: 'max-width:320px;margin-bottom:6px', placeholder: T('sub_label_placeholder') }),
			E('label', { class: 'sr-label' }, T('sub_client_label')),
			clientSelect,
			E('p', { class: 'sr-desc' }, T('sub_client_hint')),
			advToggle, advancedBox,
			E('div', { style: 'margin-top:10px' }, [E('button', { class: 'sr-btn sr-btn-primary', click: handleImport }, T('sub_import_btn'))])
		]);

		var autoRefreshToggle = E('input', { type: 'checkbox' });
		var refreshHoursInput = E('input', { type: 'number', class: 'sr-input', style: 'max-width:100px', min: '1' });
		var observatoryPeriodInput = E('input', { type: 'number', class: 'sr-input', style: 'max-width:100px', min: '1' });

		var refreshBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('refresh_settings_title')),
			E('label', { class: 'sr-row', style: 'font-weight:600' }, [autoRefreshToggle, ' ', T('auto_refresh_toggle_label')]),
			E('p', { class: 'sr-desc' }, T('auto_refresh_warning')),
			E('label', { class: 'sr-label' }, T('refresh_interval_label')),
			E('div', { class: 'sr-row' }, [refreshHoursInput, E('button', { class: 'sr-btn sr-btn-sm', click: function (ev) {
				var btn = ev.target; btn.disabled = true;
				api.setRefreshHours(refreshHoursInput.value.trim()).then(function (res) {
					btn.disabled = false;
					if (res && res.error) { SR.toast(res.detail || res.error, 'error'); return; }
					SR.toast(T('refresh_saved_ok'), 'info');
				});
			} }, T('refresh_save_btn'))]),
			E('div', { style: 'margin-top:10px' }, [E('button', { class: 'sr-btn', click: function (ev) {
				var btn = ev.target; btn.disabled = true; btn.textContent = T('sub_refreshing_one');
				st.refreshingAll = true; renderList();
				api.refreshNow().then(function () {
					SR.toast(T('refresh_now_started'), 'info');
					return pollAndRerender(8, 4000).then(function () { st.refreshingAll = false; btn.disabled = false; btn.textContent = T('refresh_now_btn'); renderList(); });
				});
			} }, T('refresh_now_btn'))])
		]);
		autoRefreshToggle.addEventListener('change', function () { api.setAutoRefreshEnabled(autoRefreshToggle.checked); });

		var observatoryBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('observatory_period_title')),
			E('label', { class: 'sr-label' }, T('observatory_period_label')),
			E('div', { class: 'sr-row' }, [observatoryPeriodInput, E('button', { class: 'sr-btn sr-btn-sm', click: function (ev) {
				var btn = ev.target; btn.disabled = true;
				api.setObservatoryPeriod(observatoryPeriodInput.value.trim()).then(function (res) {
					btn.disabled = false;
					if (res && res.error) { SR.toast(res.detail || res.error, 'error'); return; }
					SR.toast(T('observatory_period_saved_ok'), 'info');
				});
			} }, T('refresh_save_btn'))])
		]);

		container.appendChild(E('div', {}, [
			E('h1', { class: 'sr-page-title' }, T('nav_subscriptions')),
			addBox, refreshBox, observatoryBox,
			E('div', { class: 'sr-row-between', style: 'margin-top:16px' }, [
				E('h3', { style: 'margin:0' }, T('sub_subscriptions_title')),
				E('button', { class: 'sr-btn', click: function (ev) {
					var btn = ev.target; btn.disabled = true; btn.textContent = T('pinging');
					st.pingingAll = true; renderList();
					api.pingServers().then(function () {
						SR.toast(T('sub_ping_started'), 'info');
						return pollAndRerender(10, 3000).then(function () { st.pingingAll = false; btn.disabled = false; btn.textContent = T('sub_ping_all_btn'); renderList(); });
					});
				} }, T('sub_ping_all_btn'))
			]),
			E('div', { id: 'sr-subscriptions-list', style: 'margin-top:8px' })
		]));

		Promise.all([api.listSubscriptions(), api.listServers(), api.getPings(), api.getRefreshHours(), api.getHealth(), api.getObservatoryPeriod(), api.getAutoRefreshEnabled()])
			.then(function (d) {
				st.subscriptions = d[0] || []; st.servers = d[1] || []; st.pings = d[2] || {};
				refreshHoursInput.value = String(d[3] || 12);
				st.health = d[4] || {};
				observatoryPeriodInput.value = String(d[5] || 20);
				autoRefreshToggle.checked = d[6] !== false;
				renderList();
			});
	}

	renderers.subscriptions = render;
})();
