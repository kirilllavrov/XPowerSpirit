#!/usr/bin/env python3
import sys
import base64
import json
import urllib.parse as urlparse


def try_base64_decode(data: str) -> str:
    data_stripped = data.strip()
    # если уже есть vless:// — не трогаем
    if "vless://" in data_stripped:
        return data_stripped
    try:
        decoded = base64.b64decode(data_stripped, validate=True).decode(errors="ignore")
        if "vless://" in decoded:
            return decoded
    except Exception:
        pass
    return data_stripped


def parse_bool(val: str, default: bool = False) -> bool:
    if val is None:
        return default
    v = val.strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return default


def get_param(params, key, default=None):
    v = params.get(key)
    if not v:
        return default
    # parse_qs -> list
    if isinstance(v, list):
        return v[0]
    return v


def parse_vless_uri(uri: str, idx: int):
    """
    vless://uuid@host:port?type=ws&security=reality&pbk=...&sid=...&spx=...&sni=...&alpn=h2,http/1.1&fp=chrome&path=/ws&host=example.com#tag
    """
    parsed = urlparse.urlparse(uri)

    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443
    fragment = parsed.fragment or ""
    tag = fragment if fragment else f"proxy-vless-{idx}"

    # query params
    q = urlparse.parse_qs(parsed.query)

    # базовые поля пользователя
    uuid = user
    encryption = get_param(q, "encryption", "none")
    flow = get_param(q, "flow", None)

    # транспорт
    network = get_param(q, "type", "tcp").lower()
    if network in ("h2", "http2"):
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        network = "tcp"

    # security
    security = get_param(q, "security", "none").lower()
    if security in ("tls", "xtls"):
        security_mode = "tls"
    elif security == "reality":
        security_mode = "reality"
    else:
        security_mode = "none"

    sni = get_param(q, "sni", None)
    alpn_raw = get_param(q, "alpn", None)
    alpn = None
    if alpn_raw:
        alpn = [x.strip() for x in alpn_raw.split(",") if x.strip()]

    fp = get_param(q, "fp", None)  # fingerprint
    allow_insecure = parse_bool(get_param(q, "allowInsecure", None), False)

    # Reality
    pbk = get_param(q, "pbk", None)  # publicKey
    sid = get_param(q, "sid", None)  # shortId
    spx = get_param(q, "spx", None)  # spiderX

    # WS / HTTP / XHTTP / gRPC
    path = get_param(q, "path", "/")
    host_header = get_param(q, "host", None)
    grpc_service = get_param(q, "serviceName", None) or get_param(q, "grpc-service-name", None)
    xhttp_mode = get_param(q, "mode", None)

    # settings.vnext
    user_obj = {
        "id": uuid,
        "encryption": encryption,
    }
    if flow:
        user_obj["flow"] = flow

    settings = {
        "vnext": [
            {
                "address": host,
                "port": port,
                "users": [user_obj],
            }
        ]
    }

    # streamSettings
    stream = {
        "network": network,
    }

    # security / tls / reality
    if security_mode == "tls":
        stream["security"] = "tls"
        tls_settings = {}
        if sni:
            tls_settings["serverName"] = sni
        if alpn:
            tls_settings["alpn"] = alpn
        if fp:
            tls_settings["fingerprint"] = fp
        if allow_insecure:
            tls_settings["allowInsecure"] = True
        if tls_settings:
            stream["tlsSettings"] = tls_settings

    elif security_mode == "reality":
        stream["security"] = "reality"
        reality = {}
        # dest: host:port (часто не обязателен на клиенте, но добавим если есть sni)
        if sni:
            reality["serverName"] = sni
        if pbk:
            reality["publicKey"] = pbk
        if sid:
            reality["shortId"] = sid
        if spx:
            reality["spiderX"] = spx
        if fp:
            reality["fingerprint"] = fp
        if reality:
            stream["realitySettings"] = reality

    # network-specific settings
    if network == "ws":
        ws = {
            "path": path or "/",
        }
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws

    elif network == "grpc":
        grpc = {}
        if grpc_service:
            grpc["serviceName"] = grpc_service
        stream["grpcSettings"] = grpc

    elif network == "http":
        http = {}
        if path:
            http["path"] = path
        if host_header:
            http["host"] = [host_header]
        stream["httpSettings"] = http

    elif network == "xhttp":
        xhttp = {}
        if path:
            xhttp["path"] = path
        if host_header:
            xhttp["host"] = [host_header]
        if xhttp_mode:
            xhttp["mode"] = xhttp_mode
        stream["xhttpSettings"] = xhttp

    outbound = {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream,
    }

    return outbound


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print("[]")
        return

    data = try_base64_decode(raw)
    lines = [l.strip() for l in data.splitlines() if l.strip()]

    outbounds = []
    idx = 0
    for line in lines:
        if not line.startswith("vless://"):
            continue
        ob = parse_vless_uri(line, idx)
        if ob:
            outbounds.append(ob)
            idx += 1

    print(json.dumps(outbounds, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

