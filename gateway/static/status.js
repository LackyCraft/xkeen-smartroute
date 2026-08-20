'use strict';
/* Status / home dashboard: services, links, overview, health metrics,
 * active profiles right now, live traffic graph, and the Xray log viewer
 * with its own on/off + level + clear + size-cap controls. */
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var TRAFFIC_HISTORY_LEN = 60;
	var METRICS_POLL_MS = 15000;
	var ACTIVITY_POLL_MS = 3000;
	var TRAFFIC_BY_PROFILE_POLL_MS = 15000;

	var state = { trafficUp: [], trafficDown: [] };

	function httpURL(port) { return 'http://' + location.hostname + ':' + port + '/'; }
	function wsURL(path) {
		var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
		return proto + '//' + location.host + path;
	}
	// The section element (#sr-section-home) is never removed from the DOM
	// in this app -- app.js just toggles its `hidden` attribute -- so this
	// only needs to catch the (currently theoretical) case of the whole
	// section vanishing outright, not "currently hidden". Deliberately does
	// NOT treat hidden==true as gone: the traffic/log WebSockets and metrics
	// polling are meant to keep running in the background while another tab
	// is open, so Home shows fresh data immediately when you come back.
	function isGone() { return !document.getElementById('sr-section-home'); }

	function serviceCard(key, titleKey, running, onAction) {
		var dot = E('span', { class: 'sr-dot ' + (running ? 'sr-dot-ok' : 'sr-dot-bad') });
		return E('div', { class: 'sr-row-between', style: 'padding:6px 0' }, [
			E('div', {}, [dot, T(titleKey), ' — ', E('span', { style: 'opacity:.7' }, running ? T('status_svc_running') : T('status_svc_stopped'))]),
			E('div', { class: 'sr-row' }, [
				E('button', { class: 'sr-btn sr-btn-sm', click: function (ev) { onAction(key, 'start', ev); } }, T('status_action_start')),
				E('button', { class: 'sr-btn sr-btn-sm', click: function (ev) { onAction(key, 'stop', ev); } }, T('status_action_stop')),
				E('button', { class: 'sr-btn sr-btn-sm sr-btn-primary', click: function (ev) { onAction(key, 'restart', ev); } }, T('status_action_restart'))
			])
		]);
	}

	function renderServices(container, st, onAction) {
		container.innerHTML = '';
		container.appendChild(serviceCard('xray', 'status_service_xray', !!st.xray, onAction));
		container.appendChild(serviceCard('gateway', 'status_service_gateway', !!st.gateway, onAction));
		container.appendChild(serviceCard('xkeen-ui', 'status_service_xkeenui', !!st.xkeen_ui, onAction));
	}

	function renderOverview(getStatusResult, subs) {
		var rows = (subs || []).map(function (s) {
			return E('tr', {}, [E('td', {}, s.label || '—'), E('td', {}, String(s.server_count != null ? s.server_count : 0))]);
		});
		var table = rows.length
			? E('table', { class: 'sr-table' }, [E('tr', {}, [E('th', {}, T('status_subscriptions_col_label')), E('th', {}, T('status_subscriptions_col_servers'))])].concat(rows))
			: E('p', { class: 'sr-desc' }, T('status_subscriptions_none'));
		return E('div', {}, [
			E('div', { class: 'sr-grid', style: 'margin-bottom:12px' }, [
				E('div', { class: 'sr-stat' }, [E('div', { class: 'num' }, String(getStatusResult.server_count || 0)), E('div', { class: 'label' }, T('status_servers_known'))]),
				E('div', { class: 'sr-stat' }, [E('div', { class: 'num' }, String(getStatusResult.profile_count || 0)), E('div', { class: 'label' }, T('status_profiles_known'))])
			]),
			table
		]);
	}

	function renderMetrics(container, m) {
		container.innerHTML = '';
		container.appendChild(E('div', { class: 'sr-grid' }, [
			E('div', { class: 'sr-stat' }, [E('div', { class: 'num', style: 'color:var(--accent-2)' }, String(m.alive || 0)), E('div', { class: 'label' }, T('status_metrics_alive'))]),
			E('div', { class: 'sr-stat' }, [E('div', { class: 'num', style: 'color:var(--bad)' }, String(m.dead || 0)), E('div', { class: 'label' }, T('status_metrics_dead'))]),
			E('div', { class: 'sr-stat' }, [E('div', { class: 'num', style: 'color:var(--text-dim)' }, String(m.unknown || 0)), E('div', { class: 'label' }, T('status_metrics_unknown'))]),
			E('div', { class: 'sr-stat' }, [E('div', { class: 'num' }, String(m.observatory_queue_size != null ? m.observatory_queue_size : '—')), E('div', { class: 'label' }, T('status_metrics_queue'))])
		]));
		container.appendChild(E('ul', { style: 'margin:12px 0 0;padding-left:1.1em;color:var(--text-dim);font-size:.85rem' }, [
			E('li', {}, T('status_metrics_last_refresh') + ': ' + SR.relTime(m.last_subscription_refresh)),
			E('li', {}, T('status_metrics_last_ping') + ': ' + SR.relTime(m.last_ping_run)),
			E('li', {}, T('status_metrics_last_observatory') + ': ' + SR.relTime(m.last_observatory_check))
		]));
	}

	// --- active profiles right now: cross-references list_profiles with
	// get_current (which tag a balancer-mode profile is on) / fixed_server,
	// against get_activity's set of tags carrying real traffic this instant
	function renderActiveProfiles(container, profiles, current, activeTags) {
		container.innerHTML = '';
		var active = profiles.filter(function (p) {
			var tag = p.mode === 'fixed' ? p.fixed_server : (current[p.name] || '');
			return tag && activeTags[tag];
		});
		if (!active.length) {
			container.appendChild(E('p', { class: 'sr-desc' }, T('status_active_profiles_none')));
			return;
		}
		active.forEach(function (p) {
			container.appendChild(E('div', { class: 'sr-row', style: 'padding:4px 0' }, [E('span', { class: 'sr-dot sr-dot-ok' }), p.name]));
		});
	}

	function fmtFree(mb) { return mb >= 1024 ? (mb / 1024).toFixed(1) + ' GB' : mb + ' MB'; }

	// --- logs: viewer + on/off + level + clear + size cap ---
	function renderLogControls(container, cfg, onChange) {
		container.innerHTML = '';
		var enabledToggle = E('input', { type: 'checkbox' });
		enabledToggle.checked = !!cfg.enabled;
		enabledToggle.addEventListener('change', function () { onChange({ enabled: enabledToggle.checked }); });

		var levelSelect = E('select', { class: 'sr-select', style: 'max-width:160px' },
			['debug', 'info', 'warning', 'error'].map(function (lv) {
				return E('option', { value: lv, selected: lv === cfg.level ? '' : null }, lv);
			}));
		levelSelect.addEventListener('change', function () { onChange({ level: levelSelect.value }); });

		var capInput = E('input', { type: 'number', class: 'sr-input', style: 'max-width:110px', min: '1', value: String(cfg.cap_mb) });
		var capSaveBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('logs_cap_save'));
		capSaveBtn.addEventListener('click', function () {
			var mb = parseInt(capInput.value, 10);
			if (!mb || mb < 1) return;
			onChange({ cap_mb: mb });
		});

		var clearBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove' }, T('logs_clear'));
		clearBtn.addEventListener('click', function () { api.clearLogs().then(function () { document.getElementById('sr-logs-box').innerHTML = ''; }); });

		container.appendChild(E('div', { class: 'sr-row', style: 'margin-bottom:8px' }, [
			E('label', { class: 'sr-row', style: 'font-weight:600' }, [enabledToggle, ' ', T('logs_enabled')]),
			E('span', { style: 'margin-left:auto' }),
			E('label', {}, T('logs_level')), levelSelect,
			clearBtn
		]));
		container.appendChild(E('div', { class: 'sr-row' }, [
			E('label', {}, T('logs_cap')), capInput, capSaveBtn,
			E('span', { class: 'sr-desc' }, cfg.free_mb != null ? (fmtFree(cfg.free_mb) + ' ' + T('logs_cap_free')) : '')
		]));
	}

	function connectLogs() {
		var box = document.getElementById('sr-logs-box');
		if (!box) return;
		var ws;
		try { ws = new WebSocket(wsURL('/logs')); } catch (e) { setTimeout(connectLogs, 3000); return; }
		ws.onclose = function () { if (!isGone()) setTimeout(connectLogs, 3000); };
		ws.onmessage = function (ev) {
			if (isGone()) { ws.close(); return; }
			try {
				var d = JSON.parse(ev.data);
				var line = E('div', { class: d.type === 'error' ? 'sr-log-err' : null }, d.payload);
				box.appendChild(line);
				while (box.childNodes.length > 400) box.removeChild(box.firstChild);
				box.scrollTop = box.scrollHeight;
			} catch (e) {}
		};
	}

	function fmtTrafficBytes(n) {
		n = n || 0;
		if (n < 1024) return n + ' Б/с';
		if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' КБ/с';
		return (n / (1024 * 1024)).toFixed(2) + ' МБ/с';
	}

	function fmtBytesPlain(n) {
		n = n || 0;
		if (n < 1024) return n + ' Б';
		if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' КБ';
		if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' МБ';
		return (n / (1024 * 1024 * 1024)).toFixed(2) + ' ГБ';
	}

	// Cumulative since Xray's last start (not a rate) -- ranked bars, biggest
	// first, each split into an up/down segment scaled to the largest single
	// profile's total so the bars stay comparable to each other.
	function renderTrafficByProfile(container, rows) {
		container.innerHTML = '';
		rows = (rows || []).slice().sort(function (a, b) { return (b.up + b.down) - (a.up + a.down); });
		if (!rows.length) { container.appendChild(E('p', { class: 'sr-desc' }, T('no_profiles'))); return; }

		container.appendChild(E('div', { class: 'sr-trafbar-legend' }, [
			E('span', {}, [E('span', { class: 'sr-swatch', style: 'background:var(--accent-2)' }), T('status_traffic_up')]),
			E('span', {}, [E('span', { class: 'sr-swatch', style: 'background:var(--accent)' }), T('status_traffic_down')])
		]));

		var max = Math.max.apply(null, rows.map(function (r) { return r.up + r.down; })) || 1;
		rows.forEach(function (r) {
			var total = r.up + r.down;
			var upPct = (r.up / max) * 100, downPct = (r.down / max) * 100;
			container.appendChild(E('div', { class: 'sr-trafbar-row' }, [
				E('div', { class: 'sr-trafbar-label', title: r.name }, r.name),
				E('div', { class: 'sr-trafbar-track' }, [
					E('div', { class: 'sr-trafbar-fill sr-trafbar-fill-up', style: 'width:' + upPct.toFixed(2) + '%' }),
					E('div', { class: 'sr-trafbar-fill sr-trafbar-fill-down', style: 'width:' + downPct.toFixed(2) + '%' })
				]),
				E('div', { class: 'sr-trafbar-value' }, total ? (fmtBytesPlain(r.up) + ' / ' + fmtBytesPlain(r.down)) : '—')
			]));
		});
	}

	function pollTrafficByProfile() {
		if (isGone()) return;
		fetch('/api/traffic-by-profile').then(function (r) { return r.json(); }).then(function (rows) {
			if (isGone()) return;
			var box = document.getElementById('sr-traffic-by-profile');
			if (box) renderTrafficByProfile(box, rows);
			setTimeout(pollTrafficByProfile, TRAFFIC_BY_PROFILE_POLL_MS);
		}, function () { if (!isGone()) setTimeout(pollTrafficByProfile, TRAFFIC_BY_PROFILE_POLL_MS); });
	}

	function drawTraffic() {
		var canvas = document.getElementById('sr-traffic-canvas');
		if (!canvas) return;
		var ctx = canvas.getContext('2d');
		var w = canvas.width, h = canvas.height;
		ctx.clearRect(0, 0, w, h);
		var up = state.trafficUp, down = state.trafficDown;
		var max = 1;
		up.concat(down).forEach(function (v) { if (v > max) max = v; });
		ctx.strokeStyle = '#333';
		ctx.beginPath(); ctx.moveTo(0, h - 1); ctx.lineTo(w, h - 1); ctx.stroke();
		function drawLine(series, color) {
			if (series.length < 2) return;
			ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.beginPath();
			series.forEach(function (v, i) {
				var x = (i / (TRAFFIC_HISTORY_LEN - 1)) * w;
				var y = h - (v / max) * (h - 4) - 2;
				if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
			});
			ctx.stroke();
		}
		drawLine(down, '#4f8cff');
		drawLine(up, '#35c56a');
	}

	function connectTraffic() {
		if (isGone()) return;
		var ws;
		try { ws = new WebSocket(wsURL('/traffic')); } catch (e) { setTimeout(connectTraffic, 3000); return; }
		ws.onopen = function () { var el = document.getElementById('sr-traffic-conn'); if (el) el.style.display = 'none'; };
		ws.onclose = function () { if (isGone()) return; var el = document.getElementById('sr-traffic-conn'); if (el) el.style.display = ''; setTimeout(connectTraffic, 3000); };
		ws.onerror = function () { ws.close(); };
		ws.onmessage = function (ev) {
			if (isGone()) { ws.close(); return; }
			try {
				var d = JSON.parse(ev.data);
				var upEl = document.getElementById('sr-traffic-up'), downEl = document.getElementById('sr-traffic-down');
				if (upEl) upEl.textContent = fmtTrafficBytes(d.up);
				if (downEl) downEl.textContent = fmtTrafficBytes(d.down);
				state.trafficUp.push(d.up || 0);
				state.trafficDown.push(d.down || 0);
				if (state.trafficUp.length > TRAFFIC_HISTORY_LEN) state.trafficUp.shift();
				if (state.trafficDown.length > TRAFFIC_HISTORY_LEN) state.trafficDown.shift();
				drawTraffic();
			} catch (e) {}
		};
	}

	function pollMetrics() {
		if (isGone()) return;
		api.getHealthMetrics().then(function (m) {
			if (isGone()) return;
			var box = document.getElementById('sr-status-metrics');
			if (box) renderMetrics(box, m || {});
			setTimeout(pollMetrics, METRICS_POLL_MS);
		}, function () { if (!isGone()) setTimeout(pollMetrics, METRICS_POLL_MS); });
	}

	function pollActivity() {
		if (isGone()) return;
		Promise.all([api.listProfiles(), api.getCurrent(), api.getActivity()]).then(function (data) {
			if (isGone()) return;
			var profiles = data[0] || [], current = data[1] || {};
			var activeTags = {}; (data[2] || []).forEach(function (t) { activeTags[t] = true; });
			var box = document.getElementById('sr-status-active-profiles');
			if (box) renderActiveProfiles(box, profiles, current, activeTags);
			setTimeout(pollActivity, ACTIVITY_POLL_MS);
		}, function () { if (!isGone()) setTimeout(pollActivity, ACTIVITY_POLL_MS); });
	}

	function loadLogConfig() {
		var box = document.getElementById('sr-log-controls');
		if (!box) return;
		api.getLogConfig().then(function (cfg) {
			renderLogControls(box, cfg || { enabled: false, level: 'warning', cap_mb: 10 }, function (patch) {
				var chain = Promise.resolve();
				if ('enabled' in patch) chain = chain.then(function () { return api.setLogEnabled(patch.enabled); });
				if ('level' in patch) chain = chain.then(function () { return api.setLogLevel(patch.level); });
				if ('cap_mb' in patch) chain = chain.then(function () {
					return api.setLogCapMb(patch.cap_mb).then(function (r) {
						if (r && r.error) SR.toast(T('logs_cap_rejected'), 'error');
					});
				});
				chain.then(loadLogConfig);
			});
		});
	}

	function renderPasswordCard(container) {
		container.innerHTML = '';
		fetch('/api/auth/status').then(function (r) { return r.json(); }).then(function (st) {
			var currentInput = E('input', { type: 'password', class: 'sr-input', style: 'max-width:220px', autocomplete: 'current-password' });
			var newInput = E('input', { type: 'password', class: 'sr-input', style: 'max-width:220px', autocomplete: 'new-password' });
			var saveBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-primary' }, T('settings_password_save'));
			saveBtn.addEventListener('click', function () {
				saveBtn.disabled = true;
				fetch('/api/change-password', {
					method: 'POST', headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify({ current: currentInput.value, new: newInput.value })
				}).then(function (r) { return r.json().then(function (body) { return { ok: r.ok, body: body }; }); })
					.then(function (res) {
						saveBtn.disabled = false;
						if (!res.ok) {
							SR.toast(res.body && res.body.error === 'password_too_short' ? T('settings_password_too_short') : T('login_error'), 'error');
							return;
						}
						currentInput.value = ''; newInput.value = '';
						SR.toast(T('settings_password_saved'), 'info');
						renderPasswordCard(container);
					});
			});
			container.appendChild(E('div', {}, [
				st.authRequired ? null : E('p', { class: 'sr-desc', style: 'color:var(--warn)' }, T('settings_password_none')),
				E('div', { class: 'sr-row' }, [
					st.authRequired ? E('div', {}, [E('label', { class: 'sr-label' }, T('settings_password_current')), currentInput]) : null,
					E('div', {}, [E('label', { class: 'sr-label' }, T('settings_password_new')), newInput]),
					E('div', { style: 'align-self:flex-end' }, [saveBtn])
				])
			]));
		});
	}

	function handleServiceAction(service, action, ev) {
		var btn = ev.target;
		btn.disabled = true;
		api.serviceControl(service, action).then(function (res) {
			if (res && res.error) SR.toast(T('status_action_failed') + ': ' + (res.detail || res.error), 'error');
			return api.serviceStatus().then(function (st) {
				var box = document.getElementById('sr-status-services');
				if (box) renderServices(box, st || {}, handleServiceAction);
				btn.disabled = false;
			});
		});
	}

	function render(container) {
		container.innerHTML = '';

		var linksBox = E('div', { class: 'sr-row' }, [
			E('a', { class: 'sr-btn', href: httpURL(1000), target: '_blank', rel: 'noopener' }, T('status_link_xkeenui'))
		]);

		container.appendChild(E('div', {}, [
			E('h1', { class: 'sr-page-title' }, T('nav_home')),

			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_traffic_title')),
				E('p', { id: 'sr-traffic-conn', class: 'sr-desc', style: 'color:var(--bad)' }, T('status_traffic_disconnected')),
				E('div', { class: 'sr-row', style: 'gap:2em;margin:.25em 0' }, [
					E('div', {}, [E('span', { class: 'sr-dot sr-dot-ok' }), T('status_traffic_up') + ': ', E('span', { id: 'sr-traffic-up' }, '0 Б/с')]),
					E('div', {}, [E('span', { class: 'sr-dot', style: 'background:#4f8cff' }), T('status_traffic_down') + ': ', E('span', { id: 'sr-traffic-down' }, '0 Б/с')])
				]),
				E('canvas', { id: 'sr-traffic-canvas', width: '640', height: '90' })
			]),

			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_traffic_by_profile_title')), E('div', { id: 'sr-traffic-by-profile' })]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_metrics_title')), E('div', { id: 'sr-status-metrics' })]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_active_profiles_title')), E('div', { id: 'sr-status-active-profiles' })]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('settings_password_title')), E('div', { id: 'sr-password-card' })]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_services_title')), E('div', { id: 'sr-status-services' })]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_links_title')), linksBox]),
			E('div', { class: 'sr-card' }, [E('h3', {}, T('status_overview_title')), E('div', { id: 'sr-status-overview' })]),

			E('div', { class: 'sr-card' }, [
				E('h3', {}, T('logs_title')),
				E('p', { class: 'sr-desc' }, T('logs_note')),
				E('div', { id: 'sr-log-controls' }),
				E('p', { class: 'sr-desc' }, T('logs_tmpfs_note')),
				E('div', { id: 'sr-logs-box' })
			])
		]));

		Promise.all([api.getStatus(), api.serviceStatus(), api.listSubscriptions()]).then(function (data) {
			var overviewBox = document.getElementById('sr-status-overview');
			if (overviewBox) overviewBox.appendChild(renderOverview(data[0] || {}, data[2] || []));
			var svcBox = document.getElementById('sr-status-services');
			if (svcBox) renderServices(svcBox, data[1] || {}, handleServiceAction);
		});

		state.trafficUp = []; state.trafficDown = [];
		connectTraffic();
		connectLogs();
		loadLogConfig();
		pollMetrics();
		pollActivity();
		pollTrafficByProfile();
		renderPasswordCard(document.getElementById('sr-password-card'));
	}

	renderers.home = render;
})();
