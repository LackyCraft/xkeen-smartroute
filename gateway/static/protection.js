'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;

	function render(container) {
		container.innerHTML = '';

		var enabledToggle = E('input', { type: 'checkbox' });
		var dnsToggle = E('input', { type: 'checkbox' });
		var ipv6Toggle = E('input', { type: 'checkbox' });
		var quicToggle = E('input', { type: 'checkbox' });
		var portsInput = E('input', { type: 'text', class: 'sr-input', style: 'max-width:160px', placeholder: T('prot_ports_placeholder') });

		function applyStatus(status) {
			if (!status) return;
			enabledToggle.checked = !!status.enabled;
			dnsToggle.checked = !!status.dns_protect;
			ipv6Toggle.checked = !!status.ipv6_protect;
			quicToggle.checked = !!status.quic_protect;
			if (typeof status.ports === 'string') portsInput.value = status.ports;
		}

		// applyOrRevert: on failure (redirect.sh's rd_write can genuinely
		// fail its fw4 syntax check and leave the previous firewall state
		// untouched), put back the checkbox the user just clicked and show
		// why, instead of applyStatus() blindly reading .enabled etc off
		// an {error,detail} body (all undefined -> every toggle silently
		// resets to unchecked with no explanation).
		function applyOrRevert(ev, wasChecked, status) {
			if (status && status.error) {
				ev.target.checked = wasChecked;
				SR.toast(T('prot_save_failed') + ': ' + (status.detail || status.error), 'error');
				return;
			}
			applyStatus(status);
		}

		enabledToggle.addEventListener('change', function (ev) {
			var wasChecked = !ev.target.checked;
			ev.target.disabled = true;
			api.redirectSetEnabled(ev.target.checked).then(function (status) { ev.target.disabled = false; applyOrRevert(ev, wasChecked, status); });
		});
		dnsToggle.addEventListener('change', function (ev) {
			var wasChecked = !ev.target.checked;
			ev.target.disabled = true;
			api.redirectSetDnsProtect(ev.target.checked).then(function (status) { ev.target.disabled = false; applyOrRevert(ev, wasChecked, status); });
		});
		ipv6Toggle.addEventListener('change', function (ev) {
			var wasChecked = !ev.target.checked;
			ev.target.disabled = true;
			api.redirectSetIpv6Protect(ev.target.checked).then(function (status) { ev.target.disabled = false; applyOrRevert(ev, wasChecked, status); });
		});
		quicToggle.addEventListener('change', function (ev) {
			var wasChecked = !ev.target.checked;
			ev.target.disabled = true;
			api.redirectSetQuicProtect(ev.target.checked).then(function (status) { ev.target.disabled = false; applyOrRevert(ev, wasChecked, status); });
		});

		var savePortsBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('prot_ports_save'));
		savePortsBtn.addEventListener('click', function (ev) {
			ev.target.disabled = true;
			api.redirectSetPorts(portsInput.value.trim()).then(function (status) {
				ev.target.disabled = false;
				if (status && status.error) { SR.toast(T('prot_save_failed') + ': ' + (status.detail || status.error), 'error'); return; }
				applyStatus(status);
				SR.toast(T('prot_saved_ok'), 'info');
			});
		});

		container.appendChild(E('div', {}, [
			E('h1', { class: 'sr-page-title' }, T('nav_protection')),

			E('div', { class: 'sr-card' }, [
				E('p', {}, T('prot_intro')),
				E('label', { class: 'sr-row' }, [enabledToggle, ' ', T('prot_redirect_enabled')])
			]),
			E('div', { class: 'sr-card' }, [
				E('label', { class: 'sr-label' }, T('prot_ports_label')),
				E('div', { class: 'sr-row' }, [portsInput, savePortsBtn])
			]),
			E('div', { class: 'sr-card' }, [
				E('h3', {}, T('prot_dns_title')),
				E('p', { class: 'sr-desc' }, T('prot_dns_intro')),
				E('label', { class: 'sr-row' }, [dnsToggle, ' ', T('prot_dns_title')])
			]),
			E('div', { class: 'sr-card' }, [
				E('h3', {}, T('prot_ipv6_title')),
				E('p', { class: 'sr-desc' }, T('prot_ipv6_intro')),
				E('label', { class: 'sr-row' }, [ipv6Toggle, ' ', T('prot_ipv6_title')])
			]),
			E('div', { class: 'sr-card' }, [
				E('h3', {}, T('prot_quic_title')),
				E('p', { class: 'sr-desc' }, T('prot_quic_intro')),
				E('label', { class: 'sr-row' }, [quicToggle, ' ', T('prot_quic_title')])
			])
		]));

		api.redirectStatus().then(applyStatus);
	}

	renderers.protection = render;
})();
