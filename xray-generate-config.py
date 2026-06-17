#!/usr/bin/env python3
"""
Xray Config Generator for Linux/OpenWrt TProxy

Принимает унифицированный JSON из xray-sub-parser.py:
  {"hole": bool, "outbounds": [...]}

Специальная обработка "hole":
  Если в подписке обнаружен outbound с address="hole", генерируется DIRECT-конфиг
  (весь трафик идёт напрямую, прокси отключены). Это сигнал об окончании срока подписки.

Балансировка:
  Используется стратегия leastLoad с burstObservatory для выбора наиболее стабильного прокси.

Настройки:
  Читает settings.json из XPOWER_CONFIG_DIR (по умолчанию /etc/xpower/settings.json).
"""

import json
import sys
import argparse
import os

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

SETTINGS_FILE = os.environ.get("XPOWER_CONFIG_DIR", "/etc/xpower") + "/settings.json"

# Whitelist по умолчанию (переопределяется из settings.json)
DOMAIN_WHITELIST = []

# Правила роутинга по умолчанию (переопределяются из settings.json → routing)
ROUTING_CONFIG = {
    "domainStrategy": "IPOnDemand",
    "doh_domains": [
        "common.dot.dns.yandex.net",
        "cloudflare-dns.com",
        "dns.google",
        "dns.quad9.net",
        "doh.opendns.com",
        "dns.nextdns.io"
    ],
    "block_domains": ["geosite:category-ads"],
    "direct_ips": ["geoip:ru", "geoip:private"],
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
}


def load_settings():
    """Загружает настройки из /etc/xray/settings.json"""
    global DOMAIN_WHITELIST, ROUTING_CONFIG
    if os.path.isfile(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE) as f:
                settings = json.load(f)
            DOMAIN_WHITELIST = settings.get("subscription", {}).get("domain_whitelist", [])
            # Загружаем правила роутинга (мержим с дефолтами — пользователь может переопределить любое поле)
            user_routing = settings.get("routing", {})
            if user_routing:
                for key in ROUTING_CONFIG:
                    if key in user_routing:
                        ROUTING_CONFIG[key] = user_routing[key]
        except Exception:
            pass


# ============================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpNoDelay, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}
    
    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}
    
    ob["streamSettings"]["sockopt"]["mark"] = 2
    ob["streamSettings"]["sockopt"]["tcpNoDelay"] = True
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30
    ob["streamSettings"]["sockopt"]["tcpFastOpen"] = True
    ob["streamSettings"]["sockopt"]["tcpCongestion"] = "bbr"
    
    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False
    
    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    return {
        "log": {
            "loglevel": "none",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": {
            "tag": "dns-inbuilt",
            "queryStrategy": "UseIPv4",
            "disableCache": False,
            "serveStale": True,
            "serveExpiredTTL": 600,
            "disableFallback": False,
            "disableFallbackIfMatch": True,
            "enableParallelQuery": True,
            "hosts": {
                "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
                "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"]
            },
            "servers": [
                {
                    "address": "https+local://common.dot.dns.yandex.net/dns-query",
                    "domains": ["geosite:category-ru"],
                    "expectedIPs": ["geoip:ru"],
                    "skipFallback": True
                },
                {
                    "address": "https+local://cloudflare-dns.com/dns-query",
                    "skipFallback": False
                },
                {
                    "address": "https+local://dns.nextdns.io",
                    "skipFallback": False
                }
            ]
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": 12345,
                "protocol": "dokodemo-door",
                "settings": {
                    "allowedNetwork": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": True
                }
            },
            {
                "tag": "dns-local",
                "listen": "127.0.0.1",
                "port": 5353,
                "protocol": "dokodemo-door",
                "settings": {
                    "allowedNetwork": "tcp,udp"
                }
            }
        ]
    }


def build_direct_config() -> dict:
    """Создаёт DIRECT-конфиг (без прокси) для режима 'hole'"""
    cfg = base_config()
    cfg["outbounds"] = [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg["routing"] = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules([], direct_mode=True)
    }
    return cfg


def build_dns_outbound() -> dict:
    """Создаёт outbound 'dns-out' с hijack во встроенный DNS"""
    return {
        "protocol": "dns",
        "tag": "dns-out",
        "settings": {
            "rules": [
                {
                    "action": "hijack",
                    "qtype": "1,28"
                }
            ]
        }
    }


def make_direct_outbound() -> dict:
    """Стандартный direct (freedom) outbound"""
    return {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {"domainStrategy": "UseIPv4"},
        "streamSettings": {"sockopt": {"mark": 2, "tcpKeepAliveInterval": 30}}
    }


def make_block_outbound() -> dict:
    """Стандартный block (blackhole) outbound"""
    return {
        "protocol": "blackhole",
        "tag": "block",
        "settings": {"response": {"type": "http"}}
    }


def save_config(cfg: dict, output: str) -> None:
    """Сохраняет конфиг в файл"""
    with open(output, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг сохранён: {output}", file=sys.stderr)


def build_proxy_config(proxy_outbounds: list) -> dict:
    """
    Собирает полный конфиг с прокси, burstObservatory, balancer и routing.
    Используется всеми форматами (unified, json, vless).
    """
    cfg = base_config()
    cfg["outbounds"] = proxy_outbounds + [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg.update(build_burst_observatory(proxy_outbounds))
    routing = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules(proxy_outbounds),
        "balancers": [build_balancer(proxy_outbounds)]
    }
    cfg["routing"] = routing
    return cfg


def print_proxy_summary(proxy_outbounds: list) -> None:
    """Выводит сводку о количестве прокси и балансировщике"""
    print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
    if len(proxy_outbounds) > 1:
        print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)
    else:
        tag = proxy_outbounds[0].get("tag", "proxy") if proxy_outbounds else "proxy"
        print(f"  ✓ Выбран сервер: {tag}", file=sys.stderr)
        print(f"  ✓ Балансировщик: 1 сервер + fallback DIRECT", file=sys.stderr)


def build_rules(proxy_outbounds: list, direct_mode: bool = False) -> list:
    """
    Строит правила маршрутизации.
    Использует настройки из settings.json → routing (либо дефолты).
    Если несколько прокси, использует балансировщик.
    Если один прокси, использует прямой outboundTag.
    """
    rules = [
        # Клиентский DNS (от dnsmasq) → dns-out (hijack → dns-inbuilt)
        {
            "type": "field",
            "inboundTag": ["dns-local"],
            "outboundTag": "dns-out"
        },
        # Ловим DNS через DoH, которые прошли мимо dnsmasq (от браузера)
        {
            "type": "field",
            "domain": ROUTING_CONFIG["doh_domains"],
            "outboundTag": "direct"
        },
        # Блокировка рекламы
        {
            "type": "field",
            "domain": ROUTING_CONFIG["block_domains"],
            "outboundTag": "block"
        },
        # NTP (порт 123) — напрямую
        {
            "type": "field",
            "port": "123",
            "network": "udp",
            "outboundTag": "direct"
        },
        # QUIC (UDP/443) — блокируем на уровне Xray (VLESS+XTLS не поддерживает UDP)
        {
            "type": "field",
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
        },
        # Локальные и российские IP — напрямую
        {
            "type": "field",
            "ip": ROUTING_CONFIG["direct_ips"],
            "outboundTag": "direct"
        },
        # Локальные и российские домены — напрямую
        {
            "type": "field",
            "domain": ROUTING_CONFIG["direct_domains"],
            "outboundTag": "direct"
        },
    ]
    
    if not direct_mode and proxy_outbounds:
        # Всегда через balancer — даже для одного прокси (observatory следит, fallback на direct)
        rules.append({
            "type": "field",
            "domain": ROUTING_CONFIG["proxy_domains"],
            "balancerTag": "balancer"
        })
        
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "balancerTag": "balancer"
        })
    else:
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "direct"
        })
    
    return rules


def build_balancer(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию балансировщика для нескольких прокси (leastLoad).    
    leastLoad выбирает наиболее стабильные серверы на основе данных burstObservatory.    
    Если все серверы не проходят — fallback на direct.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": {
            "type": "leastLoad",
        },
        "fallbackTag": "direct"
    }


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.
    Используется со стратегией leastLoad.
    
    Пингует connectivitycheck.gstatic.com (Google Connectivity Check) —
    более надёжный endpoint, чем google.com, не троттлится.
    GET вместо HEAD — лучше совместимость с прокси-протоколами.
    Таймаут 15s — с запасом на Reality/TLS handshake.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "1m",
                "sampling": 10,
                "timeout": "15s",
                "httpMethod": "GET"
            }
        }
    }


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for OpenWrt TProxy')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--format', default='unified', help=argparse.SUPPRESS)  # обратная совместимость, не используется
    return parser.parse_args()


def main():
    args = parse_args()
    
    # Загружаем настройки из единого JSON-конфига
    load_settings()
    if DOMAIN_WHITELIST:
        print(f"  → Domain whitelist из settings.json: {', '.join(DOMAIN_WHITELIST)}", file=sys.stderr)
    
    print("  → Обработка унифицированной подписки", file=sys.stderr)
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        log_error(f"Failed to parse unified input: {e}")
        sys.exit(1)
    
    if data.get("hole", False):
        print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
        print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
        save_config(build_direct_config(), args.output)
        return
    
    raw_outbounds = data.get("outbounds", [])
    if not raw_outbounds:
        log_error("No outbounds in unified input — switching to DIRECT")
        save_config(build_direct_config(), args.output)
        return
    
    proxy_outbounds = [normalize_outbound(ob) for ob in raw_outbounds]
    cfg = build_proxy_config(proxy_outbounds)
    print_proxy_summary(proxy_outbounds)
    save_config(cfg, args.output)


if __name__ == "__main__":
    main()