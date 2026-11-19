#!/usr/bin/env bash

set -euo pipefail
export LANG=en_US.UTF-8

VERSION="1.0.0"

require_root() {
  [[ ${EUID:-1000} -eq 0 ]] || { echo "Please run this script as root."; exit 1; }
}

main() {
  require_root
  clear || true
  echo "* Welcome to the GuaPlus Airport hysteria2 installer."
  echo "* Version: $VERSION"
  echo
  systemctl stop hysteria-server >/dev/null 2>&1 || true
  systemctl disable hysteria-server >/dev/null 2>&1 || true

  rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service >/dev/null 2>&1 || true
  rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy >/dev/null 2>&1 || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "Uninstall completed."
}

main "$@"