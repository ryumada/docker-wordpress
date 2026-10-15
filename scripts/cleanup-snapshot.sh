#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Cleans up older WordPress snapshots on Google Drive based on retention policy.
# Usage: ./scripts/cleanup-snapshot.sh [--keep N] [--dry-run] [-l] [--force]
# Dependencies: curl, openssl, git, python3

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
CURRENT_DIR_USER=$(stat -c '%U' "$CURRENT_DIR")
PATH_TO_WP=$(sudo -u "$CURRENT_DIR_USER" git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$CURRENT_DIR")
SERVICE_NAME=$(basename "$PATH_TO_WP")

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
GDRIVE_MAX_BACKUPS=$(grep "^GDRIVE_MAX_BACKUPS=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
[ -z "$GDRIVE_MAX_BACKUPS" ] && GDRIVE_MAX_BACKUPS="7"

KEEP_COUNT="$GDRIVE_MAX_BACKUPS"
DRY_RUN=false
LIST_ONLY=false
FORCE=false

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Inspects and cleans up older WordPress snapshots on Google Drive based on retention policy.

Options:
  -k, --keep <N>       Number of newest snapshots to keep (default: $GDRIVE_MAX_BACKUPS)
  -d, --dry-run        Show which snapshots would be deleted without deleting
  -l, --list           List snapshots and retention status without deleting
  -f, --force          Proceed with deletion without interactive confirmation
  -h, --help           Show this help message

Examples:
  ./scripts/cleanup-snapshot.sh -l
  ./scripts/cleanup-snapshot.sh --dry-run
  ./scripts/cleanup-snapshot.sh --keep 5 --force
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--keep)
      KEEP_COUNT="$2"
      shift 2
      ;;
    --keep=*)
      KEEP_COUNT="${1#*=}"
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -l|--list)
      LIST_ONLY=true
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

if [ -n "$GDRIVE_SERVICE_ACCOUNT_KEY" ] && [[ "$GDRIVE_SERVICE_ACCOUNT_KEY" != /* ]] && [ ! -f "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
  if [ -f "$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    GDRIVE_SERVICE_ACCOUNT_KEY="$PATH_TO_WP/$GDRIVE_SERVICE_ACCOUNT_KEY"
  fi
fi

ACCESS_TOKEN=$(resolve_gdrive_access_token "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_ACCESS_TOKEN" "$GDRIVE_SERVICE_ACCOUNT_KEY")
if [ -z "$ACCESS_TOKEN" ]; then
  log_error "Google Drive access token could not be obtained."
  exit 1
fi

log_info "Fetching snapshot list for service '$SERVICE_NAME' (retention policy: keep latest $KEEP_COUNT)..."

QUERY="trashed = false and name contains 'snapshot-${SERVICE_NAME}'"
[ -n "$GDRIVE_FOLDER_ID" ] && QUERY="$QUERY and '$GDRIVE_FOLDER_ID' in parents"

RESPONSE=$(curl -s -G \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  --data-urlencode "q=$QUERY" \
  --data-urlencode "orderBy=createdTime desc" \
  --data-urlencode "fields=files(id, name, size, createdTime)" \
  --data-urlencode "pageSize=100" \
  "https://www.googleapis.com/drive/v3/files")

PARSED=$(python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
    files = data.get("files", [])
    keep = int("'$KEEP_COUNT'")
    total = len(files)
    for idx, f in enumerate(files, 1):
        status = "KEEP" if idx <= keep else "DELETE"
        print(f"{idx}\t{f.get(\"id\")}\t{f.get(\"name\")}\t{f.get(\"size\", 0)}\t{status}")
except Exception as e:
    sys.exit(1)
' <<< "$RESPONSE" || true)

if [ -z "$PARSED" ]; then
  log_info "No snapshots found for '$SERVICE_NAME' on Google Drive."
  exit 0
fi

echo "========================================================================================================"
printf "%-4s | %-45s | %-10s | %-8s\n" "No" "Snapshot File Name" "Size" "Action"
echo "--------------------------------------------------------------------------------------------------------"

to_delete=()
while IFS=$'\t' read -r idx fid fname fsize act; do
  fsize_mb="N/A"
  if [ "$fsize" -gt 0 ] 2>/dev/null; then
    fsize_mb="$(python3 -c "print(f'{$fsize / (1024*1024):.1f} MB')")"
  fi
  printf "%-4s | %-45s | %-10s | %-8s\n" "$idx" "$fname" "$fsize_mb" "$act"
  if [ "$act" = "DELETE" ]; then
    to_delete+=("$fid"$'\t'"$fname")
  fi
done <<< "$PARSED"
echo "========================================================================================================"

if [ ${#to_delete[@]} -eq 0 ]; then
  log_success "All snapshots are within retention policy ($KEEP_COUNT). No action needed."
  exit 0
fi

log_warn "${#to_delete[@]} snapshot(s) exceed retention policy and are candidates for deletion."

if [ "$LIST_ONLY" = true ]; then
  exit 0
fi

if [ "$DRY_RUN" = true ]; then
  log_info "Dry-run mode: No snapshots were deleted."
  exit 0
fi

if [ "$FORCE" != true ]; then
  read -rp "Proceed with deleting ${#to_delete[@]} old snapshot(s)? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Cleanup aborted by user."
    exit 0
  fi
fi

for item in "${to_delete[@]}"; do
  file_id=$(echo "$item" | cut -f1)
  file_name=$(echo "$item" | cut -f2)
  log_info "Deleting: $file_name ($file_id)..."
  del_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://www.googleapis.com/drive/v3/files/$file_id")
  if [ "$del_status" = "204" ] || [ "$del_status" = "200" ]; then
    log_success "Deleted $file_name"
  else
    log_warn "Failed to delete $file_name (HTTP $del_status)"
  fi
done

log_success "Snapshot retention cleanup finished."
