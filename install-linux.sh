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
#   --ua=USER_AGENT        User-Agent для запроса подписки (по умолчанию: XPower/1.0)
#   --remarks=FILTER       Фильтр по remarks (для JSON-подписок)
#   --no-dns               Не настраивать DNS
#   --dry-run              Показать что будет сделано, без реальных изменений
#   --uninstall            Удалить XPowerSpirit

set -euo pipefail

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

SCRIPT_VERSION="1.0.0"
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
UPDATER="${INSTALL_DIR}/update-xray.sh"
NFT_UPDATER="${INSTALL_DIR}/update-nft.sh"
CLI_TOOL="/usr/local/bin/xpower-client"

# Переменные (из CLI или дефолты)
SUB_URL=""
SUB_USER_AGENT="XPower/1.0"
REMARKS_FILTER=""
SETUP_DNS=true
DRY_RUN=false
UNINSTALL=false

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
                # Проверка на HTML
                if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
                    rm -f "$dst"
                    log_warn "Сервер вернул HTML вместо файла (попытка $retry/$max_retries)"
                else
                    return 0
                fi
            fi
        fi
        [ $retry -lt $max_retries ] && sleep 2
        retry=$((retry + 1))
    done
    return 1
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

    # 3. Загружаем скрипты из репозитория
    log_step "Загрузка скриптов..."
    download_file "${REPO}/xray-generate-config.py" "$GENERATOR" || die "Не удалось скачать генератор"
    download_file "${REPO}/xray-sub-parser.py" "$PARSER" || die "Не удалось скачать парсер"
    download_file "${REPO}/update-xray.sh" "$UPDATER" || die "Не удалось скачать update-xray.sh"
    run_cmd chmod +x "$GENERATOR" "$PARSER" "$UPDATER"

    # Локальные скрипты (из репозитория, если есть; иначе создаём)
    if ! download_file "${REPO}/update-nft-linux.sh" "$NFT_UPDATER" 2>/dev/null; then
        log_warn "update-nft-linux.sh не найден в репозитории — создаём локально"
        create_nft_updater
    fi
    run_cmd chmod +x "$NFT_UPDATER"

    # CLI-утилита
    create_cli_tool

    log_info "Скрипты загружены"

    # 4. Инициализируем settings.json
    log_step "Настройка settings.json..."
    if [ ! -f "$SETTINGS_JSON" ]; then
        if download_file "${REPO}/settings.default.json" "${SETTINGS_JSON}.tmp" 2>/dev/null; then
            run_cmd mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
        else
            create_default_settings
        fi
        run_cmd chmod 600 "$SETTINGS_JSON"
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

    # 5. Установка Xray
    log_step "Установка Xray..."
    install_xray

    # 6. Настройка nftables
    log_step "Настройка nftables..."
    run_cmd "$NFT_UPDATER"
    log_info "nftables настроены"

    # 7. Настройка DNS
    if $SETUP_DNS; then
        log_step "Настройка DNS..."
        setup_dns
    fi

    # 8. Генерация config.json
    log_step "Генерация config.json..."
    generate_config

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
        nft flush chain inet xpower output 2>/dev/null || true
        nft delete chain inet xpower output 2>/dev/null || true
        nft flush chain inet xpower tproxy 2>/dev/null || true
        nft delete chain inet xpower tproxy 2>/dev/null || true
        nft delete table inet xpower 2>/dev/null || true
        
        # Убираем jump-правило из OUTPUT
        local handle
        handle=$(nft -a list chain inet filter OUTPUT 2>/dev/null | grep 'jump xpower_output' | sed 's/.*handle //' | head -1)
        [ -n "$handle" ] && nft delete rule inet filter OUTPUT handle "$handle" 2>/dev/null || true
    fi

    # Восстановление DNS
    if [ -f "${CONFIG_DIR}/resolv.conf.bak" ]; then
        run_cmd cp "${CONFIG_DIR}/resolv.conf.bak" /etc/resolv.conf
        log_info "DNS восстановлен"
    fi

    run_cmd rm -rf "$INSTALL_DIR"
    run_cmd rm -rf "$STATE_DIR"
    run_cmd rm -rf "$LOG_DIR"
    run_cmd rm -rf "$CACHE_DIR"
    run_cmd rm -f "$CLI_TOOL"
    run_cmd rm -f /usr/local/bin/xpower
    run_cmd rm -f /etc/systemd/system/xpower-client.service
    run_cmd rm -f /etc/systemd/system/xpower-update.service
    run_cmd rm -f /etc/systemd/system/xpower-update.timer
    run_cmd systemctl daemon-reload

    log_info "Конфигурация сохранена в: $CONFIG_DIR"
    log_info "Для полного удаления: rm -rf $CONFIG_DIR $USER_CONFIG_DIR"
    log_info "XPowerSpirit удалён."
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
        read -p "  Обновить до последней версии? [Y/n] " -r ANSWER
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
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
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

setup_dns() {
    if $DRY_RUN; then
        log_dry "Настройка DNS: systemd-resolved или resolv.conf"
        return 0
    fi

    # Пробуем systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_info "Обнаружен systemd-resolved"
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/xpower.conf <<EOF
[Resolve]
DNS=127.0.0.1#5353
FallbackDNS=77.88.8.8 1.1.1.1
Domains=~.
EOF
        systemctl restart systemd-resolved
        log_info "systemd-resolved настроен (DNS → 127.0.0.1:5353)"
    else
        # Прямой resolv.conf
        log_info "Настройка /etc/resolv.conf..."
        if [ ! -f "${CONFIG_DIR}/resolv.conf.bak" ]; then
            cp /etc/resolv.conf "${CONFIG_DIR}/resolv.conf.bak"
        fi
        cat > /etc/resolv.conf <<EOF
# XPowerSpirit DNS
nameserver 127.0.0.1#5353
nameserver 77.88.8.8
options edns0 trust-ad
EOF
        # Защита от перезаписи NetworkManager
        chattr +i /etc/resolv.conf 2>/dev/null || \
            log_warn "Не удалось защитить resolv.conf (immutable bit)"
        log_info "/etc/resolv.conf настроен"
    fi
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

    # Валидация
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
    if $DRY_RUN; then
        log_dry "Создание /etc/systemd/system/xpower-client.service"
        return 0
    fi

    cat > /etc/systemd/system/xpower-client.service <<'SYSTEMDEOF'
[Unit]
Description=XPowerSpirit Xray TProxy Client
Documentation=https://github.com/kirilllavrov/XPowerSpirit
After=network-online.target nss-lookup.target
Wants=network-online.target
Before=nss-lookup.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=/opt/xpower
ExecStartPre=/opt/xpower/update-nft.sh
ExecStartPre=/usr/local/bin/xray run -test -config /etc/xpower/config.json
ExecStart=/usr/local/bin/xray run -config /etc/xpower/config.json
ExecStopPost=/opt/xpower/update-nft.sh --cleanup
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xpower-client

# Безопасность
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/xpower /var/cache/xpower /opt/xpower/geoip.dat /opt/xpower/geosite.dat
ReadOnlyPaths=/etc/xpower/config.json /etc/xpower/settings.json /opt/xpower

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

    log_info "systemd сервис создан"
}

create_systemd_timer() {
    if $DRY_RUN; then
        log_dry "Создание systemd timer для автообновления"
        return 0
    fi

    cat > /etc/systemd/system/xpower-update.service <<'EOF'
[Unit]
Description=XPowerSpirit Auto-Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/opt/xpower/update-xray.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xpower-update
EOF

    cat > /etc/systemd/system/xpower-update.timer <<'EOF'
[Unit]
Description=XPowerSpirit Daily Update Timer
Requires=xpower-update.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable xpower-update.timer
    run_cmd systemctl start xpower-update.timer

    log_info "systemd timer для автообновления создан (ежедневно)"
}

# ============================================
#   ЛОКАЛЬНЫЕ СКРИПТЫ
# ============================================

create_nft_updater() {
    cat > "$NFT_UPDATER" <<'NFTEOF'
#!/bin/bash
# XPowerSpirit — nftables для локального TProxy клиента
# Только OUTPUT-цепочка (трафик самой машины)

set -euo pipefail

TABLE="inet xpower"
CONFIG_DIR="${XPOWER_CONFIG_DIR:-/etc/xpower}"
CONFIG_JSON="${CONFIG_DIR}/config.json"

# Извлечение IP прокси-серверов из config.json
extract_proxy_ips() {
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr and addr not in ("hole","0.0.0.0","127.0.0.1"):
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONFIG_JSON" 2>/dev/null
}

setup_tproxy() {
    # Создаём таблицу xpower
    nft add table inet xpower 2>/dev/null || true

    # Цепочка tproxy (собственно TProxy)
    nft add chain inet xpower tproxy 2>/dev/null || true
    nft flush chain inet xpower tproxy

    # Loop protection: пакеты от Xray (mark 2) — не трогаем
    nft add rule inet xpower tproxy meta mark 2 return

    # Локальные адреса — bypass
    nft add rule inet xpower tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return

    # DNS-серверы — bypass (Яндекс, Cloudflare, NextDNS)
    nft add rule inet xpower tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return

    # DHCP
    nft add rule inet xpower tproxy udp dport { 67, 68 } return

    # Bypass для IP прокси-серверов (чтобы не зациклить)
    for ip in $(extract_proxy_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet xpower tproxy ip daddr "$ip" return
        fi
    done

    # TProxy: TCP → :12345
    nft add rule inet xpower tproxy meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    # TProxy: UDP → :12345
    nft add rule inet xpower tproxy meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # Policy routing: mark 0x1 → table 100 → lo
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Цепочка output
    nft add chain inet xpower output 2>/dev/null || true
    nft flush chain inet xpower output

    # Loop prevention
    nft add rule inet xpower output meta mark 2 return

    # Локальные адреса
    nft add rule inet xpower output ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return

    # DNS bypass
    nft add rule inet xpower output ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return

    # DHCP bypass
    nft add rule inet xpower output udp dport { 67, 68 } return

    # Bypass прокси-серверов
    for ip in $(extract_proxy_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet xpower output ip daddr "$ip" return
        fi
    done

    # Маркируем и прыгаем в tproxy
    nft add rule inet xpower output meta l4proto { tcp, udp } meta mark set 0x1 jump tproxy

    # Вставляем jump в основную OUTPUT цепочку (если ещё нет)
    if ! nft list chain inet filter OUTPUT 2>/dev/null | grep -q 'jump xpower_output'; then
        # Создаём таблицу/цепочку filter, если нет
        nft add table inet filter 2>/dev/null || true
        nft add chain inet filter OUTPUT 2>/dev/null || true
        nft insert rule inet filter OUTPUT jump xpower_output
    fi

    echo "[+] nftables TProxy правила применены"
}

cleanup() {
    # Убираем jump из основной цепочки
    local handle
    handle=$(nft -a list chain inet filter OUTPUT 2>/dev/null | grep 'jump xpower_output' | sed 's/.*handle //' | head -1)
    [ -n "$handle" ] && nft delete rule inet filter OUTPUT handle "$handle" 2>/dev/null || true

    # Чистим таблицу xpower
    nft delete table inet xpower 2>/dev/null || true

    # Policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true

    echo "[+] nftables правила удалены"
}

case "${1:-}" in
    --cleanup)
        cleanup
        ;;
    *)
        setup_tproxy
        ;;
esac
NFTEOF
    chmod +x "$NFT_UPDATER"
}

create_cli_tool() {
    cat > "$CLI_TOOL" <<'CLIEOF'
#!/bin/bash
# XPowerSpirit CLI — управление прокси-клиентом

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
XPowerSpirit Client — управление Xray TProxy

Использование:
  xpower-client status       Показать статус
  xpower-client start        Запустить прокси
  xpower-client stop         Остановить прокси
  xpower-client restart      Перезапустить
  xpower-client update       Обновить подписку и конфиг
  xpower-client toggle       Вкл/выкл
  xpower-client test         Проверить соединение
  xpower-client logs         Посмотреть логи (journalctl)
  xpower-client uninstall    Удалить XPowerSpirit
EOF
}

do_status() {
    echo -n "Сервис:     "
    if systemctl is-active --quiet xpower-client 2>/dev/null; then
        echo -e "${GREEN}активен${NC}"
    else
        echo -e "${RED}остановлен${NC}"
    fi

    echo -n "Автообновление: "
    if systemctl is-active --quiet xpower-update.timer 2>/dev/null; then
        echo -e "${GREEN}включено${NC}"
    else
        echo -e "${YELLOW}отключено${NC}"
    fi

    echo -n "Xray:       "
    if /usr/local/bin/xray version >/dev/null 2>&1; then
        /usr/local/bin/xray version 2>/dev/null | head -1
    else
        echo -e "${RED}не установлен${NC}"
    fi

    echo -n "nftables:   "
    if nft list table inet xpower >/dev/null 2>&1; then
        echo -e "${GREEN}настроены${NC}"
    else
        echo -e "${RED}не настроены${NC}"
    fi

    echo -n "Config:     "
    if [ -f /etc/xpower/config.json ]; then
        echo -e "${GREEN}/etc/xpower/config.json${NC}"
    else
        echo -e "${RED}отсутствует${NC}"
    fi
}

do_test() {
    echo "Проверка соединения..."
    echo -n "  IPv4 (прямой):   "
    if curl -fs --max-time 5 https://ifconfig.me/ip -o /dev/null 2>/dev/null; then
        IP=$(curl -s --max-time 5 https://ifconfig.me/ip)
        echo -e "${GREEN}$IP${NC}"
    else
        echo -e "${RED}нет соединения${NC}"
    fi

    echo -n "  DNS (через Xray): "
    if nslookup google.com 127.0.0.1 -port=5353 >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}недоступен (возможно используется systemd-resolved)${NC}"
    fi
}

case "${1:-}" in
    status)    do_status ;;
    start)     systemctl start xpower-client && echo "XPowerSpirit запущен" ;;
    stop)      systemctl stop xpower-client && echo "XPowerSpirit остановлен" ;;
    restart)   systemctl restart xpower-client && echo "XPowerSpirit перезапущен" ;;
    update)    /opt/xpower/update-xray.sh ;;
    toggle)
        if systemctl is-active --quiet xpower-client; then
            systemctl stop xpower-client
            echo "XPowerSpirit остановлен"
        else
            systemctl start xpower-client
            echo "XPowerSpirit запущен"
        fi ;;
    test)      do_test ;;
    logs)      journalctl -u xpower-client -f ;;
    uninstall) sudo "$0" --uninstall 2>/dev/null || echo "Запустите: sudo ./install-linux.sh --uninstall" ;;
    *)         usage ;;
esac
CLIEOF
    chmod +x "$CLI_TOOL"
}

create_default_settings() {
    cat > "$SETTINGS_JSON" <<'JSONEOF'
{
  "subscription": {
    "url": "",
    "user_agent": "XPower/1.0",
    "remarks_filter": "",
    "domain_whitelist": []
  },
  "hwid": "",
  "device_model": "",
  "device_os": "",
  "ver_os": "",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "doh_domains": [
      "common.dot.dns.yandex.net",
      "cloudflare-dns.com",
      "dns.google",
      "dns.quad9.net",
      "doh.opendns.com",
      "dns.nextdns.io"
    ],
    "block_domains": [
      "geosite:category-ads"
    ],
    "direct_ips": [
      "geoip:ru",
      "geoip:private"
    ],
    "direct_domains": [
      "geosite:private",
      "geosite:category-browser",
      "geosite:category-cdn-ru",
      "geosite:category-mobile",
      "geosite:category-ru"
    ],
    "proxy_domains": [
      "geosite:category-streaming",
      "geosite:category-games"
    ]
  },
  "geo": {
    "geoip_url": "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geoip.dat",
    "geosite_url": "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"
  }
}
JSONEOF
    log_info "settings.json создан с настройками по умолчанию"
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
            echo "  --ua=USER_AGENT    User-Agent (по умолчанию: XPower/1.0)"
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
