#!/bin/bash
set -e

# ============================================================
# Переменные (легко менять при необходимости)
# ============================================================

# Пути установки
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_BIN_DIR="/usr/local/bin"
readonly XRAY_ETC_DIR="/usr/local/etc/xray"
readonly XRAY_SHARE_DIR="/usr/local/share/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_STATE_DIR="/usr/local/share/xray/state"
readonly TMP_INSTALL_DIR="/tmp/xray_install"

# Файлы
readonly SUB_FILE="${XRAY_ETC_DIR}/subscription.url"
readonly CONFIG_FILE="${XRAY_ETC_DIR}/config.json"
readonly BACKUP_DIR="${XRAY_ETC_DIR}/backup"
readonly SHA_FILE="${XRAY_STATE_DIR}/xray.zip.sha256sum"
readonly DGST_FILE="${XRAY_STATE_DIR}/xray.dgst"

# Скрипты
readonly UPDATE_SCRIPT="${XRAY_BIN_DIR}/update-xray.sh"
readonly PARSER_SCRIPT="${XRAY_BIN_DIR}/xray-sub-parser.py"
readonly GENERATOR_SCRIPT="${XRAY_BIN_DIR}/xray-generate-config.py"

# Репозиторий
readonly REPO_BASE="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit/main"

# systemd
readonly SERVICE_FILE="/etc/systemd/system/xray.service"
readonly UPDATE_SERVICE_FILE="/etc/systemd/system/xray-update.service"
readonly UPDATE_TIMER_FILE="/etc/systemd/system/xray-update.timer"

# GitHub API
readonly GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly GITHUB_DOWNLOAD="https://github.com/XTLS/Xray-core/releases/download"

# ============================================================
# Функции
# ============================================================

# Проверка прав
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[!] Запустите скрипт через sudo"
        exit 1
    fi
}

# Проверка systemd
check_systemd() {
    if [ ! -d "/run/systemd/system" ]; then
        echo "[!] Этот скрипт поддерживает только системы с systemd"
        exit 1
    fi
}

# Определение архитектуры
detect_arch() {
    case "$(uname -m)" in
        i386|i686)       echo "32" ;;
        x86_64|amd64)    echo "64" ;;
        armv5tel|armv6l|armv7l) echo "arm32-v7a" ;;
        aarch64|armv8l)  echo "arm64-v8a" ;;
        *)               echo "64" ;;
    esac
}

# Получение последней версии Xray
get_latest_version() {
    curl -s --max-time 10 "$GITHUB_API" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
}

# Получение установленной версии Xray
get_installed_version() {
    if [ -x "$XRAY_BIN" ]; then
        "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}'
    fi
}

# Извлечение SHA256 из .dgst
extract_sha256() {
    grep -E 'SHA2-256=|SHA256=|SHA256 ' "$1" \
        | sed 's/.*= *//' \
        | tr -d '[:space:]' || true
}

# Установка зависимостей
install_deps() {
    echo "[+] Устанавливаем зависимости..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y curl unzip jq python3 uuid-runtime
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl unzip jq python3 util-linux
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl unzip jq python3 util-linux
    elif command -v apk >/dev/null 2>&1; then
        apk add curl unzip jq python3 util-linux
    else
        echo "[!] Неизвестный пакетный менеджер"
        exit 1
    fi
}

# Создание каталогов
create_dirs() {
    echo "[+] Создаём каталоги..."
    mkdir -p \
        "$XRAY_BIN_DIR" \
        "$XRAY_ETC_DIR" \
        "$XRAY_SHARE_DIR" \
        "$XRAY_LOG_DIR" \
        "$XRAY_STATE_DIR" \
        "$BACKUP_DIR"
    chmod 755 "$XRAY_LOG_DIR"
}

# Установка Xray
install_xray() {
    local version="$1"
    local arch="$2"

    echo "[+] Устанавливаем Xray..."

    # Проверяем установленную версию
    local installed_ver
    installed_ver=$(get_installed_version)
    local latest_ver_num="${version#v}"

    if [ -n "$installed_ver" ] && [ "$installed_ver" = "$latest_ver_num" ]; then
        echo "  → Xray уже актуальной версии $version, пропускаем установку"
        return 0
    fi

    [ -n "$installed_ver" ] && echo "  → Текущая версия: $installed_ver, будет обновлено до $latest_ver_num"
    [ -z "$installed_ver" ] && echo "  → Версия: $version, архитектура: $arch"

    local zip_url="${GITHUB_DOWNLOAD}/${version}/Xray-linux-${arch}.zip"
    local zip_file="${TMP_INSTALL_DIR}/xray.zip"

    mkdir -p "$XRAY_STATE_DIR" "$TMP_INSTALL_DIR"

    # Скачиваем .dgst
    echo "  → Скачиваем .dgst..."
    curl -sL --fail -o "$DGST_FILE" "${zip_url}.dgst" || {
        echo "[!] Ошибка скачивания .dgst"
        exit 1
    }

    local remote_sha
    remote_sha=$(extract_sha256 "$DGST_FILE")
    if [ -z "$remote_sha" ]; then
        echo "[!] Не удалось извлечь SHA256 из .dgst"
        exit 1
    fi

    # Проверяем, есть ли уже ZIP с таким SHA
    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$remote_sha" ] && [ -f "$zip_file" ]; then
        echo "  → Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
    else
        echo "  → Скачиваем Xray ZIP (${version})..."
        curl -L --fail -o "$zip_file" "$zip_url" || {
            echo "[!] Ошибка скачивания Xray ZIP"
            exit 1
        }

        local local_sha
        local_sha=$(sha256sum "$zip_file" | awk '{print $1}')
        if [ "$local_sha" != "$remote_sha" ]; then
            echo "[!] Ошибка: SHA не совпадает!"
            echo "  ожидалось: $remote_sha"
            echo "  получено : $local_sha"
            rm -f "$zip_file"
            exit 1
        fi

        echo "$remote_sha" > "$SHA_FILE"
    fi

    unzip -q "$zip_file" -d "$TMP_INSTALL_DIR" || {
        echo "[!] Ошибка распаковки Xray"
        exit 1
    }

    install -m 755 "${TMP_INSTALL_DIR}/xray" "$XRAY_BIN"
    rm -rf "$TMP_INSTALL_DIR"
    echo "  ✓ Xray установлен"
}

# Скачивание файла из репозитория
download_file() {
    local name="$1"
    local dest="$2"

    curl -sL --fail "${REPO_BASE}/${name}" -o "$dest" || {
        echo "[!] Ошибка скачивания $name"
        exit 1
    }
    chmod +x "$dest"
    echo "  ✓ $name"
}

# Создание systemd сервиса
create_systemd_service() {
    echo "[+] Создаём systemd сервис..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF
}

# Создание systemd таймера
create_systemd_timer() {
    echo "[+] Создаём systemd таймер..."
    cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Update Xray and geodata

[Service]
Type=oneshot
ExecStart=${UPDATE_SCRIPT}
EOF

    cat > "$UPDATE_TIMER_FILE" <<EOF
[Unit]
Description=Run Xray updater every 3 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=3h
RandomizedDelaySec=60
Unit=xray-update.service

[Install]
WantedBy=timers.target
EOF
}

# Включение сервисов
enable_services() {
    systemctl daemon-reload
    systemctl enable xray.service
    systemctl enable xray-update.timer
    systemctl start xray-update.timer
    echo "  ✓ Сервисы созданы"
}

# Деинсталляция
do_uninstall() {
    echo "===== Xray Uninstaller ====="
    echo
    echo "ВНИМАНИЕ: Это действие полностью удалит Xray и все связанные файлы."
    read -r -p "Продолжить? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "[i] Удаление отменено."
        exit 0
    fi

    echo "[+] Удаляем Xray..."

    # Остановка юнитов
    for unit in xray-update.timer xray.service xray-update.service; do
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    done

    # Удаление файлов юнитов
    rm -f "$SERVICE_FILE" "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"
    systemctl daemon-reload

    # Удаление бинарников и скриптов
    rm -f "$XRAY_BIN" "$UPDATE_SCRIPT" "$PARSER_SCRIPT" "$GENERATOR_SCRIPT"

    # Удаление каталогов
    rm -rf "$XRAY_ETC_DIR" "$XRAY_SHARE_DIR" "$XRAY_LOG_DIR"
    rm -f /tmp/new_outbounds.json
    rm -rf "$TMP_INSTALL_DIR"

    echo
    echo "✓ Xray полностью удалён"
    echo "Зависимости (jq, python3, curl) не удалены — удалите вручную при необходимости."
    exit 0
}

# ============================================================
# MAIN
# ============================================================

echo "===== Xray Installer Started ====="

check_root

# Проверка режима удаления
for arg in "$@"; do
    case $arg in
        --uninstall)
            do_uninstall
            ;;
    esac
done

check_systemd

# Парсинг подписки
SUB_URL=""
for arg in "$@"; do
    case $arg in
        --sub=*) SUB_URL="${arg#*=}" ;;
    esac
done

if [ -z "$SUB_URL" ]; then
    echo
    echo "Введите ссылку на подписку:"
    echo "(оставьте пустым — установка будет отменена)"
    read -r SUB_URL_INPUT
    [ -z "$SUB_URL_INPUT" ] && { echo "[!] Подписка не указана."; exit 1; }
    SUB_URL="$SUB_URL_INPUT"
fi

# Сохранение подписки
create_dirs
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена: $SUB_URL"

# Установка
install_deps
create_dirs

LATEST_VERSION=$(get_latest_version)
[ -z "$LATEST_VERSION" ] && { echo "[!] Не удалось получить версию Xray"; exit 1; }

ARCH=$(detect_arch)
install_xray "$LATEST_VERSION" "$ARCH"

# Скрипты
echo "[+] Устанавливаем скрипты..."
download_file "update-xray.sh" "$UPDATE_SCRIPT"
download_file "xray-sub-parser.py" "$PARSER_SCRIPT"
download_file "xray-generate-config.py" "$GENERATOR_SCRIPT"

# systemd
create_systemd_service
create_systemd_timer
enable_services

# Первое обновление
echo "[+] Выполняем первое обновление..."
"$UPDATE_SCRIPT"

echo
echo "===== Xray Installer Finished ====="
echo "Для удаления выполните: $0 --uninstall"