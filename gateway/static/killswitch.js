'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;

	function render(container) {
		container.innerHTML = '';
		container.appendChild(E('h1', { class: 'sr-page-title' }, T('nav_killswitch')));
		container.appendChild(E('p', { class: 'sr-desc' }, T('ks_intro')));
		var box = E('div', { class: 'sr-card' });
		container.appendChild(box);

		Promise.all([api.listProfiles(), api.listKillswitchEnabled()]).then(function (data) {
			var profiles = data[0] || [], enabledNames = data[1] || [];
			box.innerHTML = '';
			if (!profiles.length) { box.appendChild(E('p', { class: 'sr-desc' }, T('no_profiles'))); return; }

			var table = E('table', { class: 'sr-table' }, [E('tr', {}, [E('th', {}, T('profile_name')), E('th', {}, T('col_domains')), E('th', {}, 'Kill-Switch')])]);
			profiles.forEach(function (p) {
				var isGeosite = p.domain_source && p.domain_source.type === 'geosite';
				var domainsLabel = isGeosite ? 'geosite:' + p.domain_source.value : ((p.domain_source && p.domain_source.file) || T('domain_source_any'));
				var toggle = E('input', { type: 'checkbox' });
				toggle.checked = enabledNames.indexOf(p.name) !== -1;
				toggle.addEventListener('change', function (ev) {
					var enabled = ev.target.checked;
					ev.target.disabled = true;
					api.killswitchSet(p.name, enabled).then(function (res) {
						ev.target.disabled = false;
						// killswitch.sh can genuinely fail to arm (e.g. the
						// system dnsmasq lacks ipset/nftset support) --
						// revert the checkbox and say so instead of leaving
						// it checked as if protection were actually on.
						if (res && res.error) {
							ev.target.checked = !enabled;
							SR.toast(T('status_action_failed') + ': ' + (res.detail || res.error), 'error');
						}
					});
				});
				table.appendChild(E('tr', {}, [
					E('td', {}, p.name), E('td', {}, domainsLabel),
					E('td', {}, [toggle, isGeosite ? E('span', { class: 'sr-desc' }, ' ' + T('ks_geosite_note')) : ''])
				]));
			});
			box.appendChild(table);
		});
	}

	renderers.killswitch = render;
})();
