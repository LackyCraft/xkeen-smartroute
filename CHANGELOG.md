# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/). Версии — по
схеме проекта, см. [docs/release-process.md](docs/release-process.md) (не
классический SemVer «breaking changes», а по значимости релиза).

## [Unreleased]

### Добавлено

- **Double VPN** — опциональный дополнительный хоп перед всеми остальными
  outbound'ами: выбираете группу серверов-«шлюзов», SmartRoute сам постоянно
  выбирает из неё самый быстрый живой и релеит через него весь остальной
  трафик (и обычные подключения, и собственные проверки живости других
  серверов). Отдельная вкладка в LuCI и в панели SmartRoute. Подробности —
  [docs/functionality_doc/doublevpn.md](docs/functionality_doc/doublevpn.md).
