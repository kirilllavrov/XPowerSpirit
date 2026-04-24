#!/usr/bin/env python3
import json

with open("/tmp/new_outbounds.json") as f:
    all_obs = json.load(f)

# -----------------------------
# ФИЛЬТР ПО ДОМЕНАМ (ТОЛЬКО WHITELIST)
# -----------------------------
DOMAIN_WHITELIST = [
    "cdn.redcook.ru"
]

filtered_obs = []
for ob in all_obs:
    vnext = ob.get("settings", {}).get("vnext", [{}])[0]
    addr = vnext.get("address", "")
    if not DOMAIN_WHITELIST:
        filtered_obs.append(ob)
        continue
    if addr in DOMAIN_WHITELIST:
        filtered_obs.append(ob)

# -----------------------------
# БАЗОВЫЙ КОНФИГ ДЛЯ КЛИЕНТА
# -----------------------------
def base_config():
    return {
      "log": {
        "loglevel": "warning",
        "access": "/var/log/xray/access.log",
        "error": "/var/log/xray/error.log"
      },
      "dns": {
        "hosts": {
          "cloudflare-dns.com": "1.1.1.1",
          "dns.google": "8.8.8.8"
        },
        "queryStrategy": "UseIPv4",
        "enableParallelQuery": True,
        "disableCache": False,
        "cacheStrategy": "cacheEnabled",
        "serveStale": True,
        "disableFallback": False,

        "servers": [
          {
            "address": "195.208.4.1",
            "port": 53,
            "domains": [
              "geosite:category-ru",
              "geosite:category-browser",
              "geosite:category-mobile",
              "geosite:category-cdn-ru",
              "geosite:private"
            ],
            "skipFallback": False
          },
          {
            "address": "195.208.5.1",
            "port": 53,
            "domains": [
              "geosite:category-ru",
              "geosite:category-browser",
              "geosite:category-mobile",
              "geosite:category-cdn-ru",
              "geosite:private"
            ],
            "skipFallback": False
          },
          {
            "address": "https://cloudflare-dns.com/dns-query",
            "domains": [
              "geosite:category-streaming",
              "geosite:category-games"
            ],
            "skipFallback": False
          },

          # Cloudflare DoH && Google DoH
          "https://cloudflare-dns.com/dns-query",
          "https://dns.google/dns-query",
        ]
      },
      # SOCKS inbound
      "inbounds": [
        {
          "port": 10802,
          "listen": "127.0.0.1",
          "protocol": "socks",
          "settings": { "udp": True },
          "tag": "socks-in"
        }
      ]
    }

# -----------------------------
# ЕСЛИ СЕРВЕРОВ НЕТ
# -----------------------------
if len(filtered_obs) == 0:
    cfg = base_config()
    cfg["outbounds"] = [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ]
    cfg["routing"] = {
        "domainStrategy": "ForceIPv4",
        "rules": [
            { "type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block" },
            { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
        ]
    }
    print(json.dumps(cfg, indent=2, ensure_ascii=False))
    exit(0)

# -----------------------------
# ЕСЛИ СЕРВЕР ОДИН
# -----------------------------
if len(filtered_obs) == 1:
    only_tag = filtered_obs[0]["tag"]
    cfg = base_config()
    cfg["outbounds"] = filtered_obs + [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
    ]
    cfg["routing"] = {
        "domainStrategy": "ForceIPv4",
        "rules": [
            { "type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block" },
            { "type": "field", "domain": ["geosite:category-streaming","geosite:category-games"], "outboundTag": only_tag },
            { "type": "field", "ip": ["geoip:ru","geoip:private"], "outboundTag": "direct" },
            { "type": "field", "domain": ["geosite:private","geosite:category-browser","geosite:category-cdn-ru","geosite:category-mobile","geosite:category-ru"], "outboundTag": "direct" },
            { "type": "field", "network": "tcp,udp", "outboundTag": only_tag }
        ]
    }
    print(json.dumps(cfg, indent=2, ensure_ascii=False))
    exit(0)

# -----------------------------
# ЕСЛИ СЕРВЕРОВ 2+
# -----------------------------
xhttp_tags, reality_tags, other_tags = [], [], []
for ob in filtered_obs:
    tag = ob.get("tag", "")
    st = ob.get("streamSettings", {})
    net = st.get("network", "")
    sec = st.get("security", "")
    if net == "xhttp":
        xhttp_tags.append(tag)
    elif sec == "reality":
        reality_tags.append(tag)
    else:
        other_tags.append(tag)

balancers = []
if xhttp_tags:
    balancers.append({"tag": "balancer-xhttp","selector": xhttp_tags,"strategy": {"type": "leastPing"}})
if reality_tags:
    balancers.append({"tag": "balancer-reality","selector": reality_tags,"strategy": {"type": "leastPing"}})
if other_tags:
    balancers.append({"tag": "balancer-other","selector": other_tags,"strategy": {"type": "leastPing"}})

rules = [
    { "type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block" },
    { "type": "field", "domain": ["geosite:category-streaming","geosite:category-games"], "balancerTag": "balancer-reality" },
    { "type": "field", "ip": ["geoip:ru","geoip:private"], "outboundTag": "direct" },
    { "type": "field", "domain": ["geosite:private","geosite:category-browser","geosite:category-cdn-ru","geosite:category-mobile","geosite:category-ru"], "outboundTag": "direct" }
]

if xhttp_tags:
    rules.append({ "type": "field", "network": "tcp,udp", "balancerTag": "balancer-xhttp" })
if reality_tags:
    rules.append({ "type": "field", "network": "tcp,udp", "balancerTag": "balancer-reality" })
if other_tags:
    rules.append({ "type": "field", "network": "tcp,udp", "balancerTag": "balancer-other" })

cfg = base_config()
cfg["outbounds"] = filtered_obs + [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
]

cfg["observatory"] = {
    "subjectSelector": ["proxy-"],
    "probeURL": "https://www.google.com/generate_204",
    "probeInterval": "120s",
    "enableConcurrency": True
}

cfg["routing"] = {
    "domainStrategy": "ForceIPv4",
    "balancers": balancers,
    "rules": rules
}

print(json.dumps(cfg, indent=2, ensure_ascii=False))

