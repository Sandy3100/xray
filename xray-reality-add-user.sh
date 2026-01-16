#!/usr/bin/env bash
set -e

# =======================
# 可配置参数（Reality）
# =======================
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CLIENT_DIR="/root/xray/xray-clients"

SERVER_IP="149.28.71.196"      # 真实 VPS IP
DOMAIN="www.cloudflare.com" # Reality 伪装域名
PORT="443"
FLOW="xtls-rprx-vision"
SHORT_ID="a1b2c3d4"

# 你的 Reality 公钥（服务器级，所有客户端共用）
REALITY_PUBLIC_KEY="I56vEuFnUvHTlBdVTTzPTXxEpmHC3w7FK6ExfbYxT2E"
# =======================

if [[ $# -lt 1 ]]; then
  echo "Usage: xray-reality-add-user.sh <client_name>"
  exit 1
fi

NAME="$1"
UUID=$(xray uuid)

mkdir -p "$CLIENT_DIR"

echo "======================================"
echo "[+] New Reality client: $NAME"
echo "[+] UUID: $UUID"
echo "======================================"

# ---------- 1. 写入服务端配置 ----------
TMP=$(mktemp)

jq --arg id "$UUID" --arg flow "$FLOW" --arg email "$NAME" '
  (.inbounds[].settings.clients) += [{
    "id": $id,
    "flow": $flow,
    "email": $email
  }]
' "$XRAY_CONFIG" > "$TMP"

jq empty "$TMP"
cp "$TMP" "$XRAY_CONFIG"
rm -f "$TMP"

systemctl restart xray
echo "[+] Server config updated & reloaded"

# ---------- 2. 生成客户端 JSON ----------
CLIENT_JSON="$CLIENT_DIR/$NAME.json"

cat > "$CLIENT_JSON" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "udp": true }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER_IP",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none",
                "flow": "$FLOW"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "publicKey": "$REALITY_PUBLIC_KEY",
          "shortId": "$SHORT_ID",
          "serverName": "$DOMAIN"
        }
      }
    }
  ]
}
EOF

echo "[+] Client config written: $CLIENT_JSON"

# ---------- 3. 生成 VLESS Reality URL ----------
VLESS_URL="vless://$UUID@$SERVER_IP:$PORT?type=tcp&security=reality&flow=$FLOW&pbk=$REALITY_PUBLIC_KEY&sid=$SHORT_ID&sni=$DOMAIN#$NAME"

echo
echo "[+] VLESS Reality URL:"
echo "$VLESS_URL"
echo

# ---------- 生成 URL 文件（给只支持 URL 导入的客户端） ----------
URL_FILE="$CLIENT_DIR/$NAME.url"

cat > "$URL_FILE" <<EOF
$VLESS_URL
EOF
chmod 600 "$URL_FILE"
echo "[+] URL file generated: $URL_FILE"

# ---------- 4. 生成二维码（文件 + 终端） ----------
QR_FILE="$CLIENT_DIR/$NAME.png"

qrencode -o "$QR_FILE" "$VLESS_URL"

echo
echo "[+] QR code file: $QR_FILE"
echo "[+] QR code (terminal):"
echo
##qrencode打印二维码，通过-s调整二维码大小，1：很小；4：非常大
qrencode -t UTF8 -s 2 "$VLESS_URL"

echo
echo "[✓] Done."

