'use strict';
/*
 * Shared core for the standalone SmartRoute panel: the RPC bridge to
 * lib/*.sh (via smartroute-gateway's POST /api/call/{method}, which execs
 * the exact same rpcd script LuCI's ubus backend calls -- one source of
 * truth for subscriptions/profiles/kill-switch/leak-protection, not a
 * second copy), the RU/EN dictionary (deliberately the same keys/strings as
 * luci-app-xkeen-smartroute/root/www/luci-static/resources/xkeen-smartroute.js
 * so the two UIs never say something different for the same concept), a
 * tiny DOM-builder (E), and the section router driving the sidebar.
 */

// --- tiny DOM builder, same shape as LuCI's own E() so tab modules ported
// from the LuCI views need minimal changes ---
function E(tag, attrs, children) {
	var el = document.createElement(tag);
	attrs = attrs || {};
	for (var k in attrs) {
		if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
		var v = attrs[k];
		if (v === null || v === undefined) continue;
		if (k === 'click' || k === 'change' || k === 'input' || k === 'submit') {
			el.addEventListener(k, v);
		} else if (k === 'checked') {
			if (v !== null) el.checked = true;
		} else {
			el.setAttribute(k, v);
		}
	}
	function appendChild(c) {
		if (c === null || c === undefined || c === '') return;
		if (Array.isArray(c)) { c.forEach(appendChild); return; }
		if (c instanceof Node) { el.appendChild(c); return; }
		el.appendChild(document.createTextNode(String(c)));
	}
	if (Array.isArray(children)) children.forEach(appendChild);
	else appendChild(children);
	return el;
}

// --- i18n ---

var DICT = {
	app_name: { ru: 'XKeen SmartRoute', en: 'XKeen SmartRoute' },
	app_by: { ru: 'DanyByLC', en: 'DanyByLC' },
	nav_home: { ru: 'Статус', en: 'Status' },
	nav_subscriptions: { ru: 'Подписки', en: 'Subscriptions' },
	nav_profiles: { ru: 'Профили', en: 'Profiles' },
	nav_doublevpn: { ru: 'Double VPN', en: 'Double VPN' },
	nav_domains: { ru: 'Домены', en: 'Domains' },
	nav_killswitch: { ru: 'Kill-Switch', en: 'Kill-Switch' },
	nav_protection: { ru: 'Защита от утечек', en: 'Leak protection' },
	add_profile_btn: { ru: '+ Добавить профиль', en: '+ Add profile' },
	modal_cancel: { ru: 'Отмена', en: 'Cancel' },
	domains_page_intro: { ru: 'Свои списки доменов — используются как источник доменов при создании профиля (вкладка «Профили»).',
		en: 'Your own domain lists -- used as a domain source when creating a profile (the Profiles tab).' },

	login_title: { ru: 'Вход', en: 'Sign in' },
	login_password_placeholder: { ru: 'Пароль', en: 'Password' },
	login_btn: { ru: 'Войти', en: 'Sign in' },
	login_error: { ru: 'Неверный пароль', en: 'Wrong password' },
	login_too_many: { ru: 'Слишком много попыток, подождите немного', en: 'Too many attempts, wait a bit' },
	logout_btn: { ru: 'Выйти', en: 'Log out' },
	settings_password_title: { ru: 'Пароль панели', en: 'Panel password' },
	settings_password_set_title: { ru: 'Задать пароль', en: 'Set a password' },
	settings_password_current: { ru: 'Текущий пароль', en: 'Current password' },
	settings_password_new: { ru: 'Новый пароль', en: 'New password' },
	settings_password_save: { ru: 'Сохранить', en: 'Save' },
	settings_password_saved: { ru: 'Пароль обновлён', en: 'Password updated' },
	settings_password_none: { ru: 'Пароль ещё не задан — панель открыта всем в сети', en: 'No password set yet — the panel is open to anyone on the network' },
	settings_password_too_short: { ru: 'Минимум 6 символов', en: 'At least 6 characters' },

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
	col_server: { ru: 'Сервер', en: 'Server' },
	col_address: { ru: 'Адрес', en: 'Address' },
	col_protocol: { ru: 'Протокол', en: 'Protocol' },
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
	refresh_now_started: { ru: 'Обновление запущено в фоне — для большой подписки может занять несколько минут', en: 'Refresh started in the background -- may take a few minutes for a large subscription' },
	sub_background_note: { ru: 'Выполняется в фоне — для большой подписки может занять несколько минут. Список обновится сам, когда закончится.', en: 'Running in the background -- may take a few minutes for a large subscription. The list will update itself once it finishes.' },
	refresh_saved_ok: { ru: 'Интервал сохранён', en: 'Interval saved' },
	observatory_period_title: { ru: 'Период проверки живости серверов (Observatory)', en: 'Server liveness check period (Observatory)' },
	observatory_period_label: { ru: 'Перепроверять сервер не чаще чем раз в (минут)', en: 'Recheck a server no more often than every (minutes)' },
	observatory_period_saved_ok: { ru: 'Период сохранён', en: 'Period saved' },
	sub_add_title: { ru: 'Добавить подписку', en: 'Add a subscription' },
	sub_subscriptions_title: { ru: 'Ваши подписки', en: 'Your subscriptions' },
	sub_servers_word: { ru: 'серверов', en: 'servers' },
	sub_ping_all_btn: { ru: 'Проверить пинг всех', en: 'Ping all' },
	sub_ping_started: { ru: 'Проверка пинга запущена в фоне — для большой подписки может занять несколько минут', en: 'Ping check started in the background -- may take a few minutes for a large subscription' },
	sub_no_subscriptions: { ru: 'Подписок пока нет — добавьте выше.', en: 'No subscriptions yet — add one above.' },
	sub_delete_confirm: { ru: 'Удалить подписку «%s» и все её сервера?', en: 'Delete subscription "%s" and all its servers?' },
	sub_refreshing_one: { ru: 'Обновляю…', en: 'Refreshing…' },
	refresh_btn: { ru: 'Обновить', en: 'Refresh' },
	delete_btn: { ru: 'Удалить', en: 'Delete' },
	edit_btn: { ru: 'Изменить', en: 'Edit' },
	add_btn: { ru: 'Добавить', en: 'Add' },
	saving: { ru: 'Сохраняю…', en: 'Saving…' },
	saved_ok: { ru: 'Сохранено, xray перезапущен', en: 'Saved, xray restarted' },
	save_failed: { ru: 'Не удалось сохранить профиль', en: 'Failed to save profile' },
	auto_refresh_toggle_label: { ru: 'Автообновление подписок', en: 'Subscription auto-refresh' },
	auto_refresh_warning: { ru: '⚠️ Если провайдер удалит сервер, он пропадёт и из профиля, где был выбран.',
		en: '⚠️ If the provider genuinely removes a server, it disappears from any profile that had it selected.' },
	profile_removed_servers_label: { ru: 'пропали при обновлении подписки', en: 'removed by a subscription refresh' },

	add_profile_title: { ru: 'Добавить профиль', en: 'Add a profile' },
	profiles_intro: { ru: 'Профиль — это правило: «эти домены → на эти сервера». Можно направить список на один конкретный сервер (fixed) или на группу — тогда SmartRoute сам будет постоянно выбирать самый быстрый живой сервер из группы.',
		en: 'A profile is a rule: "these domains → these servers". Point a list at one specific server (fixed), or at a group — SmartRoute continuously picks the fastest healthy server from the group itself.' },
	profile_name: { ru: 'Название профиля', en: 'Profile name' },
	profile_name_placeholder: { ru: 'например: youtube', en: 'e.g. youtube' },
	activity_online: { ru: 'Сейчас активен — идёт трафик', en: 'Active now — traffic is flowing' },
	activity_idle: { ru: 'Нет трафика прямо сейчас', en: 'No traffic right now' },
	domain_source: { ru: 'Список доменов', en: 'Domain list' },
	domain_source_geosite: { ru: 'Категория geosite (Xray)', en: 'geosite category (Xray)' },
	domain_source_custom: { ru: 'Наш список (custom)', en: 'Our list (custom)' },
	domain_source_any: { ru: 'Все домены (только по устройству)', en: 'All domains (device-only match)' },
	mode_label: { ru: 'Режим', en: 'Mode' },
	mode_fixed: { ru: 'Конкретный сервер', en: 'Fixed server' },
	mode_balancer: { ru: 'Группа — авто-выбор самого быстрого', en: 'Group — auto-pick fastest' },
	pick_server: { ru: 'Выберите сервер', en: 'Pick a server' },
	pick_servers: { ru: 'Выберите сервера для группы', en: 'Pick servers for the group' },
	save_profile_btn: { ru: 'Сохранить и применить', en: 'Save & apply' },
	need_servers_first: { ru: 'Сначала импортируйте подписку на вкладке «Подписки».', en: 'Import a subscription on the Subscriptions tab first.' },
	existing_profiles: { ru: 'Существующие профили', en: 'Existing profiles' },
	no_profiles: { ru: 'Профилей ещё нет.', en: 'No profiles yet.' },
	profile_delete_confirm: { ru: 'Удалить профиль «%s»?', en: 'Delete profile "%s"?' },
	col_domains: { ru: 'Домены', en: 'Domains' },
	col_target: { ru: 'Куда', en: 'Target' },

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

	devices_title: { ru: 'Устройства (необязательно)', en: 'Devices (optional)' },
	devices_intro: { ru: 'Ограничьте профиль конкретными устройствами — например, «только телевизор».',
		en: 'Restrict this profile to specific devices — e.g. "only the TV".' },
	devices_no_domain_warning: { ru: 'Ни домены, ни устройства, ни IP-диапазоны не выбраны — профиль ничего не будет матчить.', en: 'No domains, devices, or IP ranges are selected — this profile would match nothing.' },
	devices_manual_placeholder: { ru: '192.168.1.50 или 192.168.1.0/24', en: '192.168.1.50 or 192.168.1.0/24' },
	devices_manual_add: { ru: 'Добавить', en: 'Add' },
	devices_manual_invalid: { ru: 'Введите IPv4-адрес или CIDR, например 192.168.1.50 или 192.168.1.0/24', en: 'Enter an IPv4 address or CIDR, e.g. 192.168.1.50 or 192.168.1.0/24' },
	devices_none_detected: { ru: 'Устройства не найдены (проверьте DHCP-аренды роутера).', en: "No devices found (check the router's DHCP leases)." },

	ip_ranges_title: { ru: 'IP-диапазоны (необязательно)', en: 'IP ranges (optional)' },
	ip_ranges_intro: { ru: 'Для приложений вроде Telegram, чей основной трафик не резолвится по домену. IP/CIDR по одному на строку или через запятую — либо вставьте/загрузите список в формате .bat (Keenetic Routes, "route ADD сеть MASK маска шлюз"), распознаётся автоматически.',
		en: 'For apps like Telegram whose core traffic isn\'t routed by domain. One IP/CIDR per line or comma-separated -- or paste/load a Keenetic Routes .bat list ("route ADD network MASK mask gateway"), detected automatically.' },
	ip_ranges_placeholder: { ru: '91.108.56.0/22\n149.154.160.0/20\nroute ADD 147.75.208.0 MASK 255.255.240.0 172.16.0.2\n...', en: '91.108.56.0/22\n149.154.160.0/20\nroute ADD 147.75.208.0 MASK 255.255.240.0 172.16.0.2\n...' },
	ip_ranges_invalid: { ru: 'Некорректная строка/IP/CIDR', en: 'Invalid line/IP/CIDR' },
	ip_ranges_load_bat_btn: { ru: 'Загрузить .bat (Keenetic Routes)', en: 'Load .bat (Keenetic Routes)' },

	custom_domain_title: { ru: 'Добавить свой домен(ы)', en: 'Add your own domain(s)' },
	custom_domain_intro: { ru: 'Если нужного сайта нет ни в geosite, ни в готовых списках — впишите домены через запятую.',
		en: "If a site isn't in geosite or the bundled lists — type domains separated by commas." },
	custom_list_name_placeholder: { ru: 'например: my-site', en: 'e.g. my-site' },
	custom_domains_placeholder: { ru: 'example.com, cdn.example.com', en: 'example.com, cdn.example.com' },
	domains_manage_title: { ru: 'Управление списками доменов', en: 'Domain list management' },
	domains_no_lists: { ru: 'Собственных списков пока нет — добавьте выше.', en: 'No custom lists yet — add one above.' },
	domains_add_domain_placeholder: { ru: 'example.com', en: 'example.com' },
	domains_delete_list_confirm: { ru: 'Удалить список «%s» целиком?', en: 'Delete list "%s" entirely?' },
	domains_list_already_exists: { ru: 'Список с таким именем уже есть — добавьте домен в него ниже.', en: 'A list with that name already exists — add the domain to it below instead.' },
	domains_sanitized_note: { ru: 'Сохранён только домен (без адреса страницы): ', en: 'Only the domain was saved (page address stripped): ' },

	ks_intro: { ru: 'Жёсткий kill-switch: если процесс xray упадёт, домены профиля будут заблокированы файрволом полностью — вместо риска уйти в интернет напрямую в обход VPN. Правило включается сразу и постоянно, без зазора по времени. Для geosite-категорий покрытие неполное — учитываются только domain:/full: записи, keyword:/regexp: не переносятся.',
		en: "Hard kill-switch: if xray dies, the profile's domains get fully blocked by the firewall instead of risking a direct route around the VPN. Armed immediately and stays on, no time gap. geosite coverage is partial — only domain:/full: entries translate to a literal block." },
	ks_geosite_note: { ru: '(частичное покрытие для geosite)', en: '(partial coverage for geosite)' },

	prot_intro: { ru: 'Перехват LAN-трафика: без него ни один профиль/kill-switch не видит реальные пакеты устройств. Выключайте только для диагностики.',
		en: "LAN traffic capture: without it, no profile/kill-switch ever sees real device packets. Only turn it off for diagnostics." },
	prot_redirect_enabled: { ru: 'Перехват трафика включён', en: 'Traffic capture enabled' },
	prot_ports_label: { ru: 'Порты перехвата (через запятую)', en: 'Captured ports (comma-separated)' },
	prot_ports_placeholder: { ru: '80,443', en: '80,443' },
	prot_ports_save: { ru: 'Сохранить порты', en: 'Save ports' },
	prot_dns_title: { ru: 'Защита от утечек DNS', en: 'DNS leak protection' },
	prot_dns_intro: { ru: 'Принудительно заворачивает все DNS-запросы (порт 53) с LAN на этот роутер.',
		en: 'Forces every LAN DNS query (port 53) through this router.' },
	prot_ipv6_title: { ru: 'Защита от утечек IPv6', en: 'IPv6 leak protection' },
	prot_ipv6_intro: { ru: 'Блокирует весь LAN→WAN IPv6-трафик, чтобы такие соединения не утекали в обход VPN.',
		en: 'Blocks all LAN→WAN IPv6 traffic so those connections cannot leak around the VPN.' },
	prot_quic_title: { ru: 'Защита от утечек через QUIC/HTTP3', en: 'QUIC/HTTP3 leak protection' },
	prot_quic_intro: { ru: 'Блокирует исходящий UDP на перехватываемых портах — браузеры откатываются на обычный TCP/TLS.',
		en: 'Blocks outbound UDP on captured ports — browsers fall back to plain TCP/TLS.' },
	prot_saved_ok: { ru: 'Применено', en: 'Applied' },
	prot_save_failed: { ru: 'Не удалось применить', en: 'Failed to apply' },

	status_services_title: { ru: 'Сервисы', en: 'Services' },
	status_service_xray: { ru: 'Xray', en: 'Xray' },
	status_service_gateway: { ru: 'Панель SmartRoute', en: 'SmartRoute panel' },
	status_service_xkeenui: { ru: 'xkeen-UI', en: 'xkeen-UI' },
	status_svc_running: { ru: 'работает', en: 'running' },
	status_svc_stopped: { ru: 'остановлен', en: 'stopped' },
	status_action_start: { ru: 'Старт', en: 'Start' },
	status_action_stop: { ru: 'Стоп', en: 'Stop' },
	status_action_restart: { ru: 'Рестарт', en: 'Restart' },
	status_action_failed: { ru: 'Не удалось', en: 'Failed' },
	status_links_title: { ru: 'Ссылки', en: 'Links' },
	status_link_xkeenui: { ru: 'Открыть xkeen-UI (порт 1000)', en: 'Open xkeen-UI (port 1000)' },
	status_overview_title: { ru: 'Обзор', en: 'Overview' },
	status_subscriptions_col_label: { ru: 'Подписка', en: 'Subscription' },
	status_subscriptions_col_servers: { ru: 'Серверов', en: 'Servers' },
	status_subscriptions_none: { ru: 'Подписок пока нет.', en: 'No subscriptions yet.' },
	status_traffic_title: { ru: 'Трафик (реальное время)', en: 'Traffic (live)' },
	status_traffic_up: { ru: 'Отдача', en: 'Upload' },
	status_traffic_down: { ru: 'Приём', en: 'Download' },
	status_traffic_disconnected: { ru: 'нет соединения с панелью', en: 'not connected to the panel' },
	status_metrics_title: { ru: 'Здоровье серверов и Observatory', en: 'Server health and Observatory' },
	status_metrics_alive: { ru: 'Живых серверов', en: 'Alive servers' },
	status_metrics_dead: { ru: 'Мёртвых серверов', en: 'Dead servers' },
	status_metrics_unknown: { ru: 'Ещё не проверено', en: 'Not checked yet' },
	status_metrics_last_refresh: { ru: 'Последнее обновление подписки', en: 'Last subscription refresh' },
	status_metrics_last_ping: { ru: 'Последний пересчёт пинга', en: 'Last ping sweep' },
	status_metrics_last_observatory: { ru: 'Последняя проверка Observatory', en: 'Last Observatory check' },
	status_metrics_queue: { ru: 'В очереди на проверку Observatory', en: 'Queued for Observatory check' },
	status_metrics_never: { ru: 'ещё ни разу', en: 'never yet' },
	status_traffic_by_profile_title: { ru: 'Трафик по профилям', en: 'Traffic by profile' },
	status_active_profiles_title: { ru: 'Активные профили сейчас', en: 'Active profiles right now' },
	status_active_profiles_none: { ru: 'Ни один профиль не передаёт трафик прямо сейчас.', en: 'No profile is carrying traffic right now.' },
	status_servers_known: { ru: 'Серверов', en: 'Servers' },
	status_profiles_known: { ru: 'Профилей', en: 'Profiles' },

	logs_title: { ru: 'Логи Xray', en: 'Xray logs' },
	logs_note: { ru: 'Логи отображаются только здесь, в SmartRoute UI (не в LuCI) — реальные строки лога Xray, включаются по требованию.',
		en: 'Logs are only shown here, in the SmartRoute UI (not in LuCI) — real Xray log lines, enabled on demand.' },
	logs_enabled: { ru: 'Логи включены', en: 'Logging enabled' },
	logs_level: { ru: 'Уровень', en: 'Level' },
	logs_clear: { ru: 'Очистить', en: 'Clear' },
	logs_cap: { ru: 'Лимит размера (МБ)', en: 'Size cap (MB)' },
	logs_cap_save: { ru: 'Сохранить', en: 'Save' },
	logs_cap_free: { ru: 'свободно', en: 'free' },
	logs_cap_rejected: { ru: 'Слишком много — превышает половину свободной памяти', en: 'Too large — exceeds half of free memory' },
	logs_empty: { ru: 'Пока пусто — включите логи выше.', en: 'Empty so far — enable logging above.' },
	logs_tmpfs_note: { ru: 'Хранятся в ОЗУ (tmpfs), не на флеше — пропадают при перезагрузке, ограничены заданным лимитом.',
		en: 'Stored in RAM (tmpfs), not flash — cleared on reboot, bounded by the cap above.' },

	lang_switch: { ru: 'EN', en: 'RU' }
};

function srLang() { return localStorage.getItem('sr_gw_lang') || 'ru'; }
function srSetLang(l) { localStorage.setItem('sr_gw_lang', l); location.reload(); }
function T(key) {
	var e = DICT[key];
	if (!e) return key;
	return e[srLang()] || e.ru || key;
}

// --- RPC bridge: POST /api/call/{method} {args...} -> the exact JSON the
// rpcd script itself would have returned to LuCI ---
//
// A 401 here only ever means one thing -- requireAuth (gateway/auth.go)
// rejected the request because the session cookie is missing/expired/
// revoked; handleRPC itself never returns 401 for any other reason. Left
// unhandled, that response body ({"success":false,"error":"unauthorized"})
// used to flow straight into each api.* wrapper's own `.then(r => r.foo ||
// [])` below, which silently resolved to an empty list/object -- a session
// that died mid-visit (7-day TTL elapsed, a password change elsewhere,
// this process restarting and dropping in-memory sessions) rendered as
// "you have no servers/profiles/subscriptions" instead of "please log back
// in". Catch it here, once, and send the user to the login screen instead
// of letting every call site downstream have to guess why its data
// vanished.
function apiCall(method, args) {
	return fetch('/api/call/' + encodeURIComponent(method), {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify(args || {})
	}).then(function (r) {
		if (r.status === 401) {
			showLogin();
			return Promise.reject(new Error('unauthorized'));
		}
		return r.json();
	});
}

var api = {
	listServers: function () { return apiCall('list_servers').then(function (r) { return (r && r.servers) || []; }); },
	importSubscription: function (url, label, client, os, locale, model, ver, hwid) {
		return apiCall('import_subscription', { url: url, label: label, client: client, os: os, locale: locale, model: model, ver: ver, hwid: hwid })
			.then(function (r) { if (r && r.error) return r; return (r && r.servers) || []; });
	},
	randomHwid: function () { return apiCall('random_hwid'); },
	listCategories: function () { return apiCall('list_categories').then(function (r) { return (r && r.categories) || []; }); },
	listCustomCategories: function () { return apiCall('list_custom_categories').then(function (r) { return (r && r.categories) || []; }); },
	listProfiles: function () { return apiCall('list_profiles').then(function (r) { return (r && r.profiles) || []; }); },
	saveProfile: function (profileJson) { return apiCall('save_profile', { profile: profileJson }); },
	deleteProfile: function (name) { return apiCall('delete_profile', { name: name }); },
	addCustomDomain: function (listName, domains) { return apiCall('add_custom_domain', { list_name: listName, domains: domains }); },
	listCustomLists: function () { return apiCall('list_custom_lists').then(function (r) { return (r && r.lists) || []; }); },
	deleteCustomList: function (key) { return apiCall('delete_custom_list', { key: key }); },
	addDomainToList: function (key, domain) { return apiCall('add_domain_to_list', { key: key, domain: domain }); },
	removeDomainFromList: function (key, domain) { return apiCall('remove_domain_from_list', { key: key, domain: domain }); },
	getStatus: function () { return apiCall('get_status'); },
	killswitchSet: function (name, enabled) { return apiCall('killswitch_set', { name: name, enabled: enabled }); },
	listKillswitchEnabled: function () { return apiCall('list_killswitch_enabled').then(function (r) { return (r && r.names) || []; }); },
	pingServers: function () { return apiCall('ping_servers').then(function (r) { return (r && r.pings) || {}; }); },
	getPings: function () { return apiCall('get_pings').then(function (r) { return (r && r.pings) || {}; }); },
	getHealth: function () { return apiCall('get_health').then(function (r) { return (r && r.health) || {}; }); },
	getCurrent: function () { return apiCall('get_current').then(function (r) { return (r && r.current) || {}; }); },
	getActivity: function () { return apiCall('get_activity').then(function (r) { return (r && r.active) || []; }); },
	getRefreshHours: function () { return apiCall('get_refresh_hours').then(function (r) { return (r && r.hours) || 12; }); },
	setRefreshHours: function (hours) { return apiCall('set_refresh_hours', { hours: hours }); },
	getObservatoryPeriod: function () { return apiCall('get_observatory_period').then(function (r) { return (r && r.minutes) || 20; }); },
	setObservatoryPeriod: function (minutes) { return apiCall('set_observatory_period', { minutes: minutes }); },
	getDoublevpnConfig: function () { return apiCall('get_doublevpn_config'); },
	setDoublevpnEnabled: function (enabled) { return apiCall('set_doublevpn_enabled', { enabled: enabled }); },
	setDoublevpnServers: function (servers) { return apiCall('set_doublevpn_servers', { servers: servers }); },
	getAutoRefreshEnabled: function () { return apiCall('get_auto_refresh_enabled').then(function (r) { return !r || r.enabled !== false; }); },
	setAutoRefreshEnabled: function (enabled) { return apiCall('set_auto_refresh_enabled', { enabled: enabled }); },
	getHealthMetrics: function () { return apiCall('get_health_metrics'); },
	refreshNow: function () { return apiCall('refresh_now'); },
	redirectStatus: function () { return apiCall('redirect_status'); },
	redirectSetEnabled: function (enabled) { return apiCall('redirect_set_enabled', { enabled: enabled }); },
	redirectSetPorts: function (ports) { return apiCall('redirect_set_ports', { ports: ports }); },
	redirectSetDnsProtect: function (enabled) { return apiCall('redirect_set_dns_protect', { enabled: enabled }); },
	redirectSetIpv6Protect: function (enabled) { return apiCall('redirect_set_ipv6_protect', { enabled: enabled }); },
	redirectSetQuicProtect: function (enabled) { return apiCall('redirect_set_quic_protect', { enabled: enabled }); },
	listLanDevices: function () { return apiCall('list_lan_devices').then(function (r) { return (r && r.devices) || []; }); },
	listSubscriptions: function () { return apiCall('list_subscriptions').then(function (r) { return (r && r.subscriptions) || []; }); },
	deleteSubscription: function (label) { return apiCall('delete_subscription', { label: label }); },
	refreshSubscription: function (label) { return apiCall('refresh_subscription', { label: label }); },
	pingSubscription: function (label) { return apiCall('ping_subscription', { label: label }); },
	serviceStatus: function () { return apiCall('service_status'); },
	serviceControl: function (service, action) { return apiCall('service_control', { service: service, action: action }); },
	getLogConfig: function () { return apiCall('get_log_config'); },
	setLogEnabled: function (enabled) { return apiCall('set_log_enabled', { enabled: enabled }); },
	setLogLevel: function (level) { return apiCall('set_log_level', { level: level }); },
	setLogCapMb: function (mb) { return apiCall('set_log_cap_mb', { mb: mb }); },
	clearLogs: function () { return apiCall('clear_logs'); }
};

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
var DEVICE_MODEL_OPTIONS = ['iPhone 15 Pro', 'iPhone16,1', 'iPhone 14', 'Pixel 8', 'Pixel 9 Pro', 'Samsung Galaxy S24', 'ELP-NX1', 'PC', 'MacBook Pro 16'];
var DEVICE_VER_OPTIONS = ['17.5', '17.0', '16.6', '15', '14', '10', '11', '13.0'];

// --- flag-emoji rendering (Windows never renders regional-indicator pairs
// as flags -- swap for a Twemoji SVG, same fix as the LuCI app) ---
var TWEMOJI_SVG_BASE = 'https://cdn.jsdelivr.net/gh/jdecked/twemoji@latest/assets/svg/';
function findFlag(s) {
	var m;
	try { m = /\p{Regional_Indicator}{2}/u.exec(s); }
	catch (e) { m = /[\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF]/.exec(s); }
	if (!m) return null;
	var pair = m[0], codepoints = [];
	for (var i = 0; i < pair.length;) {
		var cp = pair.codePointAt(i);
		codepoints.push(cp.toString(16));
		i += (cp > 0xFFFF ? 2 : 1);
	}
	return { codepoints: codepoints.join('-'), index: m.index, length: pair.length };
}
function renderName(name) {
	if (!name) return document.createTextNode('');
	var flag = findFlag(name);
	if (!flag) return document.createTextNode(name);
	var before = name.slice(0, flag.index), glyph = name.slice(flag.index, flag.index + flag.length), after = name.slice(flag.index + flag.length);
	var img = E('img', { src: TWEMOJI_SVG_BASE + flag.codepoints + '.svg', alt: glyph, style: 'height:1em;width:1.33em;vertical-align:-0.15em;margin:0 .15em 0 0' });
	img.addEventListener('error', function () { img.replaceWith(document.createTextNode(glyph)); });
	return E('span', {}, [document.createTextNode(before), img, document.createTextNode(after)]);
}

function sanitizeDomain(s) {
	if (!s) return s;
	return s.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '').replace(/[/?#].*$/, '').replace(/:\d+$/, '').toLowerCase();
}

// --- ip_ranges parsing: plain CIDR/IP list, or Keenetic's exported static
// route .bat format ("route ADD <network> MASK <netmask> <gateway>", one
// per line -- the trailing gateway address is Keenetic's own VPN-policy
// artifact and is ignored, only network+mask matter) -- see
// docs/functionality_doc/routing-generation.md for the format and why.
var IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
var KEENETIC_ROUTE_RE = /^route\s+add\s+(\S+)\s+mask\s+(\S+)\s+\S+/i;

function ipv4ToInt(ip) {
	var m = IPV4_RE.exec(ip);
	if (!m) return null;
	var parts = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
	if (parts.some(function (n) { return n > 255; })) return null;
	return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

// maskToPrefixLength: dotted-decimal netmask -> CIDR prefix length, or null
// if it isn't a real netmask (must be a contiguous run of 1-bits followed
// by 0-bits -- "255.255.240.0" is valid, "255.255.0.240" is not).
function maskToPrefixLength(mask) {
	var n = ipv4ToInt(mask);
	if (n === null) return null;
	var bin = (n >>> 0).toString(2);
	while (bin.length < 32) bin = '0' + bin;
	if (!/^1*0*$/.test(bin)) return null;
	return (bin.match(/1/g) || []).length;
}

// parseKeeneticRouteLine: undefined = not a route line at all (caller
// should fall through to plain-token parsing), null = looked like a route
// line but network/mask is malformed, string = converted "network/prefix".
function parseKeeneticRouteLine(line) {
	var m = KEENETIC_ROUTE_RE.exec(line);
	if (!m) return undefined;
	var net = m[1], mask = m[2];
	if (ipv4ToInt(net) === null) return null;
	var prefix = maskToPrefixLength(mask);
	if (prefix === null) return null;
	return net + '/' + prefix;
}

// parseIpRanges: raw textarea text -> {entries: [CIDR/IP, ...], errors: [bad line/token, ...]}.
function parseIpRanges(raw) {
	var entries = [], errors = [];
	if (!raw) return { entries: entries, errors: errors };
	raw.split(/\r?\n/).forEach(function (line) {
		var trimmed = line.trim();
		if (!trimmed || trimmed.charAt(0) === '#') return;
		var routeResult = parseKeeneticRouteLine(trimmed);
		if (routeResult === null) { errors.push(trimmed); return; }
		if (routeResult !== undefined) { entries.push(routeResult); return; }
		trimmed.split(/[\s,]+/).filter(Boolean).forEach(function (tok) {
			if (/^[0-9a-fA-F.:]+(\/\d{1,3})?$/.test(tok)) entries.push(tok);
			else errors.push(tok);
		});
	});
	return { entries: entries, errors: errors };
}

function spinner() {
	return E('span', { class: 'sr-spinner' });
}

// relTime: epoch seconds or an ISO8601 string -> "Xm ago"/never
function relTime(v) {
	if (!v) return T('status_metrics_never');
	var ms = typeof v === 'number' ? v * 1000 : Date.parse(v);
	if (!ms || isNaN(ms)) return T('status_metrics_never');
	var sec = Math.max(0, Math.floor((Date.now() - ms) / 1000));
	if (sec < 60) return sec + (srLang() === 'en' ? 's ago' : 'с назад');
	var min = Math.floor(sec / 60);
	if (min < 60) return min + (srLang() === 'en' ? 'm ago' : 'м назад');
	var hr = Math.floor(min / 60);
	return hr + (srLang() === 'en' ? 'h ago' : 'ч назад');
}

function fmtBytes(n) {
	n = n || 0;
	if (n < 1024) return n + ' Б/с';
	if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' КБ/с';
	return (n / (1024 * 1024)).toFixed(2) + ' МБ/с';
}

// --- toasts (replaces LuCI's ui.addNotification) ---
function toast(msg, kind) {
	var host = document.getElementById('sr-toasts');
	if (!host) return;
	var el = E('div', { class: 'sr-toast sr-toast-' + (kind || 'info') }, msg);
	host.appendChild(el);
	requestAnimationFrame(function () { el.classList.add('is-visible'); });
	setTimeout(function () {
		el.classList.remove('is-visible');
		setTimeout(function () { el.remove(); }, 300);
	}, 4500);
}

// --- wiring exported globally for tab modules (no bundler in this
// project -- plain <script> tags, same as gateway/static/index.html
// always was) ---
// sectionVisible: true only while both the browser tab itself is in the
// foreground (not document.hidden -- backgrounded/minimized) AND this
// specific section is the one currently shown. activateSection (below)
// never removes a section from the DOM, only toggles its `hidden`
// attribute, so checking *existence* (a pattern status.js used to lean on
// via its own now-fixed isGone()) can never actually detect "navigated
// away" -- the element is always still there. Every page's own
// setTimeout-chained poll loop (status.js's traffic/logs/metrics/activity
// polling, profiles.js's and doublevpn.js's activity polling) checks this
// before doing any real work, so switching tabs/sections -- or just
// backgrounding the browser tab -- stops the router from fielding a fresh
// `sh`-exec of the 26KB rpcd script every few seconds for a page nobody is
// looking at; the loop keeps re-checking cheaply (no network call) and
// resumes real polling the moment the section/tab is visible again.
function sectionVisible(name) {
	if (document.hidden) return false;
	var el = document.getElementById('sr-section-' + name);
	return !!el && !el.hidden;
}

window.SR = {
	E: E, T: T, api: api, lang: srLang, setLang: srSetLang,
	renderName: renderName, sanitizeDomain: sanitizeDomain, spinner: spinner,
	relTime: relTime, fmtBytes: fmtBytes, toast: toast, parseIpRanges: parseIpRanges,
	sectionVisible: sectionVisible,
	CLIENT_PRESETS: CLIENT_PRESETS, DEVICE_OS_OPTIONS: DEVICE_OS_OPTIONS,
	DEVICE_MODEL_OPTIONS: DEVICE_MODEL_OPTIONS, DEVICE_VER_OPTIONS: DEVICE_VER_OPTIONS
};

// --- modal (used by the Profiles tab for add/edit) ---

var modalOverlay, modalBody, modalTitleEl;

function initModal() {
	modalOverlay = document.getElementById('sr-modal-overlay');
	modalBody = document.getElementById('sr-modal-body');
	modalTitleEl = document.getElementById('sr-modal-title');
	document.getElementById('sr-modal-close').addEventListener('click', closeModal);
	modalOverlay.addEventListener('click', function (ev) { if (ev.target === modalOverlay) closeModal(); });
	document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape' && !modalOverlay.hidden) closeModal(); });
}

function openModal(title, bodyEl) {
	modalTitleEl.textContent = title;
	modalBody.innerHTML = '';
	modalBody.appendChild(bodyEl);
	modalOverlay.hidden = false;
}

function closeModal() {
	modalOverlay.hidden = true;
	modalBody.innerHTML = '';
}

window.SR.modal = { open: openModal, close: closeModal };

// --- auth / login screen ---

function showApp() {
	document.getElementById('sr-login-screen').hidden = true;
	document.getElementById('sr-app-shell').hidden = false;
}
function showLogin(msg) {
	document.getElementById('sr-login-screen').hidden = false;
	document.getElementById('sr-app-shell').hidden = true;
	var err = document.getElementById('sr-login-error');
	err.textContent = msg || '';
	err.hidden = !msg;
}

function checkAuth() {
	return fetch('/api/auth/status').then(function (r) { return r.json(); }).then(function (st) {
		if (!st.authRequired || st.authed) { showApp(); return true; }
		showLogin();
		return false;
	});
}

function wireLogin() {
	var form = document.getElementById('sr-login-form');
	form.addEventListener('submit', function (ev) {
		ev.preventDefault();
		var pw = document.getElementById('sr-login-password').value;
		var btn = form.querySelector('button[type=submit]');
		btn.disabled = true;
		fetch('/api/login', {
			method: 'POST', headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ password: pw })
		}).then(function (r) {
			btn.disabled = false;
			if (r.status === 429) { showLogin(T('login_too_many')); return; }
			if (!r.ok) { showLogin(T('login_error')); return; }
			document.getElementById('sr-login-password').value = '';
			initApp();
		});
	});
}

function wireLogout() {
	var btn = document.getElementById('sr-logout-btn');
	if (!btn) return;
	btn.addEventListener('click', function () {
		fetch('/api/logout', { method: 'POST' }).then(function () { showLogin(); });
	});
}

// --- section router ---

var SECTIONS = ['home', 'subscriptions', 'profiles', 'doublevpn', 'domains', 'killswitch', 'protection'];
var renderers = {}; // filled in by each tab's own <script> (status.js etc.)
var rendered = {};  // section -> true once its DOM has been built at least once

function activateSection(name) {
	if (SECTIONS.indexOf(name) === -1) name = 'home';
	SECTIONS.forEach(function (s) {
		var el = document.getElementById('sr-section-' + s);
		if (el) el.hidden = (s !== name);
		var nav = document.querySelector('.sr-nav-item[data-section="' + s + '"]');
		if (nav) nav.classList.toggle('is-active', s === name);
	});
	if (!rendered[name] && renderers[name]) {
		rendered[name] = true;
		renderers[name](document.getElementById('sr-section-' + name));
	}
	document.getElementById('sr-sidebar').classList.remove('is-open');
	location.hash = name;
}

function applyStaticI18n() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		el.textContent = T(el.getAttribute('data-i18n'));
	});
	document.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
		el.placeholder = T(el.getAttribute('data-i18n-placeholder'));
	});
	document.getElementById('sr-lang-btn').textContent = T('lang_switch');
}

function initApp() {
	showApp();
	applyStaticI18n();
	var initial = (location.hash || '#home').slice(1);
	activateSection(initial);
}

document.addEventListener('DOMContentLoaded', function () {
	wireLogin();
	wireLogout();
	initModal();

	document.getElementById('sr-burger-btn').addEventListener('click', function () {
		document.getElementById('sr-sidebar').classList.toggle('is-open');
	});
	document.querySelectorAll('.sr-nav-item').forEach(function (btn) {
		btn.addEventListener('click', function () { activateSection(btn.getAttribute('data-section')); });
	});
	document.getElementById('sr-lang-btn').addEventListener('click', function () {
		srSetLang(srLang() === 'ru' ? 'en' : 'ru');
	});
	window.addEventListener('hashchange', function () { activateSection(location.hash.slice(1)); });

	checkAuth().then(function (authed) { if (authed) initApp(); });
});
