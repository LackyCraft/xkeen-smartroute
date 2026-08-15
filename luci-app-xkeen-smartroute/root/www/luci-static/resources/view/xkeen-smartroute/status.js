'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return sr.rpc.getStatus();
	},

	handleRefresh: function () {
		return sr.rpc.getStatus().then(L.bind(function (st) {
			this.renderCard(st);
		}, this));
	},

	renderCard: function (st) {
		var container = document.getElementById('sr-status-card');
		container.innerHTML = '';
		container.appendChild(E('ul', {}, [
			E('li', {}, (st.xray_running ? '✅ ' + sr.T('xray_running') : '❌ ' + sr.T('xray_stopped'))),
			E('li', {}, st.server_count + ' ' + sr.T('servers_known')),
			E('li', {}, st.profile_count + ' ' + sr.T('profiles_configured'))
		]));
	},

	render: function (st) {
		var view = this;
		var root = E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_status')),
			E('div', { 'class': 'cbi-section', 'id': 'sr-status-card' }),
			E('button', {
				'class': 'cbi-button',
				'click': ui.createHandlerFn(view, 'handleRefresh')
			}, sr.T('refresh_btn'))
		]);

		requestAnimationFrame(function () { view.renderCard(st); });
		return root;
	}
});
