# XPowerSpirit — Linux-клиент

Прозрачный прокси-клиент Xray для **одной машины** (десктоп или сервер): трафик
самой машины перехватывается nftables (TProxy) и уходит через серверы из подписки.
Балансировка — `leastLoad`, разделение трафика на прямое и проксируемое — по
гео-правилам (RU — напрямую, остальное — через прокси).

```
подписка (URL) ──curl──> xray-sub-parser.py ──> xray-generate-config.py ──> /etc/xpower/config.json
                                                                                    │
                                                        xray run -test ─────────────┤
                                                                                    ▼
                                                     nftables (TProxy) + systemd (xray)
```

## Требования

- systemd (сервис и таймер обновления), root/sudo
- Ubuntu 20.04+, Debian 11+, Fedora 38+ (x86_64, aarch64, armv7)
- Зависимости ставятся автоматически: `curl jq python3 unzip nftables e2fsprogs`

## Установка

```bash
sudo ./install-linux.sh --sub=https://example.com/sub
```

Опции:

| Опция | Описание |
|---|---|
| `--sub=URL` | URL подписки (обязательно) |
| `--ua=USER_AGENT` | User-Agent для запроса подписки (по умолчанию `XPower/1.1`) |
| `--remarks=FILTER` | Использовать только профиль подписки, чьи remarks содержат FILTER |
| `--no-dns` | Не перенастраивать системный DNS |
| `--dry-run` | Показать план без изменений |
| `--uninstall` | Полностью удалить клиент |

Что делает установщик: ставит зависимости, скачивает Xray (с проверкой SHA256) и
geo-файлы, создаёт `/etc/xpower/settings.json`, генерирует и валидирует
`config.json`, настраивает nftables + policy routing, поднимает DNS, включает
сервис и ежедневный таймер обновления.

## Управление

```bash
xpower-client status       # статус: сервис, подписка, трафик, активные ноды
xpower-client test         # интернет, DNS через Xray, Google 204, TProxy
xpower-client traffic      # трафик по серверам (через API Xray)
xpower-client update       # обновить подписку, geo, Xray и перегенерировать конфиг
xpower-client start|stop|restart|toggle
xpower-client proxy-list   # список серверов из config.json
xpower-client config       # показать config.json
xpower-client logs         # journalctl -u xpower-client -f
xpower-client setup        # переприменить правила nftables
```

## Файлы и каталоги

| Путь | Назначение |
|---|---|
| `/opt/xpower` | скрипты установки/обновления, Xray geo-файлы (`geoip.dat`, `geosite.dat`) |
| `/etc/xpower/settings.json` | настройки (URL подписки, HWID, DNS, роутинг, API) |
| `/etc/xpower/config.json` | сгенерированный конфиг Xray |
| `/etc/xpower/state/` | статус подписки, сохранённые SHA256 (апдейтер) |
| `/var/log/xpower/` | `update.log`, `parser.log`, `generator.log`, `validate.log` |
| `/usr/local/bin/xray` | бинарник Xray |
| `/usr/local/bin/xpower-client` | CLI |
| `/etc/systemd/system/xpower-client.service`, `xpower-update.{service,timer}` | сервис и ежедневное обновление |

## Настройки (`/etc/xpower/settings.json`)

| Ключ | По умолчанию | Описание |
|---|---|---|
| `subscription.url` | — | URL подписки |
| `subscription.user_agent` | `XPower/1.1` | User-Agent запроса подписки |
| `subscription.remarks_filter` | `""` | Фильтр профиля по remarks |
| `hwid` | генерируется | Идентификатор устройства для панели (не менять без причины) |
| `mode` | `local` | Режим работы. Поддерживается только `local` |
| `dns.local_port` | 5353 / 53 | Порт локального DNS-инбаунда (выбирает установщик) |
| `dns.servers` | Yandex/Cloudflare/NextDNS | Список DNS-серверов Xray (адреса DoH и правила) |
| `dns.hosts` | адреса DoH-серверов | Статические IP для DoH-серверов (защита от петли) |
| `api.enabled` / `api.listen_port` | `true` / 10085 | API Xray для статистики (localhost) |
| `tproxy.port` | 12345 | Порт TProxy-инбаунда |
| `routing.*` | см. файл | Правила: `doh_domains`, `block_domains`, `direct_ips`, `direct_domains`, `proxy_domains` |
| `geo.geoip_url` / `geo.geosite_url` | сборки kirilllavrov | Источники geo-файлов (пусто → встроенные значения) |

После правки `settings.json` примените изменения: `xpower-client update`
(перегенерирует `config.json` и перезапустит сервис).

## Трафик и статистика

В конфиг включается API Xray (`api.listen = 127.0.0.1:10085`) и счётчики
`policy.system.stats*`. Поэтому `xpower-client status` показывает суммарный трафик
и активные ноды (ключи `outbound>>>tag>>>traffic>>>uplink|downlink`), а
`xpower-client traffic` — разбивку по всем серверам. API слушает только localhost
и обнуляется при перезапуске Xray. Отключается через `api.enabled: false`.

## Клиент и шлюз: что поддерживается

Этот проект — **локальный клиент**. Проксируется только трафик самой машины.

| | Локальный клиент (этот репозиторий) | Шлюз для LAN (`XPowerSpirit-Linux-Gateway`) |
|---|---|---|
| Цепочка nftables | `output` (трафик машины) | `output` + `prerouting` (forward) |
| Кто проксируется | сама машина | машины в локальной сети |
| Дополнительно | — | `ip_forward`, правила для forward-трафика, DHCP/DNS для клиентов |
| Настройка `mode` | `local` | см. отдельный проект |

Установка с `mode` отличным от `local` намеренно завершается ошибкой, чтобы не
создавать иллюзию работающего шлюза.

## Диагностика

| Симптом | Что делать |
|---|---|
| Нет интернета, Xray не запущен | nftables помечает трафик и уводит его в TProxy, а слушать некому. Остановите сервис через systemd (правила снимаются в `ExecStopPost`) или выполните `sudo /opt/xpower/update-nft-linux.sh --cleanup` |
| `status`: «DIRECT-режим — …» | В строке указана причина (лимит устройств, окончание подписки, профили-заглушки). Проверьте подписку/HWID у провайдера |
| Трафик идёт напрямую для части сайтов | Так задумано: RU-адреса (`geoip:ru`) и домены из `direct_domains` (например, `geosite:category-cdn-ru`) идут direct. Маршрут виден в access-логе Xray (нужен `log.loglevel: info`) |
| DNS не отвечает | Смотрите лог установки: выбранный режим DNS (`systemd-resolved` / `dnsmasq` / `resolv.conf`) и порт. При `resolvconf` Xray слушает `127.0.0.1:53` |
| Нужны детальные логи | `loglevel` в `config.json` задаётся генератором (`none`); для отладки временно поставьте `info` и перезапустите сервис |

Логи: `journalctl -u xpower-client -f`, `/var/log/xpower/update.log`,
`/var/log/xpower/parser.log`, `/var/log/xpower/validate.log`.

## Ограничения

- Проксируется только трафик локальной машины (см. раздел про шлюз).
- TProxy настроен для IPv4; IPv6-правила не добавляются.
- UDP/443 (QUIC) блокируется на уровне Xray — браузеры откатываются на TCP.
- `leastLoad` выбирает один сервер за раз: если сервер мёртв, конкретный запрос
  может не пройти (следующий запрос выберет другую ноду).
- По умолчанию логи Xray отключены (`log.loglevel: none`).

## Разработка и тесты

В репозитории есть Docker-стенд (`Dockerfile.*`, `docker-compose.yml`,
`docker-entrypoint.sh` — эти файлы в `.gitignore`, они локальные):

```bash
docker compose build fedora && docker compose up -d fedora
docker compose exec fedora bash -c 'cd /xpower && ./install-linux.sh --sub=URL'
```

В контейнере systemd не запущен, поэтому `systemctl` подменяется заглушкой, а
Xray запускается вручную:

```bash
mkdir -p /run/systemd/system   # имитация загруженного systemd (проверяется установщиком)
XRAY_LOCATION_ASSET=/opt/xpower /usr/local/bin/xray run -config /etc/xpower/config.json &
```

Образцы подписок для проверки парсера/генератора — в `tests/`:

```bash
python3 xray-sub-parser.py --ua "XPower/1.1" < tests/sub-json.json > /tmp/parsed.json
XPOWER_CONFIG_DIR=/tmp/cfg python3 xray-generate-config.py --output /tmp/config.json < /tmp/parsed.json
```
