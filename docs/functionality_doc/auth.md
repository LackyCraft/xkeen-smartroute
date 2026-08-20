# Пароль и сессии панели gateway

Источник: [`gateway/auth.go`](../../gateway/auth.go) (~300 строк).

## Содержание

- [Модель: один общий пароль, как у xkeen-UI](#модель-один-общий-пароль-как-у-xkeen-ui)
- [Хранение пароля](#хранение-пароля)
- [Сессии: в памяти, не на диске](#сессии-в-памяти-не-на-диске)
- [Троттлинг подбора пароля](#троттлинг-подбора-пароля)
- [Публичные пути: что доступно без сессии](#публичные-пути-что-доступно-без-сессии)
- [Реальный баг: rpcd сам стучится в gateway изнутри роутера](#реальный-баг-rpcd-сам-стучится-в-gateway-изнутри-роутера)

## Модель: один общий пароль, как у xkeen-UI

До этого рефакторинга панель на порту 1001 могла только показывать
данные и переключать текущий сервер профиля (`PUT /proxies/{name}`) —
теперь через RPC-мост ([rpc-bridge.md](rpc-bridge.md)) она может
редактировать подписки/профили/kill-switch/защиту от утечек, то есть
получила ту же силу действия, что и LuCI. Модель авторизации — простая
намеренно: один общий пароль на всю панель (не multi-user), сессия по
cookie — то же самое, что уже предлагает xkeen-UI (`install.sh`
предлагает задать пароль при установке для обоих сразу, один и тот же
рекомендуется для роутера/xkeen-UI/панели).

```go
// Optional password gate for the gateway's own panel. ... this only adds
// a login step in front of the panel UI and its APIs, matching the same
// "simple shared password" model xkeen-UI already offers ... No password
// configured at all ... means auth is simply off, same as today.
```

([`gateway/auth.go:1-8`](../../gateway/auth.go#L1-L8))

## Хранение пароля

```go
func hashPassword(pw string) string {
	sum := sha256.Sum256([]byte("xkeen-smartroute-gateway:" + pw))
	return hex.EncodeToString(sum[:])
}
```

([`gateway/auth.go:38-41`](../../gateway/auth.go#L38-L41))

Простой `sha256` с фиксированным проектным префиксом (не соль на
запись) — осознанный компромисс: цель не устоять перед offline-атакой
на украденный файл хеша (это одна общая парольная фраза для домашней
LAN-панели, не multi-tenant логин-система), а просто не хранить
plaintext-пароль на диске. Файл — `/etc/xkeen-smartroute/state/gateway_password_hash`,
права `0o600`. Отсутствие файла (или пустое содержимое) означает
`authEnabled() == false` — панель полностью открыта, как и раньше.

## Сессии: в памяти, не на диске

```go
type sessionStore struct {
	mu   sync.Mutex
	byID map[string]time.Time // token -> expiry
}
```

([`gateway/auth.go:67-70`](../../gateway/auth.go#L67-L70))

32 случайных байта на токен (`crypto/rand`), TTL 7 дней со скользящим
продлением при каждой успешной проверке (`sessionStore.valid()`
обновляет expiry). Перезапуск процесса `smartroute-gateway` разлогинивает
всех — приемлемо для этого уровня "простой пароль", персистентность не
стоила бы усложнения.

## Троттлинг подбора пароля

```go
func (l *loginLimiter) allow(ip string) bool {
	cutoff := time.Now().Add(-5 * time.Minute)
	recent := l.fails[ip][:0]
	for _, t := range l.fails[ip] {
		if t.After(cutoff) { recent = append(recent, t) }
	}
	l.fails[ip] = recent
	return len(recent) < 10
}
```

([`gateway/auth.go:122-134`](../../gateway/auth.go#L122-L134))

Не более 10 неудачных попыток за скользящее окно в 5 минут, на IP.
Достаточно, чтобы сделать подбор непрактичным на LAN-фейсинге с одним
паролем, не превращая опечатку в блокировку.

## Публичные пути: что доступно без сессии

```go
func isPublicPath(p string) bool {
	switch p {
	case "/api/login", "/api/auth/status":
		return true
	}
	if p == "/" { return true }
	switch filepath.Ext(p) {
	case ".html", ".css", ".js", ".png", ".svg", ".ico", ".webmanifest":
		return true
	}
	return false
}
```

([`gateway/auth.go:276-289`](../../gateway/auth.go#L276-L289))

Сама SPA-оболочка и её статика (HTML/CSS/JS/логотип) всегда доступны —
в них нет ничего чувствительного, а с чего-то экран логина должен
загрузиться. Всё, что несёт данные — каждый вызов `/api/call/{method}`
(см. [rpc-bridge.md](rpc-bridge.md)), Clash-совместимые ручки, оба
WebSocket'а (`/traffic`, `/logs`) — требует валидной сессии, как только
задан пароль.

## Реальный баг: rpcd сам стучится в gateway изнутри роутера

Найдено и исправлено вживую сразу после первого включения авторизации:
точка "online now" в LuCI (`GET /activity` через rpcd) внезапно
навсегда потухла. Причина — сам rpcd-скрипт, обслуживая LuCI-запрос
`get_activity`, делает **свой собственный** внутренний HTTP-запрос к
gateway:

```sh
out="$(curl -s -m 2 http://127.0.0.1:1001/activity 2>/dev/null)"
```

(rpcd-скрипт, метод `get_activity`)

Как только на панели появился пароль, `requireAuth()` стал требовать
сессию **у всех** запросов без исключения — включая этот внутренний
`curl`, у которого, конечно, нет и не может быть браузерной cookie-сессии.
Исправление — не трогать LuCI-сторону вообще, а признать на стороне
gateway: запрос, реально пришедший с loopback-адреса, уже обладает
root-эквивалентным доступом к роутеру (это и есть то, как сам
rpcd-скрипт достигает gateway):

```go
func isLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil { host = r.RemoteAddr }
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
```

([`gateway/auth.go:164-180`](../../gateway/auth.go#L164-L180))

Намеренно читает только `r.RemoteAddr` (реальный TCP-адрес пира,
который записал сам listener Go) — никогда `X-Forwarded-For`
(клиент-предоставляемый заголовок, тривиально подделываемый); перед
этим gateway никакого reverse-proxy нет, так что подменить
`RemoteAddr` снаружи нельзя. Пароль защищает LAN-фасад панели, а не
общение роутера самого с собой.
