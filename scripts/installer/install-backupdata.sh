#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs the backupdata utility based on .env configuration.
# Usage: ./scripts/installer/install-backupdata.sh
# Dependencies: rsync, git, sudo

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

  cd "$PATH_TO_WP"

  local link_name="backupdata-$SERVICE_NAME"
  local script_filename="$link_name.sh"
  local target_path="$PATH_TO_WP/scripts/$script_filename"
  local source_path="$PATH_TO_WP/scripts/example/backupdata.sh.example"

  log_info "Deploying backupdata script: $target_path..."
  rsync -acz "$source_path" "$target_path"
  chmod 755 "$target_path"

  log_info "Creating symbolic link: /usr/local/sbin/$link_name..."
  ln -sf "$target_path" "/usr/local/sbin/$link_name"

  log_success "Backup Data utility installed successfully as /usr/local/sbin/$link_name"
}

main "$@"
