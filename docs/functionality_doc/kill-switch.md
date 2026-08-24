# Kill-Switch изнутри: dnsmasq + ipset + nftables

Источник: [`lib/killswitch.sh`](../../lib/killswitch.sh) (252 строки).
Пользовательское описание (что видно в UI, инструкция по тестированию) —
[docs/UI_functionality/kill-switch.md](../UI_functionality/kill-switch.md);
здесь — **как это устроено в коде**.

## Содержание

- [Два независимых слоя](#два-независимых-слоя)
- [Почему "мягкий" слой не требует настройки вообще](#почему-мягкий-слой-не-требует-настройки-вообще)
- [Жёсткий слой: dnsmasq → ipset → REJECT](#жёсткий-слой-dnsmasq--ipset--reject)
- [Реальный баг: firewall-ipset никогда не создавался](#реальный-баг-firewall-ipset-никогда-не-создавался)
- [ks_check_dnsmasq_capability: preflight перед включением](#ks_check_dnsmasq_capability-preflight-перед-включением)
- [resolve_geosite_domains: откуда берутся домены для категории](#resolve_geosite_domains-откуда-берутся-домены-для-категории)
- [ks_rebuild_dnsmasq: полная пересборка, не инкрементальные правки](#ks_rebuild_dnsmasq-полная-пересборка-не-инкрементальные-правки)
- [Почему правило firewall не опрашивает "жив ли Xray"](#почему-правило-firewall-не-опрашивает-жив-ли-xray)
- [Устаревшие IP между профилями: flush/delete после reload](#устаревшие-ip-между-профилями-flushdelete-после-reload)
- [Известный пробел: ip_ranges не защищены](#известный-пробел-ip_ranges-не-защищены)

## Два независимых слоя

```
1. "Soft" (always on, free): traffic for a profile's domains is redirected
   to xray's local inbound by xkeen's own firewall rules. If the xray
   process is down, that redirect target is gone and the connection is
   refused locally — it does NOT silently fall through to a direct route.
2. "Hard" (opt-in, per profile): resolved IPs of the profile's domains are
   collected into an ipset via dnsmasq, and a firewall REJECT rule on the
   LAN->WAN forward chain covers that ipset.
```

([`lib/killswitch.sh:4-23`](../../lib/killswitch.sh#L4-L23))

## Почему "мягкий" слой не требует настройки вообще

Это не отдельный механизм, а побочное свойство того, как вообще работает
перехват трафика (см. [leak-protection.md](leak-protection.md)):
пакет DNAT-ится на локальный инбаунд Xray. Если Xray не запущен —
пакет просто некуда доставить, соединение рвётся локально, а не тихо
уходит напрямую. Это уже покрывает **любой** профиль без единой строчки
дополнительного кода — "жёсткий" слой ниже добавляет к этому явную,
постоянно взведённую блокировку на уровне firewall, а не заменяет собой
базовый механизм.

## Жёсткий слой: dnsmasq → ipset → REJECT

Четыре момента должны сработать по цепочке:

1. Клиент резолвит домен из списка профиля через dnsmasq этого роутера
   (обязательное условие — см. [leak-protection.md](leak-protection.md#dns-защита)
   про принудительный редирект DNS-запросов).
2. dhcp-сторона (`config ipset` секция `dhcp.sr_killswitch`, `list name`/
   `list domain`) говорит dnsmasq, какие домены наполняют ipset
   `sr_killswitch` — dnsmasq сам эмитит нужную ему низкоуровневую
   директиву (`ipset=` или `nftset=`, в зависимости от сборки бинарника).
3. firewall-сторона (`config ipset` секция `firewall.sr_killswitch_ipset`)
   — это то, что реально **создаёт** нативный nftables-сет с этим именем.
   Без неё шаг 2 указывает dnsmasq писать резолвнутые IP в сет, которого
   fw4 не создавал — см. ниже.
4. Правило firewall `REJECT`-ит весь LAN→WAN трафик, чей адрес назначения
   попадает в этот ipset.

dnsmasq умеет реагировать только на **буквальные** доменные имена — не
на скомпилированный `geosite.dat` Xray. Поэтому для `geosite`-профилей
нужен отдельный шаг: взять исходный список доменов той же категории (не
бинарный файл, а текстовый source-лист) и скормить его dnsmasq тем же
самым механизмом, что и `custom`-профили.

## Реальный баг: firewall-ipset никогда не создавался

Найдено и исправлено вживую: kill-switch выглядел полностью взведённым
— флаг профиля стоял, правило `REJECT` существовало в UCI, dnsmasq не
жаловался — но трафик после ручной остановки Xray утекал напрямую,
никакого блока. Причина — шаг 3 выше (`firewall.$FW_IPSET_SECTION`)
попросту отсутствовал: правило `REJECT` ссылалось на `ipset=sr_killswitch`,
но ни один UCI-раздел никогда не говорил fw4 **создать** сет с этим
именем. dnsmasq писал резолвнутые IP в никуда (сета не существовало),
а правило firewall матчило по несуществующему сету — то есть не матчило
вообще ничего, и REJECT никогда не срабатывал. Добавлена сама секция:

```sh
uci set firewall.$FW_IPSET_SECTION="ipset"
uci set firewall.$FW_IPSET_SECTION.name="$IPSET_NAME"
uci set firewall.$FW_IPSET_SECTION.match="dst_ip"
uci set firewall.$FW_IPSET_SECTION.family="4"
uci set firewall.$FW_IPSET_SECTION.timeout="-1"
```

([`lib/killswitch.sh:156-160`](../../lib/killswitch.sh#L156-L160))

## ks_check_dnsmasq_capability: preflight перед включением

```sh
ks_check_dnsmasq_capability() {
	dnsmasq --version 2>/dev/null | grep -q ' ipset\| nftset' \
		|| sr_die "system dnsmasq lacks ipset/nftset support -- install dnsmasq-full (opkg remove dnsmasq && opkg install dnsmasq-full) to use the hard kill-switch"
}
```

([`lib/killswitch.sh:208-211`](../../lib/killswitch.sh#L208-L211))

Стоковая сборка dnsmasq на многих прошивок собрана **без** поддержки
`ipset`/`nftset` вообще — в этом случае весь механизм выше молча ничего
не делает: UCI-секции пишутся исправно, но dnsmasq их просто игнорирует,
не понимая опции. `ks_enable()` теперь проверяет это явно **до** записи
любого состояния и падает с понятной ошибкой, а не оставляет профиль в
состоянии "флаг включён, защиты нет" (то же семейство симптома, что и
найденный выше баг с отсутствующей firewall-секцией, но с другой
причиной). `install.sh` также был обновлён — теперь проактивно ставит
`dnsmasq-full` вместо стокового `dnsmasq`, так что для свежих установок
этот путь ошибки практически не встречается.

## resolve_geosite_domains: откуда берутся домены для категории

```sh
resolve_geosite_domains() {
	category="$1"; seen="${2:-}"
	case " $seen " in *" $category "*) return 0 ;; esac
	seen="$seen $category"
	...
	src="$(curl -fsSL --max-time 15 "$GEOSITE_SRC_BASE/$category" 2>/dev/null)" || src=""
	printf '%s\n' "$src" \
		| sed 's/#.*$//' \
		| grep -v '^[[:space:]]*$' \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
		| grep -vE '^(keyword|regexp):' \
		| sed -E 's/^(domain|full)://; s/[[:space:]]*@[^[:space:]]*$//' \
		| sort -u > "$cache_file.direct"
	...
}
```

([`lib/killswitch.sh:63-101`](../../lib/killswitch.sh#L63-L101))

`GEOSITE_SRC_BASE` — `v2fly/domain-list-community`, тот же самый проект,
из которого Xray сам собирает свой `geosite.dat`
(`GEOSITE_SRC_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"`,
[`lib/killswitch.sh:50`](../../lib/killswitch.sh#L50)). Формат source-файла —
строки вида `domain:example.com`, `full:exact.example.com`,
`keyword:foo`, `regexp:...`, `include:другая-категория`.

`grep -vE '^(keyword|regexp):'` — это и есть архитектурный потолок
покрытия: `keyword:`/`regexp:` — не домен, а правило сопоставления
("любой домен, содержащий подстроку X"), таких доменов бесконечно много
и большинство ещё не существует. Xray сам сопоставляет их **в моменте**
по живому SNI/Host запроса; dnsmasq может реагировать только на реальный
DNS-запрос к конкретному, заранее известному имени — byte-in-byte
повторить это через "резолвь → добавь IP в список" нельзя в принципе.
`include:` обрабатывается рекурсивно, с защитой от циклов через `$seen`.

Результат кешируется на `GEOSITE_CACHE_MAX_AGE_DAYS=7` дней
(`$SR_LISTS_DIR/geosite-resolved/<category>.lst`) — повторное включение
kill-switch не должно каждый раз заново фетчить с GitHub, а
once-a-minute cron-джоб (`ks_check`, если включён — см. ниже) вообще
никогда сюда не заходит.

## ks_rebuild_dnsmasq: полная пересборка, не инкрементальные правки

```sh
uci -q delete dhcp.$DHCP_IPSET_SECTION 2>/dev/null || true

domains_file="$(mktemp)"
any=0
for f in "$SR_KS_FLAG_DIR"/*.name; do
	[ -e "$f" ] || continue
	profile="$(cat "$f")"
	...
	if [ "$src_type" = "custom" ]; then
		grep -v '^#' "$list_file" | grep -v '^$' >>"$domains_file"
	elif [ "$src_type" = "geosite" ]; then
		resolve_geosite_domains "$category" >>"$domains_file"
	fi
	any=1
done

if [ "$any" = "1" ] && [ -s "$domains_file" ]; then
	uci set dhcp.$DHCP_IPSET_SECTION="ipset"
	uci add_list dhcp.$DHCP_IPSET_SECTION.name="$IPSET_NAME"
	sort -u "$domains_file" | while IFS= read -r d; do
		uci add_list dhcp.$DHCP_IPSET_SECTION.domain="$d"
	done
else
	any=0
fi
uci commit dhcp
```

([`lib/killswitch.sh:103-148`](../../lib/killswitch.sh#L103-L148))

Named-секция (`dhcp.$DHCP_IPSET_SECTION`, не индексированная
`@dnsmasq[0].ipset`-опция) удаляется одной операцией (`uci delete` по
имени — O(1)) и строится заново с нуля, а не патчится инкрементально.
Раньше это делалось через `uci get` + `uci del_list` по одной записи —
приемлемо для десятка доменов custom-списка, но одна geosite-категория
может резолвиться в 100+ доменов, и каждый round-trip get/del заново
парсит весь файл конфига UCI — удаление занимало **минуты** вместо
мгновения. Секция — `config ipset` в `/etc/config/dhcp`
(`list name sr_killswitch`, `list domain ...` на каждый домен) — сама не
создаёт nftables-сет, а только говорит dnsmasq наполнять его; создаёт
сет отдельная firewall-секция (см. выше).

Следом собирается вторая, firewall-сторона (`config ipset` +
`config rule`, см. предыдущие два раздела) — только если набор доменов
непустой; если ни у одного профиля kill-switch не включён (`any=0`),
обе UCI-секции наоборот удаляются, а не оставляются с пустым списком
доменов.

`SR_KS_FLAG_DIR` (`$SR_STATE_DIR/killswitch/`) хранит по одному файлу
`<profile>.name` на каждый профиль с включённым kill-switch — сам факт
существования файла и есть состояние "включено".

## Почему правило firewall не опрашивает "жив ли Xray"

```sh
if [ "$any" = "1" ]; then
	uci set firewall.$FW_RULE_NAME="rule"
	uci set firewall.$FW_RULE_NAME.src="lan"
	uci set firewall.$FW_RULE_NAME.dest="wan"
	uci set firewall.$FW_RULE_NAME.ipset="$IPSET_NAME"
	uci set firewall.$FW_RULE_NAME.target="REJECT"
	uci set firewall.$FW_RULE_NAME.enabled="1"
	uci commit firewall
```

([`lib/killswitch.sh:172-178`](../../lib/killswitch.sh#L172-L178))

Правило взводится **сразу** при включении kill-switch и остаётся
взведённым постоянно — не опрашивается раз в минуту cron-джобом на
предмет "жив ли Xray сейчас" (более ранняя версия делала именно так,
оставляя окно уязвимости до 60 секунд). Опрос оказался не нужен вовсе:
собственный `PREROUTING`-редирект `lib/redirect.sh`
(`nftables redirect to :port`, не `xkeen -ap` — см.
[leak-protection.md](leak-protection.md)) шлёт совпавший трафик на
локальный инбаунд Xray через форму DNAT, а DNAT на локальный адрес
проводит пакет через цепочку `INPUT`, никогда через `FORWARD` —
независимо от того, слушает ли Xray на другом конце или нет. Значит это
`REJECT`-правило на `FORWARD` **никогда не видит** корректно
перенаправленный трафик — оно инертно в штатном режиме и срабатывает
только для трафика, который перехватом **не** пойман вообще (процесс
Xray или его правила firewall пропали) — то есть ровно для того случая,
для которого и существует. Постоянное взведение без опроса — проще
предыдущей версии и не оставляет временного зазора.

## Устаревшие IP между профилями: flush/delete после reload

Найдено вживую во время тестирования F-K1: `/etc/init.d/firewall reload`
пересобирает правила и секции, которые всё ещё числятся в конфиге, но
**не** подчищает нативный nftables-сет секции, которая из конфига только
что удалена — сет остаётся в живом рулсете со всем, что в него уже
успело резолвиться, просто более никем не упоминаемый. Оставленный так,
он либо просто висит бесхозным (не опасно, но грязно), либо — хуже —
молча переиспользуется в следующий раз, когда **любой** профиль заново
включает kill-switch (то же имя сета/тип), принося с собой IP, резолвнутые
для доменов давно отключённого или изменённого профиля, в REJECT-правило,
которое к ним отношения уже не имеет — блокировка не того, что должна.

```sh
if [ "$any" = "1" ]; then
	nft flush set inet fw4 "$IPSET_NAME" >/dev/null 2>&1 || true
else
	nft delete set inet fw4 "$IPSET_NAME" >/dev/null 2>&1 || true
fi
```

([`lib/killswitch.sh:201-205`](../../lib/killswitch.sh#L201-L205))

`ks_rebuild_dnsmasq()` теперь явно чистит (`flush`, если ipset ещё
взведён где-то) или удаляет (`delete`, если больше ни у одного профиля
kill-switch не включён) живой nftables-сет **после** `firewall reload`
— так он всегда отражает только только что записанный список доменов,
никогда предыдущий.

## Известный пробел: ip_ranges не защищены

`ks_rebuild_dnsmasq()` смотрит только на `.domain_source` профиля —
**не** на `.ip_ranges` (см. [routing-generation.md](routing-generation.md#домены-vs-устройства-vs-ip-диапазоны-почему-это-разные-правила)
про то, зачем `ip_ranges` вообще существует). Для профиля вроде
Telegram, где `ip_ranges` как раз и нужен (MTProto ходит по IP
напрямую, без DNS), kill-switch сейчас не даёт **никакой** защиты для
этой части: dnsmasq никогда не увидит DNS-запрос для трафика, который и
так не резолвит домен — ipset для этих IP просто никогда не заполнится.
Не реализовано; ближайший практичный путь — класть `ip_ranges` профиля
в ipset напрямую (IP уже известны буквально, резолвинг не нужен) —
подробнее в [UI_functionality/kill-switch.md](../UI_functionality/kill-switch.md#как-приблизиться-к-100).
