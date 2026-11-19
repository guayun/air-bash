#!/usr/bin/env bash

set -euo pipefail

export LANG=en_US.UTF-8

# --- Variables ---
readonly VERSION="1.2.0"
readonly CONFIG_DIR="/etc/hysteria"
readonly EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
readonly SYSTEMD_SERVICES_DIR="/etc/systemd/system"
readonly OPENRC_SERVICE_PATH="/etc/init.d/hysteria-server"
readonly HYSTERIA_USER="hysteria"
readonly HYSTERIA_HOME_DIR="/var/lib/${HYSTERIA_USER}"
readonly CERT_PATH="${CONFIG_DIR}/cert.crt"
readonly KEY_PATH="${CONFIG_DIR}/private.key"
readonly CONFIG_PATH="${CONFIG_DIR}/config.yaml"
readonly FINGERPRINT_PATH="${CONFIG_DIR}/fingerprint.sha256"
readonly REPO_API="https://api.github.com/repos/apernet/hysteria"
readonly REPO_DL_BASE="https://github.com/apernet/hysteria/releases/download"

INIT_SYSTEM="systemd"
PM_TYPE="unknown"

# 默认参数（支持环境变量预设）
PANEL_BASE="${PANEL_BASE:-}"
INSTALL_KEY="${INSTALL_KEY:-}"
NODE_NAME="${NODE_NAME:-}"
DOMAIN="${DOMAIN:-}"
PORT="${PORT:-3389}"
SNI="${SNI:-www.bing.com}"

PANEL_INSTALL_API=""
PANEL_VERIFY_API=""

# --- Helper Functions ---

log_info()  { echo -e "\033[32m[INFO]\033[0m $1" >&2; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

require_root() {
  [[ ${EUID:-1000} -eq 0 ]] || log_error "请使用 root 运行"
}

show_help() {
  cat <<EOF
Hysteria2 节点安装脚本 v${VERSION} (兼容 Debian/Ubuntu/Alpine)

用法:
  交互式运行:
    bash install.sh
    curl -fsSL <URL> | bash

  静默参数安装:
    bash install.sh -a <URL> -k <KEY> -n <NAME> -d <DOMAIN> [-p <PORT>] [-s <SNI>]
    curl -fsSL <URL> | bash -s -- -a <URL> -k <KEY> -n <NAME> -d <DOMAIN>

  环境变量静默安装:
    PANEL_BASE="<URL>" INSTALL_KEY="<KEY>" NODE_NAME="<NAME>" DOMAIN="<DOMAIN>" bash install.sh

选项:
  -a, --api, --panel  机场后端地址 (如: https://air.example.com)
  -k, --key           安装密钥 (INSTALL_KEY)
  -n, --name          节点名称 (如: 香港 Hy2-01)
  -d, --domain        节点域名 (如: hk-hy2.example.com)
  -p, --port          服务监听端口 (默认: 3389)
  -s, --sni           TLS 伪装 SNI (默认: www.bing.com)
  -h, --help          查看此帮助信息
EOF
}

# 命令行参数解析
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--api|--panel)
        PANEL_BASE="$2"; shift 2 ;;
      -k|--key)
        INSTALL_KEY="$2"; shift 2 ;;
      -n|--name)
        NODE_NAME="$2"; shift 2 ;;
      -d|--domain)
        DOMAIN="$2"; shift 2 ;;
      -p|--port)
        PORT="$2"; shift 2 ;;
      -s|--sni)
        SNI="$2"; shift 2 ;;
      -h|--help)
        show_help; exit 0 ;;
      *)
        log_error "未知参数: $1 (使用 -h 查看帮助)" ;;
    esac
  done
}

detect_env() {
  if [[ -f /etc/alpine-release ]]; then
    PM_TYPE="alpine"
    INIT_SYSTEM="openrc"
  elif [[ -f /etc/os-release ]]; then
    local s
    s=$(grep -i pretty_name /etc/os-release | cut -d '"' -f2 | tr '[:upper:]' '[:lower:]')
    if [[ "$s" =~ debian|ubuntu ]]; then
      PM_TYPE="debian"
      INIT_SYSTEM="systemd"
    elif [[ "$s" =~ centos|red\ hat|alma|rocky|fedora|amazon ]]; then
      PM_TYPE="rhel"
      INIT_SYSTEM="systemd"
    else
      log_error "不支持的 Linux 发行版: $s"
    fi
  else
    log_error "无法识别系统发行版"
  fi
}

ensure_dependencies() {
  log_info "检查并安装基础依赖包..."
  case "${PM_TYPE}" in
    alpine)
      apk update >/dev/null 2>&1 || true
      apk add --no-cache curl jq openssl libcap shadow bash coreutils >/dev/null 2>&1 \
        || apk add --no-cache curl jq openssl libcap bash >/dev/null 2>&1 || log_error "Alpine 依赖安装失败"
      ;;
    debian)
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y curl jq openssl libcap2-bin >/dev/null 2>&1 || log_error "Debian/Ubuntu 依赖安装失败"
      ;;
    rhel)
      yum -y update >/dev/null 2>&1 || true
      yum -y install curl jq openssl libcap >/dev/null 2>&1 || log_error "RHEL/CentOS 依赖安装失败"
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*|armv6*) echo arm ;;
    i386|i686) echo 386 ;;
    *) log_error "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

get_latest_version() {
  local ver
  ver=$(curl -fsSL --max-time 10 "${REPO_API}/releases/latest" | jq -r '.tag_name // empty' | sed 's#app/##')
  [[ -n "$ver" ]] || log_error "无法获取 Hysteria 最新版本号"
  echo "$ver"
}

rand_port() {
  if command -v shuf >/dev/null 2>&1; then
    shuf -i 20000-60000 -n 1
  else
    awk 'BEGIN{srand(); print int(rand()*(60000-20000+1))+20000}'
  fi
}

get_public_ip() {
  local ip
  ip=$(curl -4 -fsSL --max-time 8 https://whatismyip.akamai.com \
    || curl -4 -fsSL --max-time 8 https://api.ipify.org \
    || curl -4 -fsSL --max-time 8 https://ipecho.net/plain)
  [[ -n "$ip" ]] || log_error "无法获取服务器公网 IPv4 地址"
  echo "$ip"
}

# --- 核心安装逻辑 ---

install_hysteria_binary() {
  log_info "下载并安装 Hysteria2 可执行文件..."
  local arch ver url
  arch=$(detect_arch)
  ver=$(get_latest_version)
  url="${REPO_DL_BASE}/app/${ver}/hysteria-linux-${arch}"

  curl -fsSL --max-time 60 -o /tmp/hysteria "$url" || log_error "下载 Hysteria2 失败: ${url}"
  mkdir -p "$(dirname "${EXECUTABLE_INSTALL_PATH}")"
  install -Dm755 /tmp/hysteria "${EXECUTABLE_INSTALL_PATH}"
  rm -f /tmp/hysteria

  if [[ "${INIT_SYSTEM}" == "openrc" ]] && command -v setcap >/dev/null 2>&1; then
    log_info "配置 Linux Capabilities (绑定低端口能力)..."
    setcap 'cap_net_bind_service,cap_net_admin,cap_net_raw=+ep' "${EXECUTABLE_INSTALL_PATH}" || log_warn "setcap 失败"
  fi
}

create_system_user() {
  if id "${HYSTERIA_USER}" >/dev/null 2>&1; then
    return
  fi
  log_info "创建专属服务用户 ${HYSTERIA_USER}..."
  if command -v useradd >/dev/null 2>&1; then
    useradd -r -m -d "${HYSTERIA_HOME_DIR}" -s /sbin/nologin "${HYSTERIA_USER}" 2>/dev/null \
      || useradd -r -m -d "${HYSTERIA_HOME_DIR}" "${HYSTERIA_USER}"
  else
    mkdir -p "${HYSTERIA_HOME_DIR}"
    adduser -S -D -H -h "${HYSTERIA_HOME_DIR}" -s /sbin/nologin "${HYSTERIA_USER}" 2>/dev/null \
      || adduser -S -D -h "${HYSTERIA_HOME_DIR}" "${HYSTERIA_USER}"
  fi
}

install_service_unit() {
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    log_info "创建 systemd 服务文件..."
    cat > "${SYSTEMD_SERVICES_DIR}/hysteria-server.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=${EXECUTABLE_INSTALL_PATH} server -c ${CONFIG_PATH}
User=${HYSTERIA_USER}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    log_info "创建 OpenRC 服务文件 (${OPENRC_SERVICE_PATH})..."
    cat > "${OPENRC_SERVICE_PATH}" <<EOF
#!/sbin/openrc-run
description="Hysteria2 Server"
command="${EXECUTABLE_INSTALL_PATH}"
command_args="server -c ${CONFIG_PATH}"
command_user="${HYSTERIA_USER}:${HYSTERIA_USER}"
command_background="yes"
pidfile="/run/hysteria-server.pid"
output_log="/var/log/hysteria-server.log"
error_log="/var/log/hysteria-server.log"

depend() {
  need net
  after firewall
}
EOF
    chmod +x "${OPENRC_SERVICE_PATH}"
  fi
}

write_selfsigned_cert() {
  mkdir -p "${CONFIG_DIR}"
  if [[ -f "${CERT_PATH}" && -f "${KEY_PATH}" ]]; then
    log_info "证书文件已存在，跳过生成."
    return
  fi
  log_info "生成自签名证书 (CN=${SNI})..."
  openssl ecparam -genkey -name prime256v1 -out "${KEY_PATH}" 2>/dev/null
  openssl req -new -x509 -days 36500 -key "${KEY_PATH}" -out "${CERT_PATH}" -subj "/CN=${SNI}" 2>/dev/null

  chown root:"${HYSTERIA_USER}" "${CERT_PATH}" "${KEY_PATH}"
  chmod 640 "${CERT_PATH}" "${KEY_PATH}"
}

get_machine_fingerprint() {
  if [[ -f "${FINGERPRINT_PATH}" ]]; then
    cat "${FINGERPRINT_PATH}"
    return
  fi
  local fp
  fp=$(openssl x509 -in "${CERT_PATH}" -noout -fingerprint -sha256 | awk -F= '{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]')
  echo "$fp" > "${FINGERPRINT_PATH}"
  chmod 644 "${FINGERPRINT_PATH}"
  echo "$fp"
}

write_config() {
  local obfs_pwd="$1" stats_port="$2" stats_secret="$3"
  log_info "写入 Hysteria 配置文件 ${CONFIG_PATH} (监听 :${PORT})..."
  cat > "${CONFIG_PATH}" <<EOF
listen: :${PORT}

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
  chown "${HYSTERIA_USER}":"${HYSTERIA_USER}" "${CONFIG_PATH}"
  chmod 600 "${CONFIG_PATH}"
}

start_and_enable_service() {
  log_info "启动并配置 hysteria-server 自启..."
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    systemctl enable --now hysteria-server >/dev/null
    systemctl restart hysteria-server >/dev/null
  else
    rc-update add hysteria-server default >/dev/null 2>&1 || true
    rc-service hysteria-server restart >/dev/null
  fi
}

get_service_status_text() {
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    systemctl is-active hysteria-server 2>/dev/null || echo "inactive"
  else
    if rc-service hysteria-server status >/dev/null 2>&1; then
      echo "running"
    else
      echo "stopped"
    fi
  fi
}

panel_get_token() {
  log_info "尝试从面板获取授权TOKEN..."
  local key="$1" fp="$2"
  curl -fsSL --max-time 15 "${PANEL_INSTALL_API}?key=${key}&fingerprint=${fp}" | jq -r '.data.token // empty'
}

panel_upload() {
  log_info "上传节点信息到面板..."
  local token="$1" ip="$2" name="$3" domain="$4" sni="$5" port="$6" obfs_pwd="$7" stats_port="$8" stats_secret="$9"

  token="$(echo -n "$token" | tr -d '\r\n')"

  local payload
  payload=$(jq -n \
    --arg ip "$ip" \
    --arg name "$name" \
    --arg domain "$domain" \
    --arg port "$port" \
    --arg insecure "1" \
    --arg sni "$sni" \
    --arg obfs "salamander" \
    --arg obfs_password "$obfs_pwd" \
    --arg traffic_stats_port "$stats_port" \
    --arg traffic_stats_secret "$stats_secret" \
    '{
      ip: $ip,
      name: $name,
      domain: $domain,
      port: ($port | tonumber),
      insecure: ($insecure | tonumber),
      sni: $sni,
      obfs: $obfs,
      obfs_password: $obfs_password,
      traffic_stats_port: ($traffic_stats_port | tonumber),
      traffic_stats_secret: $traffic_stats_secret
    }')

  curl -fsSL --max-time 15 -X POST "${PANEL_INSTALL_API}" \
    -H "Authorization: ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload" | jq -r '.data.id // empty'
}

# 辅助读取函数：缺参时先尝试从终端 /dev/tty 读取，不可交互则报错
read_interactive() {
  local prompt="$1"
  local var_name="$2"
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "$var_name" < /dev/tty
  else
    log_error "缺少必要参数 [$var_name]，且当前不是交互式终端环境，请使用参数 (-a/-k/-n/-d) 或环境变量传入"
  fi
}

# --- 主入口 ---

main() {
  require_root
  parse_args "$@"
  detect_env
  ensure_dependencies

  # 如果有任何必填参数缺失，进入安全交互读取模式
  if [[ -z "$PANEL_BASE" || -z "$INSTALL_KEY" || -z "$NODE_NAME" || -z "$DOMAIN" ]]; then
    echo "-- GuaPlus Airport Hysteria2 Installer v${VERSION} --"
    echo "系统环境: ${PM_TYPE} (${INIT_SYSTEM})"
    echo
    [[ -n "$PANEL_BASE" ]]  || read_interactive "请输入机场地址 (如 https://air.example.com): " PANEL_BASE
    [[ -n "$INSTALL_KEY" ]] || read_interactive "请输入安装密钥 (INSTALL_KEY): " INSTALL_KEY
    [[ -n "$NODE_NAME" ]]   || read_interactive "请输入节点名称 (如 香港 Hy2-01): " NODE_NAME
    [[ -n "$DOMAIN" ]]      || read_interactive "请输入节点域名 (如 hk.example.com): " DOMAIN
  fi

  PANEL_BASE="${PANEL_BASE%/}"

  [[ -n "$PANEL_BASE" && -n "$INSTALL_KEY" && -n "$NODE_NAME" && -n "$DOMAIN" ]] \
    || log_error "PANEL_BASE / INSTALL_KEY / NODE_NAME / DOMAIN 均为必填项"

  PANEL_INSTALL_API="${PANEL_BASE}/api/v1/install"
  PANEL_VERIFY_API="${PANEL_BASE}/api/v1/verify"

  # 1. 基础环境
  create_system_user
  [[ -x "${EXECUTABLE_INSTALL_PATH}" ]] || install_hysteria_binary
  install_service_unit
  write_selfsigned_cert

  # 2. 获取必要凭证
  FINGERPRINT=$(get_machine_fingerprint)
  TOKEN=$(panel_get_token "$INSTALL_KEY" "$FINGERPRINT")
  [[ -n "$TOKEN" && "$TOKEN" != "null" ]] || log_error "获取授权TOKEN失败，请检查机场地址、密钥和指纹"

  IP=$(get_public_ip)
  OBFS_PWD=$(openssl rand -hex 16)
  STATS_PORT=$(rand_port)
  STATS_SECRET=$(openssl rand -hex 16)

  # 3. 写入配置并启动服务
  write_config "$OBFS_PWD" "$STATS_PORT" "$STATS_SECRET"
  start_and_enable_service

  # 4. 上报节点到面板
  NODE_ID=$(panel_upload "$TOKEN" "$IP" "$NODE_NAME" "$DOMAIN" "$SNI" "$PORT" "$OBFS_PWD" "$STATS_PORT" "$STATS_SECRET")
  [[ -n "$NODE_ID" && "$NODE_ID" != "null" ]] || log_error "上传节点信息到面板失败"

  # 5. 输出结果
  echo
  echo "-------------------------------------"
  echo "✅ Hysteria2 服务器安装和配置完成!"
  echo "-------------------------------------"
  echo "初始化管理系统: ${INIT_SYSTEM}"
  echo "服务运行状态  : $(get_service_status_text)"
  echo "节点 ID       : ${NODE_ID}"
  echo "节点域名/IP   : ${DOMAIN} (${IP})"
  echo "监听端口      : ${PORT}"
  echo "伪装 SNI      : ${SNI}"
  echo "面板 API 地址 : ${PANEL_BASE}"
  echo "配置文件路径  : ${CONFIG_PATH}"
  echo "-------------------------------------"
}

main "$@"