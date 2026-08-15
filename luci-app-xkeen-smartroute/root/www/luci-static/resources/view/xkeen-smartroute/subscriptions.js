'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return sr.rpc.listServers();
	},

	handleImport: function (ev) {
		var urlInput = document.getElementById('sr-sub-url');
		var labelInput = document.getElementById('sr-sub-label');
		var btn = ev.target;
		var url = urlInput.value.trim();
		var label = labelInput.value.trim() || 'sub';

		if (!url) return;

		btn.disabled = true;
		btn.textContent = sr.T('sub_importing');

		return sr.rpc.importSubscription(url, label).then(L.bind(function (res) {
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
