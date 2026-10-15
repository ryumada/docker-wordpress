#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Configures sudoers rules for WordPress deployment and backup scripts.
# Usage: ./scripts/installer/install_sudoers.sh
# Dependencies: sudo, git, visudo

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$CURRENT_DIR")")
SERVICE_NAME=$(basename "$PATH_TO_WP")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")

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

create_sudoers_file() {
  local user="$1"
  local SCRIPT_NAME="$2"

  if ! id "$user" &>/dev/null; then
    return 0
  fi

  local script_path="$PATH_TO_WP/scripts/$SCRIPT_NAME.sh"
  if [ ! -f "$script_path" ]; then
    script_path="$PATH_TO_WP/scripts/$SCRIPT_NAME"
  fi

  if [ ! -f "$script_path" ]; then
    return 0
  fi

  local sudoers_file_name="01-${user}_as_root-${SERVICE_NAME//./_}-${SCRIPT_NAME//./_}"
  local target_path="/etc/sudoers.d/$sudoers_file_name"
  local rule_content="$user ALL=(root) NOPASSWD: $script_path"
  local temp_file
  temp_file=$(mktemp)

  echo "$rule_content" > "$temp_file"
  chmod 0440 "$temp_file"

  if visudo -c -f "$temp_file" >/dev/null 2>&1; then
    mv "$temp_file" "$target_path"
    log_success "Sudoers rule created for '$user' ➡️ $target_path"
  else
    rm -f "$temp_file"
    log_warn "Generated sudoers content was invalid for '$user'"
  fi
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
  fi

  local target_users=("devops" "www-data")
  local current_user="${SUDO_USER:-${REPOSITORY_OWNER:-$(id -un)}}"
  [ "$current_user" != "root" ] && target_users+=("$current_user")

  for u in "${target_users[@]}"; do
    create_sudoers_file "$u" "snapshot-$SERVICE_NAME"
    create_sudoers_file "$u" "backupdata-$SERVICE_NAME"
    create_sudoers_file "$u" "restore_backupdata-$SERVICE_NAME"
    create_sudoers_file "$u" "restore-snapshot"
  done

  log_success "Sudoers setup finished."
}

main "$@"
