#!/bin/bash
set -e

LOG_DIR="/var/log/xray"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

echo "===== Xray Update Started: $(date) ====="

# ---------------------------------------------------------
# Проверка зависимостей
# ---------------------------------------------------------
for bin in jq python3 curl unzip; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "[!] Требуется $bin, но он не найден"
        exit 1
    fi
done

XRAY_BIN="/usr/local/bin/xray"

# ---------------------------------------------------------
# HWID (Стабильный идентификатор)
# ---------------------------------------------------------
HWID_FILE="/usr/local/etc/xray/hwid"
mkdir -p "$(dirname "$HWID_FILE")"

if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
elif [ -f /etc/machine-id ]; then
    HWID="$(cat /etc/machine-id)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
else
    HWID="$(uuidgen | tr -d '-')"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

# ---------------------------------------------------------
# Подписка
# ---------------------------------------------------------
SUB_FILE="/usr/local/etc/xray/subscription.url"
if [ -f "$SUB_FILE" ]; then
    SUB_URL="$(cat "$SUB_FILE" | tr -d '[:space:]')"
fi

if [ -z "$SUB_URL" ]; then
    echo "[!] Подписка не указана"
    exit 1
fi

# ---------------------------------------------------------
# Каталог состояния
# ---------------------------------------------------------
STATE_DIR="/usr/local/share/xray/state"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------
# Функция обновления geodata
# ---------------------------------------------------------
download_geo_if_changed() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${DEST}.sha256sum"

    echo "[*] Проверяем geodata: $DEST"
    
    # Получаем удаленный хеш
    REMOTE_SHA=$(curl -s "${URL}.sha256sum" | awk '{print $1}')
    if [ -z "$REMOTE_SHA" ]; then
        echo "    [!] Не удалось получить SHA256"
        return 1
    fi

    if [ -f "$SHA_FILE" ]; then
        LOCAL_SHA=$(cat "$SHA_FILE")
        if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
            echo "    ✓ Файл не изменился — пропускаем"
            return 0
        fi
    fi

    echo "    → Файл изменился, скачиваем..."
    curl -L -o "$DEST" "$URL"
    
    # Проверка локального хеша
    LOCAL_SHA_NEW=$(sha256sum "$DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA_NEW" != "$REMOTE_SHA" ]; then
        echo "    [!] Ошибка SHA256!"
        rm -f "$DEST"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"
    echo "    ✓ Файл обновлён"
}

# ---------------------------------------------------------
# Функция обновления Xray
# ---------------------------------------------------------
XRAY_UPDATED=0
download_xray_if_changed() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${DEST}.sha256sum"
    local DGST_URL="${URL}.dgst"

    echo "[*] Проверяем Xray ZIP: $DEST"
    
    # Скачиваем dgst
    curl -s -L -o "$STATE_DIR/xray.dgst" "$DGST_URL"
    
    # Парсим хеш. || true предотвращает выход по set -e если grep ничего не найдет
    REMOTE_SHA=$(grep -E 'SHA2-256=|SHA256=|SHA256 ' "$STATE_DIR/xray.dgst" \
        | sed 's/.*= *//' \
        | tr -d '[:space:]' || true)

    if [ -z "$REMOTE_SHA" ]; then
        echo "    [!] Не удалось получить SHA256 из .dgst"
        exit 1
    fi

    if [ -f "$SHA_FILE" ]; then
        LOCAL_SHA=$(cat "$SHA_FILE")
        if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
            echo "    ✓ Xray не изменился — пропускаем"
            return 0
        fi
    fi

    echo "    → Xray изменился, скачиваем ZIP..."
    curl -L -o "$DEST" "$URL"
    
    LOCAL_SHA_NEW=$(sha256sum "$DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA_NEW" != "$REMOTE_SHA" ]; then
        echo "    [!] Ошибка SHA256!"
        rm -f "$DEST"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"
    XRAY_UPDATED=1
    echo "    ✓ Xray ZIP обновлён"
}

# ---------------------------------------------------------
# Обновление Xray
# ---------------------------------------------------------
echo "[+] Проверяем обновления Xray..."
case "$(uname -m)" in
    'amd64'|'x86_64') MACHINE='64' ;;
    'aarch64'|'armv8') MACHINE='arm64-v8a' ;;
    'armv7'|'armv7l') MACHINE='arm32-v7a' ;;
    *) MACHINE='64' ;;
esac

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

if [ -z "$LATEST_VERSION" ]; then
    echo "[!] Не удалось получить последнюю версию Xray"
    exit 1
fi

echo "  - Последняя версия: $LATEST_VERSION"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_FILE="$STATE_DIR/xray.zip"

download_xray_if_changed "$ZIP_URL" "$ZIP_FILE"

if [ "$XRAY_UPDATED" = "1" ]; then
    echo "  - Распаковываем Xray..."
    rm -rf "$STATE_DIR/unpack"
    mkdir -p "$STATE_DIR/unpack"
    unzip -q "$ZIP_FILE" -d "$STATE_DIR/unpack"
    
    echo "  - Обновляем /usr/local/bin/xray"
    install -m 755 "$STATE_DIR/unpack/xray" "$XRAY_BIN"
    echo "    ✓ Xray обновлён"
else
    echo "    ✓ Xray уже актуален"
fi

# ---------------------------------------------------------
# Обновление geodata
# ---------------------------------------------------------
GEO_DIR="/usr/local/share/xray"
mkdir -p "$GEO_DIR"

echo "[+] Проверяем обновления geodata..."
download_geo_if_changed \
    "https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat" \
    "$GEO_DIR/geoip.dat"

download_geo_if_changed \
    "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat" \
    "$GEO_DIR/geosite.dat"

# ---------------------------------------------------------
# Подписка → парсер → генератор
# ---------------------------------------------------------
echo "[+] Скачиваем подписку..."
SUB_DATA=$(curl -s -L -m 15 -H "User-Agent: Happ" -H "x-hwid: $HWID" "$SUB_URL")

echo "[+] Парсим подписку..."
# Используем временный файл для атомарности
PARSER_OUTPUT=$(mktemp /tmp/parser_out.XXXXXX)

if ! echo "$SUB_DATA" | python3 /usr/local/bin/xray-sub-parser.py > "$PARSER_OUTPUT"; then
    echo "[!] Ошибка выполнения парсера"
    rm -f "$PARSER_OUTPUT"
    exit 1
fi

# Проверка валидности JSON
if ! jq empty "$PARSER_OUTPUT" >/dev/null 2>&1; then
    echo "[!] Ошибка: некорректный JSON от парсера"
    rm -f "$PARSER_OUTPUT"
    exit 1
fi

COUNT=$(jq length "$PARSER_OUTPUT")
echo "[+] Найдено серверов: $COUNT"

# Перемещаем результат в стандартное место, которое ждет генератор
mv "$PARSER_OUTPUT" /tmp/new_outbounds.json

CONFIG_FINAL="/usr/local/etc/xray/config.json"
BACKUP_DIR="/usr/local/etc/xray/backup"
mkdir -p "$BACKUP_DIR"

# Бэкап текущего конфига
if [ -f "$CONFIG_FINAL" ]; then
    cp "$CONFIG_FINAL" "$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"
    # Удаляем старые бэкапы, оставляем 5 последних
    ls -1t "$BACKUP_DIR"/config_*.json | tail -n +6 | xargs rm -f 2>/dev/null || true
fi

echo "[+] Генерируем конфиг..."
CONFIG_TMP=$(mktemp /tmp/config_gen.XXXXXX)
if ! python3 /usr/local/bin/xray-generate-config.py > "$CONFIG_TMP"; then
    echo "[!] Ошибка генерации конфига"
    rm -f "$CONFIG_TMP"
    exit 1
fi

# ---------------------------------------------------------
# Тест и перезапуск
# ---------------------------------------------------------
echo "[+] Тестируем конфиг..."
if "$XRAY_BIN" run -test -config "$CONFIG_TMP"; then
    # Атомарная замена конфига
    mv "$CONFIG_TMP" "$CONFIG_FINAL"
    systemctl restart xray
    echo "[✓] Успешно обновлено и перезапущено!"
else
    echo "[!] Ошибка: новый конфиг некорректен"
    rm -f "$CONFIG_TMP"
    
    # Откат к бэкапу
    LAST_BACKUP=$(ls -1t "$BACKUP_DIR"/config_*.json 2>/dev/null | head -n1)
    if [ -n "$LAST_BACKUP" ]; then
        cp "$LAST_BACKUP" "$CONFIG_FINAL"
        echo "[i] Восстановлен бэкап: $LAST_BACKUP"
        systemctl restart xray
    else
        echo "[!!] Нет бэкапов для отката!"
    fi
    exit 1
fi

echo "===== Xray Update Finished: $(date) ====="