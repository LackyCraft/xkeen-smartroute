'use strict';
(function () {
	var E = SR.E, T = SR.T, api = SR.api;
	var st = { customLists: [], customListExpanded: {} };

	function reloadCustomLists() { return api.listCustomLists().then(function (lists) { st.customLists = lists || []; renderCustomLists(); }); }

	function renderCustomLists() {
		var container = document.getElementById('sr-custom-lists');
		if (!container) return;
		container.innerHTML = '';
		if (!st.customLists.length) { container.appendChild(E('p', { class: 'sr-desc' }, T('domains_no_lists'))); return; }

		st.customLists.forEach(function (l) {
			var isOpen = !!st.customListExpanded[l.key];
			var label = SR.lang() === 'en' ? (l.label_en || l.key) : (l.label_ru || l.key);
			var toggle = E('a', { href: '#', style: 'font-weight:700' }, (isOpen ? '▾ ' : '▸ ') + label + ' — ' + l.domains.length);
			toggle.addEventListener('click', function (ev) { ev.preventDefault(); st.customListExpanded[l.key] = !st.customListExpanded[l.key]; renderCustomLists(); });
			var deleteBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove' }, T('delete_btn'));
			deleteBtn.addEventListener('click', function () {
				if (!confirm(T('domains_delete_list_confirm').replace('%s', label))) return;
				api.deleteCustomList(l.key).then(reloadCustomLists);
			});
			var card = E('div', { class: 'sr-card', style: 'margin-bottom:.5em' }, [E('div', { class: 'sr-row-between' }, [toggle, deleteBtn])]);

			if (isOpen) {
				var list = E('div', { style: 'margin:8px 0 0 4px' });
				l.domains.forEach(function (d) {
					var rmBtn = E('button', { class: 'sr-btn sr-btn-sm sr-btn-remove', style: 'padding:1px 8px' }, '×');
					rmBtn.addEventListener('click', function () { api.removeDomainFromList(l.key, d).then(reloadCustomLists); });
					list.appendChild(E('div', { class: 'sr-row', style: 'padding:2px 0' }, [d, rmBtn]));
				});
				var addInput = E('input', { type: 'text', class: 'sr-input', style: 'max-width:220px', placeholder: T('domains_add_domain_placeholder') });
				var addBtn = E('button', { class: 'sr-btn sr-btn-sm' }, T('add_btn'));
				addBtn.addEventListener('click', function () {
					var raw = addInput.value.trim();
					if (!raw) return;
					api.addDomainToList(l.key, SR.sanitizeDomain(raw)).then(function () { addInput.value = ''; reloadCustomLists(); });
				});
				list.appendChild(E('div', { class: 'sr-row', style: 'margin-top:6px;max-width:24em' }, [addInput, addBtn]));
				card.appendChild(list);
			}
			container.appendChild(card);
		});
	}

	function handleAddCustomDomain() {
		var nameInput = document.getElementById('sr-cd-name'), domInput = document.getElementById('sr-cd-domains');
		var name = nameInput.value.trim(), domainsRaw = domInput.value.trim();
		if (!name || !domainsRaw) return;
		var sanitizedList = domainsRaw.split(',').map(function (d) { return SR.sanitizeDomain(d.trim()); }).filter(Boolean);
		var domains = sanitizedList.join(',');
		if (domains !== domainsRaw.split(',').map(function (d) { return d.trim(); }).filter(Boolean).join(',')) SR.toast(T('domains_sanitized_note') + domains, 'info');

		api.addCustomDomain(name, domains).then(function (res) {
			if (res && res.error === 'list_already_exists') { SR.toast(T('domains_list_already_exists'), 'error'); return; }
			if (res && res.error) { SR.toast(res.error, 'error'); return; }
			SR.toast(T('add_btn') + ': ' + res.file, 'info');
			nameInput.value = ''; domInput.value = '';
			return reloadCustomLists();
		});
	}

	function render(container) {
		container.innerHTML = '';
		st.customListExpanded = {};

		var customDomainBox = E('div', { class: 'sr-card' }, [
			E('h3', {}, T('custom_domain_title')), E('p', { class: 'sr-desc' }, T('custom_domain_intro')),
			E('input', { type: 'text', id: 'sr-cd-name', class: 'sr-input', style: 'max-width:320px;margin-bottom:6px', placeholder: T('custom_list_name_placeholder') }),
			E('input', { type: 'text', id: 'sr-cd-domains', class: 'sr-input', style: 'margin-bottom:6px', placeholder: T('custom_domains_placeholder') }),
			E('button', { class: 'sr-btn sr-btn-primary', click: handleAddCustomDomain }, T('add_btn'))
		]);
		var manageDomainsBox = E('div', { class: 'sr-card' }, [E('h3', {}, T('domains_manage_title')), E('div', { id: 'sr-custom-lists' })]);

		container.appendChild(E('div', {}, [
			E('h1', { class: 'sr-page-title' }, T('nav_domains')),
			E('p', { class: 'sr-desc' }, T('domains_page_intro')),
			customDomainBox,
			manageDomainsBox
		]));

		reloadCustomLists();
	}

	renderers.domains = render;
})();
