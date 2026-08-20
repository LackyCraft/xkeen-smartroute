# smartroute-gateway: архитектура

Источник: [`gateway/`](../../gateway/) (Go, ~2000 строк, отдельный
`go.mod`). Бинарник `smartroute-gateway`, слушает порт 1001.

## Содержание

- [Зачем свой сервис, а не готовый Mihomo](#зачем-свой-сервис-а-не-готовый-mihomo)
- [Единственный источник истины](#единственный-источник-истины)
- [Файловая структура](#файловая-структура)
- [Как читаются состояния (smartroute.go)](#как-читаются-состояния-smartroutego)
- [Единственный путь записи: PUT /proxies/{name}](#единственный-путь-записи-put-proxiesname)
- [Процесс: сборка, деплой, боевой цикл](#процесс-сборка-деплой-боевой-цикл)

## Зачем свой сервис, а не готовый Mihomo

`smartroute-gateway` **не** запускает настоящий Mihomo/Clash-core — это
собственный Go-сервис, который читает состояние SmartRoute (те же
файлы, что пишут `lib/subscription.sh`/`lib/genroute.sh`) и настоящий
gRPC API самого Xray, и отдаёт их наружу в форме, которую понимают
готовые Clash-API дашборды (yacd, metacubexd) — а с версии этого
рефакторинга ещё и собственная standalone-панель
(`gateway/static/`, см. [rpc-bridge.md](rpc-bridge.md)).

```go
// smartroute-gateway bridges Xray-core's own gRPC API and SmartRoute's
// on-disk state (servers.json / profiles/*.json, the same files
// lib/subscription.sh and lib/genroute.sh already own) to a REST+WebSocket
// surface shaped like the "Clash API" -- the protocol yacd/metacubexd (and
// Mihomo itself) speak.
```

([`gateway/main.go:1-7`](../../gateway/main.go#L1-L7))

## Единственный источник истины

Явный архитектурный принцип, повторяющийся во всех файлах пакета:
**никакой второй копии состояния**. Чтение — напрямую из файлов
SmartRoute; единственный путь записи (`PUT /proxies/{name}`) идёт через
`lib/genroute.sh`, а не через параллельное хранилище конфига.

```go
// Deliberately NOT a second source of truth: reading happens straight from
// SmartRoute's files, and the one write path (PUT /proxies/{group}) goes
// through lib/genroute.sh, not a parallel config store.
```

([`gateway/main.go:9-11`](../../gateway/main.go#L9-L11))

Тот же принцип теперь распространён и на управление
подписками/профилями/kill-switch/защитой от утечек через панель:
`gateway/rpc.go` не переизобретает эту логику, а **exec'ает тот же
самый rpcd-скрипт**, что использует LuCI — см.
[rpc-bridge.md](rpc-bridge.md).

## Файловая структура

| Файл | Роль |
|---|---|
| [`main.go`](../../gateway/main.go) | Точка входа, регистрация HTTP/WS маршрутов, запуск фоновых циклов |
| [`smartroute.go`](../../gateway/smartroute.go) | Чтение `servers.json`/`profiles/*.json`/`ping.json`/`current.json` |
| [`handlers.go`](../../gateway/handlers.go) | Clash-API-совместимые `/proxies`, `/rules`, `/connections`, `/configs` |
| [`xray.go`](../../gateway/xray.go) | gRPC-клиент к самому Xray (`StatsService`/`ObservatoryService`/`RoutingService`) |
| [`failover.go`](../../gateway/failover.go) | Автоматический failover балансера — **см. предостережение в [gateway-telemetry.md](gateway-telemetry.md#failover-go-теперь-мёртвый-код)** |
| [`activity.go`](../../gateway/activity.go) | In-memory "кто сейчас реально гонит трафик" для точки "online now" |
| [`traffic_by_profile.go`](../../gateway/traffic_by_profile.go) | Кумулятивный трафик по профилю для дашборда Home |
| [`logs.go`](../../gateway/logs.go) | Живой вьюер логов Xray — [logging.md](logging.md) |
| [`auth.go`](../../gateway/auth.go) | Пароль/сессии панели — [auth.md](auth.md) |
| [`rpc.go`](../../gateway/rpc.go) | Мост к rpcd-скрипту — [rpc-bridge.md](rpc-bridge.md) |
| [`static/`](../../gateway/static/) | Сама панель (vanilla JS, без сборки) |

## Как читаются состояния (smartroute.go)

`smartroute.go` — единственное место, где Go-код знает про формат
файлов, которыми на самом деле владеет shell-код:

```go
const (
	serversFile = "/etc/xkeen-smartroute/state/servers.json"
	pingFile    = "/etc/xkeen-smartroute/state/ping.json"
	currentFile = "/etc/xkeen-smartroute/state/current.json"
	profilesDir = "/etc/xkeen-smartroute/profiles"
)
```

([`gateway/smartroute.go:13-18`](../../gateway/smartroute.go#L13-L18))

Каждый `load*()` — просто чтение JSON-файла с толерантностью к
"файла ещё нет" (`os.IsNotExist` → пустой результат, не ошибка — на
свежей установке до первого импорта подписки ни один из этих файлов
ещё не существует). `loadCurrent()` заслуживает отдельного упоминания:

```go
// loadCurrent reads current.json (profile name -> the outbound tag
// lib/genroute.sh's sr_pick_top1 most recently picked for it, written on
// every regen alongside routing.smartroute.json). For "fixed" mode this
// duplicates FixedServer; for "balancer" mode it's the only way to know
// which pool member is actually live right now, since that choice is made
// entirely in shell/jq and never reported back through Xray's own API.
```

([`gateway/smartroute.go:77-82`](../../gateway/smartroute.go#L77-L82))

Это прямое следствие того, что выбор топ-1 сервера — целиком в
shell/jq ([balancer.md](balancer.md)), а не в Xray-балансере: у Go-кода
нет иного способа узнать текущий выбор, кроме как прочитать тот же файл,
что пишет `genroute.sh`.

## Единственный путь записи: PUT /proxies/{name}

`handleSelectProxy()` в `handlers.go` — единственная мутирующая ручка
в Clash-совместимом слое. Она **не** пишет routing напрямую — собирает
изменённый объект профиля и передаёт его туда же, куда пишет и UI:

```go
func saveProfile(p srProfile) error {
	b, _ := json.Marshal(p)
	tmp, _ := os.CreateTemp("", "sr-profile-*.json")
	...
	cmd := exec.Command("sh", genrouteScript, "save", tmp.Name())
	out, err := cmd.CombinedOutput()
	...
}
```

([`gateway/handlers.go:210-232`](../../gateway/handlers.go#L210-L232))

Это тот же `genroute.sh save`, что и rpcd-скрипт вызывает из LuCI, и
что кнопка "Сохранить" в панели вызывает через RPC-мост — единая точка
входа, единая валидация, единый рестарт Xray
([routing-generation.md](routing-generation.md)).

`handleDelay()` — TCP+TLS connect-таймер, независимый от общего пинга
`lib/subscription.sh` (тот же принцип: измеряется голое время
установления соединения, не полноценный proxy-хендшейк).

## Процесс: сборка, деплой, боевой цикл

Кросс-компилируется в CI (`.github/workflows/build-gateway.yml`) под
5 архитектур (`mipsle`/`mips`/`arm7`/`arm64`/`amd64`,
`CGO_ENABLED=0`), публикуется в rolling-релиз `gateway-latest`.
`install.sh` качает готовый бинарник — сборка на самом роутере не
происходит никогда (Entware не тащит toolchain).

На роутере процессом управляет собственный init.d-скрипт
(`/opt/etc/init.d/S98smartroute-gateway`), не procd/systemd (ни один
из них не входит в Entware) — тот же ручной pgrep+kill+relaunch
паттерн, что и у `lib/common.sh`'s `sr_restart_xray`, см.
[install-and-process-management.md](install-and-process-management.md).
