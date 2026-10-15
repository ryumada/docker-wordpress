#!/usr/bin/env bash
set -e
# Category: Installer
# Description: Installs and schedules the WordPress snapshot utility.
# Usage: ./scripts/installer/install-snapshot.sh
# Dependencies: rsync, git, sudo, zstd, curl

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$CURRENT_DIR")")
SERVICE_NAME=$(basename "$PATH_TO_WP")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")
[ -z "$OWNER_HOME" ] && OWNER_HOME="$HOME"

# --- Logging Functions & Colors ---
COLOR_RESET="\033[0m"
COLOR_INFO="\033[0;34m"
COLOR_SUCCESS="\033[0;32m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[0;31m"
COLOR_BOLD="\033[1m"

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

error_handler() {
  local exit_code=$1
  local line_no=$2
  local command_name=$3
  log_error "An error occurred on line $line_no (Command: $command_name, Exit Code: $exit_code)"
  exit "$exit_code"
}
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR

TODO_LIST=()

installCronJob() {
  local gcs_bucket="$1"
  local snapshot_time_list="$2"
  local gdrive_token="$3"
  local gdrive_sa_key="$4"
  local snapshot_remote_host="$5"
  local enable_snapshot="$6"

  local cron_file="/etc/cron.d/snapshot-$SERVICE_NAME"

  if [ -z "$snapshot_time_list" ] || [ "$enable_snapshot" != "Y" ]; then
    if [ -f "$cron_file" ]; then
      log_warn "Removing existing cron job: $cron_file"
      rm -f "$cron_file"
      systemctl restart cron 2>/dev/null || true
    fi
    if [ "$enable_snapshot" = "Y" ] && [ -z "$snapshot_time_list" ]; then
      log_info "ENABLE_SNAPSHOT=Y but SNAPSHOT_TIME is empty. Snapshot utility installed for manual execution only (no cron)."
    fi
    return 0
  fi

  local log_dir="/var/log/wordpress/_utilities"
  mkdir -p "$log_dir"
  chmod 775 "$log_dir" 2>/dev/null || true
  chown root:root "$log_dir" 2>/dev/null || true

  local random_minute
  random_minute=$((RANDOM % 60))

  log_info "Configuring snapshot cron schedule: $snapshot_time_list (Minute: $random_minute)..."

  cat << EOF > "$HOME/snapshot-$SERVICE_NAME"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

$random_minute $snapshot_time_list * * * root /usr/local/sbin/snapshot-$SERVICE_NAME >> $log_dir/snapshot-$SERVICE_NAME.log 2>&1

EOF

  mv "$HOME/snapshot-$SERVICE_NAME" "$cron_file"
  chown root:root "$cron_file"
  chmod 644 "$cron_file"
  systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
  log_success "Cron schedule installed in $cron_file"
}

main() {
  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
    log_info "Elevating permissions to root..."
    exec sudo "$0" "$@"
    exit 1
  fi

  cd "$PATH_TO_WP"

  log_info "Checking configuration in .env..."
  local ENV_FILE="$PATH_TO_WP/.env"
  if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    exit 1
  fi

  local ENABLE_SNAPSHOT SNAPSHOT_TIME_LIST GCS_BUCKET_NAME GDRIVE_ACCESS_TOKEN GDRIVE_SERVICE_ACCOUNT_KEY
  local SNAPSHOT_REMOTE_HOST SNAPSHOT_REMOTE_USER SNAPSHOT_REMOTE_PORT SNAPSHOT_REMOTE_KEY

  ENABLE_SNAPSHOT=$(grep "^ENABLE_SNAPSHOT=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  SNAPSHOT_TIME_LIST=$(grep "^SNAPSHOT_TIME=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  GCS_BUCKET_NAME=$(grep "^GCS_BUCKET_NAME=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)

  SNAPSHOT_REMOTE_HOST=$(grep "^SNAPSHOT_REMOTE_HOST=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  SNAPSHOT_REMOTE_USER=$(grep "^SNAPSHOT_REMOTE_USER=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  SNAPSHOT_REMOTE_PORT=$(grep "^SNAPSHOT_REMOTE_PORT=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  SNAPSHOT_REMOTE_KEY=$(grep "^SNAPSHOT_REMOTE_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  [ -z "$SNAPSHOT_REMOTE_PORT" ] && SNAPSHOT_REMOTE_PORT="22"

  local link_name="snapshot-$SERVICE_NAME"
  local script_filename="$link_name.sh"
  local target_path="$PATH_TO_WP/scripts/$script_filename"
  local source_path="$PATH_TO_WP/scripts/example/snapshot.sh.example"

  log_info "Deploying snapshot script: $target_path..."
  rsync -acz "$source_path" "$target_path"
  chmod 755 "$target_path"

  log_info "Creating system-wide symlink /usr/local/sbin/$link_name..."
  ln -sf "$target_path" "/usr/local/sbin/$link_name"

  # Link companion utilities
  [ -f "$PATH_TO_WP/scripts/list-snapshot.sh" ] && ln -sf "$PATH_TO_WP/scripts/list-snapshot.sh" "/usr/local/sbin/list-snapshot-$SERVICE_NAME"
  [ -f "$PATH_TO_WP/scripts/download-snapshot.sh" ] && ln -sf "$PATH_TO_WP/scripts/download-snapshot.sh" "/usr/local/sbin/download-snapshot-$SERVICE_NAME"
  [ -f "$PATH_TO_WP/scripts/upload-snapshot.sh" ] && ln -sf "$PATH_TO_WP/scripts/upload-snapshot.sh" "/usr/local/sbin/upload-snapshot-$SERVICE_NAME"
  [ -f "$PATH_TO_WP/scripts/upload-temp-snapshots.sh" ] && ln -sf "$PATH_TO_WP/scripts/upload-temp-snapshots.sh" "/usr/local/sbin/upload-temp-snapshots-$SERVICE_NAME"
  [ -f "$PATH_TO_WP/scripts/cleanup-snapshot.sh" ] && ln -sf "$PATH_TO_WP/scripts/cleanup-snapshot.sh" "/usr/local/sbin/cleanup-snapshot-$SERVICE_NAME"
  [ -f "$PATH_TO_WP/scripts/restore-snapshot.sh" ] && ln -sf "$PATH_TO_WP/scripts/restore-snapshot.sh" "/usr/local/sbin/restore-snapshot-$SERVICE_NAME"

  # Verify system prerequisites
  for tool in zstd curl rsync; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log_info "Installing missing prerequisite: $tool..."
      apt-get update -qq && apt-get install -y "$tool" 2>/dev/null || true
    fi
  done

  if ! command -v 7z >/dev/null 2>&1 && ! command -v 7za >/dev/null 2>&1; then
    log_info "Installing 7zip..."
    apt-get install -y 7zip 2>/dev/null || apt-get install -y p7zip-full 2>/dev/null || true
  fi

  # Install cron job
  installCronJob "$GCS_BUCKET_NAME" "$SNAPSHOT_TIME_LIST" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY" "$SNAPSHOT_REMOTE_HOST" "$ENABLE_SNAPSHOT"

  # Setup logrotate
  log_info "Configuring logrotate for snapshot utility..."
  local log_dir="/var/log/wordpress/_utilities"
  mkdir -p "$log_dir"

  cat << EOF > "$HOME/logrotate-snapshot-$SERVICE_NAME"
$log_dir/snapshot-$SERVICE_NAME.log {
    rotate 4
    su root syslog
    weekly
    missingok
    nocreate
    compress
    compresscmd /usr/bin/zstd
    compressoptions -7T0
    delaycompress
    dateext
    dateformat -%Y%m%d-%H%M%S
}
EOF

  mv "$HOME/logrotate-snapshot-$SERVICE_NAME" "/etc/logrotate.d/snapshot-$SERVICE_NAME"
  chown root:root "/etc/logrotate.d/snapshot-$SERVICE_NAME"
  chmod 644 "/etc/logrotate.d/snapshot-$SERVICE_NAME"

  log_success "Snapshot utility installed successfully as /usr/local/sbin/snapshot-$SERVICE_NAME"
}

main "$@"
