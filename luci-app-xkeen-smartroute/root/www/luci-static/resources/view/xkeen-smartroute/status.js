'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

var GATEWAY_PORT = 1001;
var XKEENUI_PORT = 1000;
var TRAFFIC_HISTORY_LEN = 60;
var LOG_MAX_LINES = 200;

return view.extend({
	load: function () {
		return Promise.all([
			sr.rpc.getStatus(),
			sr.rpc.serviceStatus(),
			sr.rpc.listSubscriptions()
		]);
	},

	// wsURL: the gateway (smartroute-gateway, port 1001) is a separate
	// service from LuCI itself -- reachable at the same host LuCI is
	// currently served from, just a different port. Plain http/ws (not
	// https/wss) since the gateway has no TLS of its own -- matches how its
	// own static panel (gateway/static/index.html) connects to itself.
	wsURL: function (path) {
		return 'ws://' + location.hostname + ':' + GATEWAY_PORT + path;
	},

	httpURL: function (port) {
		return 'http://' + location.hostname + ':' + port + '/';
	},

	// True once the view's own root node has been removed from the page
	// (LuCI's SPA navigation swaps view content without a formal "unmount"
	// hook) -- checked before scheduling any reconnect/next-tick so a
	// WebSocket or timer started here doesn't keep running forever in the
	// background after the user has navigated to a different tab.
	isGone: function () {
		return !document.getElementById('sr-status-root');
	},

	handleServiceAction: function (service, action, ev) {
		var view = this;
		var btn = ev.target;
		btn.disabled = true;
		return sr.rpc.serviceControl(service, action).then(function (res) {
			if (res && res.error) {
				ui.addNotification(null, E('p', {}, sr.T('status_action_failed') + ': ' + (res.detail || res.error)), 'error');
			}
			return sr.rpc.serviceStatus().then(function (st) {
				view.serviceState = st || {};
				view.renderServices();
			});
		});
	},

	serviceCard: function (key, titleKey, running) {
		var view = this;
		var dot = E('span', { 'style': 'display:inline-block;width:.7em;height:.7em;border-radius:50%;margin-right:.5em;background:' + (running ? '#2ecc71' : '#e74c3c') });
		return E('div', { 'style': 'display:flex;align-items:center;gap:.75em;padding:.4em 0;flex-wrap:wrap' }, [
			E('div', { 'style': 'min-width:14em' }, [dot, sr.T(titleKey), ' — ', E('span', { 'style': 'opacity:.75' }, running ? sr.T('status_svc_running') : sr.T('status_svc_stopped'))]),
			E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, function (ev) { return view.handleServiceAction(key, 'start', ev); }) }, sr.T('status_action_start')),
			E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, function (ev) { return view.handleServiceAction(key, 'stop', ev); }) }, sr.T('status_action_stop')),
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(view, function (ev) { return view.handleServiceAction(key, 'restart', ev); }) }, sr.T('status_action_restart'))
		]);
	},

	renderServices: function () {
		var box = document.getElementById('sr-status-services');
		if (!box) return;
		var st = this.serviceState || {};
		box.innerHTML = '';
		box.appendChild(this.serviceCard('xray', 'status_service_xray', !!st.xray));
		box.appendChild(this.serviceCard('gateway', 'status_service_gateway', !!st.gateway));
		box.appendChild(this.serviceCard('xkeen-ui', 'status_service_xkeenui', !!st.xkeen_ui));
	},

	renderOverview: function (getStatusResult, subs) {
		var rows = (subs || []).map(function (s) {
			return E('tr', {}, [
				E('td', {}, s.label || '—'),
				E('td', {}, String(s.server_count != null ? s.server_count : 0))
			]);
		});
		var table = rows.length
			? E('table', { 'class': 'table', 'style': 'margin-top:.5em' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, sr.T('status_subscriptions_col_label')),
					E('th', {}, sr.T('status_subscriptions_col_servers'))
				])),
				E('tbody', {}, rows)
			])
			: E('p', { 'class': 'cbi-value-description' }, sr.T('status_subscriptions_none'));
		return E('div', {}, [
			E('ul', {}, [
				E('li', {}, sr.T('servers_known') + ': ' + (getStatusResult.server_count != null ? getStatusResult.server_count : 0)),
				E('li', {}, sr.T('profiles_configured') + ': ' + (getStatusResult.profile_count != null ? getStatusResult.profile_count : 0))
			]),
			table
		]);
	},

	fmtBytes: function (n) {
		n = n || 0;
		if (n < 1024) return n + ' Б/с';
		if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' КБ/с';
		return (n / (1024 * 1024)).toFixed(2) + ' МБ/с';
	},

	drawTraffic: function () {
		var canvas = document.getElementById('sr-traffic-canvas');
		if (!canvas) return;
		var ctx = canvas.getContext('2d');
		var w = canvas.width, h = canvas.height;
		ctx.clearRect(0, 0, w, h);
		var up = this.trafficUp || [], down = this.trafficDown || [];
		var max = 1;
		up.concat(down).forEach(function (v) { if (v > max) max = v; });
		var isDark = matchMedia && matchMedia('(prefers-color-scheme: dark)').matches;
		ctx.strokeStyle = isDark ? '#333' : '#ddd';
		ctx.beginPath(); ctx.moveTo(0, h - 1); ctx.lineTo(w, h - 1); ctx.stroke();
		function drawLine(series, color) {
			if (series.length < 2) return;
			ctx.strokeStyle = color;
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			series.forEach(function (v, i) {
				var x = (i / (TRAFFIC_HISTORY_LEN - 1)) * w;
				var y = h - (v / max) * (h - 4) - 2;
				if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
			});
			ctx.stroke();
		}
		drawLine(down, '#3498db');
		drawLine(up, '#2ecc71');
	},

	connectTraffic: function () {
		var view = this;
		if (view.isGone()) return;
		var ws;
		try { ws = new WebSocket(view.wsURL('/traffic')); } catch (e) {
			setTimeout(function () { view.connectTraffic(); }, 3000);
			return;
		}
		view.trafficWs = ws;
		view.trafficUp = view.trafficUp || [];
		view.trafficDown = view.trafficDown || [];
		ws.onopen = function () {
			var el = document.getElementById('sr-traffic-conn');
			if (el) el.style.display = 'none';
		};
		ws.onclose = function () {
			if (view.isGone()) return;
			var el = document.getElementById('sr-traffic-conn');
			if (el) el.style.display = '';
			setTimeout(function () { view.connectTraffic(); }, 3000);
		};
		ws.onerror = function () { ws.close(); };
		ws.onmessage = function (ev) {
			if (view.isGone()) { ws.close(); return; }
			try {
				var d = JSON.parse(ev.data);
				var upEl = document.getElementById('sr-traffic-up');
				var downEl = document.getElementById('sr-traffic-down');
				if (upEl) upEl.textContent = view.fmtBytes(d.up);
				if (downEl) downEl.textContent = view.fmtBytes(d.down);
				view.trafficUp.push(d.up || 0);
				view.trafficDown.push(d.down || 0);
				if (view.trafficUp.length > TRAFFIC_HISTORY_LEN) view.trafficUp.shift();
				if (view.trafficDown.length > TRAFFIC_HISTORY_LEN) view.trafficDown.shift();
				view.drawTraffic();
			} catch (e) {}
		};
	},

	connectLogs: function () {
		var view = this;
		if (view.isGone()) return;
		var ws;
		try { ws = new WebSocket(view.wsURL('/logs')); } catch (e) {
			setTimeout(function () { view.connectLogs(); }, 3000);
			return;
		}
		view.logsWs = ws;
		ws.onclose = function () {
			if (view.isGone()) return;
			setTimeout(function () { view.connectLogs(); }, 3000);
		};
		ws.onerror = function () { ws.close(); };
		ws.onmessage = function (ev) {
			if (view.isGone()) { ws.close(); return; }
			var box = document.getElementById('sr-logs-box');
			if (!box) return;
			try {
				var d = JSON.parse(ev.data);
				var empty = document.getElementById('sr-logs-empty');
				if (empty) empty.remove();
				var line = E('div', { 'style': d.type === 'error' ? 'color:#e74c3c' : '' }, d.payload);
				box.appendChild(line);
				while (box.childNodes.length > LOG_MAX_LINES) box.removeChild(box.firstChild);
				box.scrollTop = box.scrollHeight;
			} catch (e) {}
		};
	},

	render: function (data) {
		var view = this;
		var getStatusResult = data[0] || {};
		view.serviceState = data[1] || {};
		var subs = data[2] || [];

		var servicesBox = E('div', { 'id': 'sr-status-services' });
		var linksBox = E('div', { 'style': 'display:flex;gap:1em;flex-wrap:wrap;margin:.5em 0' }, [
			E('a', { 'class': 'cbi-button', 'href': view.httpURL(XKEENUI_PORT), 'target': '_blank', 'rel': 'noopener' }, sr.T('status_link_xkeenui')),
			E('a', { 'class': 'cbi-button', 'href': view.httpURL(GATEWAY_PORT), 'target': '_blank', 'rel': 'noopener' }, sr.T('status_link_panel'))
		]);

		var root = E('div', { 'id': 'sr-status-root' }, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_status')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('status_services_title')),
				servicesBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('status_links_title')),
				linksBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('status_overview_title')),
				view.renderOverview(getStatusResult, subs)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('status_traffic_title')),
				E('p', { 'id': 'sr-traffic-conn', 'class': 'cbi-value-description', 'style': 'color:#e74c3c' }, sr.T('status_traffic_disconnected')),
				E('div', { 'style': 'display:flex;gap:2em;margin:.25em 0' }, [
					E('div', {}, [E('span', { 'style': 'display:inline-block;width:.7em;height:.7em;background:#2ecc71;margin-right:.4em' }), sr.T('status_traffic_up') + ': ', E('span', { 'id': 'sr-traffic-up' }, '0 Б/с')]),
					E('div', {}, [E('span', { 'style': 'display:inline-block;width:.7em;height:.7em;background:#3498db;margin-right:.4em' }), sr.T('status_traffic_down') + ': ', E('span', { 'id': 'sr-traffic-down' }, '0 Б/с')])
				]),
				E('canvas', { 'id': 'sr-traffic-canvas', 'width': '640', 'height': '80', 'style': 'width:100%;max-width:640px;height:80px;border:1px solid #8884' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('status_logs_title')),
				E('div', {
					'id': 'sr-logs-box',
					'style': 'font-family:monospace;font-size:.85em;max-height:16em;overflow-y:auto;background:rgba(128,128,128,.08);border:1px solid #8884;border-radius:4px;padding:.5em'
				}, [
					E('div', { 'id': 'sr-logs-empty', 'class': 'cbi-value-description' }, sr.T('status_logs_empty'))
				])
			])
		]);

		requestAnimationFrame(function () {
			view.renderServices();
			view.connectTraffic();
			view.connectLogs();
		});

		return root;
	}
});
