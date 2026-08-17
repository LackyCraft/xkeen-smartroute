'use strict';
'require view';
'require ui';
'require xkeen-smartroute as sr';

return view.extend({
	load: function () {
		return sr.rpc.redirectStatus();
	},

	handleEnabledToggle: function (ev) {
		var view = this;
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		return sr.rpc.redirectSetEnabled(enabled).then(function (status) {
			ev.target.disabled = false;
			view.applyStatus(status);
		});
	},

	handleDnsToggle: function (ev) {
		var view = this;
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		return sr.rpc.redirectSetDnsProtect(enabled).then(function (status) {
			ev.target.disabled = false;
			view.applyStatus(status);
		});
	},

	handleIpv6Toggle: function (ev) {
		var view = this;
		var enabled = ev.target.checked;
		ev.target.disabled = true;
		return sr.rpc.redirectSetIpv6Protect(enabled).then(function (status) {
			ev.target.disabled = false;
			view.applyStatus(status);
		});
	},

	handleSavePorts: function (ev) {
		var view = this;
		var ports = view.portsInput.value.trim();
		ev.target.disabled = true;
		return sr.rpc.redirectSetPorts(ports).then(function (status) {
			ev.target.disabled = false;
			if (status && status.error) {
				ui.addNotification(null, E('p', {}, sr.T('prot_save_failed') + ': ' + (status.detail || status.error)), 'error');
			} else {
				view.applyStatus(status);
				ui.addNotification(null, E('p', {}, sr.T('prot_saved_ok')), 'info');
			}
		});
	},

	applyStatus: function (status) {
		if (!status) return;
		if (this.enabledToggle) this.enabledToggle.checked = !!status.enabled;
		if (this.dnsToggle) this.dnsToggle.checked = !!status.dns_protect;
		if (this.ipv6Toggle) this.ipv6Toggle.checked = !!status.ipv6_protect;
		if (this.portsInput && typeof status.ports === 'string') this.portsInput.value = status.ports;
	},

	render: function (status) {
		var view = this;
		status = status || {};

		view.enabledToggle = E('input', { 'type': 'checkbox' });
		view.enabledToggle.checked = !!status.enabled;
		view.enabledToggle.addEventListener('change', function (ev) { view.handleEnabledToggle(ev); });

		view.dnsToggle = E('input', { 'type': 'checkbox' });
		view.dnsToggle.checked = !!status.dns_protect;
		view.dnsToggle.addEventListener('change', function (ev) { view.handleDnsToggle(ev); });

		view.ipv6Toggle = E('input', { 'type': 'checkbox' });
		view.ipv6Toggle.checked = !!status.ipv6_protect;
		view.ipv6Toggle.addEventListener('change', function (ev) { view.handleIpv6Toggle(ev); });

		view.portsInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': sr.T('prot_ports_placeholder'),
			'value': status.ports || '80,443'
		});

		var savePortsBtn = E('button', { 'class': 'cbi-button cbi-button-save' }, sr.T('prot_ports_save'));
		savePortsBtn.addEventListener('click', ui.createHandlerFn(view, function (ev) { return view.handleSavePorts(ev); }));

		return E('div', {}, [
			sr.langSwitchButton(),
			E('h2', {}, sr.T('app_name') + ' — ' + sr.T('nav_protection')),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, sr.T('prot_intro')),
				E('label', { 'class': 'cbi-value' }, [
					view.enabledToggle,
					' ',
					sr.T('prot_redirect_enabled')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('label', { 'class': 'cbi-value-title' }, sr.T('prot_ports_label')),
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;max-width:20em' }, [
					view.portsInput,
					savePortsBtn
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('prot_dns_title')),
				E('p', { 'class': 'cbi-value-description' }, sr.T('prot_dns_intro')),
				E('label', { 'class': 'cbi-value' }, [
					view.dnsToggle,
					' ',
					sr.T('prot_dns_title')
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, sr.T('prot_ipv6_title')),
				E('p', { 'class': 'cbi-value-description' }, sr.T('prot_ipv6_intro')),
				E('label', { 'class': 'cbi-value' }, [
					view.ipv6Toggle,
					' ',
					sr.T('prot_ipv6_title')
				])
			])
		]);
	}
});
