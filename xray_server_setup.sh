#!/usr/bin/env bash
# xray-server_setup.sh
# 一键部署 Xray VLESS+Reality + 自动生成 add/list/del 工具脚本
set -euo pipefail

############################
# 可配置参数（环境变量可覆盖）
############################
PORT="${PORT:-443}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
FLOW="${FLOW:-xtls-rprx-vision}"
LOGLEVEL="${LOGLEVEL:-warning}"

# Reality 伪装站点
SNI_HOST="${SNI_HOST:-www.cloudflare.com}"
DEST_HOST="${DEST_HOST:-www.cloudflare.com}"
DEST_PORT="${DEST_PORT:-443}"

# 客户端文件输出目录
CLIENT_DIR_DEFAULT="${CLIENT_DIR_DEFAULT:-/root/xray/xray-clients}"

############################
# 路径
############################
XRAY_BIN="/usr/local/bin/xray"
CFG_DIR="/usr/local/etc/xray"
CFG_FILE="${CFG_DIR}/config.json"
REALITY_ENV="${CFG_DIR}/reality.env"

SYSTEMD_SERVICE="/etc/systemd/system/xray.service"

BIN_DIR="/usr/local/sbin"
ADD_USER_BIN="${BIN_DIR}/xray-reality-add-user"
LIST_USER_BIN="${BIN_DIR}/xray-reality-list-users"
DEL_USER_BIN="${BIN_DIR}/xray-reality-del-user"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] 请用 root 运行：sudo bash $0"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  echo "[*] 安装依赖 (curl, unzip, ca-certificates, jq, qrencode)..."
  apt-get update -y
  apt-get install -y curl unzip ca-certificates jq qrencode >/dev/null
}

install_xray() {
  if [[ -x "${XRAY_BIN}" ]]; then
    echo "[*] 检测到已安装 Xray：$(${XRAY_BIN} version | head -n 1 || true)"
    return
  fi

  echo "[*] 安装 Xray-core（官方脚本）..."
  bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

  if [[ ! -x "${XRAY_BIN}" ]]; then
    echo "[!] Xray 安装失败：未找到 ${XRAY_BIN}"
    exit 1
  fi
}

patch_xray_service_user_root() {
  if [[ ! -f "${SYSTEMD_SERVICE}" ]]; then
    echo "[!] 未找到 ${SYSTEMD_SERVICE}，跳过 User=root 修补"
    return
  fi

  if grep -q '^User=root$' "${SYSTEMD_SERVICE}"; then
    echo "[*] xray.service 已经是 User=root"
    return
  fi

  cp -a "${SYSTEMD_SERVICE}" "${SYSTEMD_SERVICE}.bak_$(date +%Y%m%d_%H%M%S)"

  if grep -q '^User=nobody$' "${SYSTEMD_SERVICE}"; then
    sed -i 's/^User=nobody$/User=root/' "${SYSTEMD_SERVICE}"
    echo "[*] 已将 xray.service 中的 User=nobody 改为 User=root"
  elif grep -q '^User=' "${SYSTEMD_SERVICE}"; then
    sed -i 's/^User=.*/User=root/' "${SYSTEMD_SERVICE}"
    echo "[*] 已将 xray.service 中的 User=... 改为 User=root"
  else
    awk '
      BEGIN { inserted=0 }
      /^\[Service\]/ {
        print
        print "User=root"
        inserted=1
        next
      }
      { print }
      END {
        if (inserted==0) {
          print "[Service]"
          print "User=root"
        }
      }
    ' "${SYSTEMD_SERVICE}" > "${SYSTEMD_SERVICE}.tmp"
    mv "${SYSTEMD_SERVICE}.tmp" "${SYSTEMD_SERVICE}"
    echo "[*] 已向 xray.service 写入 User=root"
  fi
}

get_public_ip() {
  local ip=""
  ip="$(curl -4s --max-time 3 https://api.ipify.org || true)"
  [[ -n "${ip}" ]] || ip="$(curl -4s --max-time 3 https://ifconfig.me || true)"
  [[ -n "${ip}" ]] || ip="$(curl -4s --max-time 3 https://ipv4.icanhazip.com || true)"
  ip="$(echo "${ip}" | tr -d ' \r\n')"
  [[ -n "${ip}" ]] || ip="UNKNOWN_PUBLIC_IP"
  echo "${ip}"
}

rand_shortid() {
  if have_cmd openssl; then
    openssl rand -hex 8
  else
    hexdump -n 8 -e '8/1 "%02x"' /dev/urandom
  fi
}

gen_uuid() {
  "${XRAY_BIN}" uuid | tr -d '\r\n'
}

# 兼容新旧 xray x25519 输出：
# 旧：Private key / Public key
# 新：PrivateKey / Password / Hash32
# 其中 Password 可作为客户端 public key 使用
gen_reality_keys() {
  local out priv pub
  out="$("${XRAY_BIN}" x25519 || true)"

  priv="$(
    echo "${out}" |
      awk -F': ' '
        /Private key/ {print $2}
        /PrivateKey/  {print $2}
      ' | head -n1 | tr -d '\r'
  )"

  pub="$(
    echo "${out}" |
      awk -F': ' '
        /Public key/ {print $2}
        /PublicKey/  {print $2}
        /Password/   {print $2}
      ' | head -n1 | tr -d '\r'
  )"

  if [[ -z "${priv}" || -z "${pub}" ]]; then
    echo "[!] 解析 Reality 密钥失败，原始输出："
    echo "${out}"
    return 1
  fi

  echo "${priv}|${pub}"
}

backup_if_exists() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "${f}" "${f}.bak_${ts}"
    echo "[*] 备份 -> ${f}.bak_${ts}"
  fi
}

write_server_config() {
  local admin_uuid="$1"
  local priv="$2"
  local shortid="$3"

  mkdir -p "${CFG_DIR}"
  backup_if_exists "${CFG_FILE}"

  cat > "${CFG_FILE}" <<EOF
{
  "log": { "loglevel": "${LOGLEVEL}" },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "${LISTEN_ADDR}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${admin_uuid}", "flow": "${FLOW}", "email": "admin" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_HOST}:${DEST_PORT}",
          "xver": 0,
          "serverNames": [ "${SNI_HOST}" ],
          "privateKey": "${priv}",
          "shortIds": [ "${shortid}" ]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

  chmod 600 "${CFG_FILE}"
  echo "[*] 写入服务端配置：${CFG_FILE}"

  if ! "${XRAY_BIN}" run -test -config "${CFG_FILE}" >/dev/null 2>&1; then
    echo "[!] 配置校验失败，但 config 已写入：${CFG_FILE}"
    echo "    查看错误：journalctl -u xray -n 200 --no-pager"
  else
    echo "[*] 配置校验通过"
  fi
}

setup_firewall() {
  echo "[*] 放行端口 ${PORT}/tcp（尽量不破坏你现有策略）..."

  if have_cmd ufw; then
    local s
    s="$(ufw status 2>/dev/null | head -n 1 || true)"
    if echo "${s}" | grep -qi "active"; then
      ufw allow "${PORT}/tcp" >/dev/null || true
      echo "    - UFW: 已放行 ${PORT}/tcp"
    else
      echo "    - UFW: 未启用（跳过）"
    fi
  fi

  if have_cmd iptables; then
    if ! iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1 || true
      echo "    - iptables: 已尝试放行 ${PORT}/tcp"
    else
      echo "    - iptables: 规则已存在（跳过）"
    fi
  fi

  echo "[!] 云服务器记得在【云安全组】也放行 ${PORT}/tcp"
}

restart_xray() {
  echo "[*] 修补 xray.service 为 User=root ..."
  patch_xray_service_user_root

  echo "[*] 重载并重启 xray ..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray

  echo "[*] 监听端口："
  ss -lntp | grep -E ":${PORT}\b" || echo "    (未找到监听，查看：journalctl -u xray -n 200 --no-pager)"
}

write_reality_env() {
  local server_ip="$1"
  local shortid="$2"
  local pub="$3"

  backup_if_exists "${REALITY_ENV}"

  mkdir -p "${CFG_DIR}"
  cat > "${REALITY_ENV}" <<EOF
# Auto generated by xray-server_setup.sh
XRAY_CONFIG="${CFG_FILE}"
CLIENT_DIR="${CLIENT_DIR_DEFAULT}"

# Server connect info
SERVER_IP="${server_ip}"
DOMAIN="${SNI_HOST}"
PORT="${PORT}"
FLOW="${FLOW}"

# Reality params
SHORT_ID="${shortid}"
REALITY_PUBLIC_KEY="${pub}"

# Inbound tag
INBOUND_TAG="reality-in"
EOF

  chmod 600 "${REALITY_ENV}"
  echo "[*] 写入共享参数：${REALITY_ENV}"

  mkdir -p "${CLIENT_DIR_DEFAULT}"
  chmod 700 "${CLIENT_DIR_DEFAULT}"
}

install_tool_scripts() {
  mkdir -p "${BIN_DIR}"
  chmod 755 "${BIN_DIR}"

  # ---------- add-user ----------
  cat > "${ADD_USER_BIN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REALITY_ENV="/usr/local/etc/xray/reality.env"
[[ -f "${REALITY_ENV}" ]] || { echo "[!] 找不到 ${REALITY_ENV}，请先运行 xray-server_setup.sh"; exit 1; }
# shellcheck disable=SC1090
source "${REALITY_ENV}"

command -v xray >/dev/null 2>&1 || { echo "[!] xray 未安装或不在 PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[!] 缺少 jq：apt-get install -y jq"; exit 1; }
command -v qrencode >/dev/null 2>&1 || { echo "[!] 缺少 qrencode：apt-get install -y qrencode"; exit 1; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <client_name>"
  exit 1
fi

NAME="$1"
UUID="$(xray uuid)"

mkdir -p "${CLIENT_DIR}"
chmod 700 "${CLIENT_DIR}"

if ! jq -e --arg tag "${INBOUND_TAG}" '.inbounds[] | select(.tag==$tag)' "${XRAY_CONFIG}" >/dev/null; then
  echo "[!] 未找到 tag=${INBOUND_TAG} 的 inbound，拒绝修改。"
  exit 1
fi

if jq -e --arg tag "${INBOUND_TAG}" --arg email "${NAME}" '
  .inbounds[]
  | select(.tag==$tag)
  | .settings.clients[]?
  | select(.email==$email)
' "${XRAY_CONFIG}" >/dev/null; then
  echo "[!] 已存在 email=${NAME} 的用户，拒绝重复添加。"
  exit 1
fi

echo "======================================"
echo "[+] New Reality client: ${NAME}"
echo "[+] UUID: ${UUID}"
echo "======================================"

TMP="$(mktemp)"
jq --arg tag "${INBOUND_TAG}" --arg id "${UUID}" --arg flow "${FLOW}" --arg email "${NAME}" '
  .inbounds |= map(
    if .tag == $tag then
      .settings.clients += [{"id":$id,"flow":$flow,"email":$email}]
    else
      .
    end
  )
' "${XRAY_CONFIG}" > "${TMP}"

jq empty "${TMP}"
cp "${TMP}" "${XRAY_CONFIG}"
rm -f "${TMP}"

systemctl restart xray
echo "[+] Server config updated & reloaded"

# ---------- xray/v2ray 客户端 JSON ----------
CLIENT_JSON="${CLIENT_DIR}/${NAME}.json"
cat > "${CLIENT_JSON}" <<EOF2
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
            "address": "${SERVER_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none",
                "flow": "${FLOW}"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "serverName": "${DOMAIN}"
        }
      }
    }
  ]
}
EOF2
chmod 600 "${CLIENT_JSON}"
echo "[+] Client config written: ${CLIENT_JSON}"

# ---------- VLESS URL ----------
VLESS_URL="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&flow=${FLOW}&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&sni=${DOMAIN}#${NAME}"

echo
echo "[+] VLESS Reality URL:"
echo "${VLESS_URL}"
echo

URL_FILE="${CLIENT_DIR}/${NAME}.url"
echo "${VLESS_URL}" > "${URL_FILE}"
chmod 600 "${URL_FILE}"
echo "[+] URL file generated: ${URL_FILE}"

# ---------- Clash YAML ----------
CLASH_YAML="${CLIENT_DIR}/${NAME}.yaml"
cat > "${CLASH_YAML}" <<EOF2
proxies:
  - name: "${NAME}"
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    servername: ${DOMAIN}
    flow: ${FLOW}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${NAME}"
      - DIRECT

rules:
  - MATCH,PROXY
EOF2
chmod 600 "${CLASH_YAML}"
echo "[+] Clash YAML generated: ${CLASH_YAML}"

# ---------- sing-box JSON ----------
SINGBOX_JSON="${CLIENT_DIR}/${NAME}.singbox.json"
cat > "${SINGBOX_JSON}" <<EOF2
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": ${PORT},
      "uuid": "${UUID}",
      "flow": "${FLOW}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ]
}
EOF2
chmod 600 "${SINGBOX_JSON}"
echo "[+] sing-box config generated: ${SINGBOX_JSON}"

# ---------- QR ----------
QR_FILE="${CLIENT_DIR}/${NAME}.png"
qrencode -o "${QR_FILE}" "${VLESS_URL}"

echo
echo "[+] QR code file: ${QR_FILE}"
echo "[+] QR code (terminal):"
echo
qrencode -t UTF8 -s 2 "${VLESS_URL}"

echo
echo "[✓] Done."
EOF
  chmod +x "${ADD_USER_BIN}"

  # ---------- list-users ----------
  cat > "${LIST_USER_BIN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REALITY_ENV="/usr/local/etc/xray/reality.env"
[[ -f "${REALITY_ENV}" ]] || { echo "[!] 找不到 ${REALITY_ENV}，请先运行 xray-server_setup.sh"; exit 1; }
# shellcheck disable=SC1090
source "${REALITY_ENV}"

command -v jq >/dev/null 2>&1 || { echo "[!] 缺少 jq：apt-get install -y jq"; exit 1; }

echo "================== Xray Reality Users =================="
echo "Config: ${XRAY_CONFIG}"
echo "Inbound tag: ${INBOUND_TAG} | Port: ${PORT} | SNI: ${DOMAIN}"
echo "--------------------------------------------------------"

jq -r --arg tag "${INBOUND_TAG}" '
  .inbounds[]
  | select(.tag==$tag)
  | .settings.clients[]?
  | select(.email? != null)
  | "\(.email)\t\(.id)\t\(.flow // "")"
' "${XRAY_CONFIG}" | sort -u | awk 'BEGIN{FS="\t"} {printf "%-20s  %s  %s\n",$1,$2,$3}'

echo "========================================================"
EOF
  chmod +x "${LIST_USER_BIN}"

  # ---------- del-user ----------
  cat > "${DEL_USER_BIN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REALITY_ENV="/usr/local/etc/xray/reality.env"
[[ -f "${REALITY_ENV}" ]] || { echo "[!] 找不到 ${REALITY_ENV}，请先运行 xray-server_setup.sh"; exit 1; }
# shellcheck disable=SC1090
source "${REALITY_ENV}"

command -v jq >/dev/null 2>&1 || { echo "[!] 缺少 jq：apt-get install -y jq"; exit 1; }

usage() {
  echo "Usage: $(basename "$0") <client_name> [--keep-files]"
  exit 1
}

[[ $# -ge 1 ]] || usage
NAME="$1"
KEEP_FILES="0"
[[ "${2:-}" == "--keep-files" ]] && KEEP_FILES="1"

if ! jq -e --arg tag "${INBOUND_TAG}" --arg email "${NAME}" '
  any(.inbounds[] | select(.tag==$tag) | .settings.clients[]?; (.email? == $email))
' "${XRAY_CONFIG}" >/dev/null; then
  echo "[!] 未找到用户 email=${NAME}（tag=${INBOUND_TAG}），不做修改。"
  exit 1
fi

ts="$(date +%Y%m%d_%H%M%S)"
cp -a "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak_${ts}"
echo "[*] 已备份配置 -> ${XRAY_CONFIG}.bak_${ts}"

TMP="$(mktemp)"
jq --arg tag "${INBOUND_TAG}" --arg email "${NAME}" '
  .inbounds |= map(
    if .tag == $tag then
      .settings.clients |= map(select(.email? != $email))
    else
      .
    end
  )
' "${XRAY_CONFIG}" > "${TMP}"

jq empty "${TMP}"
cp "${TMP}" "${XRAY_CONFIG}"
rm -f "${TMP}"

systemctl restart xray
echo "[+] 已删除用户 email=${NAME} 并重启 xray"

if [[ "${KEEP_FILES}" == "0" ]]; then
  if [[ -n "${CLIENT_DIR:-}" && -d "${CLIENT_DIR}" ]]; then
    rm -f \
      "${CLIENT_DIR}/${NAME}.json" \
      "${CLIENT_DIR}/${NAME}.url" \
      "${CLIENT_DIR}/${NAME}.png" \
      "${CLIENT_DIR}/${NAME}.yaml" \
      "${CLIENT_DIR}/${NAME}.singbox.json" || true
    echo "[+] 已清理客户端文件（如存在）"
  else
    echo "[!] CLIENT_DIR 未设置或不存在，跳过客户端文件清理"
  fi
else
  echo "[*] --keep-files：保留客户端文件"
fi

echo "[✓] Done."
EOF
  chmod +x "${DEL_USER_BIN}"

  echo "[*] 工具脚本已生成："
  echo "    - ${ADD_USER_BIN}"
  echo "    - ${LIST_USER_BIN}"
  echo "    - ${DEL_USER_BIN}"
}

main() {
  need_root
  install_deps
  install_xray

  echo "[*] 获取公网 IP..."
  local server_ip
  server_ip="$(get_public_ip)"
  echo "[*] SERVER_IP=${server_ip}"

  echo "[*] 生成 admin UUID..."
  local admin_uuid
  admin_uuid="$(gen_uuid)"

  echo "[*] 生成 Reality 密钥..."
  local keys priv pub
  keys="$(gen_reality_keys)"
  priv="${keys%%|*}"
  pub="${keys#*|}"

  echo "[*] 生成 shortId..."
  local shortid
  shortid="$(rand_shortid)"

  write_server_config "${admin_uuid}" "${priv}" "${shortid}"
  write_reality_env "${server_ip}" "${shortid}" "${pub}"
  install_tool_scripts
  setup_firewall
  restart_xray

  echo
  echo "================= 初始化完成 ================="
  echo "Xray 配置:     ${CFG_FILE}"
  echo "共享参数:      ${REALITY_ENV}"
  echo "客户端目录:    ${CLIENT_DIR_DEFAULT}"
  echo
  echo "工具命令："
  echo "  add  : sudo xray-reality-add-user <name>"
  echo "  list : sudo xray-reality-list-users"
  echo "  del  : sudo xray-reality-del-user <name> [--keep-files]"
  echo
  echo "Reality 参数（客户端用）："
  echo "  SERVER_IP   : ${server_ip}"
  echo "  PORT        : ${PORT}"
  echo "  SNI         : ${SNI_HOST}"
  echo "  FLOW        : ${FLOW}"
  echo "  SHORT_ID    : ${shortid}"
  echo "  PUBLIC_KEY  : ${pub}"
  echo "============================================="
}

main "$@"