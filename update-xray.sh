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
# HWID
# ---------------------------------------------------------
if [ -f /etc/machine-id ]; then
    HWID="$(cat /etc/machine-id)"
else
    HWID="$(uuidgen | tr -d '-')"
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

    LOCAL_SHA_NEW=$(sha256sum "$DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA_NEW" != "$REMOTE_SHA" ]; then
        echo "    [!] Ошибка SHA256!"
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

    curl -s -L -o "$STATE_DIR/xray.dgst" "$DGST_URL"

    REMOTE_SHA=$(grep -E 'SHA2-256=|SHA256=|SHA256 ' "$STATE_DIR/xray.dgst" \
        | sed 's/.*= *//' \
        | tr -d '[:space:]')

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
echo "$SUB_DATA" | python3 /usr/local/bin/xray-sub-parser.py > /tmp/new_outbounds.json

COUNT=$(jq length /tmp/new_outbounds.json 2>/dev/null || echo 0)
echo "[+] Найдено серверов: $COUNT"

if ! jq empty /tmp/new_outbounds.json >/dev/null 2>&1; then
    echo "[!] Ошибка: некорректный JSON от парсера"
    exit 1
fi

CONFIG_FINAL="/usr/local/etc/xray/config.json"
BACKUP_DIR="/usr/local/etc/xray/backup"
mkdir -p "$BACKUP_DIR"

cp "$CONFIG_FINAL" "$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json" 2>/dev/null || true

echo "[+] Генерируем конфиг..."
python3 /usr/local/bin/xray-generate-config.py > "$CONFIG_FINAL"

# ---------------------------------------------------------
# Тест и перезапуск
# ---------------------------------------------------------
echo "[+] Тестируем конфиг..."
if "$XRAY_BIN" run -test -config "$CONFIG_FINAL"; then
    systemctl restart xray
    echo "[✓] Успешно обновлено и перезапущено!"
else
    echo "[!] Ошибка: конфиг некорректен, откатываемся"
    LAST_BACKUP=$(ls -1t "$BACKUP_DIR"/config_*.json | head -n1)
    cp "$LAST_BACKUP" "$CONFIG_FINAL"
    echo "[i] Восстановлен бэкап: $LAST_BACKUP"
    exit 1
fi

echo "===== Xray Update Finished: $(date) ====="
