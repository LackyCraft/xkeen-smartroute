'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return Promise.all([sr.rpc.listProfiles(), sr.rpc.listKillswitchEnabled()]);
	},

	handleToggle: function (name, ev) {
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		return sr.rpc.killswitchSet(name, enabled).then(function () {
			ev.target.disabled = false;
		});
	},

	render: function (data) {
		var view = this;
		var profiles = data[0] || [];
		var enabledNames = data[1] || [];

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, sr.T('profile_name')),
				E('th', { 'class': 'th' }, sr.T('col_domains')),
				E('th', { 'class': 'th' }, 'Kill-Switch')
			])
		]);

		profiles.forEach(function (p) {
			var isGeosite = p.domain_source.type === 'geosite';
			var domainsLabel = isGeosite ? 'geosite:' + p.domain_source.value : p.domain_source.file;
			var toggle = E('input', { 'type': 'checkbox' });
			toggle.checked = enabledNames.indexOf(p.name) !== -1;
			toggle.addEventListener('change', function (ev) { view.handleToggle(p.name, ev); });
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, p.name),
				E('td', { 'class': 'td' }, domainsLabel),
				E('td', { 'class': 'td' }, [toggle, isGeosite ? E('span', { 'class': 'cbi-value-description' }, ' ' + sr.T('ks_geosite_note')) : ''])
			]));
		});

		return E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_killswitch')),
			E('p', {}, sr.T('ks_intro')),
			profiles.length ? table : E('p', { 'class': 'cbi-value-description' }, sr.T('no_profiles'))
		]);
	}
});
