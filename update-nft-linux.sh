#!/bin/bash
# XPowerSpirit — nftables TProxy для Linux-клиента
#
# Настраивает прозрачное проксирование только для локальной машины
# (OUTPUT-цепочка, не PREROUTING).
#
# Использование:
#   ./update-nft-linux.sh           Применить правила
#   ./update-nft-linux.sh --cleanup Удалить правила
#   ./update-nft-linux.sh --check   Проверить статус

set -euo pipefail

# Кастомные пути (если не стандартная установка)
CONFIG_DIR="${XPOWER_CONFIG_DIR:-/etc/xpower}"
CONFIG_JSON="${CONFIG_DIR}/config.json"
TABLE="inet xpower"
TPROXY_PORT="${TPROXY_PORT:-12345}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================
#   ИЗВЛЕЧЕНИЕ IP ПРОКСИ-СЕРВЕРОВ
# ============================================

extract_proxy_ips() {
    [ -f "$CONFIG_JSON" ] || return 0
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
except Exception as e:
    print(f"# Error: {e}", file=sys.stderr)
' "$CONFIG_JSON" 2>/dev/null
}

# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================

setup_tproxy() {
    echo -n "Настройка nftables TProxy... "

    # --- Таблица и цепочки ---
    nft add table "$TABLE" 2>/dev/null || true

    # Цепочка tproxy
    nft add chain "$TABLE" tproxy 2>/dev/null || true
    nft flush chain "$TABLE" tproxy

    # ========================================
    # ПРАВИЛА TPROXY
    # ========================================

    # Loop protection: пакеты от Xray (mark 2) — НЕ трогаем
    nft add rule "$TABLE" tproxy meta mark 2 return

    # Локальные/частные сети — bypass
    nft add rule "$TABLE" tproxy ip daddr { \
        127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, \
        192.168.0.0/16, 169.254.0.0/16 \
    } return

    # DNS-серверы (Яндекс, Cloudflare, NextDNS) — bypass
    nft add rule "$TABLE" tproxy ip daddr { \
        77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, \
        45.90.28.0, 45.90.30.0 \
    } return

    # DHCP — не трогаем
    nft add rule "$TABLE" tproxy udp dport { 67, 68 } return

    # Bypass для IP прокси-серверов (предотвращение петель)
    for ip in $(extract_proxy_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule "$TABLE" tproxy ip daddr "$ip" return
        fi
    done

    # TProxy: TCP и UDP → localhost:TPROXY_PORT
    nft add rule "$TABLE" tproxy meta l4proto tcp tproxy ip to "127.0.0.1:${TPROXY_PORT}" meta mark set 0x1 accept
    nft add rule "$TABLE" tproxy meta l4proto udp tproxy ip to "127.0.0.1:${TPROXY_PORT}" meta mark set 0x1 accept

    # ========================================
    # POLICY ROUTING
    # ========================================

    # Очищаем старые правила
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true

    # Создаём: mark 1 → table 100 → lo
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # ========================================
    # ЦЕПОЧКА OUTPUT
    # ========================================

    nft add chain "$TABLE" output 2>/dev/null || true
    nft flush chain "$TABLE" output

    # Loop prevention
    nft add rule "$TABLE" output meta mark 2 return

    # Локальные адреса
    nft add rule "$TABLE" output ip daddr { \
        127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, \
        192.168.0.0/16, 169.254.0.0/16 \
    } return

    # DNS bypass
    nft add rule "$TABLE" output ip daddr { \
        77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, \
        45.90.28.0, 45.90.30.0 \
    } return

    # DHCP bypass
    nft add rule "$TABLE" output udp dport { 67, 68 } return

    # Bypass IP прокси-серверов
    for ip in $(extract_proxy_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule "$TABLE" output ip daddr "$ip" return
        fi
    done

    # Маркируем и направляем в tproxy
    nft add rule "$TABLE" output meta l4proto { tcp, udp } meta mark set 0x1 jump tproxy

    # ========================================
    # ПОДКЛЮЧЕНИЕ К ОСНОВНОЙ ЦЕПОЧКЕ
    # ========================================

    # Создаём таблицу/цепочку filter:OUTPUT если их нет
    nft add table inet filter 2>/dev/null || true
    nft add chain inet filter OUTPUT 2>/dev/null || true

    # Вставляем jump в начало OUTPUT, если ещё не добавлен
    if ! nft list chain inet filter OUTPUT 2>/dev/null | grep -q 'jump xpower_output'; then
        nft insert rule inet filter OUTPUT jump xpower_output
        echo "вставлен jump в filter:OUTPUT"
    fi

    echo -e "${GREEN}OK${NC}"
    echo "  ✓ TProxy порт: ${TPROXY_PORT}"
    echo "  ✓ Policy routing: fwmark 1 → table 100 → lo"

    # Выводим IP прокси-серверов
    local proxy_count=0
    for ip in $(extract_proxy_ips); do
        proxy_count=$((proxy_count + 1))
    done
    echo "  ✓ Прокси-серверов в bypass: $proxy_count"

    logger -t xpower-nft "Xray TProxy rules applied"
}

# ============================================
#   УДАЛЕНИЕ ПРАВИЛ
# ============================================

cleanup() {
    echo -n "Удаление nftables правил... "

    # Убираем jump из filter:OUTPUT
    local handle
    handle=$(nft -a list chain inet filter OUTPUT 2>/dev/null | \
        grep 'jump xpower_output' | sed 's/.*handle //' | head -1)
    [ -n "$handle" ] && nft delete rule inet filter OUTPUT handle "$handle" 2>/dev/null

    # Удаляем таблицу xpower
    nft delete table "$TABLE" 2>/dev/null || true

    # Policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true

    echo -e "${GREEN}OK${NC}"
    logger -t xpower-nft "Xray TProxy rules removed"
}

# ============================================
#   ПРОВЕРКА СТАТУСА
# ============================================

check_status() {
    echo "=== XPowerSpirit nftables Status ==="
    echo ""

    # Таблица xpower
    if nft list table "$TABLE" >/dev/null 2>&1; then
        echo -e "Таблица xpower:     ${GREEN}существует${NC}"
        echo ""
        nft list table "$TABLE" 2>/dev/null
    else
        echo -e "Таблица xpower:     ${RED}отсутствует${NC}"
    fi

    echo ""

    # Policy routing
    if ip rule show | grep -q 'fwmark 0x1 lookup 100'; then
        echo -e "Policy routing:     ${GREEN}настроен${NC}"
        echo "  $(ip rule show | grep 'fwmark 0x1')"
    else
        echo -e "Policy routing:     ${RED}не настроен${NC}"
    fi

    echo ""

    # Xray порт
    if ss -tlnp 2>/dev/null | grep -q ":${TPROXY_PORT}"; then
        echo -e "Xray TProxy (:${TPROXY_PORT}): ${GREEN}слушает${NC}"
    else
        echo -e "Xray TProxy (:${TPROXY_PORT}): ${RED}не слушает${NC}"
    fi
}

# ============================================
#   ТОЧКА ВХОДА
# ============================================

case "${1:-}" in
    --cleanup)
        cleanup
        ;;
    --check|--status|status)
        check_status
        ;;
    --help|-h)
        echo "XPowerSpirit nftables TProxy для Linux-клиента"
        echo ""
        echo "Использование:"
        echo "  $0             Применить TProxy правила"
        echo "  $0 --cleanup   Удалить все правила"
        echo "  $0 --check     Проверить статус"
        echo ""
        echo "Переменные окружения:"
        echo "  XPOWER_CONFIG_DIR  Путь к конфигам (по умолчанию: /etc/xpower)"
        echo "  TPROXY_PORT        Порт TProxy (по умолчанию: 12345)"
        ;;
    *)
        setup_tproxy
        ;;
esac
