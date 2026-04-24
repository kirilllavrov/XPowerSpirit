#!/usr/bin/env python3
import sys
import base64
import json
import urllib.parse as urlparse
import re


# -----------------------------
# НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def normalize_tag(tag: str) -> str:
    # URL-decode
    tag = urlparse.unquote(tag)

    # Пробелы → _
    tag = tag.replace(" ", "_")

    # Убираем скобки
    tag = tag.replace("(", "").replace(")", "")

    # Разрешаем буквы, цифры, _, -, emoji
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-🇦-🇿🇦-🇿]", "", tag)

    # Если тег пустой — fallback
    if not tag:
        tag = "proxy"

    return tag


# -----------------------------
# BASE64 → TEXT
# -----------------------------
def try_base64_decode(data: str) -> str:
    data_stripped = data.strip()
    if "vless://" in data_stripped:
        return data_stripped
    try:
        decoded = base64.b64decode(data_stripped, validate=True).decode(errors="ignore")
        if "vless://" in decoded:
            return decoded
    except Exception:
        pass
    return data_stripped


# -----------------------------
# ПАРСЕР VLESS
# -----------------------------
def parse_vless_uri(uri: str, idx: int):
    parsed = urlparse.urlparse(uri)

    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443

    # ТЕГ
    fragment = parsed.fragment or ""
    if fragment:
        tag = normalize_tag(fragment)
    else:
        tag = f"proxy-vless-{idx}"

    # QUERY
    q = urlparse.parse_qs(parsed.query)

    def get_param(key, default=None):
        v = q.get(key)
        if not v:
            return default
        return v[0]

    # БАЗОВЫЕ ПОЛЯ
    uuid = user
    encryption = get_param("encryption", "none")
    flow = get_param("flow", None)

    # ТРАНСПОРТ
    network = get_param("type", "tcp").lower()
    if network in ("h2", "http2"):
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        network = "tcp"

    # SECURITY
    security = get_param("security", "none").lower()
    if security in ("tls", "xtls"):
        security_mode = "tls"
    elif security == "reality":
        security_mode = "reality"
    else:
        security_mode = "none"

    sni = get_param("sni", None)
    fp = get_param("fp", None)
    alpn_raw = get_param("alpn", None)
    alpn = [x.strip() for x in alpn_raw.split(",")] if alpn_raw else None

    allow_insecure = get_param("allowInsecure", "0") in ("1", "true", "yes")

    # REALITY
    pbk = get_param("pbk", None)
    sid = get_param("sid", None)
    spx = get_param("spx", None)

    # WS / HTTP / XHTTP / gRPC
    path = get_param("path", "/")
    host_header = get_param("host", None)
    grpc_service = get_param("serviceName", None) or get_param("grpc-service-name", None)
    xhttp_mode = get_param("mode", None)

    # SETTINGS
    user_obj = {
        "id": uuid,
        "encryption": encryption
    }
    if flow:
        user_obj["flow"] = flow

    settings = {
        "vnext": [
            {
                "address": host,
                "port": port,
                "users": [user_obj]
            }
        ]
    }

    # STREAM SETTINGS
    stream = {
        "network": network
    }

    # TLS / REALITY
    if security_mode == "tls":
        stream["security"] = "tls"
        tls = {}
        if sni:
            tls["serverName"] = sni
        if alpn:
            tls["alpn"] = alpn
        if fp:
            tls["fingerprint"] = fp
        if allow_insecure:
            tls["allowInsecure"] = True
        if tls:
            stream["tlsSettings"] = tls

    elif security_mode == "reality":
        stream["security"] = "reality"
        reality = {}
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
        stream["realitySettings"] = reality

    # NETWORK-SPECIFIC
    if network == "ws":
        ws = {"path": path}
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

    # OUTBOUND
    outbound = {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream
    }

    return outbound


# -----------------------------
# MAIN
# -----------------------------
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
        if line.startswith("vless://"):
            ob = parse_vless_uri(line, idx)
            if ob:
                outbounds.append(ob)
                idx += 1

    print(json.dumps(outbounds, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
