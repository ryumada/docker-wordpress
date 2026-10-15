#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Uninstalls the WordPress snapshot utility, removing script, symlinks, cron, and logrotate configs.
# Usage: ./scripts/installer/uninstall-snapshot.sh
# Dependencies: sudo, git, systemctl

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$CURRENT_DIR")")
SERVICE_NAME=$(basename "$PATH_TO_WP")

# --- Logging Functions & Colors ---
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"
COLOR_SUCCESS="\033[0;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}"
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
    exit 1
  fi

  log_info "Uninstalling snapshot utility for service: $SERVICE_NAME"

  local CRON_FILE="/etc/cron.d/snapshot-$SERVICE_NAME"
  local LOGROTATE_FILE="/etc/logrotate.d/snapshot-$SERVICE_NAME"
  local SOFTLINK_FILE="/usr/local/sbin/snapshot-$SERVICE_NAME"
  local SCRIPT_FILE="$PATH_TO_WP/scripts/snapshot-$SERVICE_NAME.sh"

  if [ -f "$CRON_FILE" ]; then
    log_info "Removing cron job: $CRON_FILE"
    rm -f -- "$CRON_FILE"
    systemctl restart cron 2>/dev/null || true
  fi

  if [ -f "$LOGROTATE_FILE" ]; then
    log_info "Removing logrotate configuration: $LOGROTATE_FILE"
    rm -f -- "$LOGROTATE_FILE"
  fi

  if [ -L "$SOFTLINK_FILE" ] || [ -f "$SOFTLINK_FILE" ]; then
    log_info "Removing symbolic link: $SOFTLINK_FILE"
    rm -f -- "$SOFTLINK_FILE"
  fi

  rm -f -- "/usr/local/sbin/list-snapshot-$SERVICE_NAME" \
          "/usr/local/sbin/download-snapshot-$SERVICE_NAME" \
          "/usr/local/sbin/upload-snapshot-$SERVICE_NAME" \
          "/usr/local/sbin/upload-temp-snapshots-$SERVICE_NAME" \
          "/usr/local/sbin/cleanup-snapshot-$SERVICE_NAME" \
          "/usr/local/sbin/restore-snapshot-$SERVICE_NAME"

  if [ -f "$SCRIPT_FILE" ]; then
    log_info "Removing snapshot script file: $SCRIPT_FILE"
    rm -f -- "$SCRIPT_FILE"
  fi

  rm -f -- "/var/run/snapshot-$SERVICE_NAME.lock"

  log_success "WordPress snapshot utility uninstalled successfully."
}

main "$@"
