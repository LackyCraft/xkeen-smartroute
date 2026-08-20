# Что gateway знает о живом Xray: телеметрия

Источники: [`gateway/xray.go`](../../gateway/xray.go),
[`gateway/failover.go`](../../gateway/failover.go),
[`gateway/activity.go`](../../gateway/activity.go),
[`gateway/traffic_by_profile.go`](../../gateway/traffic_by_profile.go).

## Содержание

- [gRPC-клиент: три сервиса Xray](#grpc-клиент-три-сервиса-xray)
- [failover.go теперь мёртвый код](#failover-go-теперь-мёртвый-код)
- [health.json: устойчивость данных между рестартами](#healthjson-устойчивость-данных-между-рестартами)
- [Точка "online now": activity.go](#точка-online-now-activityго)
- [Трафик по профилю: агрегация без отдельного цикла](#трафик-по-профилю-агрегация-без-отдельного-цикла)

## gRPC-клиент: три сервиса Xray

`xrayClient` — один ленивый gRPC-коннект к `127.0.0.1:10085`
(включается через `00_api.smartroute.json`), три обёрнутых сервиса:

```go
type xrayClient struct {
	conn        *grpc.ClientConn
	stats       statscmd.StatsServiceClient
	observatory obscmd.ObservatoryServiceClient
	routing     routercmd.RoutingServiceClient
}
```

([`gateway/xray.go:26-31`](../../gateway/xray.go#L26-L31))

- **`StatsService`** — счётчики трафика (`queryTraffic`,
  `queryOutboundTrafficByTag`). Включаются `policy.system`-блоком в
  `00_api.smartroute.json`, не сами по себе.
- **`ObservatoryService.GetOutboundStatus`** — реальный статус
  прощупывания каждого outbound'а: настоящее
  VLESS/REALITY-соединение + HTTP-запрос через него, не голый TCP-connect
  (см. [balancer.md](balancer.md) про то, почему это принципиально —
  REALITY-узел с битой камуфляжной сертификацией отвечает на TCP
  мгновенно, но реальный proxy-запрос через него стабильно падает).
- **`RoutingService.GetBalancerInfo`/`OverrideBalancerTarget`** — API
  для управления Xray-балансером. Формально всё ещё используется
  `failover.go` — но см. ниже, почему это сейчас никогда не срабатывает.

## failover.go теперь мёртвый код

**Важно для точности документации**: `failover.go` был написан, чтобы
патчить дыру в собственном `leastPing`-балансере Xray (не демотирует
узел с битым REALITY-хендшейком, даже когда Observatory уже видит его
мёртвым — [XTLS/Xray-core#5295](https://github.com/XTLS/Xray-core/issues/5295)),
принудительно переключая `RoutingService.OverrideBalancerTarget` на
живой узел каждые 20 секунд:

```go
func reconcileBalancer(ctx context.Context, xc *xrayClient, balancerTag string, candidates []string, health map[string]outboundHealth) {
	info, err := xc.getBalancerInfo(ctx, balancerTag)
	if err != nil {
		log.Printf("failover: getBalancerInfo(%s): %v", balancerTag, err)
		return
	}
	...
}
```

([`gateway/failover.go:81-86`](../../gateway/failover.go#L81-L86))

С момента находки другого, куда более серьёзного бага Xray-core —
**любое** правило с `balancerTag` в `routing.rules` полностью ломает
совпадение вообще всех правил маршрутизации
([XTLS/Xray-core#6642](https://github.com/XTLS/Xray-core/issues/6642),
подробно разобрано в [balancer.md](balancer.md)) — `genroute.sh`
больше **никогда** не эмитит `balancerTag`-правило и удаляет
`09_balancer.smartroute.json` на каждом regen. Значит тега вида
`bal_<профиль>`, который `reconcileBalancer()` пытается опросить, в
живом конфиге Xray физически не существует — `GetBalancerInfo` **всегда**
проваливается на первой же строке функции с ошибкой
`app/router: cannot find tag`, и функция сразу возвращается, ничего не
сделав.

Это подтверждено вживую — реальный, постоянный лог с боевого роутера:

```
failover: getBalancerInfo(bal_Claude): rpc error: code = Unknown desc = app/router: cannot find tag
failover: getBalancerInfo(bal_Telegram): rpc error: code = Unknown desc = app/router: cannot find tag
```

**Что именно мертво, а что нет**: `startFailoverLoop()`
([`gateway/failover.go:40-48`](../../gateway/failover.go#L40-L48)) по-прежнему
каждые 20 секунд вызывает `queryOutboundHealth()` и
`persistHealth()` — **это** часть полностью рабочая и критически
важная (`health.json` — прямая зависимость `sr_pick_top1`, см.
[balancer.md](balancer.md)). Мёртв конкретно цикл `for _, p := range
profiles { ... reconcileBalancer(...) }` внутри `runFailoverTick()`
([`gateway/failover.go:73-78`](../../gateway/failover.go#L73-L78)) — он
запускается, честно логирует неудачу и ничего не меняет, каждые 20
секунд, для каждого `balancer`-режим профиля. Безвредно (просто шум в
логе), но не выполняет то, что описано в комментарии наверху файла —
эта документация фиксирует расхождение явно, а не молчит о нём.

Не убрано специально: если апстрим когда-нибудь починит
`XTLS/Xray-core#6642` и `balancerTag`-правила снова станут безопасны,
эта логика немедленно снова заработает как задумано без единой правки
кода — она уже правильно реагирует на "тега нет" через `err != nil`.

## health.json: устойчивость данных между рестартами

`persistHealth()` **мёржит**, а не перезаписывает — Xray-шный
Observatory сбрасывает весь прогресс прощупывания на каждом рестарте, и
для сотни с лишним серверов полное покрытие занимает больше часа
(~20-30с на сервер). Простая перезапись стёрла бы вердикт по каждому
ещё не переопрошенному тегу немедленно на рестарте — именно тогда,
когда `sr_pick_top1` и колонка Observatory на UI в нём больше всего
нуждаются:

```go
func persistHealth(health map[string]outboundHealth) {
	merged := map[string]outboundHealth{}
	if old, err := os.ReadFile(healthStateFile); err == nil {
		_ = json.Unmarshal(old, &merged)
	}
	for tag, h := range health {
		merged[tag] = h
	}
	...
	tmp := healthStateFile + ".tmp"
	os.WriteFile(tmp, b, 0o644)
	os.Rename(tmp, healthStateFile)
}
```

([`gateway/failover.go:151-178`](../../gateway/failover.go#L151-L178))

Атомарная запись через временный файл + `rename` — не случайная
предосторожность: этот код пишет файл каждые 20 секунд весь день;
прямая `os.WriteFile` в целевой путь, оборвись питание точно в момент
записи, оставила бы битый файл, а `json.Unmarshal` на следующем старте
тихо проглотил бы ошибку (`_ = json.Unmarshal(...)`) и код счёл бы это
"старых данных нет", переписав файл почти пустым — вживую найденная и
исправленная проблема.

## Точка "online now": activity.go

Отдельный, куда более быстрый механизм от `health.json` — реагирует за
секунды, не минуты/часы. Не пишется на диск вообще:

```go
// That needs a signal that reacts within a couple of seconds, which rules
// out piggybacking on health.json ... refreshed every 20s -- both too slow
// for "right now" and, if pushed to a 3-5s cadence instead, exactly the
// kind of constant-flash-write pattern already rejected once this project.
// So this state lives only in this process's memory ...
const activityInterval = 3 * time.Second
const activityWindow = 8 * time.Second
```

([`gateway/activity.go:10-27`](../../gateway/activity.go#L10-L27))

Каждые 3 секунды снимается срез трафика по тегам
(`queryOutboundTrafficByTag`), сравнивается с предыдущим снимком — тег
считается "активным", если хоть один из счётчиков (up/down) вырос:

```go
for tag, t := range cur {
	if p := prev[tag]; t.Up > p.Up || t.Down > p.Down {
		activityLast[tag] = now
	}
}
```

([`gateway/activity.go:56-59`](../../gateway/activity.go#L56-L59))

`activityWindow` (8с) чуть больше одного интервала (3с) — чтобы один
случайно медленный тик не мигнул реально активным тегом как "потух".
Это и есть источник данных для зелёной точки "online now" на вкладке
Профили — полностью независимый от Observatory/`health.json`: точка
показывает, реально ли **прямо сейчас** идёт трафик через конкретный
outbound, а не жив ли он в принципе (см.
[docs/UI_functionality/profiles.md](../UI_functionality/profiles.md#точка-online-now--что-она-реально-означает)).

## Трафик по профилю: агрегация без отдельного цикла

`handleTrafficByProfile()` — не отдельный тикер, а бесстейтовое чтение
по запросу: те же кумулятивные счётчики `activity.go` уже опрашивает,
но суммированные до уровня профиля вместо тега.

Ключевая тонкость: пул `balancer`-профиля (`.servers`) — это **весь
кандидатный набор** (10-50 тегов), не то, через что реально сейчас
идёт трафик, и пулы разных профилей в реальности пересекаются
(подтверждено вживую: один и тот же сервер числится кандидатом сразу у
трёх разных профилей тестовой подписки). Суммирование по всему пулу
задвоило/затроило бы трафик такого общего сервера в каждый профиль, где
он просто **упомянут**, а не реально используется:

```go
for _, p := range profiles {
	tag := p.FixedServer
	if p.Mode != "fixed" {
		tag = current[p.Name]
	}
	t := byTag[tag]
	out = append(out, profileTraffic{Name: p.Name, Up: t.Up, Down: t.Down})
}
```

([`gateway/traffic_by_profile.go:48-56`](../../gateway/traffic_by_profile.go#L48-L56))

`current.json` (тот же файл, что и точка "online now" в таблице
профилей) — единственный источник "какой тег реально выбран прямо
сейчас" для `balancer`-режима; только его трафик и засчитывается в
профиль.
