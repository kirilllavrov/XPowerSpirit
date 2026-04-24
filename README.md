# XPowerSpirit - Xray Install Scripts

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-linux-blue)
![Systemd](https://img.shields.io/badge/init-systemd-orange)
![Xray](https://img.shields.io/badge/Xray-Automated%20Installer-purple)

Полный набор скриптов для установки и автоматического обновления Xray:

- Автоматическая установка Xray
- Автоматическое обновление Xray и geodata
- Парсер подписки
- Генератор конфига
- systemd сервисы и таймеры
- Поддержка пользовательской подписки (аргумент или интерактив)

---

## ⚠️ Требуется указать ссылку на подписку

Вы должны указать ссылку:

- через аргумент `--sub=...`
- или вручную при интерактивном вводе

Если подписка не указана — установка будет отменена.

---

## 🌐 Настройка системного прокси (обязательно)

После установки Xray запускается локальный SOCKS5‑прокси: 127.0.0.1:1080

Чтобы трафик начал идти через Xray, необходимо настроить системный прокси.

### Linux (GNOME / KDE / XFCE)

Откройте: Настройки → Сеть → Прокси

и укажите:

- **SOCKS5 proxy:** `127.0.0.1`
- **Port:** `1080`

### Через переменные окружения (консоль)

Добавьте в `~/.bashrc` или `~/.zshrc`:

```bash
export ALL_PROXY="socks5://127.0.0.1:1080"
export all_proxy="socks5://127.0.0.1:1080"
source ~/.bashrc
```

## 🚀 Установка
Вариант 1 — указать подписку аргументом
```bash
curl -sL https://raw.githubusercontent.com/kirilllavrov/install-scripts/main/install-xray.sh \
  | sudo bash -s -- --sub="https://example.com/subscription"
```

## 📌 Где хранится подписка

После установки ссылка сохраняется в файл:
```Код

/usr/local/etc/xray/subscription.url
```
Чтобы изменить подписку:
```bash
echo "https://new-subscription-url" | sudo tee /usr/local/etc/xray/subscription.url
sudo systemctl start xray-update.service
```
## 🔄 Автообновление

Работает через systemd timer:
```Код

xray-update.timer → каждые 3 часа
```
Запуск вручную:
```bash
sudo systemctl start xray-update.service
```

## 🧩 Что делает скрипт

   - скачивает и обновляет Xray

   - скачивает и обновляет geoip.dat и geosite.dat

   - скачивает подписку

   - парсит её в outbounds

   - генерирует финальный config.json

   - тестирует конфиг

   - перезапускает Xray

