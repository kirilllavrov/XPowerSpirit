#!/usr/bin/env python3
import sys, json, base64, re, urllib.parse

def normalize_tag(s: str) -> str:
    s = s.lower()
    s = re.sub(r'[^a-z0-9\-]+', '-', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s or "srv"

def unique_tag(base: str, used: set) -> str:
    tag = base
    i = 1
    while tag in used:
        tag = f"{base}-{i}"
        i += 1
    used.add(tag)
    return tag

def get_param(params, key, default=""):
    return urllib.parse.unquote(params.get(key, [default])[0])

def get_bool_param(params, key, default=False):
    v = params.get(key, [None])[0]
    if v is None:
        return default
    v = v.lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return default

def parse_vless(link: str, used_tags: set):
    raw = link[8:]
    if '@' not in raw:
        return None

    left, right = raw.split('@', 1)

    if '?' in left:
        uuid = left.split('?', 1)[0]
    else:
        uuid = left

    if '?' in right:
        addr_port, params_raw = right.split('?', 1)
    else:
        addr_port, params_raw = right, ""

    if ':' not in addr_port:
        return None

    address, port = addr_port.rsplit(':', 1)
    try:
        port = int(port)
    except:
        return None

    params = urllib.parse.parse_qs(params_raw)
    remarks = get_param(params, "remarks", "Unknown")

    network = params.get("type", ["tcp"])[0]
    security = params.get("security", ["tls"])[0]

    r = remarks.lower()
    a = address.lower()

    if "redcook" in a:
        base = "proxy-redcook"
    elif "auto" in r or "автовыбор" in r:
        base = "proxy-auto"
    elif "ru" in r or "россия" in r:
        base = "proxy-ru"
    else:
        base = "proxy-sub"

    tag = unique_tag(normalize_tag(base), used_tags)

    ob = {
        "tag": tag,
        "protocol": "vless",
        "settings": {
            "vnext": [{
                "address": address,
                "port": port,
                "users": [{
                    "id": uuid,
                    "encryption": "none",
                    "flow": get_param(params, "flow", "")
                }]
            }]
        },
        "streamSettings": {
            "network": network,
            "security": security,
            "sockopt": {
                "tcpNoDelay": True,
                "tcpFastOpen": True
            }
        },
        "mux": {
            "enabled": False
        }
    }

    if security == "reality":
        ob["streamSettings"]["realitySettings"] = {
            "serverName": get_param(params, "sni", ""),
            "fingerprint": get_param(params, "fp", "chrome"),
            "publicKey": get_param(params, "pbk", ""),
            "shortId": get_param(params, "sid", ""),
            "spiderX": get_param(params, "spx", "/")
        }

    if security == "tls":
        alpn_raw = get_param(params, "alpn", "h2,http/1.1")
        alpn = [val.split("#")[0].strip() for val in alpn_raw.split(",") if val.strip()]
        
        ob["streamSettings"]["tlsSettings"] = {
            "serverName": get_param(params, "sni", ""),
            "fingerprint": get_param(params, "fp", "chrome"),
            "alpn": alpn,
            "allowInsecure": False
        }

    if network == "ws":
        ob["streamSettings"]["wsSettings"] = {
            "path": get_param(params, "path", "/"),
            "headers": {}
        }

    if network == "grpc":
        ob["streamSettings"]["grpcSettings"] = {
            "serviceName": get_param(params, "serviceName", "grpc"),
            "multiMode": False
        }

    if network == "h2":
        ob["streamSettings"]["httpSettings"] = {
            "path": get_param(params, "path", "/"),
            "host": [get_param(params, "host", "")]
        }

    if network == "xhttp":
        mode = get_param(params, "mode", "stream-up")
        path = get_param(params, "path", "/")

        # extra / xmux / padding / noGRPCHeader
        xmux_cMaxReuseTimes = get_param(params, "xmux_cMaxReuseTimes", "0")
        xmux_maxConcurrency = get_param(params, "xmux_maxConcurrency", "6-14")
        xmux_hMaxRequestTimes = get_param(params, "xmux_hMaxRequestTimes", "300-750")
        xmux_hMaxReusableSecs = get_param(params, "xmux_hMaxReusableSecs", "1200-2500")
        xPaddingBytes = get_param(params, "xPaddingBytes", "180-950")
        noGRPCHeader = get_bool_param(params, "noGRPCHeader", False)

        ob["streamSettings"]["xhttpSettings"] = {
            "mode": mode,
            "path": path,
            "extra": {
                "xmux": {
                    "cMaxReuseTimes": int(xmux_cMaxReuseTimes) if xmux_cMaxReuseTimes.isdigit() else 0,
                    "maxConcurrency": xmux_maxConcurrency,
                    "hMaxRequestTimes": xmux_hMaxRequestTimes,
                    "hMaxReusableSecs": xmux_hMaxReusableSecs
                },
                "xPaddingBytes": xPaddingBytes,
                "noGRPCHeader": noGRPCHeader
            }
        }

    print(f"✓ {remarks} → {tag} | {address}", file=sys.stderr)
    return ob


raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read().strip()

try:
    decoded = base64.b64decode(raw + "===").decode()
except:
    decoded = raw

links = re.findall(r'vless://[^\s]+', decoded)

used_tags = set()
outbounds = []

for link in links:
    ob = parse_vless(link, used_tags)
    if ob:
        outbounds.append(ob)

print(json.dumps(outbounds, indent=2, ensure_ascii=False))
