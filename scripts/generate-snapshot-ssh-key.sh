#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Generates ed25519 SSH key pair for cross-VPS remote snapshot operations and displays authorization snippet.
# Usage: ./scripts/generate-snapshot-ssh-key.sh [--target-host HOST] [--target-user USER] [--force]
# Dependencies: ssh-keygen, git, sudo

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_WP")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")

# Source shared SSH utilities
if [ -f "$CURRENT_DIR/lib/ssh_utils.sh" ]; then
  # shellcheck source=/dev/null
  source "$CURRENT_DIR/lib/ssh_utils.sh"
elif [ -f "$PATH_TO_WP/scripts/lib/ssh_utils.sh" ]; then
  # shellcheck source=/dev/null
  source "$PATH_TO_WP/scripts/lib/ssh_utils.sh"
fi

# --- Logging Functions & Colors ---
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"
COLOR_SUCCESS="\033[0;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[0;31m"
COLOR_CYAN="\033[0;36m"
COLOR_BOLD="\033[1m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

ENV_FILE="$PATH_TO_WP/.env"
TOOL_TYPE="snapshot"
TARGET_HOST=""
TARGET_USER=""
FORCE=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generates a dedicated ed25519 SSH key pair for cross-VPS remote snapshot operations,
saves it to ~/.ssh/snapshot-\$THIS_VPS_HOSTNAME-\$TARGET_VPS_HOSTNAME, updates .env, and outputs the public key.

Options:
  -t, --target-host <HOST>   Hostname or IP of the Remote Secondary VPS
  -u, --target-user <USER>   SSH username on Remote VPS (default: from .env or root)
  -f, --force                Overwrite existing SSH key if it already exists
  -h, --help                 Show this help message

Examples:
  ./scripts/generate-snapshot-ssh-key.sh
  ./scripts/generate-snapshot-ssh-key.sh --target-host backup-vps.example.com --target-user wpbackup
  ./scripts/generate-snapshot-ssh-key.sh --target-host 192.168.1.100 -f
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target-host)
      TARGET_HOST="$2"
      shift 2
      ;;
    --target-host=*)
      TARGET_HOST="${1#*=}"
      shift
      ;;
    -u|--target-user)
      TARGET_USER="$2"
      shift 2
      ;;
    --target-user=*)
      TARGET_USER="${1#*=}"
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

ENV_VAR_KEY="SNAPSHOT_REMOTE_KEY"
ENV_VAR_HOST="SNAPSHOT_REMOTE_HOST"
ENV_VAR_USER="SNAPSHOT_REMOTE_USER"

ENV_REMOTE_HOST=$(grep "^${ENV_VAR_HOST}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
ENV_REMOTE_USER=$(grep "^${ENV_VAR_USER}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

if [ -z "$TARGET_HOST" ]; then
  TARGET_HOST="$ENV_REMOTE_HOST"
fi

if [ -z "$TARGET_HOST" ]; then
  echo -ne "${COLOR_CYAN}Enter Target VPS Hostname or IP (for snapshot): ${COLOR_RESET}"
  read -r TARGET_HOST
fi

if [ -z "$TARGET_HOST" ]; then
  log_error "Target VPS Hostname or IP is required."
  exit 1
fi

if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${ENV_REMOTE_USER:-root}"
fi

generate_ssh_key_pair "$TOOL_TYPE" "$TARGET_HOST" "$TARGET_USER" "$REPOSITORY_OWNER" "$FORCE" "$ENV_VAR_KEY" "$ENV_FILE" >/dev/null

if [ -f "$ENV_FILE" ]; then
  if [ -n "$TARGET_HOST" ] && ! grep -q "^${ENV_VAR_HOST}=" "$ENV_FILE"; then
    echo "${ENV_VAR_HOST}=$TARGET_HOST" >> "$ENV_FILE"
  fi
  if [ -n "$TARGET_USER" ] && ! grep -q "^${ENV_VAR_USER}=" "$ENV_FILE"; then
    echo "${ENV_VAR_USER}=$TARGET_USER" >> "$ENV_FILE"
  fi
fi
