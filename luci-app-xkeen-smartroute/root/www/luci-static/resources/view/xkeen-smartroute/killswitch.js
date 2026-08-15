'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return sr.rpc.listProfiles();
	},

	handleToggle: function (name, ev) {
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		return sr.rpc.killswitchSet(name, enabled).then(function () {
			ev.target.disabled = false;
		});
	},

	render: function (profiles) {
		var view = this;
		profiles = profiles || [];

		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, sr.T('profile_name')),
				E('th', { 'class': 'th' }, sr.T('col_domains')),
				E('th', { 'class': 'th' }, 'Kill-Switch')
			])
		]);

		profiles.forEach(function (p) {
			var isCustom = p.domain_source.type === 'custom';
			var domainsLabel = isCustom ? p.domain_source.file : 'geosite:' + p.domain_source.value;
			var toggle = E('input', { 'type': 'checkbox' });
			if (!isCustom) {
				toggle.disabled = true;
			} else {
				toggle.addEventListener('change', function (ev) { view.handleToggle(p.name, ev); });
			}
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, p.name),
				E('td', { 'class': 'td' }, domainsLabel),
				E('td', { 'class': 'td' }, [toggle, !isCustom ? E('span', { 'class': 'cbi-value-description' }, ' ' + sr.T('ks_custom_only')) : ''])
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
