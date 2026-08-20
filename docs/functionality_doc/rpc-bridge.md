# Один backend, два UI: rpcd-скрипт и мост gateway

Источники:
[`luci-app-xkeen-smartroute/root/usr/libexec/rpcd/luci.xkeen-smartroute`](../../luci-app-xkeen-smartroute/root/usr/libexec/rpcd/luci.xkeen-smartroute)
(~850 строк shell), [`gateway/rpc.go`](../../gateway/rpc.go).

## Содержание

- [rpcd-скрипт как самодостаточный CLI](#rpcd-скрипт-как-самодостаточный-cli)
- [ACL: два уровня доступа для LuCI](#acl-два-уровня-доступа-для-luci)
- [gateway/rpc.go: тот же скрипт, другой транспорт](#gatewayrpcgo-тот-же-скрипт-другой-транспорт)
- [Allow-list читается из схемы, а не дублируется](#allow-list-читается-из-схемы-а-не-дублируется)
- [Почему это безопасно без своего ACL на стороне gateway](#почему-это-безопасно-без-своего-acl-на-стороне-gateway)

## rpcd-скрипт как самодостаточный CLI

Формально это ubus/rpcd script-protocol бэкенд для LuCI — но сам
протокол крайне простой и не завязан на ubus как таковой:

```sh
# Protocol: `list` prints the method schema, `call <method>` reads JSON args
# from stdin and prints a JSON result.
```

([rpcd-скрипт:5-6](../../luci-app-xkeen-smartroute/root/usr/libexec/rpcd/luci.xkeen-smartroute#L5-L6))

`list` печатает JSON-схему всех методов (имя → ожидаемые параметры),
`call <method>` читает JSON-аргументы из stdin и печатает JSON-результат
в stdout. rpcd — только один из способов дойти досюда; сам скрипт можно
вызвать и напрямую как обычный shell-процесс, что и делает
`gateway/rpc.go`.

Каждый метод внутри — тонкая обёртка над реальной логикой в
`lib/*.sh`:

```sh
list_servers)
	wrap_array servers "$(sh "$LIB_DIR/subscription.sh" list 2>/dev/null)"
	;;
```

`wrap_array()` существует из-за отдельного технического ограничения
rpcd: голый JSON-массив на верхнем уровне результата отклоняется
("Invalid argument") — каждый массив-результат оборачивается в объект
(`{"servers": [...]}`) перед выдачей.

## ACL: два уровня доступа для LuCI

Для пути через ubus (LuCI) есть отдельный ACL-файл
([`acl.d/luci-app-xkeen-smartroute.json`](../../luci-app-xkeen-smartroute/root/usr/share/rpcd/acl.d/luci-app-xkeen-smartroute.json)),
разделяющий методы на `read` и `write` группы — это то, что не даёт
непривилегированной LuCI-сессии вызвать мутирующий метод, даже если она
как-то узнает его имя. rpcd подгружает этот файл при своём старте
(поэтому `install.sh` рестартует `rpcd` после каждого обновления
скрипта/ACL).

## gateway/rpc.go: тот же скрипт, другой транспорт

Панель на порту 1001 — это **не** второй набор бизнес-логики. Вместо
повторной реализации subscription/profile/kill-switch/leak-protection
CRUD на Go, `rpc.go` просто **exec'ает тот же самый скрипт**:

```go
func (b *rpcBridge) call(ctx context.Context, method string, args json.RawMessage) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", b.script, "call", method)
	if len(args) > 0 {
		cmd.Stdin = bytes.NewReader(args)
	} else {
		cmd.Stdin = bytes.NewReader([]byte("{}"))
	}
	out, err := cmd.Output()
	...
	return json.RawMessage(out), nil
}
```

([`gateway/rpc.go:66-84`](../../gateway/rpc.go#L66-L84))

`POST /api/call/{method}` в `main.go` — единственная точка входа для
всей функциональности подписок/профилей/kill-switch/защиты от утечек в
новой панели ([`gateway/static/app.js`](../../gateway/static/app.js)'s
`apiCall()` — просто `fetch('/api/call/'+method, {body: JSON.stringify(args)})`).
Нулевое дублирование логики, нулевой риск разойтись поведением между
LuCI и панелью — оба буквально вызывают одну и ту же функцию в одном и
том же shell-скрипте.

## Allow-list читается из схемы, а не дублируется

```go
func (b *rpcBridge) refreshMethods() {
	out, err := exec.Command("sh", b.script, "list").Output()
	...
	var schema map[string]json.RawMessage
	json.Unmarshal(out, &schema)
	methods := make(map[string]struct{}, len(schema))
	for name := range schema {
		methods[name] = struct{}{}
	}
	b.methods = methods
}
```

([`gateway/rpc.go:42-59`](../../gateway/rpc.go#L42-L59))

При старте gateway один раз вызывает `sh <script> list` и строит
allow-list методов прямо из реальной схемы скрипта — не хардкодит
список имён вторым местом, которое рано или поздно разойдётся с
`case "$method" in ...` внутри самого скрипта. Метод, которого нет в
этой схеме, отклоняется на уровне HTTP-хендлера (`404 unknown_method`)
ещё до вызова `exec` — тот же эффект, что дал бы явный allow-list, без
второй копии для поддержки.

## Почему это безопасно без своего ACL на стороне gateway

В отличие от rpcd/LuCI, `gateway/rpc.go` **не разделяет** методы на
read/write — весь список из `list` одинаково доступен через
`/api/call/{method}`, включая мутирующие (`save_profile`,
`killswitch_set`, `redirect_set_enabled`, ...). Это осознанно: панель
gateway уже требует прохождения `requireAuth()` (см.
[auth.md](auth.md)) для **любого** нестатического запроса, как только
задан пароль — граница доступа проведена на уровне "залогинен ли
вообще", а не "какой конкретно метод разрешён этой сессии". Ровно тот
же уровень доверия, что уже был у остальной части gateway (он и так
управляет Xray/`servers.json`/профилями напрямую в других частях
кодовой базы — см. [gateway-architecture.md](gateway-architecture.md)) —
`rpc.go` не открывает ничего нового, чего процесс не мог бы и так.
