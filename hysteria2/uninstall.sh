#!/usr/bin/env bash

set -euo pipefail

export LANG=en_US.UTF-8

readonly CONFIG_DIR="/etc/hysteria"
readonly BIN_PATH="/usr/local/bin/hysteria"
readonly USER_NAME="hysteria"
readonly USER_HOME="/var/lib/${USER_NAME}"
readonly LOG_PATH="/var/log/hysteria-server.log"
readonly PID_PATH="/run/hysteria-server.pid"
readonly SERVICE_SYSTEMD="/etc/systemd/system/hysteria-server.service"
readonly SERVICE_OPENRC="/etc/init.d/hysteria-server"

INIT_SYSTEM="systemd"
FORCE=0

log_info()  { echo -e "\033[32m[INFO]\033[0m $1" >&2; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

require_root() {
  [[ ${EUID:-1000} -eq 0 ]] || log_error "请使用 root 运行"
}

detect_init() {
  if [[ -f /etc/alpine-release ]]; then
    INIT_SYSTEM="openrc"
  else
    INIT_SYSTEM="systemd"
  fi
}

confirm_action() {
  [[ "${FORCE}" -eq 1 ]] && return

  echo -e "\033[33m即将彻底卸载 Hysteria2 节点服务及配置目录 (${CONFIG_DIR})\033[0m"
  local answer=""
  if [[ -r /dev/tty ]]; then
    read -r -p "确认卸载? [y/N]: " answer < /dev/tty
  else
    read -r -p "确认卸载? [y/N]: " answer
  fi

  [[ "${answer}" =~ ^[Yy]$ ]] || { log_info "已取消卸载"; exit 0; }
}

stop_and_remove_service() {
  log_info "停止并注销 Hysteria2 服务 (${INIT_SYSTEM})..."
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f "${SERVICE_SYSTEMD}"
    systemctl daemon-reload 2>/dev/null || true
  else
    rc-service hysteria-server stop 2>/dev/null || true
    rc-update del hysteria-server default 2>/dev/null || true
    rm -f "${SERVICE_OPENRC}"
  fi

  pkill -9 -f "${BIN_PATH}" 2>/dev/null || true
}

cleanup_files() {
  log_info "清理文件与目录..."
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}"
  rm -f "${LOG_PATH}" "${PID_PATH}"

  if id "${USER_NAME}" >/dev/null 2>&1; then
    log_info "删除系统用户 ${USER_NAME}..."
    if command -v userdel >/dev/null 2>&1; then
      userdel -r "${USER_NAME}" 2>/dev/null \vert{}\vert{} userdel -f "${USER_NAME}" 2>/dev/null || true
    else
      deluser "${USER_NAME}" 2>/dev/null || true
      delgroup "${USER_NAME}" 2>/dev/null || true
    fi
  fi
  rm -rf "${USER_HOME}"
}

main() {
  require_root
  [[ "${1:-}" =~ ^(-f\vert{}--force)$ ]] && FORCE=1
  detect_init
  confirm_action

  stop_and_remove_service
  cleanup_files

  echo
  echo "-------------------------------------"
  echo "✅ Hysteria2 卸载清理完成"
  echo "-------------------------------------"
}

main "$@"