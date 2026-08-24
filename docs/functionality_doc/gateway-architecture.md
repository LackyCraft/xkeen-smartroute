# smartroute-gateway: архитектура

Источник: [`gateway/`](../../gateway/) (Go, ~2000 строк, отдельный
`go.mod`). Бинарник `smartroute-gateway`, слушает порт 1001.

## Содержание

- [Зачем свой сервис, а не готовый Mihomo](#зачем-свой-сервис-а-не-готовый-mihomo)
- [Единственный источник истины](#единственный-источник-истины)
- [Файловая структура](#файловая-структура)
- [Как читаются состояния (smartroute.go)](#как-читаются-состояния-smartroutego)
- [Единственный путь записи: PUT /proxies/{name}](#единственный-путь-записи-put-proxiesname)
- [Same-origin: CORS, Host, WebSocket](#same-origin-cors-host-websocket)
- [`http.Server`: таймауты и WS-keepalive](#httpserver-таймауты-и-ws-keepalive)
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
| [`failover.go`](../../gateway/failover.go) | `health.json`-polling (живое) + балансер-reconciliation (сейчас закомментирована) — см. [gateway-telemetry.md](gateway-telemetry.md#failover-go-балансер-reconciliation-отключена) |
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

([`gateway/handlers.go:217-239`](../../gateway/handlers.go#L217-L239))

Это тот же `genroute.sh save`, что и rpcd-скрипт вызывает из LuCI, и
что кнопка "Сохранить" в панели вызывает через RPC-мост — единая точка
входа, единая валидация, единый рестарт Xray
([routing-generation.md](routing-generation.md)).

`srProfile` (`smartroute.go`) обязан перечислять **каждое** поле, которое
реально может быть в файле профиля, не только те, что использует эта
конкретная ручка — `json.Unmarshal` в Go молча отбрасывает поля JSON, у
которых нет соответствующего поля структуры, а `json.Marshal` при записи
обратно просто не напишет то, чего не было прочитано. Подтверждено
вживую: `devices`/`ip_ranges`/`removed_servers` отсутствовали в
структуре — выбор конкретного сервера через `PUT /proxies/{name}`
(например, дашбордом yacd/metacubexd) молча стирал ограничение профиля
по устройствам/IP-диапазонам при следующем же сохранении через этот
путь, хотя сам пользователь ничего такого не трогал.

`handleDelay()` — TLS-хендшейк-таймер (не голый TCP-connect, несмотря
на то что комментарий в коде когда-то утверждал обратное — все узлы,
для которых этот проект вообще генерирует outbound'ы, говорят
VLESS/Trojan поверх TLS или REALITY), независимый от общего пинга
`lib/subscription.sh`. `?timeout=` теперь ограничен 15 секундами
сверху — раньше клиент мог запросить произвольно большое значение и
держать goroutine с диалером открытой сколько угодно, по одной на
каждый такой запрос.

## Same-origin: CORS, Host, WebSocket

При отсутствии пароля (задокументированный дефолт) единственная
граница, отделяющая эту панель от любой веб-страницы, которую LAN-юзер
открыл в соседней вкладке — это same-origin-проверка на уровне HTTP.
Раньше её не было вообще:

```go
func sameOriginHost(origin, host string) bool {
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	return u.Host == host
}
```

([`gateway/main.go:133-142`](../../gateway/main.go#L133-L142))

`corsWrap` отражает `Origin` обратно только когда он совпадает с
`r.Host` этого же запроса (а не хардкодит allowlist конкретных
адресов — работает независимо от того, по какому LAN IP/hostname
реально открыта панель), и отвечает на preflight сам, а не через
отдельный вечно висящий маршрут `OPTIONS /`
([`gateway/main.go:153-168`](../../gateway/main.go#L153-L168)). Та же
проверка используется в `upgrader.CheckOrigin`
([`gateway/main.go:175-179`](../../gateway/main.go#L175-L179)) — раньше
было `CheckOrigin: func(r *http.Request) bool { return true }`, то есть
**любой** сайт мог открыть кросс-сайтовый WebSocket к `/traffic` или
`/logs` и стримить чужой роутерный лог посещённых доменов.

Найдено вживую при проверке: одного `corsWrap` было недостаточно —
`writeJSON` (handlers.go) и `handleRPC` (rpc.go) каждый independently
ставил свой собственный хардкодный `Access-Control-Allow-Origin: *`
**поверх** уже правильно выставленного значения (`Header().Set`
замещает, не мержит) на каждом отдельном ответе — из-за этого
исправленный `corsWrap` всё равно измерялся как полностью открытый
`*` на любом реальном эндпоинте, пока оба лишних `Set()` не были
убраны.

## `http.Server`: таймауты и WS-keepalive

`http.ListenAndServe` без настроек не ограничивает ни время чтения
заголовков, ни время простоя keep-alive соединения, ни размер
заголовков — на железе такого класса это реальный slowloris-риск, не
теоретический. `main()` теперь конфигурирует `http.Server` явно
(`ReadHeaderTimeout`, `IdleTimeout`, `MaxHeaderBytes`) — ничего из
этого не действует на уже апгрейженное WebSocket-соединение, тем
занимается отдельный механизм ниже.

Ни `/traffic`, ни `/logs` раньше не читали из своего же соединения ни
байта — `gorilla/websocket` обрабатывает входящие control-фреймы
(pong, close) только пока что-то активно вызывает `ReadMessage`. Без
этого клиент, чьё TCP-соединение оборвалось не чистым FIN/RST
(телефон вышел из Wi-Fi посреди сессии, ноутбук уснул, NAT-таймаут —
не редкость), оставлял `conn.WriteJSON` буквально не с чем упасть,
пока не сработает таймаут повторных попыток самого TCP на уровне ОС
(может занять минуты) — всё это время горутина, её тикер и (для
`/traffic`) опрос Xray API раз в секунду продолжали жить ради пира,
которого уже нет. `wsKeepalive()` добавляет стандартный для
`gorilla/websocket` heartbeat — read pump плюс read-дедлайн, который
двигает только свежий pong:

```go
func wsKeepalive(conn *websocket.Conn, cancel context.CancelFunc) {
	conn.SetReadDeadline(time.Now().Add(wsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(wsPongWait))
		return nil
	})
	go func() {
		defer cancel()
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()
}
```

([`gateway/main.go:202-216`](../../gateway/main.go#L202-L216))

Используется обоими WS-хендлерами (`/traffic` в `main.go`, `/logs` в
`logs.go`) — мёртвый пир теперь обнаруживается в пределах `wsPongWait`
(30с), а не сколько бы ни занимал голый TCP.

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
