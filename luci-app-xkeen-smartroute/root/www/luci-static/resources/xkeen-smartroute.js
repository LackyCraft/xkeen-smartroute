'use strict';
'require rpc';
'require ui';

// Shared helpers for all xkeen-smartroute views: ubus RPC declarations and a
// tiny hand-rolled RU/EN dictionary. LuCI's real gettext (.po -> .lmo) needs
// the LuCI build SDK to compile, which a hand-copied app (no opkg build step)
// doesn't have — so instead of a half-working single-language app, this file
// keeps its own dictionary and a language switch stored in localStorage.
// Every user-facing string in the four views is looked up through T(key).

// ubus/rpcd requires a JSON *object* at the top level of a script's output --
// a bare top-level JSON array makes the whole call fail with "Invalid
// argument" (confirmed against real hardware: rpcd script backends can't
// return arrays directly). The backend wraps every list-shaped result in a
// named field ({"servers":[...]}, {"categories":[...]}, ...); unwrap it here
// once so every view can keep working with plain arrays/promises.
var _callListServers = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_servers'
});
function callListServers() {
	return _callListServers().then(function (r) { return (r && r.servers) || []; });
}
var _callImportSubscription = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'import_subscription',
	params: ['url', 'label', 'client', 'os', 'locale', 'model', 'ver', 'hwid']
});
function callImportSubscription(url, label, client, os, locale, model, ver, hwid) {
	return _callImportSubscription(url, label, client, os, locale, model, ver, hwid).then(function (r) {
		if (r && r.error) return r;
		return (r && r.servers) || [];
	});
}
var callRandomHwid = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'random_hwid'
});
var _callListCategories = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_categories'
});
function callListCategories() {
	return _callListCategories().then(function (r) { return (r && r.categories) || []; });
}
var _callListCustomCategories = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_custom_categories'
});
function callListCustomCategories() {
	return _callListCustomCategories().then(function (r) { return (r && r.categories) || []; });
}
var _callListProfiles = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_profiles'
});
function callListProfiles() {
	return _callListProfiles().then(function (r) { return (r && r.profiles) || []; });
}
var callSaveProfile = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'save_profile',
	params: ['profile']
});
var callDeleteProfile = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'delete_profile',
	params: ['name']
});
var callAddCustomDomain = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'add_custom_domain',
	params: ['list_name', 'domains']
});
var callGetStatus = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_status'
});
var callKillswitchSet = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'killswitch_set',
	params: ['name', 'enabled']
});
var _callPingServers = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'ping_servers'
});
function callPingServers() {
	return _callPingServers().then(function (r) { return (r && r.pings) || {}; });
}
var _callGetRefreshHours = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_refresh_hours'
});
function callGetRefreshHours() {
	return _callGetRefreshHours().then(function (r) { return (r && r.hours) || 12; });
}
var callSetRefreshHours = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'set_refresh_hours',
	params: ['hours']
});
var callRefreshNow = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'refresh_now'
});
var _callListKillswitchEnabled = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_killswitch_enabled'
});
function callListKillswitchEnabled() {
	return _callListKillswitchEnabled().then(function (r) { return (r && r.names) || []; });
}
var callRedirectStatus = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_status'
});
var callRedirectSetEnabled = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_set_enabled',
	params: ['enabled']
});
var callRedirectSetPorts = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_set_ports',
	params: ['ports']
});
var callRedirectSetDnsProtect = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_set_dns_protect',
	params: ['enabled']
});
var callRedirectSetIpv6Protect = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_set_ipv6_protect',
	params: ['enabled']
});
var _callListLanDevices = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_lan_devices'
});
function callListLanDevices() {
	return _callListLanDevices().then(function (r) { return (r && r.devices) || []; });
}

var DICT = {
	app_name:            { ru: 'XKeen SmartRoute DanyByLC', en: 'XKeen SmartRoute DanyByLC' },
	nav_subscriptions:   { ru: 'Подписки', en: 'Subscriptions' },
	nav_profiles:        { ru: 'Профили маршрутизации', en: 'Routing profiles' },
	nav_status:          { ru: 'Статус', en: 'Status' },
	nav_killswitch:      { ru: 'Kill-Switch', en: 'Kill-Switch' },
	nav_protection:      { ru: 'Защита от утечек', en: 'Leak protection' },

	sub_intro: { ru: 'Вставьте ссылку-подписку VLESS/Trojan (та же, что в V2rayNG/V2Box) — сервера из неё появятся ниже и станут доступны для выбора в профилях.',
	             en: 'Paste a VLESS/Trojan subscription link (the same one you use in V2rayNG/V2Box) — its servers will show up below and become selectable in profiles.' },
	sub_url_placeholder: { ru: 'https://example.com/sub/xxxxxxxx', en: 'https://example.com/sub/xxxxxxxx' },
	sub_label_placeholder: { ru: 'Название подписки (например: main)', en: 'Subscription label (e.g. main)' },
	sub_client_label: { ru: 'Представиться как', en: 'Identify as' },
	sub_client_hint: { ru: 'Некоторые провайдеры подписок отдают инструкцию для браузера вместо самой подписки — переключите на конкретное приложение, если импорт вернул 0 серверов.',
	                    en: "Some subscription providers serve a browser landing page instead of the actual subscription — switch to a specific app if import returns 0 servers." },
	sub_advanced_toggle: { ru: 'Настроить заголовки устройства…', en: 'Customize device headers…' },
	sub_device_os_label: { ru: 'Device-OS', en: 'Device-OS' },
	sub_locale_label: { ru: 'Device-Locale', en: 'Device-Locale' },
	sub_model_label: { ru: 'Device-Model', en: 'Device-Model' },
	sub_ver_label: { ru: 'X-Ver-Os', en: 'X-Ver-Os' },
	sub_hwid_label: { ru: 'X-Hwid', en: 'X-Hwid' },
	sub_hwid_generate: { ru: 'Сгенерировать', en: 'Generate' },
	sub_import_btn: { ru: 'Импортировать', en: 'Import' },
	sub_importing: { ru: 'Импортирую…', en: 'Importing…' },
	sub_imported_ok: { ru: 'Готово, сервера обновлены', en: 'Done, server list updated' },
	sub_import_failed: { ru: 'Не удалось импортировать подписку', en: 'Failed to import subscription' },
	sub_table_title: { ru: 'Известные сервера', en: 'Known servers' },
	col_server: { ru: 'Сервер', en: 'Server' },
	col_address: { ru: 'Адрес', en: 'Address' },
	col_protocol: { ru: 'Протокол', en: 'Protocol' },
	col_subscription: { ru: 'Подписка', en: 'Subscription' },
	col_ping: { ru: 'Пинг', en: 'Ping' },
	no_servers: { ru: 'Пока нет ни одного сервера — импортируйте подписку выше.', en: 'No servers yet — import a subscription above.' },
	ping_btn: { ru: 'Проверить пинг', en: 'Check ping' },
	pinging: { ru: 'Проверяю…', en: 'Checking…' },
	ping_timeout: { ru: 'нет ответа', en: 'no response' },
	refresh_settings_title: { ru: 'Автообновление подписок', en: 'Subscription auto-refresh' },
	refresh_interval_label: { ru: 'Обновлять каждые (часов)', en: 'Refresh every (hours)' },
	refresh_save_btn: { ru: 'Сохранить', en: 'Save' },
	refresh_now_btn: { ru: 'Обновить все подписки сейчас', en: 'Refresh all subscriptions now' },
	refresh_now_started: { ru: 'Обновление запущено в фоне — обновите список серверов через несколько секунд', en: 'Refresh started in the background — reload the server list in a few seconds' },
	refresh_saved_ok: { ru: 'Интервал сохранён', en: 'Interval saved' },

	profiles_intro: { ru: 'Профиль — это правило: «эти домены → на эти сервера». Можно направить список на один конкретный сервер (fixed) или на группу — тогда Xray сам будет постоянно выбирать самый быстрый живой сервер из группы (balancer / leastPing).',
	                   en: 'A profile is a rule: "these domains → these servers". Point a list at one specific server (fixed), or at a group — Xray will then continuously pick the fastest healthy server from the group itself (balancer / leastPing).' },
	profile_name: { ru: 'Название профиля', en: 'Profile name' },
	profile_name_placeholder: { ru: 'например: youtube', en: 'e.g. youtube' },
	domain_source: { ru: 'Список доменов', en: 'Domain list' },
	domain_source_geosite: { ru: 'Категория geosite (Xray)', en: 'geosite category (Xray)' },
	domain_source_custom: { ru: 'Наш список (custom)', en: 'Our list (custom)' },
	mode_label: { ru: 'Режим', en: 'Mode' },
	mode_fixed: { ru: 'Конкретный сервер', en: 'Fixed server' },
	mode_balancer: { ru: 'Группа — авто-выбор самого быстрого', en: 'Group — auto-pick fastest' },
	pick_server: { ru: 'Выберите сервер', en: 'Pick a server' },
	pick_servers: { ru: 'Выберите сервера для группы', en: 'Pick servers for the group' },
	save_profile_btn: { ru: 'Сохранить и применить', en: 'Save & apply' },
	saving: { ru: 'Сохраняю…', en: 'Saving…' },
	saved_ok: { ru: 'Сохранено, xray перезапущен', en: 'Saved, xray restarted' },
	save_failed: { ru: 'Не удалось сохранить профиль', en: 'Failed to save profile' },
	delete_btn: { ru: 'Удалить', en: 'Delete' },
	existing_profiles: { ru: 'Существующие профили', en: 'Existing profiles' },
	no_profiles: { ru: 'Профилей ещё нет.', en: 'No profiles yet.' },
	col_domains: { ru: 'Домены', en: 'Domains' },
	col_target: { ru: 'Куда', en: 'Target' },
	need_servers_first: { ru: 'Сначала импортируйте подписку на вкладке «Подписки».', en: 'Import a subscription on the Subscriptions tab first.' },

	devices_title: { ru: 'Устройства (необязательно)', en: 'Devices (optional)' },
	devices_intro: { ru: 'Ограничьте профиль конкретными устройствами — например, «только телевизор» вместо всей сети. Можно оставить пустым (профиль сработает для всех устройств) или сочетать со списком доменов выше — например, «только телевизор, только для YouTube».',
	                 en: "Restrict this profile to specific devices — e.g. \"only the TV\" instead of the whole network. Leave empty for all devices, or combine with the domain list above — e.g. \"only the TV, only for YouTube\"." },
	devices_none_selected: { ru: 'Устройства не выбраны — сработает для всего трафика, попадающего под список доменов выше.', en: 'No devices selected — applies to all traffic matching the domain list above.' },
	devices_no_domain_warning: { ru: 'Ни домены, ни устройства не выбраны — профиль ничего не будет матчить.', en: 'Neither domains nor devices are selected — this profile would match nothing.' },
	devices_manual_label: { ru: 'Добавить вручную (IP или CIDR)', en: 'Add manually (IP or CIDR)' },
	devices_manual_placeholder: { ru: '192.168.1.50 или 192.168.1.0/24', en: '192.168.1.50 or 192.168.1.0/24' },
	devices_manual_add: { ru: 'Добавить', en: 'Add' },
	devices_manual_invalid: { ru: 'Введите IPv4-адрес или CIDR, например 192.168.1.50 или 192.168.1.0/24', en: 'Enter an IPv4 address or CIDR, e.g. 192.168.1.50 or 192.168.1.0/24' },
	devices_detected_title: { ru: 'Обнаруженные в сети', en: 'Detected on the network' },
	devices_loading: { ru: 'Ищу устройства…', en: 'Looking for devices…' },
	devices_none_detected: { ru: 'Устройства не найдены (проверьте DHCP-аренды роутера).', en: 'No devices found (check the router\'s DHCP leases).' },
	devices_selected_title: { ru: 'Выбрано', en: 'Selected' },
	col_device_ip: { ru: 'IP', en: 'IP' },
	col_device_mac: { ru: 'MAC', en: 'MAC' },
	col_device_hostname: { ru: 'Имя', en: 'Hostname' },
	remove_btn: { ru: 'Убрать', en: 'Remove' },
	domain_source_any: { ru: 'Все домены (только по устройству)', en: 'All domains (device-only match)' },

	custom_domain_title: { ru: 'Добавить свой домен(ы)', en: 'Add your own domain(s)' },
	custom_domain_intro: { ru: 'Если нужного сайта нет ни в geosite, ни в готовых списках — впишите домены через запятую, мы сложим их в свой список и он сразу появится в выборе выше.',
	                        en: "If a site isn't in geosite or in the bundled lists — type domains separated by commas, we'll save them as a list that immediately appears in the picker above." },
	custom_list_name: { ru: 'Название списка', en: 'List name' },
	custom_list_name_placeholder: { ru: 'например: my-site', en: 'e.g. my-site' },
	custom_domains_placeholder: { ru: 'example.com, cdn.example.com', en: 'example.com, cdn.example.com' },
	add_btn: { ru: 'Добавить', en: 'Add' },

	status_title: { ru: 'Состояние стека', en: 'Stack status' },
	xray_running: { ru: 'Xray работает', en: 'Xray is running' },
	xray_stopped: { ru: 'Xray остановлен', en: 'Xray is stopped' },
	servers_known: { ru: 'Серверов известно', en: 'Servers known' },
	profiles_configured: { ru: 'Профилей настроено', en: 'Profiles configured' },
	refresh_btn: { ru: 'Обновить', en: 'Refresh' },

	ks_intro: { ru: 'Жёсткий kill-switch: если процесс xray упадёт (или его правила перехвата трафика пропадут), домены профиля будут заблокированы файрволом полностью — вместо риска уйти в интернет напрямую в обход VPN. Правило включается сразу и постоянно, без опроса раз в минуту — зазора по времени нет. Работает для geosite- и custom-профилей; для geosite-категорий покрытие неполное — учитываются только записи domain:/full: из исходного списка geosite, а keyword:/regexp: (их нет как буквальных доменов) не переносятся.',
	           en: "Hard kill-switch: if the xray process dies (or its traffic-capture rules disappear), the profile's domains get fully blocked by the firewall instead of risking a direct route around the VPN. The rule is armed immediately and stays on — no once-a-minute polling, so there's no time gap. Works for both geosite and custom profiles; geosite coverage is partial — only the domain:/full: entries from the category's source list translate to a literal block, keyword:/regexp: entries have no literal-domain equivalent and aren't covered." },
	ks_enabled: { ru: 'Включено', en: 'Enabled' },
	ks_disabled: { ru: 'Выключено', en: 'Disabled' },
	ks_geosite_note: { ru: '(частичное покрытие для geosite — см. пояснение выше)', en: '(partial coverage for geosite — see note above)' },

	prot_intro: { ru: 'Перехват LAN-трафика: без него ни один профиль/kill-switch не видит реальные пакеты устройств — это включает сам механизм, через который SmartRoute вообще может что-то маршрутизировать (свой nftables-редирект, не сломанный xkeen -ap на OpenWrt/nftables). Выключайте только для диагностики.',
	            en: "LAN traffic capture: without it, no profile/kill-switch ever sees real device packets — this is the mechanism SmartRoute routing depends on in the first place (our own nftables redirect, not xkeen's broken -ap on OpenWrt/nftables). Only turn it off for diagnostics." },
	prot_redirect_enabled: { ru: 'Перехват трафика включён', en: 'Traffic capture enabled' },
	prot_ports_label: { ru: 'Порты перехвата (через запятую)', en: 'Captured ports (comma-separated)' },
	prot_ports_placeholder: { ru: '80,443', en: '80,443' },
	prot_ports_save: { ru: 'Сохранить порты', en: 'Save ports' },
	prot_dns_title: { ru: 'Защита от утечек DNS', en: 'DNS leak protection' },
	prot_dns_intro: { ru: 'Принудительно заворачивает все DNS-запросы (порт 53) с LAN на этот роутер, даже если устройство прописано на сторонний DNS (8.8.8.8 и т.п.). Без этого запросы могут уходить напрямую мимо VPN и раскрывать, какие сайты вы посещаете, а kill-switch не увидит домены для блокировки.',
	              en: "Forces every LAN DNS query (port 53) through this router, even if a device is hardcoded to a third-party DNS (8.8.8.8, etc). Without this, queries can leave directly, bypassing the VPN and revealing which sites you visit — and the kill-switch never sees the domains to block." },
	prot_ipv6_title: { ru: 'Защита от утечек IPv6', en: 'IPv6 leak protection' },
	prot_ipv6_intro: { ru: 'Наш перехват работает только для IPv4 — сайт, доступный по IPv6, может открыться напрямую через провайдера в обход VPN и всех правил/kill-switch. Эта опция полностью блокирует LAN→WAN IPv6-трафик, чтобы такие соединения падали и уходили через IPv4 (уже защищённый) вместо утечки.',
	               en: "Our redirect is IPv4-only — a site reachable over IPv6 could load directly through your ISP, bypassing the VPN and every rule/kill-switch. This option blocks all LAN→WAN IPv6 traffic outright, so those connections fail closed and fall back to IPv4 (which is covered) instead of leaking." },
	prot_saving: { ru: 'Сохраняю…', en: 'Saving…' },
	prot_saved_ok: { ru: 'Применено', en: 'Applied' },
	prot_save_failed: { ru: 'Не удалось применить', en: 'Failed to apply' },

	lang_switch: { ru: 'EN', en: 'RU' }
};

function srLang() {
	return localStorage.getItem('xkeen-smartroute-lang') || 'ru';
}

function srSetLang(l) {
	localStorage.setItem('xkeen-smartroute-lang', l);
	window.location.reload();
}

function T(key) {
	var lang = srLang();
	var e = DICT[key];
	if (!e) return key;
	return e[lang] || e.ru || key;
}

function srLangSwitchButton() {
	return E('button', {
		'class': 'cbi-button',
		'style': 'float:right;margin-bottom:1em',
		'click': ui.createHandlerFn(this, function () {
			srSetLang(srLang() === 'ru' ? 'en' : 'ru');
		})
	}, T('lang_switch'));
}

// Keep in sync with client_preset() in lib/subscription.sh. Only the key is
// sent to the backend, which owns the actual UA/OS/locale/model/ver default
// values for each — the five text fields in the UI are pure overrides.
var CLIENT_PRESETS = [
	{ key: 'smartroute', label: 'XKeen SmartRoute' },
	{ key: 'happ', label: 'Happ' },
	{ key: 'happ-android', label: 'Happ (Android)' },
	{ key: 'v2rayng', label: 'v2rayNG' },
	{ key: 'v2ray', label: 'v2ray (core)' },
	{ key: 'v2box', label: 'V2Box' },
	{ key: 'clash', label: 'Clash' },
	{ key: 'clash-meta', label: 'Clash Meta' },
	{ key: 'mihomo', label: 'Mihomo' },
	{ key: 'sing-box', label: 'sing-box' },
	{ key: 'nekobox', label: 'NekoBox' },
	{ key: 'shadowrocket', label: 'Shadowrocket' },
	{ key: 'stash', label: 'Stash' },
	{ key: 'surge', label: 'Surge' },
	{ key: 'loon', label: 'Loon' },
	{ key: 'flclash', label: 'FlClash' },
	{ key: 'incy', label: 'Incy' }
];

var DEVICE_OS_OPTIONS = ['XKeen SmartRoute', 'iOS', 'Android', 'Windows', 'macOS', 'Linux'];

var DEVICE_MODEL_OPTIONS = [
	'iPhone 15 Pro', 'iPhone16,1', 'iPhone 14', 'Pixel 8', 'Pixel 9 Pro',
	'Samsung Galaxy S24', 'ELP-NX1', 'PC', 'MacBook Pro 16'
];

var DEVICE_VER_OPTIONS = ['17.5', '17.0', '16.6', '15', '14', '10', '11', '13.0'];

return L.Class.extend({
	rpc: {
		listServers: callListServers,
		importSubscription: callImportSubscription,
		listCategories: callListCategories,
		listCustomCategories: callListCustomCategories,
		listProfiles: callListProfiles,
		saveProfile: callSaveProfile,
		deleteProfile: callDeleteProfile,
		addCustomDomain: callAddCustomDomain,
		getStatus: callGetStatus,
		killswitchSet: callKillswitchSet,
		randomHwid: callRandomHwid,
		pingServers: callPingServers,
		getRefreshHours: callGetRefreshHours,
		setRefreshHours: callSetRefreshHours,
		refreshNow: callRefreshNow,
		listKillswitchEnabled: callListKillswitchEnabled,
		redirectStatus: callRedirectStatus,
		redirectSetEnabled: callRedirectSetEnabled,
		redirectSetPorts: callRedirectSetPorts,
		redirectSetDnsProtect: callRedirectSetDnsProtect,
		redirectSetIpv6Protect: callRedirectSetIpv6Protect,
		listLanDevices: callListLanDevices
	},
	T: T,
	lang: srLang,
	setLang: srSetLang,
	langSwitchButton: srLangSwitchButton,
	CLIENT_PRESETS: CLIENT_PRESETS,
	DEVICE_OS_OPTIONS: DEVICE_OS_OPTIONS,
	DEVICE_MODEL_OPTIONS: DEVICE_MODEL_OPTIONS,
	DEVICE_VER_OPTIONS: DEVICE_VER_OPTIONS
});
