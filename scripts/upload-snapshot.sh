#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Uploads a local WordPress snapshot archive to Google Drive.
# Usage: ./scripts/upload-snapshot.sh [SNAPSHOT_FILE] [--folder-id ID] [--sa-key PATH] [--token TOKEN]
# Dependencies: curl, openssl, dd, git, python3

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
GDRIVE_CHUNK_SIZE=$(grep "^GDRIVE_CHUNK_SIZE=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
GDRIVE_MAX_BACKUPS=$(grep "^GDRIVE_MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$GDRIVE_MAX_BACKUPS" ] && GDRIVE_MAX_BACKUPS="7"
[ -z "$GDRIVE_CHUNK_SIZE" ] && GDRIVE_CHUNK_SIZE="10"

TARGET_SNAPSHOT_FILE=""

show_help() {
  cat << EOF
Usage: $(basename "$0") [SNAPSHOT_FILE] [OPTIONS]

Uploads a local WordPress snapshot archive to Google Drive.

Options:
  --folder-id <ID>     Override Google Drive Folder ID
  --sa-key <PATH>      Override Google Drive Service Account JSON key file
  --token <TOKEN>      Override Google Drive OAuth2 Access Token
  -h, --help           Show this help message

Examples:
  ./scripts/upload-snapshot.sh
  ./scripts/upload-snapshot.sh ~/snapshot-$SERVICE_NAME.tar.zst
  ./scripts/upload-snapshot.sh --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder-id)
      GDRIVE_FOLDER_ID="$2"
      shift 2
      ;;
    --folder-id=*)
      GDRIVE_FOLDER_ID="${1#*=}"
      shift
      ;;
    --sa-key)
      GDRIVE_SERVICE_ACCOUNT_KEY="$2"
      shift 2
      ;;
    --sa-key=*)
      GDRIVE_SERVICE_ACCOUNT_KEY="${1#*=}"
      shift
      ;;
    --token)
      GDRIVE_ACCESS_TOKEN="$2"
      shift 2
      ;;
    --token=*)
      GDRIVE_ACCESS_TOKEN="${1#*=}"
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      if [ -z "$TARGET_SNAPSHOT_FILE" ]; then
        TARGET_SNAPSHOT_FILE="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$TARGET_SNAPSHOT_FILE" ]; then
  if [ -f "$OWNER_HOME/snapshot-$SERVICE_NAME.tar.zst" ]; then
    TARGET_SNAPSHOT_FILE="$OWNER_HOME/snapshot-$SERVICE_NAME.tar.zst"
  else
    latest_archive=$(find "$OWNER_HOME/.wordpress-snapshots/$SERVICE_NAME/archives" -type f -name "snapshot-*.tar.zst" 2>/dev/null | sort -r | head -n 1 || true)
    if [ -n "$latest_archive" ] && [ -f "$latest_archive" ]; then
      TARGET_SNAPSHOT_FILE="$latest_archive"
    fi
  fi
fi

if [ -z "$TARGET_SNAPSHOT_FILE" ] || [ ! -f "$TARGET_SNAPSHOT_FILE" ]; then
  log_error "Snapshot file not found: ${TARGET_SNAPSHOT_FILE:-$OWNER_HOME/snapshot-$SERVICE_NAME.tar.zst}"
  exit 1
fi

if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -f "$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
fi

ACCESS_TOKEN=$(resolve_gdrive_access_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
if [ -z "$ACCESS_TOKEN" ]; then
  log_error "Google Drive access token could not be obtained. Please configure GDRIVE_SERVICE_ACCOUNT_KEY or GDRIVE_ACCESS_TOKEN in .env."
  exit 1
fi

# Upload resumably
file_name=$(basename "$TARGET_SNAPSHOT_FILE")
file_size=$(stat -c%s "$TARGET_SNAPSHOT_FILE")
chunk_size=$((GDRIVE_CHUNK_SIZE * 1024 * 1024))

log_info "Initiating upload for $file_name ($((file_size / 1024 / 1024)) MB) to Google Drive..."

if [ -n "$GDRIVE_FOLDER_ID" ]; then
  metadata_json="{\"name\":\"$file_name\",\"parents\":[\"$GDRIVE_FOLDER_ID\"]}"
else
  metadata_json="{\"name\":\"$file_name\"}"
fi

init_response=$(curl -s -i -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json; charset=UTF-8" \
  -H "X-Upload-Content-Type: application/octet-stream" \
  -H "X-Upload-Content-Length: $file_size" \
  -d "$metadata_json" \
  "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")

session_url=$(echo "$init_response" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')
if [ -z "$session_url" ]; then
  log_error "Failed to initiate Google Drive upload session. Response: $init_response"
  exit 1
fi

start_byte=0
chunk_index=0
total_chunks=$(( (file_size + chunk_size - 1) / chunk_size ))
[ "$total_chunks" -eq 0 ] && total_chunks=1

while [ "$start_byte" -lt "$file_size" ]; do
  end_byte=$((start_byte + chunk_size - 1))
  [ "$end_byte" -ge "$file_size" ] && end_byte=$((file_size - 1))
  current_chunk_len=$((end_byte - start_byte + 1))
  chunk_index=$((chunk_index + 1))

  log_info "Uploading chunk #$chunk_index/$total_chunks ($((current_chunk_len / 1024 / 1024)) MB)..."

  ACCESS_TOKEN=$(resolve_gdrive_access_token "$ACCESS_TOKEN" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")

  upload_response=$(dd if="$TARGET_SNAPSHOT_FILE" bs=1M skip=$((start_byte / 1024 / 1024)) count=$((current_chunk_len / 1024 / 1024 + 1)) 2>/dev/null | \
    head -c "$current_chunk_len" | \
    curl -s -w "\n%{http_code}" -X PUT \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Range: bytes $start_byte-$end_byte/$file_size" \
      --data-binary @- \
      "$session_url")

  http_status=$(echo "$upload_response" | tail -n1)

  if [ "$http_status" = "308" ]; then
    start_byte=$((end_byte + 1))
  elif [ "$http_status" = "200" ] || [ "$http_status" = "201" ]; then
    log_success "Snapshot uploaded successfully to Google Drive: $file_name"
    cleanup_gdrive_old_snapshots "$ACCESS_TOKEN" "$GDRIVE_FOLDER_ID" "$SERVICE_NAME" "$GDRIVE_MAX_BACKUPS" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY"
    exit 0
  else
    log_error "Upload failed at chunk #$chunk_index (HTTP $http_status)"
    exit 1
  fi
done
