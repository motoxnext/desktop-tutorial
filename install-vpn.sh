#!/usr/bin/env bash
# ============================================================================
# install-vpn.sh — one-shot hysteria2 VPN installer for HiveOS rigs (RU)
#
# Запуск на каждом риге одной командой:
#   curl -L https://raw.githubusercontent.com/motoxnext/desktop-tutorial/main/install-vpn.sh -o /tmp/install-vpn.sh && bash /tmp/install-vpn.sh
#
# Что делает:
#   1. качает бинарь hysteria2 (с raw.githubusercontent — риги его достают)
#   2. пишет /opt/hysteria/config.yaml (твой VPS Meganet)
#   3. ставит systemd-автозапуск (переживает ребут)
#   4. прописывает apt-прокси -> HiveOS качает майнеры по полётнику через VPN
#   5. проверяет туннель
#
# Идемпотентный: можно гонять повторно.
# ============================================================================
set -uo pipefail

HY_BIN_URL="https://raw.githubusercontent.com/motoxnext/desktop-tutorial/main/hysteria-linux-amd64"
HY_DIR="/opt/hysteria"
SRV="144.172.108.76:8443"
AUTH="8b9f81ae0dba9a8f"
SNI="bing.com"
PIN="CF:9E:50:F5:9B:60:B1:D4:E1:C0:BA:E6:5D:82:7C:0F:3A:16:AB:3F:01:71:12:CF:94:5A:8E:D5:24:DC:6D:E6"
SOCKS="127.0.0.1:1080"
HTTPP="127.0.0.1:8080"

log(){ echo -e "\033[36m[vpn]\033[0m $*"; }
err(){ echo -e "\033[31m[vpn] ERROR:\033[0m $*"; }

[[ $EUID -eq 0 ]] || { err "запусти под root"; exit 1; }

# ---- 1. бинарь ----
mkdir -p "$HY_DIR"
if [[ ! -x "$HY_DIR/hysteria" ]] || [[ $(stat -c%s "$HY_DIR/hysteria" 2>/dev/null || echo 0) -lt 5000000 ]]; then
    log "качаю hysteria..."
    curl -L --connect-timeout 30 --retry 3 -o "$HY_DIR/hysteria" "$HY_BIN_URL" || { err "не скачался бинарь (риг не достаёт raw.githubusercontent?)"; exit 2; }
    chmod +x "$HY_DIR/hysteria"
fi
SZ=$(stat -c%s "$HY_DIR/hysteria")
[[ $SZ -gt 5000000 ]] || { err "бинарь битый ($SZ байт)"; exit 2; }
log "бинарь ок ($SZ байт)"

# ---- 2. конфиг ----
cat > "$HY_DIR/config.yaml" <<EOF
server: $SRV
auth: $AUTH
tls:
  sni: $SNI
  insecure: true
  pinSHA256: $PIN
socks5:
  listen: $SOCKS
http:
  listen: $HTTPP
fastOpen: true
EOF
log "конфиг записан"

# ---- 3. systemd автозапуск ----
# на всякий случай убить ручной screen, чтоб не занимал порт
screen -S hysteria -X quit 2>/dev/null || true
pkill -f "hysteria client" 2>/dev/null || true
sleep 1

cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=hysteria2 vpn client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$HY_DIR/hysteria client -c $HY_DIR/config.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria >/dev/null 2>&1
systemctl restart hysteria
sleep 4

if systemctl is-active --quiet hysteria; then
    log "hysteria active (running)"
else
    err "hysteria не поднялась — лог: journalctl -u hysteria -n 20 --no-pager"
    journalctl -u hysteria -n 15 --no-pager
    exit 3
fi

# ---- 4. apt-прокси (HiveOS качает майнеры через apt -> пойдёт через VPN) ----
cat > /etc/apt/apt.conf.d/01hysteria-proxy <<EOF
Acquire::http::Proxy  "http://$HTTPP";
Acquire::https::Proxy "http://$HTTPP";
EOF
log "apt-прокси прописан -> полётник будет качать майнеры через VPN"

# ---- 5. проверка туннеля ----
log "проверка туннеля..."
R1=$(curl -x socks5h://$SOCKS -sI -m 15 https://github.com 2>/dev/null | head -1)
R2=$(curl -x http://$HTTPP -sI -m 15 http://download.hiveos.farm 2>/dev/null | head -1)
echo "  github через VPN:        ${R1:-НЕТ ОТВЕТА}"
echo "  download.hiveos через VPN: ${R2:-НЕТ ОТВЕТА}"

if echo "$R1" | grep -q "200\|301"; then
    log "ГОТОВО ✅ VPN работает. Полётник теперь качает мимо блокировок."
    log "Подожди обновления майнера по полётнику ИЛИ дёрни вручную:"
    log "  apt-get update && miner restart"
else
    err "туннель не отвечает — проверь, достаёт ли риг сервер $SRV (UDP)"
    exit 4
fi
