'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return sr.rpc.listServers();
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
			this.renderTable(res || []);
		}, this));
	},

	renderTable: function (servers) {
		var container = document.getElementById('sr-servers-table');
		if (!container) return;

		if (!servers || !servers.length) {
			container.innerHTML = '';
			container.appendChild(E('p', { 'class': 'cbi-value-description' }, sr.T('no_servers')));
			return;
		}

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, sr.T('col_server')),
				E('th', { 'class': 'th' }, sr.T('col_address')),
				E('th', { 'class': 'th' }, sr.T('col_protocol')),
				E('th', { 'class': 'th' }, sr.T('col_subscription'))
			])
		]);

		servers.forEach(function (s) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, s.name),
				E('td', { 'class': 'td' }, s.address),
				E('td', { 'class': 'td' }, s.protocol),
				E('td', { 'class': 'td' }, s.subscription)
			]));
		});

		container.innerHTML = '';
		container.appendChild(table);
	},

	render: function (servers) {
		var view = this;

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

		var root = E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_subscriptions')),
			E('p', {}, sr.T('sub_intro')),
			E('div', { 'class': 'cbi-section' }, [
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
			]),
			E('h3', {}, sr.T('sub_table_title')),
			E('div', { 'id': 'sr-servers-table' })
		]);

		requestAnimationFrame(function () { view.renderTable(servers); });

		return root;
	}
});
