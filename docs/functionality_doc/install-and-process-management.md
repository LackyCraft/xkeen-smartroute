# Установка, жизненный цикл Xray и cron

Источники: [`install.sh`](../../install.sh) (~640 строк),
[`lib/common.sh`](../../lib/common.sh) (управление процессом Xray).

## Содержание

- [Почему не `xkeen -restart`](#почему-не-xkeen--restart)
- [_sr_xray_validate: самолечение известного класса ошибок](#_sr_xray_validate-самолечение-известного-класса-ошибок)
- [_sr_xray_launch: как реально стартует процесс](#_sr_xray_launch-как-реально-стартует-процесс)
- [Boot-порядок: два независимых механизма автозапуска](#boot-порядок-два-независимых-механизма-автозапуска)
- [Cron: пять задач, разная частота по разным причинам](#cron-пять-задач-разная-частота-по-разным-причинам)

## Почему не `xkeen -restart`

xkeen — родная платформа KeenticOS, не "чистый" OpenWrt. Его собственный
путь рестарта пишет hook-файл netfilter в стиле KeenticOS NDM и пытается
почистить iptables-правила, которых на этом OpenWrt просто нет —
подтверждено на реальном железе: шаг очистки iptables **зависал
бесконечно**, роняя прокси без пути назад, кроме SSH-сессии и ручного
`kill`:

```sh
# xkeen's own restart path writes a KeenticOS NDM netfilter hook file
# and expects to clean up NDM-managed iptables state -- neither applies
# on real OpenWrt (xkeen primarily targets KeenticOS), and the missing
# directory alone makes it fail outright; on hardware tested against,
# the iptables cleanup step *hung indefinitely* ...
mkdir -p /opt/etc/ndm/netfilter.d
timeout 30 xkeen -restart >/dev/null 2>&1 || log "..."
```

([`install.sh:227-238`](../../install.sh#L227-L238))

`timeout 30` только страхует **этот однократный вызов** во время
установки (нужен xkeen'у для его собственной первичной инициализации).
Всё остальное — каждый рестарт после установки, всегда — идёт через
`lib/common.sh`'s собственные `sr_start_xray`/`sr_restart_xray`/
`sr_stop_xray`, которые управляют процессом Xray напрямую (`pgrep`+`kill`
+ relaunch), никогда не трогая `xkeen -restart` снова.

## _sr_xray_validate: самолечение известного класса ошибок

Перед тем как тронуть уже работающий процесс (в любую сторону — старт
или рестарт), смёрженный конфиг **обязан** пройти `xray run -test`:

```sh
_sr_xray_validate() {
	attempts=0
	while [ "$attempts" -lt 20 ]; do
		if test_out="$(XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" xray run -test -confdir "$XKEEN_CONFIGS_DIR" 2>&1)"; then
			return 0
		fi
		bad_tag="$(printf '%s' "$test_out" | sed -n 's/.*failed to build outbound config with tag \([^ ]*\).*/\1/p' | head -n1)"
		if [ -z "$bad_tag" ] || ...; then break; fi
		sr_log "WARNING: outbound '$bad_tag' has an XHTTP 'extra' field combination Xray's validator rejects -- dropping just that field ..."
		jq --arg tag "$bad_tag" '(.outbounds[] | select(.tag==$tag) | .streamSettings.xhttpSettings) |= (if . then del(.extra) else . end)' \
			"$SR_OUTBOUNDS_FILE" > "$SR_OUTBOUNDS_FILE.tmp" && mv "$SR_OUTBOUNDS_FILE.tmp" "$SR_OUTBOUNDS_FILE"
		attempts=$((attempts + 1))
	done
	sr_log "ERROR: refusing to $1 xray, the merged config failed validation: ..."
	return 1
}
```

([`lib/common.sh:206-223`](../../lib/common.sh#L206-L223))

Один сломанный outbound (частый случай — XHTTP `extra` поле от
конкретного провайдера с комбинацией подполей, которую Xray-валидатор
жёстко отвергает, см. [subscription-import.md](subscription-import.md#xhttp-extra-почему-это-не-опциональное-украшение))
иначе заблокировал бы **весь** рестарт целиком — а рестарты запускаются
без присмотра (cron), так что никто бы не заметил вовремя. Вместо
слепого отказа: если ошибка называет конкретный тег outbound'а — у
**этого одного** узла срезается только поле `.extra` (не весь узел, не
вся подписка), и валидация повторяется — с потолком в 20 попыток, чтобы
по-настоящему битый confdir всё равно отказал явно, а не зациклился
навечно.

Если валидация так и не прошла — функция возвращает ошибку, и
вызывающая сторона (`sr_start_xray`/`sr_restart_xray`) **не трогает**
уже работающий процесс вообще — лучше громко залогировать и оставить
то, что уже крутится (или оставить Xray остановленным, для первого
старта), чем молча положить доступ в интернет.

## _sr_xray_launch: как реально стартует процесс

```sh
_sr_xray_launch() {
	(
		trap '' HUP
		ulimit -SHn 1000000
		exec su -c "XRAY_LOCATION_ASSET='$XRAY_ASSET_DIR' xray run -confdir '$XKEEN_CONFIGS_DIR'" "$XRAY_RUN_USER" >"$SR_STATE_DIR/xray-launch.log" 2>&1 </dev/null
	) &
	i=0
	while ! pgrep -x xray >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
}
```

([`lib/common.sh:230-253`](../../lib/common.sh#L230-L253))

Два момента, оба найдены вживую, не теоретически:

- **`-confdir` флаг, а не переменная окружения.** Реальный, но
  малоизвестный факт про Xray: `XRAY_LOCATION_CONFDIR` **не
  существует** как настоящая переменная окружения Xray (подтверждено:
  ноль упоминаний в строках собранного бинарника). Процесс, запущенный
  так, стартует нормально и вроде бы обслуживает трафик — но **тихо**
  никогда не грузит routing/balancer-правила (`xray api lsrules/bi`
  рапортуют, что их просто не существует), при этом inbounds/outbounds/api
  грузятся нормально. Ложноположительный, ничего не падает, ничего не
  логирует ошибку — Xray просто спокойно работает с пустой таблицей
  правил, откатываясь на задокументированное поведение "ни одно
  правило не совпало → первый outbound" для **любого** соединения.
  Флаг `-confdir`, переданный как часть строки команды через `su -c`
  (не отдельно экспортированная переменная — некоторые реализации `su`
  вообще не прокидывают такие переменные дочернему шеллу) — единственный
  рабочий вариант.
- **`trap '' HUP` + subshell.** У этого busybox нет ни `nohup`, ни
  `setsid` — без ловушки на HUP процесс Xray получил бы SIGHUP и
  завершился бы в момент, когда запустивший его shell (rpcd-вызов,
  cron-задача) сам завершается.

## Boot-порядок: два независимых механизма автозапуска

Entware официально не гарантирует hook автозапуска после ребута — это
подтверждено вживую: ничего под `/opt` не стартовало после
перезагрузки реального роутера, пока `install.sh` не создал
`/etc/init.d/entware` руками:

```sh
if [ ! -x /etc/init.d/entware ]; then
	cat > /etc/init.d/entware <<'ENTWARE_HOOK_EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
boot() { /opt/etc/init.d/rc.unslung start }
...
ENTWARE_HOOK_EOF
	chmod +x /etc/init.d/entware
	/etc/init.d/entware enable
fi
```

([`install.sh:76-97`](../../install.sh#L76-L97))

`rc.unslung start` запускает **каждый** `S*`-скрипт под
`/opt/etc/init.d/` по номеру — включая собственный `S24xray` **самого**
xkeen (не через `lib/common.sh`, отдельный путь запуска!) и
`S98smartroute-gateway`. Значит директория для tmpfs-логов
([logging.md](logging.md)) должна существовать **до** того, как
запустится `S24xray` — ни один из хелперов `lib/common.sh` тут не
участвует вообще, единственная гарантия — отдельный, специально
пронумерованный init.d-скрипт:

```sh
mkdir -p /tmp/xray-logs /opt/etc/init.d
cat > /opt/etc/init.d/S23xray-logdir <<'XRAY_LOGDIR_EOF'
#!/bin/sh
mkdir -p /tmp/xray-logs
XRAY_LOGDIR_EOF
chmod +x /opt/etc/init.d/S23xray-logdir
```

([`install.sh:253-258`](../../install.sh#L253-L258))

`S23` < `S24` — гарантированно раньше, на каждой загрузке, независимо
от того, какой из нескольких способов запуска Xray сейчас сработает
(boot, ночной cron-рестарт, ручной рестарт из любого UI).

## Cron: пять задач, разная частота по разным причинам

```sh
CRON_GEO="0 */8 * * * xkeen -ug; xkeen -uk #xkeen-smartroute-cron"
CRON_SUB="7 * * * * sh $SR_LIB_DIR/subscription.sh refresh #xkeen-smartroute-cron"
CRON_RESTART="15 5 * * * sh -c '. $SR_LIB_DIR/common.sh; sr_restart_xray' #xkeen-smartroute-cron"
CRON_REGEN="*/3 * * * * sh $SR_LIB_DIR/genroute.sh regen #xkeen-smartroute-cron"
CRON_PING="0 */2 * * * sh $SR_LIB_DIR/subscription.sh ping #xkeen-smartroute-cron"
```

([`install.sh:598-630`](../../install.sh#L598-L630))

| Задача | Частота | Почему именно так |
|---|---|---|
| `xkeen -ug`/`-uk` (geosite/geoip) | раз в 8ч | Обновление баз geosite/geoip самого xkeen |
| `subscription.sh refresh` | тикает каждый час, но реально обновляет по настраиваемому интервалу (по умолчанию 12ч) | `sr_refresh_due()` сам проверяет таймстамп — проще менять интервал через UI, чем переписывать cron-строку |
| `sr_restart_xray` | раз в сутки, 05:15 | Xray-шный RSS растёт со временем работы (наблюдалось: ~37МБ сразу после рестарта, 120МБ+ после нескольких часов с непрерывным Observatory-прощупыванием) — на роутере без swap это реальный риск OOM-killer'а в неподходящий момент. Ежедневный рестарт в тихий час ограничивает рост дёшево; `sr_restart_xray` уже валидирует конфиг перед подменой процесса, так что это не может превратить рабочий роутер в сломанный так, как мог бы слепой `kill`+relaunch |
| `genroute.sh regen` | раз в 3 минуты | `sr_pick_top1` больше не делает собственных сетевых вызовов на каждый regen — читает уже свежие `health.json` (обновляется фоном каждые 20с самим `failover.go`) и `ping.json`, так что достаточно дёшево гонять часто |
| `subscription.sh ping` | раз в 2 часа | Строго последовательный пробник (см. [subscription-import.md](subscription-import.md#пинг-почему-последовательно-а-не-параллельно)) — на большой подписке не может себе позволить быть чаще, а выбор **рабочего** сервера теперь и не зависит от его свежести так сильно |

Все задачи маркированы одним общим комментарием `#xkeen-smartroute-cron`
— `install.sh` при переустановке сначала вычищает все строки с этой
меткой (`grep -v`), затем добавляет актуальный набор заново, так что
повторный запуск идемпотентен и не копит дубликаты.
