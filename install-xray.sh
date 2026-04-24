#!/bin/bash
set -e

echo "===== Xray Installer Started ====="

# ---------------------------------------------------------
# 1. Проверка root
# ---------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[!] Запустите скрипт через sudo"
    exit 1
fi

# ---------------------------------------------------------
# 2. Установка зависимостей
# ---------------------------------------------------------
echo "[+] Устанавливаем зависимости..."
if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y curl unzip jq python3
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip jq python3
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip jq python3
elif command -v apk >/dev/null 2>&1; then
    apk add curl unzip jq python3
else
    echo "[!] Неизвестный пакетный менеджер"
    exit 1
fi

# ---------------------------------------------------------
# 3. Создание каталогов
# ---------------------------------------------------------
echo "[+] Создаём каталоги..."
mkdir -p /usr/local/bin
mkdir -p /usr/local/etc/xray
mkdir -p /usr/local/share/xray
mkdir -p /var/log/xray
chmod 755 /var/log/xray

# ---------------------------------------------------------
# 4. Установка Xray (последняя версия)
# ---------------------------------------------------------
echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

TMP_DIR="/tmp/xray_install"
mkdir -p "$TMP_DIR"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"

curl -L -o "$TMP_DIR/xray.zip" "$ZIP_URL"
unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR"

install -m 755 "$TMP_DIR/xray" /usr/local/bin/xray

echo "✓ Xray установлен"

# ---------------------------------------------------------
# 5. Установка наших файлов
# ---------------------------------------------------------
echo "[+] Устанавливаем update-xray.sh, parser, generator..."

curl -sL https://raw.githubusercontent.com/kirilllavrov/xray-config/main/update-xray.sh \
    -o /usr/local/bin/update-xray.sh
chmod +x /usr/local/bin/update-xray.sh

curl -sL https://raw.githubusercontent.com/kirilllavrov/xray-config/main/xray-sub-parser.py \
    -o /usr/local/bin/xray-sub-parser.py
chmod +x /usr/local/bin/xray-sub-parser.py

curl -sL https://raw.githubusercontent.com/kirilllavrov/xray-config/main/xray-generate-config.py \
    -o /usr/local/bin/xray-generate-config.py
chmod +x /usr/local/bin/xray-generate-config.py

echo "✓ Файлы установлены"

# ---------------------------------------------------------
# 6. Создание systemd service
# ---------------------------------------------------------
echo "[+] Создаём systemd сервис..."

cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray.service

echo "✓ systemd сервис создан"

# ---------------------------------------------------------
# 7. Создание systemd timer для автообновления
# ---------------------------------------------------------
echo "[+] Создаём systemd таймер..."

cat >/etc/systemd/system/xray-update.service <<EOF
[Unit]
Description=Update Xray and geodata

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-xray.sh
EOF

cat >/etc/systemd/system/xray-update.timer <<EOF
[Unit]
Description=Run Xray updater every 3 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=3h
Unit=xray-update.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable xray-update.timer
systemctl start xray-update.timer

echo "✓ systemd таймер создан"

# ---------------------------------------------------------
# 8. Первое обновление
# ---------------------------------------------------------
echo "[+] Выполняем первое обновление..."
/usr/local/bin/update-xray.sh

echo "===== Xray Installer Finished ====="
