#!/bin/bash
set -e

# ============================================================
# Переменные
# ============================================================

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_ETC_DIR="/usr/local/etc/xray"
readonly XRAY_SHARE_DIR="/usr/local/share/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_STATE_DIR="/usr/local/share/xray/state"

readonly SUB_FILE="${XRAY_ETC_DIR}/subscription.url"
readonly CONFIG_FILE="${XRAY_ETC_DIR}/config.json"
readonly BACKUP_DIR="${XRAY_ETC_DIR}/backup"
readonly GEO_DIR="$XRAY_SHARE_DIR"

readonly PARSER_SCRIPT="/usr/local/bin/xray-sub-parser.py"
readonly GENERATOR_SCRIPT="/usr/local/bin/xray-generate-config.py"

readonly GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly GITHUB_DOWNLOAD="https://github.com/XTLS/Xray-core/releases/download"

readonly GEOIP_URL="https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat"
readonly GEOSITE_URL="https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"

readonly PARSER_OUTPUT="/tmp/new_outbounds.json"

# ============================================================
# Функции
# ============================================================

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

# Проверка зависимостей
check_deps() {
    for bin in jq python3 curl unzip; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "[!] Требуется $bin, но он не найден"
            exit 1
        fi
    done
}

# HWID
get_hwid() {
    if [ -f /etc/machine-id ]; then
        cat /etc/machine-id
    else
        uuidgen | tr -d '-'
    fi
}

# Загрузка подписки
load_subscription() {
    if [ -f "$SUB_FILE" ]; then
        tr -d '[:space:]' < "$SUB_FILE"
    fi
}

# Обновление geodata
download_geo_if_changed() {
    local url="$1"
    local dest="$2"
    local sha_file="${dest}.sha256sum"

    echo "[*] Проверяем geodata: $dest"

    local remote_sha
    remote_sha=$(curl -s "${url}.sha256sum" | awk '{print $1}')
    if [ -z "$remote_sha" ]; then
        echo "    [!] Не удалось получить SHA256"
        return 1
    fi

    if [ -f "$sha_file" ] && [ "$(cat "$sha_file")" = "$remote_sha" ]; then
        echo "    ✓ Файл не изменился — пропускаем"
        return 0
    fi

    echo "    → Файл изменился, скачиваем..."
    curl -L --fail -o "$dest" "$url" || {
        echo "    [!] Ошибка скачивания"
        return 1
    }

    local local_sha
    local_sha=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$local_sha" != "$remote_sha" ]; then
        echo "    [!] Ошибка SHA256!"
        rm -f "$dest"
        exit 1
    fi

    echo "$remote_sha" > "$sha_file"
    echo "    ✓ Файл обновлён"
}

# Обновление Xray
download_xray_if_changed() {
    local url="$1"
    local dest="$2"
    local sha_file="${dest}.sha256sum"
    local dgst_url="${url}.dgst"
    local dgst_file="$XRAY_STATE_DIR/xray.dgst"

    echo "[*] Проверяем Xray ZIP: $dest"

    curl -s -L -o "$dgst_file" "$dgst_url"

    local remote_sha
    remote_sha=$(grep -E 'SHA2-256=|SHA256=|SHA256 ' "$dgst_file" \
        | sed 's/.*= *//' \
        | tr -d '[:space:]' || true)

    if [ -z "$remote_sha" ]; then
        echo "    [!] Не удалось получить SHA256 из .dgst"
        exit 1
    fi

    if [ -f "$sha_file" ] && [ "$(cat "$sha_file")" = "$remote_sha" ]; then
        echo "    ✓ Xray не изменился — пропускаем"
        return 1  # не обновлён
    fi

    echo "    → Xray изменился, скачиваем ZIP..."
    curl -L --fail -o "$dest" "$url" || {
        echo "    [!] Ошибка скачивания Xray ZIP"
        exit 1
    }

    local local_sha
    local_sha=$(sha256sum "$dest" | awk '{print $1}')
    if [ "$local_sha" != "$remote_sha" ]; then
        echo "    [!] Ошибка SHA256!"
        rm -f "$dest"
        exit 1
    fi

    echo "$remote_sha" > "$sha_file"
    echo "    ✓ Xray ZIP обновлён"
    return 0  # обновлён
}

# Бэкап конфига
backup_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"
        ls -1t "$BACKUP_DIR"/config_*.json | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
}

# Восстановление из бэкапа
restore_backup() {
    local last_backup
    last_backup=$(ls -1t "$BACKUP_DIR"/config_*.json 2>/dev/null | head -n1)
    if [ -n "$last_backup" ]; then
        cp "$last_backup" "$CONFIG_FILE"
        echo "[i] Восстановлен бэкап: $last_backup"
        systemctl restart xray
    else
        echo "[!!] Нет бэкапов для отката!"
    fi
}

# ============================================================
# MAIN
# ============================================================

mkdir -p "$XRAY_LOG_DIR" "$XRAY_STATE_DIR" "$GEO_DIR" "$BACKUP_DIR"
chmod 755 "$XRAY_LOG_DIR"

echo "===== Xray Update Started: $(date) ====="

check_deps

HWID=$(get_hwid)
SUB_URL=$(load_subscription)

if [ -z "$SUB_URL" ]; then
    echo "[!] Подписка не указана"
    exit 1
fi

# Обновление Xray
echo "[+] Проверяем обновления Xray..."

ARCH=$(detect_arch)
LATEST_VERSION=$(get_latest_version)

if [ -z "$LATEST_VERSION" ]; then
    echo "[!] Не удалось получить последнюю версию Xray"
    exit 1
fi

echo "  - Последняя версия: $LATEST_VERSION"

ZIP_URL="${GITHUB_DOWNLOAD}/${LATEST_VERSION}/Xray-linux-${ARCH}.zip"
ZIP_FILE="$XRAY_STATE_DIR/xray.zip"

if download_xray_if_changed "$ZIP_URL" "$ZIP_FILE"; then
    echo "  - Распаковываем Xray..."
    rm -rf "$XRAY_STATE_DIR/unpack"
    mkdir -p "$XRAY_STATE_DIR/unpack"
    unzip -q "$ZIP_FILE" -d "$XRAY_STATE_DIR/unpack"

    echo "  - Обновляем $XRAY_BIN"
    install -m 755 "$XRAY_STATE_DIR/unpack/xray" "$XRAY_BIN"
    echo "    ✓ Xray обновлён"
else
    echo "    ✓ Xray уже актуален"
fi

# Обновление geodata
echo "[+] Проверяем обновления geodata..."
download_geo_if_changed "$GEOIP_URL" "$GEO_DIR/geoip.dat"
download_geo_if_changed "$GEOSITE_URL" "$GEO_DIR/geosite.dat"

# Подписка → парсер → генератор
echo "[+] Скачиваем подписку..."
SUB_DATA=$(curl -s -L -m 15 -H "User-Agent: Happ" -H "x-hwid: $HWID" "$SUB_URL")

echo "[+] Парсим подписку..."
PARSER_TMP=$(mktemp /tmp/parser_out.XXXXXX)

if ! echo "$SUB_DATA" | python3 "$PARSER_SCRIPT" > "$PARSER_TMP"; then
    echo "[!] Ошибка выполнения парсера"
    rm -f "$PARSER_TMP"
    exit 1
fi

if ! jq empty "$PARSER_TMP" >/dev/null 2>&1; then
    echo "[!] Ошибка: некорректный JSON от парсера"
    rm -f "$PARSER_TMP"
    exit 1
fi

COUNT=$(jq length "$PARSER_TMP")
echo "[+] Найдено серверов: $COUNT"

mv "$PARSER_TMP" "$PARSER_OUTPUT"

# Бэкап и генерация
backup_config

echo "[+] Генерируем конфиг..."
CONFIG_TMP=$(mktemp /tmp/config_gen.XXXXXX)
if ! python3 "$GENERATOR_SCRIPT" > "$CONFIG_TMP"; then
    echo "[!] Ошибка генерации конфига"
    rm -f "$CONFIG_TMP"
    exit 1
fi

# Тест и перезапуск
echo "[+] Тестируем конфиг..."
if "$XRAY_BIN" run -test -config "$CONFIG_TMP"; then
    mv "$CONFIG_TMP" "$CONFIG_FILE"
    systemctl restart xray
    echo "[✓] Успешно обновлено и перезапущено!"
else
    echo "[!] Ошибка: новый конфиг некорректен"
    rm -f "$CONFIG_TMP"
    restore_backup
    exit 1
fi

echo "===== Xray Update Finished: $(date) ====="