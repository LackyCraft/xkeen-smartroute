# Переключаемые логи Xray: почему они были пустыми и как это устроено

Источники: [`lib/common.sh`](../../lib/common.sh) (`sr_*_log_*` функции),
[`gateway/logs.go`](../../gateway/logs.go). UI-сторона —
[docs/UI_functionality/status.md](../UI_functionality/status.md#логи-xray)
(логи видны только в панели gateway, не в LuCI).

## Содержание

- [Корневая причина: `loglevel: "none"` — не фильтр, а выключатель](#корневая-причина-loglevel-none--не-фильтр-а-выключатель)
- [Почему tmpfs, а не флеш](#почему-tmpfs-а-не-флеш)
- [sr_apply_log_config: единственное место, решающее путь/уровень](#sr_apply_log_config-единственное-место-решающее-путьуровень)
- [Жёсткий лимит размера: две независимые проверки](#жёсткий-лимит-размера-две-независимые-проверки)
- [Очистка на месте, не удаление файла](#очистка-на-месте-не-удаление-файла)
- [Boot-порядок: tmpfs-директория должна существовать раньше Xray](#boot-порядок-tmpfs-директория-должна-существовать-раньше-xray)

## Корневая причина: `loglevel: "none"` — не фильтр, а выключатель

Долгое время вьюер логов был пуст **везде** — и в панели gateway, и в
xkeen-UI. Причина — не баг вывода, а сам Xray физически ничего не писал.
Подтверждено чтением реального исходника Xray-core (`app/log`'s
`Build()`): top-level `loglevel` — не порог серьёзности поверх
постоянно включённого логирования, а полный выключатель:

```go
switch level {
case "none":
    config.ErrorLogType = log.LogType_None
    config.AccessLogType = log.LogType_None
```

`"none"` выключает **и** access-, **и** error-лог одновременно — ни
одна строка не пишется, даже подавленная. Именно это значение годами
было зашито намертво в `install.sh`'s шаблоне `01_log.json`.

## Почему tmpfs, а не флеш

Access-лог пишет по строке на **каждый** запрос — реальная стоимость,
если направить его на флеш постоянно. Логи пишутся в `/tmp`
(`XRAY_LOG_DIR="/tmp/xray-logs"`, [`lib/common.sh:72`](../../lib/common.sh#L72)) —
оперативная память, не флеш-накопитель. Компромисс: файл не переживает
перезагрузку и ограничен по размеру (ниже) — оба приемлемы для живого
отладочного вьюера, каким это задумано, а не для архива.

## sr_apply_log_config: единственное место, решающее путь/уровень

```sh
sr_apply_log_config() {
	mkdir -p "$XRAY_LOG_DIR"
	if [ "$(sr_get_log_enabled)" = "1" ]; then
		level="$(sr_get_log_level)"
	else
		level="none"
	fi
	cat > "$XKEEN_CONFIGS_DIR/01_log.json" <<EOF
{
  "log": {
    "access": "$XRAY_LOG_DIR/access.log",
    "error": "$XRAY_LOG_DIR/error.log",
    "loglevel": "$level",
    "dnsLog": false
  }
}
EOF
	command -v xray >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1 && sr_restart_xray
}
```

([`lib/common.sh:101-119`](../../lib/common.sh#L101-L119))

Путь к файлам **не меняется** между вкл/выкл — только `loglevel`. Это
специально: `gateway/logs.go` держит эти пути как константы и никогда
не должен знать, включено логирование сейчас или нет — файл просто не
растёт, пока выключено:

```go
const (
	accessLogPath = "/tmp/xray-logs/access.log"
	errorLogPath  = "/tmp/xray-logs/error.log"
	...
)
```

([`gateway/logs.go:24-28`](../../gateway/logs.go#L24-L28))

Xray не умеет "горячо" перечитывать свой лог-конфиг — единственный
способ применить изменение уровня/включения — рестарт (`sr_restart_xray`,
та же безопасная, самовалидирующая процедура, что и у любого другого
изменения конфига, см.
[install-and-process-management.md](install-and-process-management.md)).
Рестарт вызывается только если Xray уже запущен — на установке до
первого старта просто пишется файл, который подхватится при обычном
запуске.

## Жёсткий лимит размера: две независимые проверки

**На входе** — сервер отклоняет запрошенный лимит, если он больше
половины реально свободной памяти прямо сейчас:

```sh
sr_set_log_cap_mb() {
	free_mb="$(sr_log_free_mb)"
	max_allowed=$((free_mb / 2))
	[ "$max_allowed" -ge 1 ] || max_allowed=1
	if [ "$1" -gt "$max_allowed" ]; then
		sr_die "cap ${1}MB exceeds half of currently free memory (${free_mb}MB free, max ${max_allowed}MB) -- pick a smaller value"
	fi
	...
}
```

([`lib/common.sh:141-152`](../../lib/common.sh#L141-L152))

`sr_log_free_mb()` читает `MemAvailable` (не голый `MemFree`) из
`/proc/meminfo` — оценка ядра "сколько реально безопасно выделить",
честнее сырого свободного счётчика.

**В рантайме** — независимо от того, кто и когда задал лимит, gateway
сам постоянно следит за фактическим размером файлов, раз в 5 секунд,
вне зависимости от того, открыт ли вьюер:

```go
func startLogCapLoop() {
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		for range ticker.C {
			capBytes := readLogCapMB() * 1024 * 1024
			enforceLogCap(accessLogPath, capBytes)
			enforceLogCap(errorLogPath, capBytes)
		}
	}()
}

func enforceLogCap(path string, capBytes int64) {
	fi, err := os.Stat(path)
	if err != nil || fi.Size() <= capBytes { return }
	_ = os.Truncate(path, 0)
}
```

([`gateway/logs.go:134-167`](../../gateway/logs.go#L134-L167))

Это осознанное дублирование двух проверок: входная — чтобы не дать
задать заведомо опасное число, рантайм-цикл — чтобы гарантировать
потолок **всегда**, даже если кто-то оставил логирование включённым и
забыл про него (собственно весь смысл лимита). Первая проверка не
заменяет вторую — файл может вырасти между проверками при высокой
нагрузке, и именно рантайм-цикл — тот механизм, что реально не даёт
превысить лимит.

## Очистка на месте, не удаление файла

```go
// Truncate in place (not remove) so Xray's already-open file handle
// keeps writing into the same inode -- see sr_clear_logs's identical
// reasoning in lib/common.sh, this is the same operation for the same
// reason, just triggered by size instead of a button.
_ = os.Truncate(path, 0)
```

([`gateway/logs.go:163-167`](../../gateway/logs.go#L163-L167))

И ручная кнопка "Очистить" (`sr_clear_logs()` в `lib/common.sh`,
`: > "$XRAY_LOG_DIR/access.log"`), и автоматическое срабатывание
лимита используют одну и ту же операцию — обнуление содержимого файла
по тому же inode, не `rm` + пересоздание. Xray держит файл открытым по
файловому дескриптору, а не по имени — удаление файла оставило бы Xray
дозаписывать в теперь безымянный inode, невидимый для любого
вьюера, что заново открывает файл по пути, до следующего рестарта.

`gateway/logs.go`'s `tailFile()` уже штатно обрабатывает внешнее
обнуление файла — `fi.Size() < pos` трактуется как "файл
обрезан/перезапущен", позиция чтения сбрасывается на 0 без разрыва
соединения WebSocket-вьюера.

## Boot-порядок: tmpfs-директория должна существовать раньше Xray

`/tmp` стирается на каждой перезагрузке, а Xray на боевом старте
запускается собственным init.d-скриптом xkeen (`S24xray`), который
**не** проходит через `lib/common.sh` вообще (см.
[install-and-process-management.md](install-and-process-management.md)) —
значит ни один из хелперов этого проекта не гарантированно успевает
создать `/tmp/xray-logs` до того, как Xray попробует туда писать.
Решение — отдельный init.d-скрипт, пронумерованный так, чтобы стартовать
раньше `S24xray`:

```sh
# /opt/etc/init.d/S23xray-logdir
#!/bin/sh
mkdir -p /tmp/xray-logs
```

(создаётся `install.sh`, см.
[install-and-process-management.md](install-and-process-management.md#boot-порядок))
