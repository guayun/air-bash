#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8

# --- 路径常量 ---
readonly XRAY_DIR="/usr/local/etc/xray"
readonly BIN_DIR="/usr/local/bin"
readonly CERT_PATH="${XRAY_DIR}/cert.crt"
readonly KEY_PATH="${XRAY_DIR}/private.key"
readonly CONFIG_PATH="${XRAY_DIR}/config.json"
readonly SYNC_CONFIG_PATH="${XRAY_DIR}/sync.json"
readonly SYNC_BIN_PATH="${BIN_DIR}/xray-sync"

OS_TYPE="unknown"
ARCH="amd64"

log_info()  { echo -e "\033[32m[INFO]\033[0m $1" >&2; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

require_root() {
  [[ ${EUID:-1000} -eq 0 ]] || log_error "请使用 root 运行"
}

detect_os_arch() {
  if [[ -f /etc/alpine-release ]]; then
    OS_TYPE="alpine"
  elif [[ -f /etc/os-release ]] && grep -qiE 'debian|ubuntu' /etc/os-release; then
    OS_TYPE="debian"
  else
    log_error "仅支持 Alpine 和 Debian/Ubuntu"
  fi

  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) log_error "不支持的架构: $(uname -m)" ;;
  esac
}

ensure_cmds() {
  local pkgs=(curl openssl unzip jq)
  if [[ "${OS_TYPE}" == "alpine" ]]; then
    apk add --no-cache "${pkgs[@]}" >/dev/null
  else
    apt-get update -y >/dev/null && apt-get install -y "${pkgs[@]}" >/dev/null
  fi
}

collect_inputs() {
  API_BASE="${API_BASE:-}"
  INSTALL_KEY="${INSTALL_KEY:-}"
  NODE_NAME="${NODE_NAME:-}"
  NODE_DOMAIN="${NODE_DOMAIN:-}"
  PORT="${PORT:-3389}"
  SNI="${SNI:-www.bing.com}"
  SYNC_INTERVAL="${SYNC_INTERVAL:-30}"
  # 可选：xray-sync 二进制下载地址，支持 {arch} 占位符，例如 https://dl.example.com/xray-sync-linux-{arch}
  SYNC_BIN_URL="${SYNC_BIN_URL:-}"

  [[ -n "${API_BASE}" ]]    || read -rp "请输入后端 API 地址 (如 https://api.example.com): " API_BASE
  [[ -n "${INSTALL_KEY}" ]] || read -rp "请输入安装密钥 (INSTALL_KEY): " INSTALL_KEY
  [[ -n "${NODE_NAME}" ]]   || read -rp "请输入节点名称 (如 香港 VLESS-01): " NODE_NAME
  [[ -n "${NODE_DOMAIN}" ]] || read -rp "请输入节点域名 (如 hk-vless.example.com): " NODE_DOMAIN

  API_BASE="${API_BASE%/}"
  [[ -n "${API_BASE}" && -n "${INSTALL_KEY}" && -n "${NODE_NAME}" && -n "${NODE_DOMAIN}" ]] \
    || log_error "API_BASE / INSTALL_KEY / NODE_NAME / NODE_DOMAIN 均为必填项"
}

get_fingerprint() {
  local raw=""
  if [[ -r /etc/machine-id ]]; then
    raw="$(cat /etc/machine-id)"
  elif [[ -r /sys/class/dmi/id/product_uuid ]]; then
    raw="$(cat /sys/class/dmi/id/product_uuid)"
  else
    raw="$(hostname)-$(uname -m)-$(ip link 2>/dev/null | awk '/ether/{print $2; exit}')"
  fi
  printf '%s' "${raw}" | openssl dgst -sha256 | awk '{print $NF}'
}

get_public_ipv4() {
  local ip
  ip=$(curl -4 -fsSL --max-time 8 https://whatismyip.akamai.com \
    || curl -4 -fsSL --max-time 8 https://api.ipify.org \
    || curl -4 -fsSL --max-time 8 https://ipecho.net/plain)
  [[ -n "${ip}" ]] || log_error "无法获取公网 IPv4 地址"
  echo "${ip}"
}

install_xray() {
  log_info "下载并安装 Xray-core (${ARCH})..."
  local xray_arch="64"
  [[ "${ARCH}" == "arm64" ]] && xray_arch="arm64-v8a"
  curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
  unzip -qo /tmp/xray.zip xray -d /tmp/
  install -m 755 /tmp/xray "${BIN_DIR}/xray"
  rm -f /tmp/xray.zip /tmp/xray
  mkdir -p "${XRAY_DIR}"
}

install_sync_bin() {
  if [[ -n "${SYNC_BIN_URL}" ]]; then
    local url="${SYNC_BIN_URL//\{arch\}/${ARCH}}"
    log_info "下载 xray-sync (${url})..."
    curl -fsSL -o "${SYNC_BIN_PATH}" "${url}"
    chmod 755 "${SYNC_BIN_PATH}"
  elif [[ -f "./xray-sync-linux-${ARCH}" ]]; then
    log_info "使用当前目录的 ./xray-sync-linux-${ARCH}..."
    install -m 755 "./xray-sync-linux-${ARCH}" "${SYNC_BIN_PATH}"
  elif [[ -f "./xray-sync" ]]; then
    log_info "使用当前目录的 ./xray-sync..."
    install -m 755 "./xray-sync" "${SYNC_BIN_PATH}"
  elif [[ -x "${SYNC_BIN_PATH}" ]]; then
    log_info "检测到已存在的 ${SYNC_BIN_PATH}"
  else
    log_warn "未提供 SYNC_BIN_URL 且未找到本地 xray-sync，请稍后手动上传到 ${SYNC_BIN_PATH} 再启动 xray-sync 服务"
  fi
}

generate_cert() {
  if [[ ! -f "${CERT_PATH}" || ! -f "${KEY_PATH}" ]]; then
    log_info "生成自签名证书 (CN=${SNI})..."
    openssl ecparam -genkey -name prime256v1 -out "${KEY_PATH}" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${KEY_PATH}" -out "${CERT_PATH}" -subj "/CN=${SNI}" 2>/dev/null
    chmod 644 "${CERT_PATH}"
    chmod 600 "${KEY_PATH}"
  fi
}

write_xray_config() {
  log_info "写入 Xray 配置文件 (gRPC API: 127.0.0.1:10085)..."
  cat > "${CONFIG_PATH}" <<EOF
{
  "log": { "loglevel": "warning" },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "tag": "vless_inbound",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{ "certificateFile": "${CERT_PATH}", "keyFile": "${KEY_PATH}" }]
        },
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    },
    {
      "tag": "api_inbound",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }],
  "routing": {
    "rules": [{ "inboundTag": ["api_inbound"], "outboundTag": "api", "type": "field" }]
  }
}
EOF
}

register_node() {
  log_info "向后端申请安装会话..."
  local session_resp session_status jwt_token
  session_resp=$(curl -fsSL -G "${API_BASE}/api/v1/install" \
    --data-urlencode "fingerprint=${FINGERPRINT}" \
    --data-urlencode "key=${INSTALL_KEY}")

  session_status=$(echo "${session_resp}" | jq -r '.status // empty')
  if [[ "${session_status}" != "20000" ]]; then
    log_error "获取安装会话失败: ${session_resp}"
  fi

  jwt_token=$(echo "${session_resp}" | jq -r '.data.token // empty')
  [[ -n "${jwt_token}" ]] || log_error "后端未返回有效 JWT Token"

  log_info "注册 VLESS 节点并更新 Cloudflare DNS (${NODE_DOMAIN} -> ${PUBLIC_IP})..."
  local payload register_resp reg_status
  payload=$(jq -n \
    --arg protocol "vless" \
    --arg ip "${PUBLIC_IP}" \
    --arg name "${NODE_NAME}" \
    --arg domain "${NODE_DOMAIN}" \
    --arg port "${PORT}" \
    --arg insecure "1" \
    --arg sni "${SNI}" \
    --arg network "ws" \
    --arg security "tls" \
    --arg encryption "none" \
    --arg ws_host "${NODE_DOMAIN}" \
    --arg ws_path "${WS_PATH}" \
    '{
      protocol: $protocol,
      ip: $ip,
      name: $name,
      domain: $domain,
      port: $port,
      insecure: $insecure,
      sni: $sni,
      network: $network,
      security: $security,
      encryption: $encryption,
      ws_host: $ws_host,
      ws_path: $ws_path
    }')

  register_resp=$(curl -fsSL -X POST "${API_BASE}/api/v1/install" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${jwt_token}" \
    -d "${payload}")

  reg_status=$(echo "${register_resp}" | jq -r '.status // empty')
  if [[ "${reg_status}" != "20000" ]]; then
    log_error "节点注册失败: ${register_resp}"
  fi

  REGION_ID=$(echo "${register_resp}" | jq -r '.data.id // empty')
  NODE_SECRET=$(echo "${register_resp}" | jq -r '.data.node_secret // empty')
  [[ -n "${REGION_ID}" && -n "${NODE_SECRET}" ]] || log_error "节点注册响应缺少 id 或 node_secret: ${register_resp}"

  log_info "写入同步配置 ${SYNC_CONFIG_PATH}..."
  jq -n \
    --arg api_base "${API_BASE}" \
    --arg region_id "${REGION_ID}" \
    --arg node_secret "${NODE_SECRET}" \
    --arg grpc_addr "127.0.0.1:10085" \
    --arg inbound_tag "vless_inbound" \
    --argjson interval_sec "${SYNC_INTERVAL}" \
    '{
      api_base: $api_base,
      region_id: $region_id,
      node_secret: $node_secret,
      grpc_addr: $grpc_addr,
      inbound_tag: $inbound_tag,
      interval_sec: $interval_sec
    }' > "${SYNC_CONFIG_PATH}"
  chmod 600 "${SYNC_CONFIG_PATH}"
}

setup_services() {
  log_info "配置并启动服务 (${OS_TYPE})..."
  if [[ "${OS_TYPE}" == "debian" ]]; then
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${BIN_DIR}/xray run -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/xray-sync.service <<EOF
[Unit]
Description=Xray VLESS User Sync Agent
After=network.target xray.service
PartOf=xray.service

[Service]
ExecStart=${SYNC_BIN_PATH} sync -c ${SYNC_CONFIG_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray >/dev/null
    systemctl restart xray >/dev/null
    if [[ -x "${SYNC_BIN_PATH}" ]]; then
      systemctl enable --now xray-sync >/dev/null
      systemctl restart xray-sync >/dev/null
    fi
  else
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
command="${BIN_DIR}/xray"
command_args="run -c ${CONFIG_PATH}"
command_background="yes"
pidfile="/run/xray.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null
    rc-service xray restart >/dev/null

    cat > /etc/init.d/xray-sync <<EOF
#!/sbin/openrc-run
command="${SYNC_BIN_PATH}"
command_args="sync -c ${SYNC_CONFIG_PATH}"
command_background="yes"
pidfile="/run/xray-sync.pid"
output_log="/var/log/xray-sync.log"
error_log="/var/log/xray-sync.log"
depend() { need net xray; }
EOF
    chmod +x /etc/init.d/xray-sync
    rc-update add xray-sync default >/dev/null
    if [[ -x "${SYNC_BIN_PATH}" ]]; then
      rc-service xray-sync restart >/dev/null
    fi
  fi
}

main() {
  require_root
  detect_os_arch
  ensure_cmds
  collect_inputs

  FINGERPRINT="$(get_fingerprint)"
  log_info "获取服务器公网 IPv4..."
  PUBLIC_IP="$(get_public_ipv4)"
  WS_PATH="/$(openssl rand -hex 6)"

  install_xray
  install_sync_bin
  generate_cert
  write_xray_config
  register_node
  setup_services

  echo
  echo "-------------------------------------"
  echo "✅ VLESS 节点部署并注册完成"
  echo "-------------------------------------"
  echo "节点 ID   : ${REGION_ID}"
  echo "节点名称  : ${NODE_NAME}"
  echo "节点域名  : ${NODE_DOMAIN} (${PUBLIC_IP})"
  echo "监听端口  : ${PORT}"
  echo "WS 路径   : ${WS_PATH}"
  echo "同步配置  : ${SYNC_CONFIG_PATH}"
  echo "-------------------------------------"
}

main "$@"