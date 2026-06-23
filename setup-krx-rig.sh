#!/usr/bin/env bash
# ============================================================================
# setup-krx-rig.sh — настройка HiveOS-рига под майнинг KERYX (KRX) одной командой
#
# Запуск на риге (под root):
#   curl -L https://raw.githubusercontent.com/motoxnext/desktop-tutorial/main/setup-krx-rig.sh -o /tmp/s.sh && sed -i 's/\r$//' /tmp/s.sh && bash /tmp/s.sh
#
# Делает по порядку:
#   1. hysteria2 VPN (SOCKS5 1080 / HTTP 8080) + systemd-автозапуск
#   2. драйвер NVIDIA 570 (нужен для KRX PTX/cuBLAS на CMP 90HX)
#   3. kubo/IPFS: качает настоящий бинарь ЧЕРЕЗ VPN, ставит, init,
#      шлюз на 8081 (8080 занят VPN), systemd-демон ipfs
#   4. перезапуск майнера + проверка шар
#
# Идемпотентный: можно гонять повторно. Предполагает, что полётник KRX
# (keryx-miner-OPoI) уже назначен на риг в HiveOS.
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
DRV_VER="570.133.07"
KUBO_VER="v0.42.0"
KUBO_URL="https://dist.ipfs.tech/kubo/${KUBO_VER}/kubo_${KUBO_VER}_linux-amd64.tar.gz"
IPFS_PATH=/root/.ipfs
export IPFS_PATH

log(){ echo -e "\033[36m[krx]\033[0m $*"; }
err(){ echo -e "\033[31m[krx] ERROR:\033[0m $*"; }
[[ $EUID -eq 0 ]] || { err "запусти под root"; exit 1; }

# ---------------------------------------------------------------------------
# 1. hysteria VPN
# ---------------------------------------------------------------------------
log "1/4 VPN (hysteria2)..."
mkdir -p "$HY_DIR"
if [[ ! -x "$HY_DIR/hysteria" ]] || [[ $(stat -c%s "$HY_DIR/hysteria" 2>/dev/null || echo 0) -lt 5000000 ]]; then
    curl -L --connect-timeout 30 --retry 3 -o "$HY_DIR/hysteria" "$HY_BIN_URL" || { err "не скачался бинарь hysteria"; exit 2; }
    chmod +x "$HY_DIR/hysteria"
fi
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
sleep 5
systemctl is-active --quiet hysteria || { err "hysteria не поднялась — journalctl -u hysteria -n 20"; exit 3; }
# apt тоже через VPN
cat > /etc/apt/apt.conf.d/01hysteria-proxy <<EOF
Acquire::http::Proxy  "http://$HTTPP";
Acquire::https::Proxy "http://$HTTPP";
EOF
# проверка туннеля (до 30с пока хэндшейк устаканится)
for i in 1 2 3 4 5 6; do
    code=$(curl -x http://$HTTPP -s -o /dev/null -w '%{http_code}' -m 12 https://github.com 2>/dev/null || echo 000)
    [[ "$code" =~ ^(200|301)$ ]] && break
    sleep 4
done
[[ "$code" =~ ^(200|301)$ ]] && log "  VPN ОК (github=$code через прокси)" || { err "туннель не отвечает (github=$code)"; exit 4; }

# ---------------------------------------------------------------------------
# 2. драйвер NVIDIA 570 (нужен для KRX). Пропустить, если уже >= 570.
# ---------------------------------------------------------------------------
log "2/4 драйвер NVIDIA..."
CUR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
if [[ -n "$CUR" && "$CUR" -ge 570 ]]; then
    log "  драйвер уже $CUR.x — пропускаю"
else
    log "  ставлю $DRV_VER (через VPN, без ребута)..."
    nvidia-driver-update "$DRV_VER" --no-prime 2>&1 | tail -5 || log "  (предупреждения драйвера некритичны, проверь nvidia-smi ниже)"
fi
nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1

# ---------------------------------------------------------------------------
# 3. kubo / IPFS — главный блокер OPoI в РФ
# ---------------------------------------------------------------------------
log "3/4 IPFS (kubo $KUBO_VER)..."
if ! /usr/local/bin/ipfs --version 2>/dev/null | grep -q "$KUBO_VER"; then
    cd /tmp
    curl -x http://$HTTPP -sL -m 300 -o kubo.tar.gz "$KUBO_URL" || { err "kubo не скачался через VPN"; exit 5; }
    SZ=$(stat -c%s kubo.tar.gz)
    [[ $SZ -gt 40000000 ]] || { err "kubo битый ($SZ байт) — DPI режет, повтори запуск"; exit 5; }
    tar xzf kubo.tar.gz
    install -m755 kubo/ipfs /usr/local/bin/ipfs
fi
[[ -d "$IPFS_PATH" ]] || ipfs init >/dev/null 2>&1
# шлюз на 8081 (8080 занят hysteria-прокси!)
ipfs config Addresses.Gateway /ip4/127.0.0.1/tcp/8081 >/dev/null 2>&1
cat > /etc/systemd/system/ipfs.service <<EOF
[Unit]
Description=IPFS daemon for KRX OPoI
After=network-online.target
Wants=network-online.target
[Service]
Environment=IPFS_PATH=$IPFS_PATH
ExecStart=/usr/local/bin/ipfs daemon --enable-gc
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
EOF
# на всякий убить ручные screen-сессии ipfs
screen -S ipfs -X quit 2>/dev/null || true
pkill -f "ipfs daemon" 2>/dev/null || true
sleep 2
systemctl daemon-reload
systemctl enable ipfs >/dev/null 2>&1
systemctl restart ipfs
for i in 1 2 3 4 5 6; do
    curl -s -X POST http://127.0.0.1:5001/api/v0/version 2>/dev/null | grep -q Version && break
    sleep 3
done
curl -s -X POST http://127.0.0.1:5001/api/v0/version 2>/dev/null | grep -q Version \
    && log "  IPFS daemon ОК (API :5001, gateway :8081)" \
    || { err "IPFS daemon не отвечает на :5001"; exit 6; }

# ---------------------------------------------------------------------------
# 4. перезапуск майнера + проверка
# ---------------------------------------------------------------------------
log "4/4 рестарт майнера..."
miner stop  >/dev/null 2>&1; sleep 3
miner start >/dev/null 2>&1; sleep 45
echo "----- лог майнера -----"
miner log 2>/dev/null | grep -iE "reachable|accepted|share|error|fatal" | tail -10
echo "----- GPU -----"
nvidia-smi --query-gpu=index,utilization.gpu,power.draw --format=csv,noheader

log "ГОТОВО ✅  Шары идут на krx.baikalmine.com:9020 — проверь дашборд HiveOS."
