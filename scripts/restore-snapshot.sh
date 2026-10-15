#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Restores a WordPress snapshot (full, data-only, or custom target db) from a tar.zst archive.
# Usage: ./scripts/restore-snapshot.sh [--data-only] [SNAPSHOT_FILE] [-n DB_NAME] [-y]
# Dependencies: tar, zstd, docker, sudo, rsync

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_WP")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")
[ -z "$OWNER_HOME" ] && OWNER_HOME="$HOME"
DEFAULT_TAR_FILE_NAME="snapshot-$SERVICE_NAME.tar.zst"

# Source helper libraries if available
if [ -f "$CURRENT_DIR/lib/wp_utils.sh" ]; then
  # shellcheck source=/dev/null
  source "$CURRENT_DIR/lib/wp_utils.sh"
elif [ -f "$PATH_TO_WP/scripts/lib/wp_utils.sh" ]; then
  # shellcheck source=/dev/null
  source "$PATH_TO_WP/scripts/lib/wp_utils.sh"
fi

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

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [SNAPSHOT_FILE]

Restores a WordPress deployment snapshot from a .tar.zst archive.

Options:
  -d, --data, --data-only        Restore ONLY database and data/wordpress files (fast mode).
                                 Does not stop container stack or overwrite configs/.env.
  -n, --name, --dbname <NAME>    Rename/specify target database name
  -f, --file <PATH>              Path to snapshot .tar.zst file
  -y, --yes, --force             Skip confirmation prompt
  -h, --help                     Show this help message

Arguments:
  SNAPSHOT_FILE                  Optional path to snapshot file (default: ~/$DEFAULT_TAR_FILE_NAME)

Examples:
  ./scripts/restore-snapshot.sh --data-only
  ./scripts/restore-snapshot.sh --data-only -n my_test_db -y
  ./scripts/restore-snapshot.sh ~/$DEFAULT_TAR_FILE_NAME
EOF
}

# --- Database Operations ---
is_mysql_container_running() {
  local compose_file="$PATH_TO_WP/docker-compose.yml"
  [ ! -f "$compose_file" ] && return 1
  local cid
  cid=$(docker compose -f "$compose_file" ps -q db 2>/dev/null || true)
  if [ -n "$cid" ] && [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  return 1
}

ensure_mysql_container_running() {
  local compose_file="$PATH_TO_WP/docker-compose.yml"
  if ! is_mysql_container_running; then
    log_info "Starting database container 'db'..."
    docker compose -f "$compose_file" up -d db
    log_info "Waiting for MySQL database service to become ready..."
    local attempts=0
    local max_attempts=30
    while [ $attempts -lt $max_attempts ]; do
      if docker compose -f "$compose_file" exec -T db sh -c 'mysqladmin ping -h localhost --silent' 2>/dev/null; then
        log_success "MySQL database is ready."
        return 0
      fi
      sleep 2
      attempts=$((attempts + 1))
    done
    log_error "MySQL database did not become ready in time."
    return 1
  fi
  return 0
}

run_mysql_restore() {
  local target_db="$1"
  local sql_file="$2"
  local compose_file="$PATH_TO_WP/docker-compose.yml"
  local env_file="$PATH_TO_WP/.env"

  local db_user
  db_user=$(grep "^WORDPRESS_DB_USER=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  [ -z "$db_user" ] && db_user="wordpress"

  ensure_mysql_container_running

  log_info "Ensuring target database '$target_db' exists..."
  docker compose -f "$compose_file" exec -T db sh -c '
    if [ -f /run/secrets/db_password ]; then
      PASS=$(cat /run/secrets/db_password)
    else
      PASS="$MYSQL_PASSWORD"
    fi
    MYSQL_PWD="$PASS" exec mysql -u "'"$db_user"'" -e "CREATE DATABASE IF NOT EXISTS \`'"$target_db"'\`;"
  '

  log_info "Importing SQL dump into '$target_db'..."
  docker compose -f "$compose_file" exec -T db sh -c '
    if [ -f /run/secrets/db_password ]; then
      PASS=$(cat /run/secrets/db_password)
    else
      PASS="$MYSQL_PASSWORD"
    fi
    MYSQL_PWD="$PASS" exec mysql -u "'"$db_user"'" "'"$target_db"'"
  ' < "$sql_file"
}

main() {
  for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
      show_help
      exit 0
    fi
  done

  # Self-elevate to root if not already
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
  fi

  local DATA_ONLY=false
  local TARGET_DB=""
  local SNAPSHOT_FILE=""
  local AUTO_CONFIRM=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--data|--data-only)
        DATA_ONLY=true
        shift
        ;;
      -n|--name|--dbname)
        TARGET_DB="$2"
        shift 2
        ;;
      --dbname=*|--name=*)
        TARGET_DB="${1#*=}"
        shift
        ;;
      -f|--file)
        SNAPSHOT_FILE="$2"
        shift 2
        ;;
      --file=*)
        SNAPSHOT_FILE="${1#*=}"
        shift
        ;;
      -y|--yes|--force)
        AUTO_CONFIRM=true
        shift
        ;;
      *)
        if [ -z "$SNAPSHOT_FILE" ]; then
          SNAPSHOT_FILE="$1"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$SNAPSHOT_FILE" ]; then
    SNAPSHOT_FILE="$OWNER_HOME/$DEFAULT_TAR_FILE_NAME"
  fi

  if [ ! -f "$SNAPSHOT_FILE" ]; then
    log_error "Snapshot file not found: $SNAPSHOT_FILE"
    exit 1
  fi

  if ! command -v zstd >/dev/null 2>&1; then
    log_error "zstd is not installed. Please install with: sudo apt install zstd"
    exit 1
  fi

  local ENV_FILE="$PATH_TO_WP/.env"
  if [ -z "$TARGET_DB" ] && [ -f "$ENV_FILE" ]; then
    TARGET_DB=$(grep "^WORDPRESS_DB_NAME=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  fi

  if [ -z "$TARGET_DB" ]; then
    read -rp "Enter destination database name: " TARGET_DB
  fi

  if [ "$AUTO_CONFIRM" != true ]; then
    if [ "$DATA_ONLY" = true ]; then
      log_warn "Data-only restore will overwrite database '$TARGET_DB' and $PATH_TO_WP/data/wordpress."
    else
      log_warn "FULL RESTORE will stop Docker containers, overwrite configurations, database '$TARGET_DB', and data/wordpress."
    fi
    read -rp "Are you sure you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      log_info "Restore aborted by user."
      exit 0
    fi
  fi

  local WP_TMP_DIR="$OWNER_HOME/.wordpress-tmp/$SERVICE_NAME"
  local EXTRACT_DIR="$WP_TMP_DIR/restore_snapshot_staging_$$"
  mkdir -p "$EXTRACT_DIR"

  cleanup_extract() {
    rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  }
  trap cleanup_extract EXIT

  log_info "Decompressing and unpacking snapshot $SNAPSHOT_FILE..."
  zstd -d -c "$SNAPSHOT_FILE" | tar -xf - -C "$EXTRACT_DIR"

  # Find dump.sql and data directory
  local dump_file
  dump_file=$(find "$EXTRACT_DIR" -maxdepth 3 -name "dump.sql" -type f -print -quit 2>/dev/null || true)
  local wp_dir
  wp_dir=$(find "$EXTRACT_DIR" -maxdepth 3 -type d -path "*/data/wordpress" -o -name "wordpress" 2>/dev/null | head -n 1 || true)

  if [ "$DATA_ONLY" = true ]; then
    log_info "Running DATA-ONLY restore..."

    if [ -n "$dump_file" ] && [ -f "$dump_file" ]; then
      log_info "Restoring database to '$TARGET_DB'..."
      run_mysql_restore "$TARGET_DB" "$dump_file"
      log_success "Database restore complete."
    else
      log_warn "No dump.sql found in snapshot."
    fi

    if [ -n "$wp_dir" ] && [ -d "$wp_dir" ]; then
      log_info "Restoring WordPress files to $PATH_TO_WP/data/wordpress..."
      mkdir -p "$PATH_TO_WP/data/wordpress"
      rsync -a --delete "$wp_dir/" "$PATH_TO_WP/data/wordpress/"
      chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_WP/data/wordpress" 2>/dev/null || true
      log_success "WordPress files restored."
    fi

  else
    log_info "Running FULL snapshot restore..."

    log_info "Stopping running Docker compose containers..."
    (cd "$PATH_TO_WP" && docker compose down 2>/dev/null || true)

    # Restore configs if present in staging
    if [ -f "$EXTRACT_DIR/.env" ] && [ -f "$PATH_TO_WP/.env" ]; then
      log_info "Backing up current .env to .env.pre-restore..."
      cp "$PATH_TO_WP/.env" "$PATH_TO_WP/.env.pre-restore"
    fi

    log_info "Restoring configurations and deployment files..."
    for item in .env .secrets docker-compose.yml php-config nginx_sites_available_configurations scripts; do
      if [ -e "$EXTRACT_DIR/$item" ]; then
        rsync -a "$EXTRACT_DIR/$item" "$PATH_TO_WP/"
      fi
    done

    # Restore data/wordpress
    if [ -n "$wp_dir" ] && [ -d "$wp_dir" ]; then
      log_info "Restoring data/wordpress..."
      mkdir -p "$PATH_TO_WP/data/wordpress"
      rsync -a --delete "$wp_dir/" "$PATH_TO_WP/data/wordpress/"
      chown -R "$REPOSITORY_OWNER":"$REPOSITORY_OWNER" "$PATH_TO_WP/data/wordpress" 2>/dev/null || true
    fi

    # Start db container to restore database
    log_info "Starting database container for restore..."
    (cd "$PATH_TO_WP" && docker compose up -d db)

    if [ -n "$dump_file" ] && [ -f "$dump_file" ]; then
      log_info "Restoring MySQL database to '$TARGET_DB'..."
      run_mysql_restore "$TARGET_DB" "$dump_file"
      log_success "Database restore complete."
    fi

    log_info "Restarting full Docker stack..."
    (cd "$PATH_TO_WP" && docker compose up -d)
    log_success "Docker stack started."
  fi

  log_success "Snapshot restoration from $SNAPSHOT_FILE completed successfully."
}

main "$@"
