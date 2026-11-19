#!/usr/bin/env bash

set -euo pipefail

export LANG=en_US.UTF-8

# --- Variables ---
readonly VERSION="1.0.0"
readonly CONFIG_DIR="/etc/hysteria"
readonly EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
readonly SYSTEMD_SERVICES_DIR="/etc/systemd/system"
readonly HYSTERIA_USER="hysteria"
readonly HYSTERIA_HOME_DIR="/var/lib/${HYSTERIA_USER}"
readonly CERT_PATH="${CONFIG_DIR}/cert.crt"
readonly KEY_PATH="${CONFIG_DIR}/private.key"
readonly CONFIG_PATH="${CONFIG_DIR}/config.yaml"
readonly FINGERPRINT_PATH="${CONFIG_DIR}/fingerprint.sha256"
readonly SNI_DEFAULT="www.bing.com"
readonly REPO_API="https://api.github.com/repos/apernet/hysteria"
readonly REPO_DL_BASE="https://github.com/apernet/hysteria/releases/download"
PANEL_BASE=""
PANEL_INSTALL_API=""
PANEL_VERIFY_API=""

# --- Helper Functions ---

log_info() { echo -e "\033[32m[INFO]\033[0m $1" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

require_root() {
  [[ ${EUID:-1000} -eq 0 ]] || log_error "请使用 root 运行"
}

# Detect OS and set package manager commands
detect_os_pm() {
  local s=$(grep -i pretty_name /etc/os-release | cut -d '"' -f2 | tr '[:upper:]' '[:lower:]')
  if [[ "$s" =~ debian|ubuntu ]]; then
    PM_UPDATE="apt-get update -y"; PM_INSTALL="apt-get install -y"
  elif [[ "$s" =~ centos|red\ hat|alma|rocky|fedora|amazon ]]; then
    PM_UPDATE="yum -y update"; PM_INSTALL="yum -y install"
  else log_error "不支持的系统: $s"
  fi
}

# Ensure required commands are installed
ensure_cmds() {
  local m=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m+=("$c"); done
  ((${#m[@]}==0)) && return
  log_info "安装所需依赖: ${m[*]}"
  ${PM_UPDATE} >/dev/null 2>&1 || true
  ${PM_INSTALL} "${m[@]}" >/dev/null 2>&1 || log_error "依赖安装失败，请检查系统包管理器"
}

# Get system architecture
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*|armv6*) echo arm ;;
    i386|i686) echo 386 ;;
    *) log_error "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

# Get latest Hysteria version tag
get_latest_version() {
  curl -fsSL "${REPO_API}/releases/latest" | jq -r '.tag_name' | sed 's#app/##'
}

# Generate a random port number
rand_port() { shuf -i 20000-60000 -n 1; }

# Get public IP address
get_public_ip() {
  curl -fsS https://whatismyip.akamai.com || curl -fsS https://ipecho.net/plain
}

# --- Core Installation Functions ---

# 1. Install Hysteria binary
install_hysteria_binary() {
  log_info "下载并安装 Hysteria2 可执行文件..."
  local arch ver url
  arch=$(detect_arch)
  ver=$(get_latest_version)
  url="${REPO_DL_BASE}/app/${ver}/hysteria-linux-${arch}"

  curl -fsSL -o /tmp/hysteria "$url" || log_error "下载 Hysteria2 失败"
  install -Dm755 /tmp/hysteria "${EXECUTABLE_INSTALL_PATH}"
  rm -f /tmp/hysteria
}

# 2. Setup systemd service
install_systemd() {
  log_info "创建 systemd 服务文件..."
  cat > "${SYSTEMD_SERVICES_DIR}/hysteria-server.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${EXECUTABLE_INSTALL_PATH} server -c ${CONFIG_PATH}
User=${HYSTERIA_USER}
# Hysteria2 needs raw sockets for QUIC, thus CAP_NET_RAW.
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# 3. Create Hysteria user and install files
setup_hysteria() {
  id ${HYSTERIA_USER} >/dev/null 2>&1 || useradd -r -m -d "${HYSTERIA_HOME_DIR}" ${HYSTERIA_USER}
  [[ -x "${EXECUTABLE_INSTALL_PATH}" ]] || install_hysteria_binary
  install_systemd
}

# 4. Generate self-signed certificate
write_selfsigned_cert() {
  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${CERT_PATH}" && -f "${KEY_PATH}" ]]; then
    log_info "证书文件已存在，跳过生成."
    return
  fi
  log_info "生成自签名证书 (CN=${SNI_DEFAULT})..."
  openssl ecparam -genkey -name prime256v1 -out "${KEY_PATH}" >/dev/null
  openssl req -new -x509 -days 36500 -key "${KEY_PATH}" -out "${CERT_PATH}" -subj "/CN=${SNI_DEFAULT}" >/dev/null
  # Set permissions: root:hysteria, readable by both
  chown root:${HYSTERIA_USER} "${CERT_PATH}" "${KEY_PATH}"
  chmod 640 "${CERT_PATH}" "${KEY_PATH}"
}

# 5. Get and save SHA256 fingerprint of the certificate
get_machine_fingerprint() {
  if [[ -f "${FINGERPRINT_PATH}" ]]; then
    cat "${FINGERPRINT_PATH}"
    return
  fi
  local fp=$(openssl x509 -in "${CERT_PATH}" -noout -fingerprint -sha256 | awk -F= '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')
  echo "$fp" > "${FINGERPRINT_PATH}"
  chmod 644 "${FINGERPRINT_PATH}"
  echo "$fp"
}

# 6. Write Hysteria config file
write_config() {
  local obfs_pwd="$1" stats_port="$2" stats_secret="$3"
  log_info "写入 Hysteria 配置文件 ${CONFIG_PATH}..."
  cat > "${CONFIG_PATH}" <<EOF
listen: :3389

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: http
  http:
    url: ${PANEL_VERIFY_API}
    insecure: false

obfs:
  type: salamander
  salamander:
    password: ${obfs_pwd}

trafficStats:
  listen: :${stats_port}
  secret: ${stats_secret}
EOF
  chown ${HYSTERIA_USER}:${HYSTERIA_USER} "${CONFIG_PATH}"
  chmod 600 "${CONFIG_PATH}"
}

# 7. Start and enable service
start_service() {
  log_info "启动并启用 hysteria-server 服务..."
  systemctl enable --now hysteria-server >/dev/null
}

# --- Panel Interaction Functions ---

# Get auth token from panel
panel_get_token() {
  log_info "尝试从面板获取授权TOKEN..."
  local key="$1" fp="$2"
  curl -fsSL "${PANEL_INSTALL_API}?key=${key}&fingerprint=${fp}" | jq -r '.data.token'
}

# Upload node details to panel
panel_upload() {
  log_info "上传节点信息到面板..."
  local token="$1" ip="$2" name="$3" domain="$4" sni="$5" obfs_pwd="$6" stats_port="$7" stats_secret="$8"

  token="$(echo -n "$token" | tr -d '\r\n')"

  local payload
  payload=$(jq -n \
    --arg ip "$ip" \
    --arg name "$name" \
    --arg domain "$domain" \
    --arg port "3389" \
    --arg insecure "1" \
    --arg sni "$sni" \
    --arg obfs "salamander" \
    --arg obfs_password "$obfs_pwd" \
    --arg traffic_stats_port "$stats_port" \
    --arg traffic_stats_secret "$stats_secret" \
    '{ip: $ip, name: $name, domain: $domain, port: $port | tonumber, insecure: $insecure | tonumber, sni: $sni, obfs: $obfs, obfs_password: $obfs_password, traffic_stats_port: $traffic_stats_port | tonumber, traffic_stats_secret: $traffic_stats_secret}')

  curl -fsS -X POST "${PANEL_INSTALL_API}" \
    -H "Authorization: ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload" | jq -r '.data.id'
}

# --- Main Logic ---

main() {
  require_root
  detect_os_pm
  ensure_cmds curl jq openssl shuf systemctl

  clear
  echo "-- GuaPlus Airport Hysteria2 Installer v${VERSION} --"
  echo

  # Get user input
  read -r -p "请输入机场地址: " PANEL_BASE
  read -r -p "请输入安装密钥: " INSTALL_KEY
  read -r -p "请输入节点名称: " NODE_NAME
  read -r -p "请输入节点域名: " DOMAIN

  # Basic input validation
  [[ -z "$PANEL_BASE" || -z "$INSTALL_KEY" || -z "$NODE_NAME" || -z "$DOMAIN" ]] && log_error "所有输入项都不能为空"

  PANEL_INSTALL_API="${PANEL_BASE}/api/v1/install"
  PANEL_VERIFY_API="${PANEL_BASE}/api/v1/verify"

  # 1. Installation Steps
  setup_hysteria
  write_selfsigned_cert

  # 2. Get necessary parameters
  FINGERPRINT=$(get_machine_fingerprint)
  TOKEN=$(panel_get_token "$INSTALL_KEY" "$FINGERPRINT")
  [[ -n "$TOKEN" && "$TOKEN" != "null" ]] || log_error "获取授权TOKEN失败，请检查机场地址、密钥和指纹"

  IP=$(get_public_ip)
  OBFS_PWD=$(openssl rand -hex 16)
  STATS_PORT=$(rand_port)
  STATS_SECRET=$(openssl rand -hex 16)

  # 3. Write config and start service
  write_config "$OBFS_PWD" "$STATS_PORT" "$STATS_SECRET"
  start_service

  # 4. Upload to panel
  NODE_ID=$(panel_upload "$TOKEN" "$IP" "$NODE_NAME" "$DOMAIN" "$SNI_DEFAULT" "$OBFS_PWD" "$STATS_PORT" "$STATS_SECRET")
  [[ -n "$NODE_ID" && "$NODE_ID" != "null" ]] || log_error "上传节点信息到面板失败"

  # 5. Success Message
  echo
  echo "-------------------------------------"
  echo "✅ Hysteria2 服务器安装和配置完成!"
  echo "-------------------------------------"
  echo "服务状态: $(systemctl is-active hysteria-server)"
  echo "节点 ID: $NODE_ID"
  echo "面板 API 地址: ${PANEL_BASE}"
  echo "Hysteria2 配置路径: ${CONFIG_PATH}"
  echo "-------------------------------------"
}

main "$@"
