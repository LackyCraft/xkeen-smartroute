# Kill-Switch изнутри: два бэкенда, один ipset

Источник: [`lib/killswitch.sh`](../../lib/killswitch.sh) (~530 строк, два
платформенных бэкенда). Пользовательское описание (что видно в UI,
инструкция по тестированию) —
[docs/UI_functionality/kill-switch.md](../UI_functionality/kill-switch.md);
здесь — **как это устроено в коде**.

## Содержание

- [Два независимых слоя](#два-независимых-слоя)
- [Почему "мягкий" слой не требует настройки вообще](#почему-мягкий-слой-не-требует-настройки-вообще)
- [Жёсткий слой на OpenWrt: dnsmasq → ipset → REJECT](#жёсткий-слой-на-openwrt-dnsmasq--ipset--reject)
- [Реальный баг: firewall-ipset никогда не создавался](#реальный-баг-firewall-ipset-никогда-не-создавался)
- [Жёсткий слой на KeeneticOS: теневой dnsmasq + iptables](#жёсткий-слой-на-keeneticos-теневой-dnsmasq--iptables)
- [Два живых бага, найденных тестированием: REDIRECT-адрес и порядок правил](#два-живых-бага-найденных-тестированием-redirect-адрес-и-порядок-правил)
- [Гонка при перестройке: свой mkdir-лок плюс -w на iptables](#гонка-при-перестройке-свой-mkdir-лок-плюс--w-на-iptables)
- [ks_check_dnsmasq_capability: preflight перед включением](#ks_check_dnsmasq_capability-preflight-перед-включением)
- [resolve_geosite_domains: откуда берутся домены для категории](#resolve_geosite_domains-откуда-берутся-домены-для-категории)
- [ks_rebuild_dnsmasq: сбор доменов один раз, применение — по платформе](#ks_rebuild_dnsmasq-сбор-доменов-один-раз-применение--по-платформе)
- [Почему правило firewall не опрашивает "жив ли Xray"](#почему-правило-firewall-не-опрашивает-жив-ли-xray)
- [Устаревшие IP между профилями: flush/delete после reload](#устаревшие-ip-между-профилями-flushdelete-после-reload)
- [Известный пробел: ip_ranges не защищены](#известный-пробел-ip_ranges-не-защищены)

## Два независимых слоя

```
1. "Soft" (always on, free): traffic for a profile's domains is redirected
   to xray's local inbound by lib/redirect.sh's own firewall rules. If the
   xray process is down, that redirect target is gone and the connection
   is refused locally — it does NOT silently fall through to a direct
   route (unless the user opted into leak-protect's fail-open default).
2. "Hard" (opt-in, per profile): resolved IPs of the profile's domains are
   collected into an ipset, and a firewall REJECT rule on the LAN->WAN
   forward chain covers that ipset. Two platform backends, same
   domain-collection logic feeding both (ks_apply_openwrt / ks_apply_keenetic).
```

([`lib/killswitch.sh` top-of-file comment](../../lib/killswitch.sh#L2-L71))

## Почему "мягкий" слой не требует настройки вообще

Это не отдельный механизм, а побочное свойство того, как вообще работает
перехват трафика (см. [leak-protection.md](leak-protection.md)):
пакет DNAT-ится на локальный инбаунд Xray. Если Xray не запущен —
пакет просто некуда доставить, соединение рвётся локально, а не тихо
уходит напрямую. Это уже покрывает **любой** профиль без единой строчки
дополнительного кода — "жёсткий" слой ниже добавляет к этому явную,
постоянно взведённую блокировку на уровне firewall, а не заменяет собой
базовый механизм.

## Жёсткий слой на OpenWrt: dnsmasq → ipset → REJECT

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

## Жёсткий слой на KeeneticOS: теневой dnsmasq + iptables

KeeneticOS не имеет системного dnsmasq вообще — DNS роутера обслуживает
NDM'овский `ndnproxy`, уже занявший порт 53, безо всякого dnsmasq внутри.
Значит "повесить ipset-директиву на существующий резолвер LAN", как на
OpenWrt, здесь просто не на что вешать. Вместо этого `ks_apply_keenetic`
поднимает **отдельный, выделенный** экземпляр Entware `dnsmasq-full`,
чья единственная задача — смотреть DNS-запросы и наполнять ipset, а не
быть реальным резолвером LAN:

```sh
{
	echo "port=$KS_DNS_PORT"
	echo "no-resolv"
	echo "no-hosts"
	echo "interface=$LAN_DEVICE"
	echo "server=127.0.0.1"
	domain_list="$(sort -u "$domains_file" | tr '\n' '/' | sed 's#/$##')"
	[ -n "$domain_list" ] && echo "ipset=/$domain_list/$IPSET_NAME"
} > "$KS_DNSMASQ_CONF"
```

([`lib/killswitch.sh` — `ks_apply_keenetic`](../../lib/killswitch.sh))

`server=127.0.0.1` пересылает каждый запрос на настоящий `ndnproxy` — LAN
получает ровно тот же ответ, что и без этого механизма вообще, разница
только в побочном эффекте (заполнение ipset). Чтобы теневой экземпляр
вообще увидел LAN-запросы, PREROUTING-правило перенаправляет TCP/UDP :53
с LAN-интерфейса на `$KS_DNS_PORT` (по умолчанию 5310) — отдельная
цепочка от DNS-защиты `lib/redirect.sh`, вставленная **первой** в
PREROUTING (`-I`, не `-A`): если dns-protect тоже активен, kill-switch
всё равно должен увидеть запрос первым для своего ipset, при этом
конечный ответ клиенту не меняется — обе цепочки в итоге ведут к тому же
`ndnproxy`, просто с разным числом промежуточных хопов.

## Два живых бага, найденных тестированием: REDIRECT-адрес и порядок правил

Оба обнаружены **вживую** при первом реальном прогоне на Keenetic Hero
4G+/KN-2311, не в код-ревью:

1. **`iptables REDIRECT` переписывает адрес назначения на адрес
   входящего интерфейса, а не на `127.0.0.1`.** Первая версия конфига
   слушала только `listen-address=127.0.0.1` — LAN-клиент слал запрос на
   `192.168.2.2:53`, REDIRECT менял порт на `$KS_DNS_PORT`, но **адрес**
   оставался LAN-адресом роутера (`192.168.2.2:5310`), не loopback —
   dnsmasq, слушающий только `127.0.0.1`, этот пакет просто не видел
   (тихий таймаут, ни одной ошибки ни с одной стороны). Исправлено:
   `interface=$LAN_DEVICE` вместо `listen-address=127.0.0.1` — привязка
   по имени интерфейса, а не по конкретному IP (тот же приём, что уже
   использует `lib/redirect.sh` для своих собственных правил).
2. **REJECT-правило на `FORWARD` изначально ничего не блокировало** —
   добавлялось через `-A` (в конец цепочки), а собственные цепочки NDM
   (`_NDM_FORWARD`, `_NDM_SL_FORWARD`, ...) уже принимали обычный
   LAN→WAN трафик раньше в этой же цепочке; правило просто никогда не
   успевало сработать (0 попаданий при живом трафике на watched-IP,
   подтверждено `Test-NetConnection` с LAN-клиента). Исправлено: `-I
   FORWARD 1` — вставка в самое начало, та же логика, что уже применена
   к DNS-редиректу выше.

## Гонка при перестройке: свой mkdir-лок плюс -w на iptables

Once-a-minute cron-вотчдог (`killswitch.sh reapply`, самолечение упавшего
теневого dnsmasq — см. ниже) может пересечься по времени с ручным
включением/выключением kill-switch через панель. Подтверждено вживую:
без сериализации два параллельных прогона `ks_apply_keenetic` могут
перемежать свои `-F`(flush)/`-A`(append) вызовы и оставить дублированные
правила в цепочке (безобидно, раз правила идентичны, но не гарантия в
общем случае — и класс проблемы, который в этом проекте нигде больше не
считается приемлемым). Тот же `mkdir`-мьютекс, что уже использует
`genroute.sh`'s regen-лок (атомарно на любой файловой системе проекта, в
этом busybox нет `flock`), плюс отдельно — обёртка `ipt()` вокруг
`iptables -w`, потому что легаси xtables-лок общий на весь роутер: гонка
возможна не только между двумя вызовами `killswitch.sh`, но и с
одновременным вызовом `redirect.sh` (тот же баг класса, что уже был
найден и исправлен в `redirect.sh` — см.
[leak-protection.md](leak-protection.md)).

## ks_check_dnsmasq_capability: preflight перед включением

```sh
ks_check_dnsmasq_capability() {
	if [ "$SR_PLATFORM" = "openwrt" ]; then
		dnsmasq --version 2>/dev/null | grep -q ' ipset\| nftset' \
			|| sr_die "system dnsmasq lacks ipset/nftset support -- install dnsmasq-full ..."
	else
		[ -x "$KS_DNSMASQ_BIN" ] && "$KS_DNSMASQ_BIN" --version 2>/dev/null | grep -q ' ipset' \
			|| sr_die "dnsmasq-full (с поддержкой ipset) не установлен ..."
		command -v ipset >/dev/null 2>&1 \
			|| sr_die "ipset не установлен ..."
	fi
}
```

([`lib/killswitch.sh` — `ks_check_dnsmasq_capability`](../../lib/killswitch.sh))

Стоковая сборка dnsmasq на многих прошивках OpenWrt собрана **без**
поддержки `ipset`/`nftset` вообще — в этом случае весь механизм выше
молча ничего не делает: UCI-секции пишутся исправно, но dnsmasq их
просто игнорирует, не понимая опции. `ks_enable()` теперь проверяет это
явно **до** записи любого состояния и падает с понятной ошибкой, а не
оставляет профиль в состоянии "флаг включён, защиты нет" (то же
семейство симптома, что и найденный выше баг с отсутствующей
firewall-секцией, но с другой причиной). `install.sh` также был
обновлён — на OpenWrt проактивно ставит `dnsmasq-full` вместо стокового
`dnsmasq`, на KeeneticOS ставит Entware-пакеты `dnsmasq-full ipset`
через `opkg` — так что для свежих установок этот путь ошибки практически
не встречается ни на одной платформе. Сам preflight по-прежнему ничего
не устанавливает сам — только проверяет и падает с понятной инструкцией,
как и раньше на OpenWrt, чтобы rpcd-вызов от клика тумблера не начинал
незапрошенную установку пакетов за пользователя.

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

## ks_rebuild_dnsmasq: сбор доменов один раз, применение — по платформе

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

Сбор доменов (`ks_collect_domains`) — общий код для обеих платформ, не
дублируется: печатает домены всех включённых профилей в stdout, отдаёт
"был ли хоть один включённый профиль с реальным источником доменов"
через глобальную `$ks_any` (в POSIX sh нет другого дешёвого способа
вернуть второе значение). `ks_rebuild_dnsmasq` вызывает его один раз, а
дальше диспетчеризует по `$SR_PLATFORM` в `ks_apply_openwrt` (код и
поведение выше — без изменений) или `ks_apply_keenetic`.

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

Это рассуждение справедливо для REJECT-правила на обеих платформах
(KeeneticOS — тот же принцип, `-I FORWARD 1`, см. выше). Но
DNS-редирект на теневой dnsmasq (KeeneticOS-only, см. выше) — другая
история: если теневой процесс упадёт, а PREROUTING-редирект на его порт
останется взведённым, это заблокирует DNS **всей** LAN, не только
kill-switch-профилей — ровно тот класс бага, ради которого сделан
fail-open в `redirect.sh` (см. [leak-protection.md](leak-protection.md)).
Поэтому `ks_apply_keenetic` взводит DNS-редирект только после того, как
подтвердит, что свежезапущенный dnsmasq реально поднялся; `killswitch.sh
reapply` (боевой хук на загрузке + cron раз в минуту, `install.sh`, но
**только на KeeneticOS** — на OpenWrt эта же задача перезапускала бы
системный dnsmasq и `firewall reload` каждую минуту без всякой нужды)
перепроверяет и самолечит упавший процесс тем же способом.

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
