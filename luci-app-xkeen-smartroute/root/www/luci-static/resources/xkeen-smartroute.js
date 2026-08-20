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
var _callListCustomLists = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_custom_lists'
});
function callListCustomLists() {
	return _callListCustomLists().then(function (r) { return (r && r.lists) || []; });
}
var callDeleteCustomList = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'delete_custom_list',
	params: ['key']
});
var callAddDomainToList = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'add_domain_to_list',
	params: ['key', 'domain']
});
var callRemoveDomainFromList = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'remove_domain_from_list',
	params: ['key', 'domain']
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
var _callGetPings = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_pings'
});
function callGetPings() {
	return _callGetPings().then(function (r) { return (r && r.pings) || {}; });
}
var _callGetHealth = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_health'
});
// health: {tag: {alive: bool, delay_ms: num, last_error: str}}, from
// smartroute-gateway's failover.go -- a real VLESS/REALITY connection +
// HTTP GET through each outbound (Xray's observatory), not a bare TCP
// connect like the ping data above. A tag absent from this map hasn't been
// reached by observatory's probe sweep yet (still sparse for a while after
// every Xray restart -- see AGENTS.md), not confirmed either way.
function callGetHealth() {
	return _callGetHealth().then(function (r) { return (r && r.health) || {}; });
}
var _callGetCurrent = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_current'
});
// current: {profile_name: outbound_tag}, the tag lib/genroute.sh's
// sr_pick_top1 actually picked for a balancer-mode profile on its last
// regen -- lets the UI show a real server name instead of just "N servers".
function callGetCurrent() {
	return _callGetCurrent().then(function (r) { return (r && r.current) || {}; });
}
var _callGetActivity = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_activity'
});
// active: [outbound_tag, ...] that have carried traffic in the last few
// seconds, straight from smartroute-gateway's in-memory tracker (never
// written to disk -- see gateway/activity.go). Meant to be polled often
// (every few seconds) while the Profiles page is open, for a live "this
// profile is passing traffic right now" dot.
function callGetActivity() {
	return _callGetActivity().then(function (r) { return (r && r.active) || []; });
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
var _callGetObservatoryPeriod = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_observatory_period'
});
function callGetObservatoryPeriod() {
	return _callGetObservatoryPeriod().then(function (r) { return (r && r.minutes) || 20; });
}
var callSetObservatoryPeriod = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'set_observatory_period',
	params: ['minutes']
});
var callGetDoublevpnConfig = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_doublevpn_config'
});
var callSetDoublevpnEnabled = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'set_doublevpn_enabled',
	params: ['enabled']
});
var callSetDoublevpnServers = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'set_doublevpn_servers',
	params: ['servers']
});
var _callGetAutoRefreshEnabled = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_auto_refresh_enabled'
});
function callGetAutoRefreshEnabled() {
	return _callGetAutoRefreshEnabled().then(function (r) { return !r || r.enabled !== false; });
}
var callSetAutoRefreshEnabled = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'set_auto_refresh_enabled',
	params: ['enabled']
});
var callGetHealthMetrics = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'get_health_metrics'
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
var callRedirectSetQuicProtect = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'redirect_set_quic_protect',
	params: ['enabled']
});
var _callListLanDevices = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_lan_devices'
});
function callListLanDevices() {
	return _callListLanDevices().then(function (r) { return (r && r.devices) || []; });
}
var _callListSubscriptions = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'list_subscriptions'
});
function callListSubscriptions() {
	return _callListSubscriptions().then(function (r) { return (r && r.subscriptions) || []; });
}
var callDeleteSubscription = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'delete_subscription',
	params: ['label']
});
var callRefreshSubscription = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'refresh_subscription',
	params: ['label']
});
var callPingSubscription = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'ping_subscription',
	params: ['label']
});
var callServiceStatus = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'service_status'
});
var callServiceControl = rpc.declare({
	object: 'luci.xkeen-smartroute', method: 'service_control',
	params: ['service', 'action']
});

var DICT = {
	app_name:            { ru: 'XKeen SmartRoute DanyByLC', en: 'XKeen SmartRoute DanyByLC' },
	nav_subscriptions:   { ru: 'Подписки', en: 'Subscriptions' },
	nav_profiles:        { ru: 'Профили маршрутизации', en: 'Routing profiles' },
	nav_status:          { ru: 'Статус', en: 'Status' },
	nav_killswitch:      { ru: 'Kill-Switch', en: 'Kill-Switch' },
	nav_protection:      { ru: 'Защита от утечек', en: 'Leak protection' },
	nav_doublevpn:       { ru: 'Double VPN', en: 'Double VPN' },

	dv_intro: { ru: 'Провайдер часто блокирует отдельные сервера напрямую, но почти всегда хотя бы один остаётся доступен. Double VPN добавляет ещё один хоп перед всем остальным трафиком (и обычным, и собственными проверками живости): весь трафик сначала идёт через один выбранный «шлюз» из группы серверов ниже, и только потом — на его настоящий адрес. Самый быстрый живой шлюз выбирается автоматически (пинг + Observatory), точно так же, как сервер для профиля-группы.',
	          en: "An ISP often blocks individual servers directly, but almost always leaves at least one reachable. Double VPN adds one more hop in front of everything else (both real traffic and our own liveness checks): everything is relayed through one chosen \"gateway\" from the group below first, then on to its real address. The fastest alive gateway is picked automatically (ping + Observatory), the same way a group-mode profile picks its own server." },
	dv_enabled_label: { ru: 'Double VPN включён', en: 'Double VPN enabled' },
	dv_pool_label: { ru: 'Группа серверов-шлюзов', en: 'Gateway server pool' },
	dv_pool_intro: { ru: 'Выберите сервера, из которых будет автоматически выбираться самый быстрый живой шлюз. Сами эти сервера никогда не заворачиваются друг через друга — только через них идёт весь остальной трафик.',
	                 en: "Pick the servers to automatically choose the fastest alive gateway from. These servers themselves are never relayed through each other -- only everything else is relayed through them." },
	dv_save_btn: { ru: 'Сохранить группу', en: 'Save pool' },
	dv_saved_ok: { ru: 'Сохранено, применится при следующей перегенерации маршрутов (до 3 минут)', en: 'Saved, will apply on the next routing regen (up to 3 minutes)' },
	dv_toggle_saved_ok: { ru: 'Применено', en: 'Applied' },
	dv_need_pool_warning: { ru: 'Включено, но группа пуста — добавьте хотя бы один сервер ниже.', en: 'Enabled, but the pool is empty -- pick at least one server below.' },
	dv_pool_members_title: { ru: 'Сейчас участвуют в Double VPN', en: 'Currently in the Double VPN pool' },
	dv_pool_members_empty: { ru: 'Группа пуста.', en: 'The pool is empty.' },
	dv_gateway_badge: { ru: 'текущий шлюз', en: 'current gateway' },

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
	col_health: { ru: 'Observatory', en: 'Observatory' },
	health_alive: { ru: 'жив', en: 'alive' },
	health_dead: { ru: 'мёртв', en: 'dead' },
	health_unknown: { ru: 'ещё не проверен', en: 'not checked yet' },
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
	observatory_period_title: { ru: 'Период проверки живости серверов (Observatory)', en: 'Server liveness check period (Observatory)' },
	observatory_period_label: { ru: 'Перепроверять сервер не чаще чем раз в (минут)', en: 'Recheck a server no more often than every (minutes)' },
	observatory_period_intro: { ru: 'Xray сам проверяет, жив ли каждый сервер (реальное подключение + запрос, не просто пинг) — этот период задаёт, насколько свежие данные нужны. Сервера, задействованные в текущих профилях, проверяются в первую очередь, остальная часть подписки — во вторую, без остановки одного обхода на середине.',
	                        en: "Xray itself checks whether each server is actually alive (a real connection + request, not just a ping) — this period sets how fresh that data needs to be. Servers used by your current profiles are rechecked first, the rest of the subscription second, without ever restarting a sweep partway through." },
	observatory_period_saved_ok: { ru: 'Период сохранён', en: 'Period saved' },
	sub_add_title: { ru: 'Добавить подписку', en: 'Add a subscription' },
	sub_subscriptions_title: { ru: 'Ваши подписки', en: 'Your subscriptions' },
	sub_servers_word: { ru: 'серверов', en: 'servers' },
	sub_ping_all_btn: { ru: 'Проверить пинг всех', en: 'Ping all' },
	sub_ping_started: { ru: 'Проверка пинга запущена в фоне (по очереди, может занять время)', en: 'Ping check started in the background (one at a time, may take a while)' },
	sub_no_subscriptions: { ru: 'Подписок пока нет — добавьте выше.', en: 'No subscriptions yet — add one above.' },
	sub_delete_confirm: { ru: 'Удалить подписку «%s» и все её сервера?', en: 'Delete subscription "%s" and all its servers?' },
	sub_refreshing_one: { ru: 'Обновляю…', en: 'Refreshing…' },

	add_profile_title: { ru: 'Добавить профиль', en: 'Add a profile' },
	profiles_intro: { ru: 'Профиль — это правило: «эти домены → на эти сервера». Можно направить список на один конкретный сервер (fixed) или на группу — тогда SmartRoute сам будет постоянно выбирать самый быстрый живой сервер из группы (по пингу и собственному Observatory, не встроенный leastPing Xray — см. README).',
	                   en: 'A profile is a rule: "these domains → these servers". Point a list at one specific server (fixed), or at a group — SmartRoute will then continuously pick the fastest healthy server from the group itself (by ping + its own Observatory data, not Xray\'s built-in leastPing — see README).' },
	profile_name: { ru: 'Название профиля', en: 'Profile name' },
	activity_online: { ru: 'Сейчас активен — идёт трафик', en: 'Active now — traffic is flowing' },
	activity_idle: { ru: 'Нет трафика прямо сейчас', en: 'No traffic right now' },
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
	edit_btn: { ru: 'Изменить', en: 'Edit' },
	edit_loaded_note: { ru: 'Профиль загружен в форму выше — измените и сохраните', en: 'Profile loaded into the form above — change it and save' },
	domains_manage_title: { ru: 'Управление списками доменов', en: 'Domain list management' },
	domains_manage_intro: { ru: 'Ваши собственные списки доменов (не путать со списками из geosite Xray). Можно посмотреть, что в них, добавить или убрать отдельный домен, или удалить список целиком.',
	                         en: "Your own domain lists (not the built-in Xray geosite categories). View what's in them, add or remove a single domain, or delete the whole list." },
	domains_no_lists: { ru: 'Собственных списков пока нет — добавьте выше.', en: 'No custom lists yet — add one above.' },
	domains_add_domain_placeholder: { ru: 'example.com', en: 'example.com' },
	domains_delete_list_confirm: { ru: 'Удалить список «%s» целиком?', en: 'Delete list "%s" entirely?' },
	domains_list_already_exists: { ru: 'Список с таким именем уже есть — добавьте домен в него ниже вместо создания нового.', en: "A list with that name already exists — add the domain to it below instead of creating a new one." },
	domains_sanitized_note: { ru: 'Сохранён только домен (без адреса страницы): ', en: 'Only the domain was saved (page address stripped): ' },
	existing_profiles: { ru: 'Существующие профили', en: 'Existing profiles' },
	no_profiles: { ru: 'Профилей ещё нет.', en: 'No profiles yet.' },
	col_domains: { ru: 'Домены', en: 'Domains' },
	col_target: { ru: 'Куда', en: 'Target' },
	need_servers_first: { ru: 'Сначала импортируйте подписку на вкладке «Подписки».', en: 'Import a subscription on the Subscriptions tab first.' },

	devices_title: { ru: 'Устройства (необязательно)', en: 'Devices (optional)' },
	devices_intro: { ru: 'Ограничьте профиль конкретными устройствами — например, «только телевизор» вместо всей сети. Можно оставить пустым (профиль сработает для всех устройств) или сочетать со списком доменов выше — например, «только телевизор, только для YouTube».',
	                 en: "Restrict this profile to specific devices — e.g. \"only the TV\" instead of the whole network. Leave empty for all devices, or combine with the domain list above — e.g. \"only the TV, only for YouTube\"." },
	devices_none_selected: { ru: 'Устройства не выбраны — сработает для всего трафика, попадающего под список доменов выше.', en: 'No devices selected — applies to all traffic matching the domain list above.' },
	devices_no_domain_warning: { ru: 'Ни домены, ни устройства, ни IP-диапазоны не выбраны — профиль ничего не будет матчить.', en: 'No domains, devices, or IP ranges are selected — this profile would match nothing.' },
	devices_manual_label: { ru: 'Добавить вручную (IP или CIDR)', en: 'Add manually (IP or CIDR)' },
	devices_manual_placeholder: { ru: '192.168.1.50 или 192.168.1.0/24', en: '192.168.1.50 or 192.168.1.0/24' },
	devices_manual_add: { ru: 'Добавить', en: 'Add' },

	ip_ranges_title: { ru: 'IP-диапазоны (необязательно)', en: 'IP ranges (optional)' },
	ip_ranges_intro: { ru: 'Некоторые приложения не используют домены для основного трафика — например, Telegram на телефоне/десктопе соединяется по MTProto напрямую по IP дата-центров, без SNI/Host, поэтому geosite:telegram (список доменов) их не ловит — только веб-версию. Впишите сюда известные IP-диапазоны такого сервиса (по одному на строку или через запятую) — они добавят отдельное правило маршрутизации в дополнение к списку доменов выше.',
	                  en: "Some apps don't route their core traffic by domain at all — e.g. Telegram's phone/desktop apps talk MTProto straight to datacenter IPs with no SNI/Host, so geosite:telegram (a domain list) only ever catches the web version. Paste that service's known IP ranges here (one per line or comma-separated) — they add a separate routing rule alongside the domain list above." },
	ip_ranges_placeholder: { ru: '91.108.56.0/22\n149.154.160.0/20\n...', en: '91.108.56.0/22\n149.154.160.0/20\n...' },
	ip_ranges_invalid: { ru: 'Некорректный IP/CIDR', en: 'Invalid IP/CIDR' },
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

	status_services_title: { ru: 'Сервисы', en: 'Services' },
	status_service_xray: { ru: 'Xray', en: 'Xray' },
	status_service_gateway: { ru: 'Панель SmartRoute (gateway)', en: 'SmartRoute panel (gateway)' },
	status_service_xkeenui: { ru: 'xkeen-UI', en: 'xkeen-UI' },
	status_svc_running: { ru: 'работает', en: 'running' },
	status_svc_stopped: { ru: 'остановлен', en: 'stopped' },
	status_action_start: { ru: 'Старт', en: 'Start' },
	status_action_stop: { ru: 'Стоп', en: 'Stop' },
	status_action_restart: { ru: 'Рестарт', en: 'Restart' },
	status_action_failed: { ru: 'Не удалось', en: 'Failed' },
	status_links_title: { ru: 'Ссылки', en: 'Links' },
	status_link_xkeenui: { ru: 'Открыть xkeen-UI (порт 1000)', en: 'Open xkeen-UI (port 1000)' },
	status_link_panel: { ru: 'Открыть панель SmartRoute (порт 1001)', en: 'Open SmartRoute panel (port 1001)' },
	status_overview_title: { ru: 'Обзор', en: 'Overview' },
	status_subscriptions_col_label: { ru: 'Подписка', en: 'Subscription' },
	status_subscriptions_col_servers: { ru: 'Серверов', en: 'Servers' },
	status_subscriptions_none: { ru: 'Подписок пока нет — добавьте на вкладке «Подписки».', en: 'No subscriptions yet — add one on the Subscriptions tab.' },
	status_traffic_title: { ru: 'Трафик (реальное время)', en: 'Traffic (live)' },
	status_traffic_up: { ru: 'Отдача', en: 'Upload' },
	status_traffic_down: { ru: 'Приём', en: 'Download' },
	status_traffic_disconnected: { ru: 'нет соединения с панелью (порт 1001)', en: 'not connected to the panel (port 1001)' },
	status_metrics_title: { ru: 'Здоровье серверов и Observatory', en: 'Server health and Observatory' },
	status_metrics_alive: { ru: 'Живых серверов', en: 'Alive servers' },
	status_metrics_dead: { ru: 'Мёртвых серверов', en: 'Dead servers' },
	status_metrics_unknown: { ru: 'Ещё не проверено', en: 'Not checked yet' },
	status_metrics_last_refresh: { ru: 'Последнее обновление подписки', en: 'Last subscription refresh' },
	status_metrics_last_ping: { ru: 'Последний пересчёт пинга', en: 'Last ping sweep' },
	status_metrics_last_observatory: { ru: 'Последняя проверка Observatory', en: 'Last Observatory check' },
	status_metrics_queue: { ru: 'В очереди на проверку Observatory', en: 'Queued for Observatory check' },
	status_metrics_never: { ru: 'ещё ни разу', en: 'never yet' },

	auto_refresh_toggle_label: { ru: 'Автообновление подписок', en: 'Subscription auto-refresh' },
	auto_refresh_warning: { ru: '⚠️ Если состав подписки изменится, серверы профилей сверяются автоматически (тот же узел под новым адресом/параметрами — переносится), но если провайдер реально удалит сервер — он пропадёт и из профиля, где был выбран.',
	                       en: "⚠️ If the subscription's server list changes, profile selections are reconciled automatically (the same node under a new address/params carries over) — but if the provider genuinely removes a server, it disappears from any profile that had it selected too." },
	profile_removed_servers_label: { ru: 'пропали при обновлении подписки', en: 'removed by a subscription refresh' },

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
	prot_quic_title: { ru: 'Защита от утечек через QUIC/HTTP3', en: 'QUIC/HTTP3 leak protection' },
	prot_quic_intro: { ru: 'Наш перехват ловит только TCP-трафик. Сайты, объявляющие поддержку HTTP/3 (заголовок Alt-Svc: h3), браузер может открыть по QUIC — это тот же порт 443, но по UDP, и он проходит мимо перехвата целиком, в обход VPN и правил. Подтверждено на практике. Эта опция блокирует исходящий UDP на перехватываемых портах с LAN — браузеры при этом просто откатываются на обычный TCP/TLS, без потери функциональности.',
	                en: "Our redirect only catches TCP traffic. A site that advertises HTTP/3 support (Alt-Svc: h3 header) may get requested over QUIC — the same port 443, but over UDP — which bypasses the redirect entirely, VPN and rules included. Confirmed in practice. This option blocks outbound UDP on the captured ports from the LAN; browsers just fall back to plain TCP/TLS cleanly, no functionality lost." },
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

// Flag emoji (pairs of Unicode Regional Indicator Symbols, U+1F1E6-U+1F1FF)
// don't render as actual flags in several real environments -- Windows in
// particular has never rendered a regional-indicator pair as a flag glyph
// (shows the two letters in a box instead, by Microsoft's own long-standing
// design choice), unlike macOS/iOS/Android. Server names pulled straight
// from a subscription often lead with one ("🇩🇪 Германия 3"). Rather than
// dropping the flag, swap it for an actual image -- the same approach
// Discord/Slack/X use (Twemoji), served from jsDelivr's mirror of
// jdecked/twemoji (the actively maintained continuation of Twitter's
// original, now-archived project). No local asset bundling, but it does mean
// the flag image needs the *browser's* own internet access to load -- not
// the router's; if that fails (offline admin machine, CDN unreachable), the
// onerror handler below just falls back to the plain emoji character.
var TWEMOJI_SVG_BASE = 'https://cdn.jsdelivr.net/gh/jdecked/twemoji@latest/assets/svg/';

function srFindFlag(s) {
	try {
		var m = /\p{Regional_Indicator}{2}/u.exec(s);
	} catch (e) {
		m = /[\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF]/.exec(s);
	}
	if (!m) return null;
	var pair = m[0];
	var codepoints = [];
	for (var i = 0; i < pair.length;) {
		var cp = pair.codePointAt(i);
		codepoints.push(cp.toString(16));
		i += (cp > 0xFFFF ? 2 : 1);
	}
	return { codepoints: codepoints.join('-'), index: m.index, length: pair.length };
}

// srRenderName(name) -> DOM node. The one (if any) flag-emoji pair found
// anywhere in the string is replaced with a small <img>; everything else
// (including any other, non-flag emoji, which render fine as-is) passes
// through untouched. Safe to pass into E(...) as a child directly.
function srRenderName(name) {
	if (!name) return document.createTextNode('');
	var flag = srFindFlag(name);
	if (!flag) return document.createTextNode(name);
	var before = name.slice(0, flag.index);
	var glyph = name.slice(flag.index, flag.index + flag.length);
	var after = name.slice(flag.index + flag.length);
	var img = E('img', {
		'src': TWEMOJI_SVG_BASE + flag.codepoints + '.svg',
		'alt': glyph,
		'style': 'height:1em;width:1.33em;vertical-align:-0.15em;margin:0 .15em 0 0'
	});
	img.addEventListener('error', function () {
		img.replaceWith(document.createTextNode(glyph));
	});
	return E('span', {}, [document.createTextNode(before), img, document.createTextNode(after)]);
}

// srSpinner() -> a small inline spinning indicator, CSS-only (no external
// asset). Injects its @keyframes once per page. Used anywhere a background
// operation (ping/refresh, in particular) is in flight and the on-disk data
// it'll eventually update hasn't changed yet -- showing the last cached
// value during that window reads as a wrong/final result, not as "still
// working", so callers should swap it in instead of the stale value.
var _srSpinnerStyleInjected = false;
function srSpinner() {
	if (!_srSpinnerStyleInjected) {
		document.head.appendChild(E('style', {}, '@keyframes sr-spin{to{transform:rotate(360deg)}}'));
		_srSpinnerStyleInjected = true;
	}
	return E('span', {
		'style': 'display:inline-block;width:.9em;height:.9em;border:2px solid var(--border-color-medium,#ccc);' +
			'border-top-color:var(--color-primary,#2f7dd0);border-radius:50%;animation:sr-spin .7s linear infinite;' +
			'vertical-align:-0.15em'
	});
}

// srSanitizeDomain: mirrors sanitize_domain() in the rpcd backend exactly
// (strip URL scheme, path/query/fragment, trailing :port, lowercase) --
// pasting a full URL you just had open in a browser tab is the obvious
// thing to try in a "domain" field, and the backend already saves the
// sanitized form regardless, so showing the *un*-sanitized text back after
// save would just be confusing. Doing it client-side too means the user
// sees exactly what's going to be saved before they click anything.
function srSanitizeDomain(s) {
	if (!s) return s;
	return s
		.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '')
		.replace(/[/?#].*$/, '')
		.replace(/:\d+$/, '')
		.toLowerCase();
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
		listCustomLists: callListCustomLists,
		deleteCustomList: callDeleteCustomList,
		addDomainToList: callAddDomainToList,
		removeDomainFromList: callRemoveDomainFromList,
		getStatus: callGetStatus,
		killswitchSet: callKillswitchSet,
		randomHwid: callRandomHwid,
		pingServers: callPingServers,
		getPings: callGetPings,
		getHealth: callGetHealth,
		getCurrent: callGetCurrent,
		getActivity: callGetActivity,
		getRefreshHours: callGetRefreshHours,
		setRefreshHours: callSetRefreshHours,
		getObservatoryPeriod: callGetObservatoryPeriod,
		setObservatoryPeriod: callSetObservatoryPeriod,
		getDoublevpnConfig: callGetDoublevpnConfig,
		setDoublevpnEnabled: callSetDoublevpnEnabled,
		setDoublevpnServers: callSetDoublevpnServers,
		getAutoRefreshEnabled: callGetAutoRefreshEnabled,
		setAutoRefreshEnabled: callSetAutoRefreshEnabled,
		getHealthMetrics: callGetHealthMetrics,
		refreshNow: callRefreshNow,
		listKillswitchEnabled: callListKillswitchEnabled,
		redirectStatus: callRedirectStatus,
		redirectSetEnabled: callRedirectSetEnabled,
		redirectSetPorts: callRedirectSetPorts,
		redirectSetDnsProtect: callRedirectSetDnsProtect,
		redirectSetIpv6Protect: callRedirectSetIpv6Protect,
		redirectSetQuicProtect: callRedirectSetQuicProtect,
		listLanDevices: callListLanDevices,
		listSubscriptions: callListSubscriptions,
		deleteSubscription: callDeleteSubscription,
		refreshSubscription: callRefreshSubscription,
		pingSubscription: callPingSubscription,
		serviceStatus: callServiceStatus,
		serviceControl: callServiceControl
	},
	T: T,
	lang: srLang,
	setLang: srSetLang,
	langSwitchButton: srLangSwitchButton,
	renderName: srRenderName,
	spinner: srSpinner,
	sanitizeDomain: srSanitizeDomain,
	CLIENT_PRESETS: CLIENT_PRESETS,
	DEVICE_OS_OPTIONS: DEVICE_OS_OPTIONS,
	DEVICE_MODEL_OPTIONS: DEVICE_MODEL_OPTIONS,
	DEVICE_VER_OPTIONS: DEVICE_VER_OPTIONS
});
