#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Uploads all temporary/archived WordPress snapshots to Google Drive or Google Cloud Storage.
# Usage: ./scripts/upload-temp-snapshots.sh [--service NAME] [--all] [--dry-run] [--keep-local]
# Dependencies: curl, openssl, sudo, git, python3

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_WP")
REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")
OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")
[ -z "$OWNER_HOME" ] && OWNER_HOME="$HOME"

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
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

ENV_FILE="$PATH_TO_WP/.env"
GDRIVE_ACCESS_TOKEN=$(grep "^GDRIVE_ACCESS_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_SERVICE_ACCOUNT_KEY=$(grep "^GDRIVE_SERVICE_ACCOUNT_KEY=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_FOLDER_ID=$(grep "^GDRIVE_FOLDER_ID=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GCS_BUCKET_NAME=$(grep "^GCS_BUCKET_NAME=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_MAX_BACKUPS=$(grep "^GDRIVE_MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$GDRIVE_MAX_BACKUPS" ] && GDRIVE_MAX_BACKUPS="7"

DRY_RUN=false
KEEP_LOCAL=false
ALL_SERVICES=false
TARGET_SERVICE="$SERVICE_NAME"

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Uploads temporary/local WordPress snapshot archives to Google Drive and/or Google Cloud Storage.

Options:
  --service <NAME>     Filter temporary snapshots by service name (default: $SERVICE_NAME)
  --all                Search across all service snapshot directories
  --dry-run            Show snapshots that would be uploaded without uploading
  --keep-local         Do not delete local archives after successful upload
  -h, --help           Show this help message

Examples:
  ./scripts/upload-temp-snapshots.sh
  ./scripts/upload-temp-snapshots.sh --dry-run
  ./scripts/upload-temp-snapshots.sh --all
  ./scripts/upload-temp-snapshots.sh --keep-local
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      TARGET_SERVICE="$2"
      shift 2
      ;;
    --service=*)
      TARGET_SERVICE="${1#*=}"
      shift
      ;;
    --all)
      ALL_SERVICES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --keep-local)
      KEEP_LOCAL=true
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

# Search directories for temporary snapshots
search_dirs=()
if [ "$ALL_SERVICES" = true ]; then
  [ -d "$OWNER_HOME/.wordpress-snapshots" ] && search_dirs+=("$OWNER_HOME/.wordpress-snapshots")
  [ -d "$OWNER_HOME/.wordpress-tmp" ] && search_dirs+=("$OWNER_HOME/.wordpress-tmp")
else
  [ -d "$OWNER_HOME/.wordpress-snapshots/$TARGET_SERVICE/archives" ] && search_dirs+=("$OWNER_HOME/.wordpress-snapshots/$TARGET_SERVICE/archives")
  [ -d "$OWNER_HOME/.wordpress-tmp/$TARGET_SERVICE" ] && search_dirs+=("$OWNER_HOME/.wordpress-tmp/$TARGET_SERVICE")
fi

if [ ${#search_dirs[@]} -eq 0 ]; then
  log_info "No snapshot directories found to check."
  exit 0
fi

found_files=()
for sdir in "${search_dirs[@]}"; do
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && found_files+=("$f")
  done < <(find "$sdir" -type f -name "snapshot-*.tar.zst" 2>/dev/null || true)
done

if [ ${#found_files[@]} -eq 0 ]; then
  log_info "No local temporary snapshots found."
  exit 0
fi

log_info "Found ${#found_files[@]} local snapshot archive(s):"
for f in "${found_files[@]}"; do
  sz=$(du -h "$f" | awk '{print $1}')
  echo "  - $f ($sz)"
done

if [ "$DRY_RUN" = true ]; then
  log_info "Dry-run mode complete. No files uploaded or modified."
  exit 0
fi

# Resolve GDrive token if configured
ACCESS_TOKEN=""
if [ -n "$GDRIVE_ACCESS_TOKEN" ] || [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    if [ -f "$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
      GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY"
    fi
  fi
  ACCESS_TOKEN=$(resolve_gdrive_access_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
fi

for snap in "${found_files[@]}"; do
  fname=$(basename "$snap")
  log_info "Processing $fname..."
  uploaded=false

  # GCS Upload
  if [ -n "$GCS_BUCKET_NAME" ] && command -v gcloud >/dev/null 2>&1; then
    log_info "Uploading $fname to Google Cloud Storage (gs://$GCS_BUCKET_NAME)..."
    if gcloud storage cp "$snap" "gs://$GCS_BUCKET_NAME/$fname" 2>/dev/null; then
      log_success "Uploaded to GCS."
      uploaded=true
    fi
  fi

  # Google Drive Upload
  if [ -n "$ACCESS_TOKEN" ]; then
    if "$CURRENT_DIR/upload-snapshot.sh" "$snap"; then
      log_success "Uploaded to Google Drive."
      uploaded=true
    fi
  fi

  if [ "$uploaded" = true ] && [ "$KEEP_LOCAL" = false ]; then
    # Delete file and its parent container directory if inside archives
    parent_dir=$(dirname "$snap")
    if [[ "$parent_dir" == *"/archives/snapshot-"* ]]; then
      rm -rf "$parent_dir"
      log_info "Cleaned up temporary directory: $parent_dir"
    else
      rm -f "$snap"
      log_info "Cleaned up local file: $snap"
    fi
  fi
done

log_success "Finished processing temporary snapshots."
