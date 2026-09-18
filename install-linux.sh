#!/bin/bash
# XPowerSpirit — Xray TProxy Client for Linux (Ubuntu/Debian/Fedora)
#
# Установка прозрачного прокси-клиента Xray на Linux-десктоп/сервер.
# Поддерживает: Ubuntu 20.04+, Debian 11+, Fedora 38+
#
# Использование:
#   sudo ./install-linux.sh --sub=https://your-subscription-url [опции]
#
# Опции:
#   --sub=URL              URL подписки (обязателен)
#   --ua=USER_AGENT        User-Agent для запроса подписки (по умолчанию: XPower/1.1)
#   --remarks=FILTER       Фильтр по remarks (для JSON-подписок)
#   --no-dns               Не настраивать DNS
#   --dry-run              Показать что будет сделано, без реальных изменений
#   --uninstall            Удалить XPowerSpirit

set -euo pipefail

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

SCRIPT_VERSION="1.0.1"
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit/main"

# Пути установки
INSTALL_DIR="/opt/xpower"
CONFIG_DIR="/etc/xpower"
USER_CONFIG_DIR="${HOME}/.xpower"
STATE_DIR="${CONFIG_DIR}/state"
LOG_DIR="/var/log/xpower"
CACHE_DIR="/var/cache/xpower"

# Файлы
SETTINGS_JSON="${CONFIG_DIR}/settings.json"
CONFIG_JSON="${CONFIG_DIR}/config.json"
GENERATOR="${INSTALL_DIR}/xray-generate-config.py"
PARSER="${INSTALL_DIR}/xray-sub-parser.py"
UPDATER="${INSTALL_DIR}/update-xray-linux.sh"
NFT_UPDATER="${INSTALL_DIR}/update-nft-linux.sh"
CLI_TOOL="/usr/local/bin/xpower-client"

# Каталог, из которого запущен установщик: если рядом есть копии файлов —
# берём их, иначе качаем из REPO (работает и при `curl | bash`)
SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

# Переменные (из CLI или дефолты)
SUB_URL=""
SUB_USER_AGENT="XPower/1.1"
REMARKS_FILTER=""
SETUP_DNS=true
DRY_RUN=false
UNINSTALL=false

# DNS: заполняется в detect_dns_mode() — resolved | dnsmasq | resolvconf | none
# DNS_LOCAL_PORT — порт inбаунда Xray "dns-local" (он же попадает в config.json)
DNS_MODE=""
DNS_LOCAL_PORT=5353

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================
#   ХЕЛПЕРЫ
# ============================================

log_info()  { echo -e "${GREEN}[+]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[X]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}==>${NC} $1"; }
log_dry()   { echo -e "${BLUE}[DRY-RUN]${NC} $1"; }

die() {
    log_error "$1"
    exit 1
}

run_cmd() {
    if $DRY_RUN; then
        log_dry "$*"
        return 0
    fi
    "$@"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_NAME="${PRETTY_NAME:-$NAME}"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian $(cat /etc/debian_version)"
        OS_VERSION="$(cat /etc/debian_version)"
    elif [ -f /etc/fedora-release ]; then
        OS_ID="fedora"
        OS_NAME="$(cat /etc/fedora-release)"
        OS_VERSION="unknown"
    else
        OS_ID="unknown"
        OS_NAME="Unknown Linux"
        OS_VERSION="unknown"
    fi

    case "$OS_ID" in
        ubuntu|debian|fedora|rhel|centos|rocky|almalinux)
            log_info "Определена ОС: ${OS_NAME}"
            ;;
        *)
            log_warn "Неподдерживаемая ОС: ${OS_NAME} (продолжаем на свой риск)"
            ;;
    esac
}

# Установка пакетов
install_packages() {
    log_step "Установка зависимостей..."

    local pkgs="curl jq python3 unzip nftables"

    case "$OS_ID" in
        ubuntu|debian)
            run_cmd apt-get update -qq
            run_cmd apt-get install -y -qq $pkgs
            ;;
        fedora)
            run_cmd dnf install -y $pkgs
            ;;
        rhel|centos|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                run_cmd dnf install -y $pkgs
            else
                run_cmd yum install -y $pkgs
            fi
            ;;
        *)
            log_warn "Неизвестный пакетный менеджер. Установите вручную: $pkgs"
            ;;
    esac

    log_info "Зависимости установлены"
}

# Загрузка файла
download_file() {
    local url="$1"
    local dst="$2"
    local max_retries=3
    local retry=1

    if $DRY_RUN; then
        log_dry "curl → $dst"
        return 0
    fi

    while [ $retry -le $max_retries ]; do
        if curl -sSL --max-time 30 -o "$dst" "$url"; then
            if [ -s "$dst" ]; then
                # Проверка на HTML / HTTP-ошибки (raw GitHub отдаёт "404: Not Found" текстом)
                if head -n 1 "$dst" 2>/dev/null | grep -qiE "<html|<!DOCTYPE|^[0-9]{3}:"; then
                    rm -f "$dst"
                    log_warn "Сервер вернул ошибку вместо файла (попытка $retry/$max_retries): $url"
                else
                    return 0
                fi
            fi
        else
            log_warn "Не удалось скачать (попытка $retry/$max_retries): $url"
        fi
        [ $retry -lt $max_retries ] && sleep 2
        retry=$((retry + 1))
    done
    log_error "Исчерпаны попытки скачать: $url"
    return 1
}

# Установка файла проекта: сначала локальная копия рядом с install-скриптом,
# иначе — загрузка из репозитория. Единый источник правды, чтобы файлы
# в репозитории и на диске не расходились (см. историю про update-nft.sh).
install_file() {
    local name="$1"
    local dst="$2"
    local mode="${3:-644}"

    if [ -f "${SCRIPT_DIR}/${name}" ]; then
        run_cmd cp "${SCRIPT_DIR}/${name}" "$dst"
        log_info "${name} (локальная копия)"
    else
        download_file "${REPO}/${name}" "$dst" || die "Не удалось скачать ${name}"
    fi
    run_cmd chmod "$mode" "$dst"
}

# jq-хелперы для settings.json
settings_get() {
    local key="$1"
    [ -f "$SETTINGS_JSON" ] || return 1
    jq -r "
        if $key | type == \"boolean\" then
            if $key then \"1\" else \"0\" end
        elif $key | type == \"array\" then
            $key[]
        else
            $key // empty
        end
    " "$SETTINGS_JSON" 2>/dev/null
}

settings_set() {
    local key="$1"
    local val="$2"
    if $DRY_RUN; then
        log_dry "settings.json: $key = $val"
        return 0
    fi
    mkdir -p "$(dirname "$SETTINGS_JSON")"
    [ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
    if echo "$val" | grep -qE '^[0-9]+$'; then
        jq --argjson v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    else
        jq --arg v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    fi
    mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
    chmod 600 "$SETTINGS_JSON"
}

# ============================================
#   УСТАНОВКА
# ============================================

do_install() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║   XPowerSpirit Linux Client v${SCRIPT_VERSION}             ║"
    echo "║   Прозрачный прокси-клиент Xray               ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    # 0. Проверка прав
    [ "$(id -u)" = "0" ] || die "Запускайте от root (sudo)"

    # 0a. Определяем ОС
    detect_os

    # 0b. Проверка --uninstall
    if $UNINSTALL; then
        do_uninstall
        return
    fi

    # 0c. Проверка обязательных параметров
    [ -z "$SUB_URL" ] && die "--sub=URL обязателен"

    # 1. Устанавливаем зависимости
    install_packages

    # 2. Создаём директории
    log_step "Создание директорий..."
    run_cmd mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$CACHE_DIR"
    run_cmd mkdir -p "$USER_CONFIG_DIR"
    run_cmd chmod 755 "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
    log_info "Директории созданы"

    # 3. Загружаем скрипты из репозитория (или копируем локальные)
    log_step "Загрузка скриптов..."

    install_file "xray-generate-config.py" "$GENERATOR" 755
    install_file "xray-sub-parser.py"     "$PARSER"    755
    install_file "update-xray-linux.sh"   "$UPDATER"   755
    install_file "update-nft-linux.sh"    "$NFT_UPDATER" 755

    # CLI-утилита
    install_file "xpower-client" "$CLI_TOOL" 755

    # Проверяем, что критичные файлы на месте и не мусор
    # (в dry-run файлы не создаются, поэтому проверки пропускаем)
    if ! $DRY_RUN; then
        for f in "$GENERATOR" "$PARSER" "$UPDATER" "$NFT_UPDATER" "$CLI_TOOL"; do
            [ -s "$f" ] || die "Критичный файл отсутствует: $f"
            head -c 4 "$f" | grep -q '^#!/' || die "Файл повреждён (не скрипт): $f"
        done
    fi

    log_info "Скрипты загружены"

    # 4. Инициализируем settings.json
    log_step "Настройка settings.json..."
    if [ ! -f "$SETTINGS_JSON" ]; then
        install_file "settings.default.json" "$SETTINGS_JSON" 600
        [ -s "$SETTINGS_JSON" ] || die "Не удалось установить settings.json"
    fi

    # Сохраняем параметры
    settings_set ".subscription.url" "$SUB_URL"
    settings_set ".subscription.user_agent" "$SUB_USER_AGENT"
    [ -n "$REMARKS_FILTER" ] && settings_set ".subscription.remarks_filter" "$REMARKS_FILTER"

    # HWID
    if [ -z "$(settings_get '.hwid')" ]; then
        HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
        settings_set ".hwid" "$HWID"
        log_info "HWID сгенерирован: $HWID"
    fi

    # Информация об ОС
    settings_set ".device_os" "$OS_ID"
    settings_set ".ver_os" "$OS_VERSION"
    [ -f /sys/devices/virtual/dmi/id/product_name ] && \
        settings_set ".device_model" "$(cat /sys/devices/virtual/dmi/id/product_name)"

    log_info "settings.json сохранён: $SETTINGS_JSON"

    # 5. Установка Xray + Geo-файлы
    log_step "Установка Xray..."
    install_xray

    # 5b. Скачиваем geoip.dat и geosite.dat (нужны для валидации config.json)
    log_step "Загрузка geo-файлов..."
    download_geo

    # 5c. Определяем режим DNS ДО генерации конфига:
    #     от этого зависит порт инбаунда dns-local в config.json
    if $SETUP_DNS; then
        log_step "Определение режима DNS..."
        detect_dns_mode
    fi

    # 6. Генерация config.json (до nftables — нужны IP прокси для bypass)
    log_step "Генерация config.json..."
    generate_config

    # 7. Настройка nftables (теперь config.json уже есть)
    log_step "Настройка nftables..."
    # sysctl для TProxy (route_localnet + ip_forward)
    if ! $DRY_RUN; then
        sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        cat > /etc/sysctl.d/99-xpower.conf <<'SYSCTLEOF'
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
SYSCTLEOF
        sysctl -p /etc/sysctl.d/99-xpower.conf >/dev/null 2>&1
    fi
    run_cmd "$NFT_UPDATER"
    log_info "nftables настроены"

    # 8. Настройка DNS
    if $SETUP_DNS; then
        log_step "Настройка DNS..."
        setup_dns
    fi

    # 9. Создание systemd сервиса
    log_step "Создание systemd сервиса..."
    create_systemd_service

    # 10. Запуск
    log_step "Запуск XPowerSpirit..."
    run_cmd systemctl daemon-reload
    run_cmd systemctl enable xpower-client
    run_cmd systemctl start xpower-client

    # Проверка
    sleep 2
    if systemctl is-active --quiet xpower-client; then
        log_info "XPowerSpirit запущен и работает!"
    else
        log_warn "Сервис не запустился. Проверьте: systemctl status xpower-client"
        log_warn "Логи: journalctl -u xpower-client -f"
    fi

    # 11. Создаём systemd timer для автообновления
    create_systemd_timer

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Установка завершена!                       ║"
    echo "║                                              ║"
    echo "║   Управление:                                ║"
    echo "║     xpower-client status                     ║"
    echo "║     xpower-client stop                       ║"
    echo "║     xpower-client start                      ║"
    echo "║     xpower-client update                     ║"
    echo "║                                              ║"
    echo "║   Конфигурация: ${CONFIG_DIR}         ║"
    echo "║   Логи:         journalctl -u xpower-client  ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

# ============================================
#   УДАЛЕНИЕ
# ============================================

do_uninstall() {
    log_step "Удаление XPowerSpirit..."

    run_cmd systemctl stop xpower-client 2>/dev/null || true
    run_cmd systemctl disable xpower-client 2>/dev/null || true
    run_cmd systemctl stop xpower-update.timer 2>/dev/null || true
    run_cmd systemctl disable xpower-update.timer 2>/dev/null || true

    # Очистка nftables
    if ! $DRY_RUN; then
        nft delete table inet xpower 2>/dev/null || true
        while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null || true
    fi

    # Восстановление DNS (systemd-resolved)
    if [ -f /etc/systemd/resolved.conf.d/xpower.conf ]; then
        run_cmd rm -f /etc/systemd/resolved.conf.d/xpower.conf
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            run_cmd systemctl restart systemd-resolved
        fi
        log_info "systemd-resolved восстановлен"
    fi

    # Восстановление DNS (resolv.conf)
    if [ -f "${CONFIG_DIR}/resolv.conf.bak" ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        run_cmd cp "${CONFIG_DIR}/resolv.conf.bak" /etc/resolv.conf
        log_info "/etc/resolv.conf восстановлен"
    fi

    # Восстановление DNS (dnsmasq)
    if [ -f /etc/dnsmasq.d/xpower.conf ]; then
        run_cmd rm -f /etc/dnsmasq.d/xpower.conf
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            run_cmd systemctl restart dnsmasq
        fi
        log_info "dnsmasq восстановлен"
    fi

    # Удаление файлов
    run_cmd rm -rf "$INSTALL_DIR"
    run_cmd rm -rf "$STATE_DIR"
    run_cmd rm -rf "$LOG_DIR"
    run_cmd rm -rf "$CACHE_DIR"
    run_cmd rm -rf "$CONFIG_DIR"
    run_cmd rm -rf "$USER_CONFIG_DIR"
    run_cmd rm -f "$CLI_TOOL"
    run_cmd rm -f /usr/local/bin/xpower
    run_cmd rm -f /usr/local/bin/xray
    run_cmd rm -f /etc/systemd/system/xpower-client.service
    run_cmd rm -f /etc/systemd/system/xpower-update.service
    run_cmd rm -f /etc/systemd/system/xpower-update.timer
    run_cmd systemctl daemon-reload

    log_info "XPowerSpirit полностью удалён."
}

# ============================================
#   УСТАНОВКА XRAY
# ============================================

install_xray() {
    local ARCH MACHINE

    # Проверка существующей установки
    if [ -x /usr/local/bin/xray ]; then
        CURRENT_VER=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
        log_info "Xray уже установлен (версия: $CURRENT_VER)"
        # < /dev/tty — иначе при установке через `curl | bash` read() съел бы
        # сам скрипт из stdin
        ANSWER="y"
        if ! read -r -p "  Обновить до последней версии? [Y/n] " ANSWER < /dev/tty 2>/dev/null; then
            log_info "Нет доступа к терминалу — обновляю Xray без вопросов"
            ANSWER="y"
        fi
        if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi

    # Ожидание GitHub API
    for i in $(seq 1 10); do
        if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
            break
        fi
        [ "$i" = "10" ] && die "GitHub API недоступен после 10 попыток"
        sleep 2
    done

    LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
        jq -r '.tag_name // empty' 2>/dev/null)
    [ -z "$LATEST_VERSION" ] && die "Не удалось получить версию Xray"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  MACHINE="64" ;;
        aarch64)       MACHINE="arm64-v8a" ;;
        armv7l)        MACHINE="arm32-v7a" ;;
        *)             MACHINE="64" ;;
    esac

    ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
    
    log_info "Скачиваю Xray ${LATEST_VERSION} (linux-${MACHINE})..."
    
    if $DRY_RUN; then
        log_dry "Скачивание и распаковка $ZIP_URL"
        return 0
    fi

    local TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT

    # Скачиваем .dgst
    if ! curl -sSL --max-time 30 "${ZIP_URL}.dgst" -o "$TMP_DIR/xray.dgst"; then
        log_warn "Не удалось скачать .dgst — проверка SHA будет пропущена"
    fi

    # Скачиваем ZIP
    if ! curl -sSL --max-time 120 "$ZIP_URL" -o "$TMP_DIR/xray.zip"; then
        die "Не удалось скачать Xray"
    fi

    # Проверка SHA (если есть .dgst)
    if [ -f "$TMP_DIR/xray.dgst" ]; then
        REMOTE_SHA=$(grep '^SHA2-256' "$TMP_DIR/xray.dgst" | sed 's/.*= *//' | tr -cd '0-9a-fA-F' | cut -c1-64)
        LOCAL_SHA=$(sha256sum "$TMP_DIR/xray.zip" | awk '{print $1}')
        if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
            die "SHA не совпадает для Xray!"
        fi
        log_info "SHA проверка пройдена"
    fi

    # Распаковка и установка
    unzip -qo "$TMP_DIR/xray.zip" -d "$TMP_DIR"
    run_cmd cp "$TMP_DIR/xray" /usr/local/bin/xray
    run_cmd chmod 755 /usr/local/bin/xray

    log_info "Xray ${LATEST_VERSION} установлен"
}

# ============================================
#   НАСТРОЙКА DNS
# ============================================

# Занят ли порт каким-нибудь слушателем (tcp или udp)
port_busy() {
    local port="$1"
    ss -lnut 2>/dev/null | awk -v pat=":${port}$" 'NR > 1 { for (i = 1; i <= NF; i++) if ($i ~ pat) found = 1 } END { exit found ? 0 : 1 }'
}

# Определяет, КАК система будет отдавать DNS в Xray, и какой порт должен
# слушать инбаунд dns-local. Вызывать ДО generate_config().
#
#   resolved   — systemd-resolved: в resolved.conf.d допустимо "DNS=127.0.0.1#5353"
#   dnsmasq    — dnsmasq: допустимо "server=127.0.0.1#5353"
#   resolvconf — голый /etc/resolv.conf: порт указать нельзя, Xray слушает :53
#   none       — сами не трогаем (--no-dns или неизвестный резолвер)
detect_dns_mode() {
    DNS_MODE="none"
    DNS_LOCAL_PORT=5353

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        DNS_MODE="resolved"
    elif systemctl is-active --quiet dnsmasq 2>/dev/null; then
        DNS_MODE="dnsmasq"
    elif port_busy 53; then
        log_warn "Порт 53 занят неизвестным резолвером — DNS не перенастраиваем"
    else
        DNS_MODE="resolvconf"
        DNS_LOCAL_PORT=53
    fi

    # resolved и dnsmasq умеют указывать порт (127.0.0.1#port), поэтому при
    # занятом 5353 (его держит mDNS/avahi) можно взять соседний свободный порт
    case "$DNS_MODE" in
        resolved|dnsmasq)
            local p=5353
            while port_busy "$p" && [ "$p" -lt 5370 ]; do
                p=$((p + 1))
            done
            [ "$p" != 5353 ] && log_warn "Порт 5353 занят (mDNS/avahi) — использую ${p}"
            DNS_LOCAL_PORT="$p"
            ;;
    esac

    # Порт нужен генератору config.json (инбаунд dns-local)
    settings_set ".dns.mode" "$DNS_MODE"
    settings_set ".dns.local_port" "$DNS_LOCAL_PORT"

    if $DRY_RUN; then
        log_dry "Режим DNS: ${DNS_MODE}, Xray dns-local слушает 127.0.0.1:${DNS_LOCAL_PORT}"
        return 0
    fi

    case "$DNS_MODE" in
        resolved)   log_info "DNS: systemd-resolved → 127.0.0.1#${DNS_LOCAL_PORT}" ;;
        dnsmasq)    log_info "DNS: dnsmasq → 127.0.0.1#${DNS_LOCAL_PORT}" ;;
        resolvconf) log_info "DNS: /etc/resolv.conf → 127.0.0.1:${DNS_LOCAL_PORT}" ;;
    esac
}

setup_dns() {
    if $DRY_RUN; then
        log_dry "Настройка DNS: режим ${DNS_MODE:-?}, порт Xray ${DNS_LOCAL_PORT}"
        return 0
    fi

    case "$DNS_MODE" in
        resolved)
            log_info "Настройка systemd-resolved..."
            mkdir -p /etc/systemd/resolved.conf.d
            cat > /etc/systemd/resolved.conf.d/xpower.conf <<EOF
[Resolve]
DNS=127.0.0.1#${DNS_LOCAL_PORT}
FallbackDNS=77.88.8.8 1.1.1.1
Domains=~.
EOF
            systemctl restart systemd-resolved
            log_info "systemd-resolved настроен (DNS → 127.0.0.1#${DNS_LOCAL_PORT})"
            ;;

        dnsmasq)
            log_info "Настройка dnsmasq..."
            mkdir -p /etc/dnsmasq.d
            cat > /etc/dnsmasq.d/xpower.conf <<EOF
# XPowerSpirit: весь DNS уходит в Xray (dns-local)
no-resolv
no-poll
server=127.0.0.1#${DNS_LOCAL_PORT}
EOF
            systemctl restart dnsmasq
            log_info "dnsmasq настроен (upstream → 127.0.0.1#${DNS_LOCAL_PORT})"
            ;;

        resolvconf)
            # glibc НЕ понимает запись вида "nameserver 127.0.0.1#5353" — порт в
            # /etc/resolv.conf указывать нельзя, поэтому Xray слушает :53.
            log_info "Настройка /etc/resolv.conf (Xray слушает 127.0.0.1:${DNS_LOCAL_PORT})..."
            if [ ! -f "${CONFIG_DIR}/resolv.conf.bak" ]; then
                cp /etc/resolv.conf "${CONFIG_DIR}/resolv.conf.bak"
            fi
            cat > /etc/resolv.conf <<EOF
# XPowerSpirit DNS — обслуживается Xray (inbound dns-local)
nameserver 127.0.0.1
nameserver 77.88.8.8
options edns0 trust-ad
EOF
            # Защита от перезаписи NetworkManager
            chattr +i /etc/resolv.conf 2>/dev/null || \
                log_warn "Не удалось защитить resolv.conf (immutable bit)"
            log_info "/etc/resolv.conf настроен (127.0.0.1:${DNS_LOCAL_PORT})"
            ;;

        *)
            log_warn "DNS не настроен автоматически (резолвер не распознан)"
            ;;
    esac
}

# ============================================
#   ЗАГРУЗКА GEO-ФАЙЛОВ
# ============================================

download_geo() {
    local GEOIP_URL GEOSITE_URL
    GEOIP_URL=$(settings_get ".geo.geoip_url")
    GEOSITE_URL=$(settings_get ".geo.geosite_url")
    [ -z "$GEOIP_URL" ] && GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
    [ -z "$GEOSITE_URL" ] && GEOSITE_URL="https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"

    for ITEM in "$GEOIP_URL|geoip.dat" "$GEOSITE_URL|geosite.dat"; do
        URL="${ITEM%%|*}"
        NAME="${ITEM##*|}"
        DST="${INSTALL_DIR}/${NAME}"

        if [ -f "$DST" ]; then
            log_info "$NAME уже загружен"
            continue
        fi

        if $DRY_RUN; then
            log_dry "curl → $DST"
            continue
        fi

        log_info "Скачиваю $NAME..."
        if download_file "$URL" "$DST"; then
            log_info "$NAME загружен ($(stat -c%s "$DST" 2>/dev/null || echo '?') байт)"
        else
            log_warn "Не удалось скачать $NAME — geo-правила не будут работать"
        fi
    done
}

# ============================================
#   ГЕНЕРАЦИЯ КОНФИГА
# ============================================

generate_config() {
    if $DRY_RUN; then
        log_dry "Пайплайн: подписка → парсер → генератор → config.json"
        return 0
    fi

    local HWID
    HWID=$(settings_get ".hwid")

    # Скачиваем подписку
    local SUB_TMP="${CACHE_DIR}/subscription.txt"
    local PARSED_TMP="${CACHE_DIR}/parsed.json"

    if ! curl -sSL --max-time 30 \
        -H "User-Agent: ${SUB_USER_AGENT}" \
        -H "x-hwid: ${HWID}" \
        -o "$SUB_TMP" "$SUB_URL"; then
        log_error "Не удалось скачать подписку"
        # Если уже есть config.json — оставляем старый
        if [ -f "$CONFIG_JSON" ]; then
            log_warn "Использую существующий config.json"
            return 0
        fi
        die "Нет config.json и не удалось скачать подписку"
    fi

    # Проверка на HTML
    if head -n 1 "$SUB_TMP" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        rm -f "$SUB_TMP"
        die "Подписка вернула HTML, а не данные"
    fi

    # Парсинг
    if ! python3 "$PARSER" --ua "$SUB_USER_AGENT" --remarks "$REMARKS_FILTER" < "$SUB_TMP" > "$PARSED_TMP" 2>"${LOG_DIR}/parser.log"; then
        rm -f "$SUB_TMP"
        die "Ошибка парсера подписки (см. ${LOG_DIR}/parser.log)"
    fi

    # Генерация
    if ! python3 "$GENERATOR" --output "$CONFIG_JSON" < "$PARSED_TMP" 2>"${LOG_DIR}/generator.log"; then
        rm -f "$SUB_TMP" "$PARSED_TMP"
        die "Ошибка генератора конфига (см. ${LOG_DIR}/generator.log)"
    fi

    # Валидация (Xray ищет geo-файлы в XRAY_LOCATION_ASSET или рядом с бинарником)
    export XRAY_LOCATION_ASSET="$INSTALL_DIR"
    if ! /usr/local/bin/xray run -test -config "$CONFIG_JSON" > "${LOG_DIR}/validate.log" 2>&1; then
        log_error "config.json не прошёл валидацию Xray (см. ${LOG_DIR}/validate.log)"
        rm -f "$SUB_TMP" "$PARSED_TMP"
        die "Некорректный config.json"
    fi

    rm -f "$SUB_TMP" "$PARSED_TMP"
    log_info "config.json сгенерирован и проверен"
}

# ============================================
#   SYSTEMD СЕРВИС И ТАЙМЕР
# ============================================

create_systemd_service() {
    log_step "Установка systemd сервиса..."
    install_file "xpower-client.service" "/etc/systemd/system/xpower-client.service" 644
    log_info "systemd сервис установлен"
}

create_systemd_timer() {
    log_step "Установка systemd timer автообновления..."
    install_file "xpower-update.service" "/etc/systemd/system/xpower-update.service" 644
    install_file "xpower-update.timer"   "/etc/systemd/system/xpower-update.timer"   644

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable xpower-update.timer
    run_cmd systemctl start xpower-update.timer

    log_info "systemd timer для автообновления установлен (ежедневно)"
}

# ============================================
#   ПАРСЕР АРГУМЕНТОВ
# ============================================

for arg in "$@"; do
    case $arg in
        --sub=*)       SUB_URL="${arg#*=}" ;;
        --ua=*)        SUB_USER_AGENT="${arg#*=}" ;;
        --remarks=*)   REMARKS_FILTER="${arg#*=}" ;;
        --no-dns)      SETUP_DNS=false ;;
        --dry-run)     DRY_RUN=true ;;
        --uninstall)   UNINSTALL=true ;;
        --help|-h)
            echo "XPowerSpirit Linux Client v${SCRIPT_VERSION}"
            echo ""
            echo "Использование: sudo ./install-linux.sh --sub=URL [опции]"
            echo ""
            echo "Опции:"
            echo "  --sub=URL          URL подписки (обязателен)"
            echo "  --ua=USER_AGENT    User-Agent (по умолчанию: XPower/1.1)"
            echo "  --remarks=FILTER   Фильтр по remarks"
            echo "  --no-dns           Не настраивать DNS"
            echo "  --dry-run          Показать план без выполнения"
            echo "  --uninstall        Удалить XPowerSpirit"
            echo "  --help             Эта справка"
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: $arg"
            echo "Используйте --help для справки"
            exit 1
            ;;
    esac
done

# ============================================
#   ЗАПУСК
# ============================================

do_install