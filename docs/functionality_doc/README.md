# Документация по функциональности (code-level)

Как устроен код изнутри: почему конкретное решение принято именно так,
какие реальные баги оно закрывает, куда смотреть в исходниках. Не
путать с [docs/UI_functionality/](../UI_functionality/) — та папка
объясняет вкладки LuCI с точки зрения пользователя ("что нажать и что
это значит"); эта — с точки зрения того, кто читает или меняет код.

Каждый документ цитирует реальный код с прямыми ссылками на файл и
диапазон строк. Если код с тех пор изменился — верить коду, не тексту;
эти файлы не тестируются автоматически на соответствие исходникам.

## Подписки и профили

- [subscription-import.md](subscription-import.md) — парсинг `vless://`/`trojan://`,
  обход anti-bot защиты подписок, генерация уникального тега сервера
  (история трёх коллизий), поле XHTTP `extra`, атомарность импорта.
- [subscription-update.md](subscription-update.md) — что происходит с
  тегами профилей при обновлении подписки: `match_key`, remap,
  `.removed_servers`.
- [routing-generation.md](routing-generation.md) — как `genroute.sh`
  превращает профиль (домены/устройства/IP-диапазоны, fixed/balancer)
  в правила маршрутизации Xray.
- [balancer.md](balancer.md) — алгоритм выбора топ-1 сервера
  (`sr_pick_top1`) и приоритетный Observatory-scheduler на основе
  "протухания".
- [doublevpn.md](doublevpn.md) — Double VPN: релей всего трафика (и
  Observatory-проб) через один выбранный шлюз, `sockopt.dialerProxy`,
  почему это не самодельный туннель.

## Firewall и защита

- [leak-protection.md](leak-protection.md) — перехват LAN-трафика
  через nftables (`redirect.sh`), почему не `xkeen -ap`, DNS/IPv6/QUIC
  защита.
- [kill-switch.md](kill-switch.md) — dnsmasq+ipset+nftables изнутри,
  почему geosite не даёт 100% покрытия, известный пробел с `ip_ranges`.

## Панель smartroute-gateway (порт 1001)

- [gateway-architecture.md](gateway-architecture.md) — зачем свой
  Clash-API мост вместо настоящего Mihomo, структура сервиса, принцип
  "нет второй копии состояния".
- [gateway-telemetry.md](gateway-telemetry.md) — как gateway узнаёт,
  что происходит в Xray: gRPC-клиент, health-polling, точка "online
  now", трафик по профилю. Включает честную заметку про то, что
  автоматический failover-цикл балансера был мёртвым кодом и теперь
  явно закомментирован (с объяснением, при каком условии его вернуть).
- [rpc-bridge.md](rpc-bridge.md) — rpcd-скрипт как общий backend для
  LuCI и новой панели: один источник бизнес-логики, два транспорта.
- [logging.md](logging.md) — переключаемые логи Xray: почему были
  пустыми везде, tmpfs + жёсткий лимит размера.
- [auth.md](auth.md) — пароль/сессии панели, и реальный баг с
  loopback-исключением для внутренних запросов rpcd.

## Установка и эксплуатация

- [install-and-process-management.md](install-and-process-management.md) —
  `install.sh`, жизненный цикл процесса Xray (валидация/запуск/рестарт),
  boot-порядок, расписание cron.

## Смежное

- [docs/UI_functionality/](../UI_functionality/) — те же фичи, но с
  точки зрения UI/пользователя.
- [docs/release-process.md](../release-process.md) — схема веток и
  релизов проекта.
- [AGENTS.md](../../AGENTS.md) — сжатый журнал находок для агента,
  разворачивающего проект на реальном роутере (полезен как быстрый
  индекс "что уже было сломано и как чинили", в дополнение к этим
  документам).
