#!/usr/bin/env bash

set -euo pipefail

export LANG=en_US.UTF-8

readonly XRAY_DIR="/usr/local/etc/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly SYNC_BIN="/usr/local/bin/xray-sync"
readonly LOG_PATH="/var/log/xray-sync.log"
readonly PID_XRAY="/run/xray.pid"
readonly PID_SYNC="/run/xray-sync.pid"

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

  echo -e "\033[33m即将彻底卸载 Xray 与 xray-sync 节点服务及配置目录 (${XRAY_DIR})\033[0m"
  local answer=""
  if [[ -r /dev/tty ]]; then
    read -r -p "确认卸载? [y/N]: " answer < /dev/tty
  else
    read -r -p "确认卸载? [y/N]: " answer
  fi

  [[ "${answer}" =~ ^[Yy]$ ]] || { log_info "已取消卸载"; exit 0; }
}

stop_and_remove_services() {
  log_info "停止并注销 Xray 及同步服务 (${INIT_SYSTEM})..."
  if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
    systemctl stop xray-sync xray 2>/dev/null || true
    systemctl disable xray-sync xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray-sync.service
    systemctl daemon-reload 2>/dev/null || true
  else
    rc-service xray-sync stop 2>/dev/null || true
    rc-service xray stop 2>/dev/null || true
    rc-update del xray-sync default 2>/dev/null || true
    rc-update del xray default 2>/dev/null || true
    rm -f /etc/init.d/xray /etc/init.d/xray-sync
  fi

  pkill -9 -f "${XRAY_BIN}" 2>/dev/null || true
  pkill -9 -f "${SYNC_BIN}" 2>/dev/null || true
}

cleanup_files() {
  log_info "清理可执行文件与配置目录..."
  rm -f "${XRAY_BIN}" "${SYNC_BIN}"
  rm -rf "${XRAY_DIR}"
  rm -f "${LOG_PATH}" "${PID_XRAY}" "${PID_SYNC}"
}

main() {
  require_root
  [[ "${1:-}" =~ ^(-f|--force)$ ]] && FORCE=1
  detect_init
  confirm_action

  stop_and_remove_services
  cleanup_files

  echo
  echo "-------------------------------------"
  echo "✅ VLESS (Xray & xray-sync) 卸载清理完成"
  echo "-------------------------------------"
}

main "$@"