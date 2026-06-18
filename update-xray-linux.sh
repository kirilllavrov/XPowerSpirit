#!/bin/bash
# XPowerSpirit — автообновление Xray, geo, подписки и config.json (Linux)
#
# Вызывается systemd timer'ом ежедневно, либо вручную:
#   sudo /opt/xpower/update-xray.sh
#
# Поддерживает форматы подписок:
#   - Base64 VLESS (User-Agent: XPower/1.0)
#   - JSON Happ/Sing-box/XPower

set -euo pipefail

# ============================================
#   БЛОКИРОВКА ОТ ОДНОВРЕМЕННОГО ЗАПУСКА
# ============================================

LOCK_FILE="/var/lock/xpower-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[!] Другой экземпляр обновления уже запущен" >&2
    exit 1
fi

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

CONFIG_DIR="${XPOWER_CONFIG_DIR:-/etc/xpower}"
INSTALL_DIR="${XPOWER_INSTALL_DIR:-/opt/xpower}"
STATE_DIR="${CONFIG_DIR}/state"
LOG_DIR="${XPOWER_LOG_DIR:-/var/log/xpower}"
CACHE_DIR="${XPOWER_CACHE_DIR:-/var/cache/xpower}"
TMP_DIR="${CACHE_DIR}/update"

SETTINGS_JSON="${CONFIG_DIR}/settings.json"
CONFIG_JSON="${CONFIG_DIR}/config.json"

GENERATOR="${INSTALL_DIR}/xray-generate-config.py"
PARSER="${INSTALL_DIR}/xray-sub-parser.py"
NFT_UPDATER="${INSTALL_DIR}/update-nft.sh"

GEO_DIR="${INSTALL_DIR}"
GEOIP="${GEO_DIR}/geoip.dat"
GEOSITE="${GEO_DIR}/geosite.dat"

export XRAY_LOCATION_ASSET="$GEO_DIR"

LOG="${LOG_DIR}/update.log"

# ============================================
#   ХЕЛПЕРЫ
# ============================================

mkdir -p "$STATE_DIR" "$LOG_DIR" "$CACHE_DIR" "$TMP_DIR"

echo "===== $(date '+%Y-%m-%d %H:%M:%S') =====" >>"$LOG"

die() {
    echo "[X] $(date '+%H:%M:%S') $1" | tee -a "$LOG"
    exit 1
}

# jq-хелперы
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
    [ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
    if echo "$val" | grep -qE '^[0-9]+$'; then
        jq --argjson v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    else
        jq --arg v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    fi
    mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
    chmod 600 "$SETTINGS_JSON"
}

fetch_url() {
    local url="$1"
    local dst="$2"
    local max_retries=2
    local retry=1

    local _ua _ver _model _os
    _ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "XPower/1.0")
    _ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
    _model=$(settings_get ".device_model" 2>/dev/null || echo "")
    _os=$(settings_get ".device_os" 2>/dev/null || echo "")

    while [ $retry -le $max_retries ]; do
        if curl -sSL --max-time 30 \
            -H "User-Agent: $_ua" \
            ${_ver:+-H "X-Ver-Os: $_ver"} \
            ${_model:+-H "X-Device-Model: $_model"} \
            ${_os:+-H "X-Device-Os: $_os"} \
            -o "$dst" "$url"; then
            if [ -s "$dst" ]; then
                if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
                    rm -f "$dst"
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

# SHA256 из .dgst
extract_sha256() {
    grep '^SHA2-256' "$1" 2>/dev/null | sed 's/.*= *//' | tr -cd '0-9a-fA-F' | cut -c1-64
}

# Ротация логов (очистка при превышении размера)
rotate_log() {
    local log_file="$1"
    local max_size="${2:-524288}"  # 512KB
    [ -f "$log_file" ] || return
    local size
    size=$(stat -c%s "$log_file" 2>/dev/null || wc -c <"$log_file")
    if [ "$size" -gt "$max_size" ]; then
        : >"$log_file"
        echo "[*] Лог очищен: $log_file" >>"$LOG"
    fi
}

# ============================================
#   ПРОВЕРКИ
# ============================================

# Свободное место
FREE_SPACE=$(df / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 10240 ]; then
    die "Недостаточно места в / (нужно минимум 10MB, доступно ${FREE_SPACE}KB)"
fi

# settings.json
[ -f "$SETTINGS_JSON" ] || die "Нет $SETTINGS_JSON — запустите install-linux.sh"

# HWID
HWID=$(settings_get ".hwid")
[ -z "$HWID" ] && die "HWID пуст в settings.json"

# URL подписки
SUB_URL=$(settings_get ".subscription.url")
[ -z "$SUB_URL" ] && die "Пустой URL подписки в settings.json"

# User-Agent
SUB_USER_AGENT=$(settings_get ".subscription.user_agent")
[ -z "$SUB_USER_AGENT" ] && SUB_USER_AGENT="XPower/1.0"

# Фильтр remarks
REMARKS_FILTER=$(settings_get ".subscription.remarks_filter")

# Geo URL
GEOIP_URL=$(settings_get ".geo.geoip_url")
GEOSITE_URL=$(settings_get ".geo.geosite_url")

echo "→ UA: $SUB_USER_AGENT, HWID: $HWID" >>"$LOG"
[ -n "$REMARKS_FILTER" ] && echo "→ Фильтр remarks: $REMARKS_FILTER" >>"$LOG"

# Ротация логов
rotate_log "${LOG_DIR}/xray-access.log" 524288
rotate_log "${LOG_DIR}/xray-error.log" 262144
rotate_log "$LOG" 262144

# ============================================
#   ОБНОВЛЕНИЕ XRAY CORE
# ============================================

echo "→ Проверка обновлений Xray Core..." >>"$LOG"

for i in $(seq 1 5); do
    if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
        break
    fi
    [ "$i" = "5" ] && echo "[!] GitHub API недоступен — пропускаем обновление Xray" >>"$LOG"
    sleep 2
done

LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

if [ -z "$LATEST_VERSION" ]; then
    echo "[!] Не удалось получить версию Xray — пропускаем" >>"$LOG"
else
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) MACHINE="64" ;;
        aarch64)      MACHINE="arm64-v8a" ;;
        armv7l)       MACHINE="arm32-v7a" ;;
        *)            MACHINE="64" ;;
    esac

    ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
    ZIP_DEST="$TMP_DIR/xray.zip"
    SHA_FILE="${STATE_DIR}/xray.zip.sha256sum"

    if fetch_url "${ZIP_URL}.dgst" "${STATE_DIR}/xray.dgst"; then
        REMOTE_SHA=$(extract_sha256 "${STATE_DIR}/xray.dgst")

        if [ -n "$REMOTE_SHA" ]; then
            if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
                echo "✓ Xray ZIP не изменился (${LATEST_VERSION})" >>"$LOG"
            else
                FREE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
                if [ "$FREE_TMP" -lt 20480 ]; then
                    echo "[!] Мало места в /tmp — пропускаем обновление Xray" >>"$LOG"
                else
                    echo "→ Скачиваем Xray ${LATEST_VERSION}..." >>"$LOG"
                    if fetch_url "$ZIP_URL" "$ZIP_DEST"; then
                        LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
                        if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
                            echo "$REMOTE_SHA" >"$SHA_FILE"
                            unzip -qo "$ZIP_DEST" -d "$TMP_DIR"
                            if [ -f "$TMP_DIR/xray" ]; then
                                systemctl stop xpower-client 2>/dev/null || true
                                cp "$TMP_DIR/xray" /usr/local/bin/xray
                                chmod 755 /usr/local/bin/xray
                                echo "[+] Xray обновлён до ${LATEST_VERSION}" >>"$LOG"
                            else
                                echo "[!] Не удалось распаковать Xray" >>"$LOG"
                            fi
                        else
                            echo "[X] SHA не совпадает для Xray" >>"$LOG"
                        fi
                    else
                        echo "[!] Не удалось скачать Xray ZIP" >>"$LOG"
                    fi
                fi
            fi
        else
            echo "[!] Не удалось извлечь SHA из .dgst" >>"$LOG"
        fi
    else
        echo "[!] Не удалось скачать .dgst" >>"$LOG"
    fi
fi

# ============================================
#   ОБНОВЛЕНИЕ GEOIP / GEOSITE
# ============================================

update_geo() {
    local URL="$1"
    local DEST="$2"
    local BASE
    BASE=$(basename "$DEST")
    local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"
    local TMP_DEST="${TMP_DIR}/${BASE}"
    local TMP_SHA="${TMP_DIR}/${BASE}.sha256"

    echo "→ Обновление $BASE..." >>"$LOG"

    if ! fetch_url "${URL}.sha256sum" "$TMP_SHA"; then
        echo "[!] Не удалось скачать sha256sum для $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    REMOTE_SHA=$(cut -d' ' -f1 "$TMP_SHA" 2>/dev/null)
    if [ -z "$REMOTE_SHA" ]; then
        echo "[!] Пустой sha256sum для $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
        echo "✓ $BASE не изменился" >>"$LOG"
        return 0
    fi

    if ! fetch_url "$URL" "$TMP_DEST"; then
        echo "[!] Не удалось скачать $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    LOCAL_SHA=$(sha256sum "$TMP_DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "[X] SHA не совпадает для $BASE" >>"$LOG"
        rm -f "$TMP_DEST"
        return 1
    fi

    mv "$TMP_DEST" "$DEST"
    echo "$REMOTE_SHA" >"$SHA_FILE"
    echo "[+] $BASE обновлён" >>"$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# ============================================
#   ГЕНЕРАЦИЯ CONFIG.JSON
# ============================================

echo "→ Генерация config.json (UA: $SUB_USER_AGENT)..." >>"$LOG"

_ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
_model=$(settings_get ".device_model" 2>/dev/null || echo "")
_os=$(settings_get ".device_os" 2>/dev/null || echo "")

# Скачиваем подписку
SUB_TMP="${TMP_DIR}/subscription.txt"
PARSED_TMP="${TMP_DIR}/parsed.json"
CONFIG_TMP="${TMP_DIR}/config.json"

if curl -sSL --max-time 30 \
    -H "User-Agent: $SUB_USER_AGENT" \
    -H "x-hwid: $HWID" \
    ${_ver:+-H "X-Ver-Os: $_ver"} \
    ${_model:+-H "X-Device-Model: $_model"} \
    ${_os:+-H "X-Device-Os: $_os"} \
    -o "$SUB_TMP" "$SUB_URL"; then

    if head -n 1 "$SUB_TMP" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        echo "[X] Подписка вернула HTML" >>"$LOG"
    else
        # Парсинг → генерация
        if [ -n "$REMARKS_FILTER" ]; then
            python3 "$PARSER" --ua "$SUB_USER_AGENT" --remarks "$REMARKS_FILTER" \
                < "$SUB_TMP" > "$PARSED_TMP" 2>>"$LOG"
        else
            python3 "$PARSER" --ua "$SUB_USER_AGENT" \
                < "$SUB_TMP" > "$PARSED_TMP" 2>>"$LOG"
        fi

        if [ $? -eq 0 ] && [ -s "$PARSED_TMP" ]; then
            if python3 "$GENERATOR" --output "$CONFIG_TMP" \
                < "$PARSED_TMP" 2>>"$LOG"; then

                if /usr/local/bin/xray run -test -config "$CONFIG_TMP" >>"$LOG" 2>&1; then
                    mv "$CONFIG_TMP" "$CONFIG_JSON"
                    echo "[+] config.json обновлён" >>"$LOG"
                    
                    # Сравниваем старый и новый конфиг
                    echo "→ Обновлены прокси:" >>"$LOG"
                    python3 -c "
import json
with open('$CONFIG_JSON') as f:
    cfg = json.load(f)
tags = [o.get('tag','?') for o in cfg.get('outbounds',[]) if o.get('protocol')=='vless']
print(f'  Серверов: {len(tags)}')
for t in tags:
    print(f'    - {t}')
" 2>/dev/null >>"$LOG"
                else
                    echo "[X] Новый config.json невалиден — оставляем старый" >>"$LOG"
                    /usr/local/bin/xray run -test -config "$CONFIG_TMP" 2>>"$LOG" || true
                fi
            else
                echo "[X] Ошибка генератора конфига" >>"$LOG"
            fi
        else
            echo "[X] Ошибка парсера подписки" >>"$LOG"
        fi
    fi
else
    echo "[!] Не удалось скачать подписку" >>"$LOG"
fi

# ============================================
#   ФИНАЛЬНЫЕ ПРОВЕРКИ
# ============================================

if [ -f "$CONFIG_JSON" ]; then
    if ! /usr/local/bin/xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
        echo "[X] Итоговый config.json невалиден — останавливаем Xray" >>"$LOG"
        systemctl stop xpower-client 2>/dev/null || true
        exit 1
    fi
else
    echo "[X] config.json отсутствует — останавливаем Xray" >>"$LOG"
    systemctl stop xpower-client 2>/dev/null || true
    exit 1
fi

# ============================================
#   NFTABLES + ПЕРЕЗАПУСК
# ============================================

echo "→ Обновление nftables правил..." >>"$LOG"
if [ -x "$NFT_UPDATER" ]; then
    if "$NFT_UPDATER" >>"$LOG" 2>&1; then
        echo "[+] nftables правила обновлены" >>"$LOG"
    else
        echo "[X] Ошибка при обновлении nftables" >>"$LOG"
    fi
fi

echo "→ Перезапуск Xray..." >>"$LOG"
if systemctl restart xpower-client >>"$LOG" 2>&1; then
    echo "[+] Xray перезапущен" >>"$LOG"
else
    echo "[!] Не удалось перезапустить Xray" >>"$LOG"
fi

# ============================================
#   ОЧИСТКА
# ============================================

rm -rf "$TMP_DIR"

echo "===== Готово =====" >>"$LOG"

# Снимаем блокировку
flock -u 200
