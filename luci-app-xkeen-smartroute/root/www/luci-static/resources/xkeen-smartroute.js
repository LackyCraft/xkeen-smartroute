'use strict';
'require rpc';
'require ui';

// Shared helpers for all xkeen-smartroute views: ubus RPC declarations and a
// tiny hand-rolled RU/EN dictionary. LuCI's real gettext (.po -> .lmo) needs
// the LuCI build SDK to compile, which a hand-copied app (no opkg build step)
// doesn't have — so instead of a half-working single-language app, this file
// keeps its own dictionary and a language switch stored in localStorage.
// Every user-facing string in the four views is looked up through T(key).

var callListServers = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_servers'
});
var callImportSubscription = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'import_subscription',
	params: ['url', 'label', 'client', 'os', 'locale', 'model', 'ver', 'hwid']
});
var callRandomHwid = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'random_hwid'
});
var callListCategories = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_categories'
});
var callListCustomCategories = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_custom_categories'
});
var callListProfiles = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_profiles'
});
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

var DICT = {
	app_name:            { ru: 'XKeen SmartRoute DanyByLC', en: 'XKeen SmartRoute DanyByLC' },
	nav_subscriptions:   { ru: 'Подписки', en: 'Subscriptions' },
	nav_profiles:        { ru: 'Профили маршрутизации', en: 'Routing profiles' },
	nav_status:          { ru: 'Статус', en: 'Status' },
	nav_killswitch:      { ru: 'Kill-Switch', en: 'Kill-Switch' },

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
	no_servers: { ru: 'Пока нет ни одного сервера — импортируйте подписку выше.', en: 'No servers yet — import a subscription above.' },

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
	servers_known: { ru: 'серверов известно', en: 'servers known' },
	profiles_configured: { ru: 'профилей настроено', en: 'profiles configured' },
	refresh_btn: { ru: 'Обновить', en: 'Refresh' },

	ks_intro: { ru: 'Для профилей на «наших» списках (custom) можно включить жёсткий kill-switch: если процесс xray упадёт, домены этого профиля будут заблокированы файрволом полностью — вместо риска уйти в интернет напрямую в обход VPN. Для geosite-профилей защита работает и так: без xray редирект в прокси просто обрывает соединение.',
	           en: "For profiles built on our custom lists you can turn on a hard kill-switch: if the xray process dies, that profile's domains get fully blocked by the firewall instead of risking a direct route around the VPN. geosite-based profiles are already protected the soft way: with xray down, the proxy redirect just fails the connection." },
	ks_enabled: { ru: 'Включено', en: 'Enabled' },
	ks_disabled: { ru: 'Выключено', en: 'Disabled' },
	ks_custom_only: { ru: '(доступно только для custom-профилей)', en: '(available for custom profiles only)' },

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
		randomHwid: callRandomHwid
	},
	T: T,
	lang: srLang,
	setLang: srSetLang,
	langSwitchButton: srLangSwitchButton,
	CLIENT_PRESETS: CLIENT_PRESETS,
	DEVICE_OS_OPTIONS: DEVICE_OS_OPTIONS
});
