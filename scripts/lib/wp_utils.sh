#!/usr/bin/env bash
set -e
# Category: Utility
# Description: Common WordPress and database operation utilities.
# Usage: source scripts/lib/wp_utils.sh
# Dependencies: docker, curl, openssl

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

# --- Repository & Environment Resolution ---
detect_project_paths() {
  local script_dir
  script_dir=$(dirname "$(readlink -f "${BASH_SOURCE[1]:-$0}")")
  local script_dir_user
  script_dir_user=$(stat -c '%U' "$script_dir" 2>/dev/null || echo "$USER")
  
  PATH_TO_WP=$(sudo -u "$script_dir_user" git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || dirname "$script_dir")
  SERVICE_NAME=$(basename "$PATH_TO_WP")
  REPOSITORY_OWNER=$(stat -c '%U' "$PATH_TO_WP" 2>/dev/null || echo "$USER")
  OWNER_HOME=$(eval echo "~$REPOSITORY_OWNER" 2>/dev/null || echo "$HOME")
  [ -z "$OWNER_HOME" ] && OWNER_HOME="$HOME"
}

# --- WordPress Database Operations ---
is_mysql_container_running() {
  local compose_file="${PATH_TO_WP:-.}/docker-compose.yml"
  if [ ! -f "$compose_file" ]; then
    return 1
  fi
  local container_id
  container_id=$(docker compose -f "$compose_file" ps -q db 2>/dev/null || true)
  if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null)" = "true" ]; then
    return 0
  fi
  return 1
}

ensure_mysql_container_running() {
  local compose_file="${PATH_TO_WP:-.}/docker-compose.yml"
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

run_mysql_dump() {
  local db_name="$1"
  local compose_file="${PATH_TO_WP:-.}/docker-compose.yml"
  local env_file="${PATH_TO_WP:-.}/.env"
  local secret_file="${PATH_TO_WP:-.}/.secrets/db_password"

  if [ -z "$db_name" ]; then
    db_name=$(grep "^WORDPRESS_DB_NAME=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  fi

  local db_user
  db_user=$(grep "^WORDPRESS_DB_USER=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  [ -z "$db_user" ] && db_user="wordpress"

  ensure_mysql_container_running

  docker compose -f "$compose_file" exec -T db sh -c '
    if [ -f /run/secrets/db_password ]; then
      PASS=$(cat /run/secrets/db_password)
    else
      PASS="$MYSQL_PASSWORD"
    fi
    MYSQL_PWD="$PASS" exec mysqldump -u "'"$db_user"'" --single-transaction --quick --routines --triggers "'"$db_name"'"
  '
}

run_mysql_restore() {
  local target_db="$1"
  local compose_file="${PATH_TO_WP:-.}/docker-compose.yml"
  local env_file="${PATH_TO_WP:-.}/.env"

  if [ -z "$target_db" ]; then
    target_db=$(grep "^WORDPRESS_DB_NAME=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  fi

  local db_user
  db_user=$(grep "^WORDPRESS_DB_USER=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
  [ -z "$db_user" ] && db_user="wordpress"

  ensure_mysql_container_running

  # Ensure target database exists
  docker compose -f "$compose_file" exec -T db sh -c '
    if [ -f /run/secrets/db_password ]; then
      PASS=$(cat /run/secrets/db_password)
    else
      PASS="$MYSQL_PASSWORD"
    fi
    MYSQL_PWD="$PASS" exec mysql -u "'"$db_user"'" -e "CREATE DATABASE IF NOT EXISTS \`'"$target_db"'\`;"
  '

  # Restore SQL dump from stdin
  docker compose -f "$compose_file" exec -T db sh -c '
    if [ -f /run/secrets/db_password ]; then
      PASS=$(cat /run/secrets/db_password)
    else
      PASS="$MYSQL_PASSWORD"
    fi
    MYSQL_PWD="$PASS" exec mysql -u "'"$db_user"'" "'"$target_db"'"
  '
}

# --- WordPress Metadata & Version Detection ---
extract_wp_version() {
  local version_file="${PATH_TO_WP:-.}/data/wordpress/wp-includes/version.php"
  if [ -f "$version_file" ]; then
    local ver
    ver=$(grep "\$wp_version\s*=" "$version_file" | head -n 1 | cut -d "'" -f 2 | tr -d '\r\n')
    if [ -n "$ver" ]; then
      echo "$ver"
      return 0
    fi
  fi

  local env_file="${PATH_TO_WP:-.}/.env"
  local img_tag
  img_tag=$(grep "^WORDPRESS_IMAGE_TAG=" "$env_file" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  if [ -n "$img_tag" ]; then
    echo "$img_tag"
    return 0
  fi

  echo "unknown"
}

generate_wp_manifest() {
  local target_file="$1"
  local db_name="$2"
  local wp_version
  wp_version=$(extract_wp_version)
  local img_tag
  img_tag=$(grep "^WORDPRESS_IMAGE_TAG=" "${PATH_TO_WP:-.}/.env" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true)
  local created_at
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat <<EOF > "$target_file"
{
  "application": "wordpress",
  "service_name": "${SERVICE_NAME:-wordpress}",
  "db_name": "$db_name",
  "wp_version": "$wp_version",
  "image_tag": "$img_tag",
  "created_at": "$created_at"
}
EOF
}

# --- Git Hashes Helper ---
getGitHash() {
  local git_path=$1
  local output_file=$2
  local git_real_owner
  git_real_owner=$(stat -c '%U' "$git_path" 2>/dev/null || echo "${REPOSITORY_OWNER:-$USER}")

  {
      echo "  Updated at [$(date +"%Y-%m-%d %H:%M:%S")]"
      echo "  Git Directory: $git_path"
      echo "  Git Remote: $(sudo -u "$git_real_owner" git -C "$git_path" config --get remote.origin.url 2>/dev/null || echo "N/A")"
      echo "  Git Branch: $(sudo -u "$git_real_owner" git -C "$git_path" branch --show-current 2>/dev/null || echo "HEAD")"
      echo "  Git Hashes: $(sudo -u "$git_real_owner" git -C "$git_path" rev-parse HEAD 2>/dev/null || echo "N/A")"
      echo ""
  } >> "$output_file"
}

writeGitHash() {
  local search_dir=$1
  local output_file=$2

  [ -d "$search_dir" ] || return 0

  if [ -e "$search_dir/.git" ]; then
    getGitHash "$search_dir" "$output_file"
  fi
}

# --- Google Drive Helpers ---
get_gdrive_access_token_from_sa() {
  local sa_input="$1"
  local sa_json_content=""

  if [ -f "$sa_input" ]; then
    sa_json_content=$(cat "$sa_input")
  elif [[ "$sa_input" =~ ^\{.*\}$ ]]; then
    sa_json_content="$sa_input"
  else
    log_error "Service Account JSON key file or content '$sa_input' not found."
    return 1
  fi

  local client_email token_uri key_pem
  client_email=$(echo "$sa_json_content" | grep -o '"client_email": *"[^"]*"' | cut -d'"' -f4)
  token_uri=$(echo "$sa_json_content" | grep -o '"token_uri": *"[^"]*"' | cut -d'"' -f4)
  [ -z "$token_uri" ] && token_uri="https://oauth2.googleapis.com/token"

  key_pem=$(echo "$sa_json_content" | grep -o '"private_key": *"[^"]*"' | sed 's/^"private_key": *"//;s/"$//')

  if [ -z "$client_email" ] || [ -z "$key_pem" ]; then
    log_error "Could not parse client_email or private_key from Service Account JSON."
    return 1
  fi

  local b64url_cmd='openssl base64 -e -A | tr "+/" "-_" | tr -d "="'
  local now exp header_b64 claims claims_b64 unsigned_jwt sig_b64 jwt
  now=$(date +%s)
  exp=$((now + 3600))

  header_b64=$(echo -n '{"alg":"RS256","typ":"JWT"}' | eval "$b64url_cmd")
  claims="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/drive\",\"aud\":\"$token_uri\",\"exp\":$exp,\"iat\":$now}"
  claims_b64=$(echo -n "$claims" | eval "$b64url_cmd")

  unsigned_jwt="${header_b64}.${claims_b64}"
  sig_b64=$(printf "%s" "$unsigned_jwt" | openssl dgst -sha256 -sign <(printf '%b' "$key_pem") -binary 2>/dev/null | eval "$b64url_cmd")

  if [ -z "$sig_b64" ]; then
    log_error "Failed to sign Service Account JWT with openssl."
    return 1
  fi

  jwt="${unsigned_jwt}.${sig_b64}"

  local token_response
  token_response=$(curl -s -X POST \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=$jwt" \
    "$token_uri")

  echo "$token_response" | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4
}

is_gdrive_token_valid() {
  local token="$1"
  [ -z "$token" ] && return 1

  local resp http_code exp
  resp=$(curl -s --connect-timeout 5 --max-time 10 -w "\n%{http_code}" "https://oauth2.googleapis.com/tokeninfo?access_token=${token}" 2>/dev/null || true)
  http_code=$(echo "$resp" | tail -n1)

  if [ "$http_code" = "200" ]; then
    exp=$(echo "$resp" | sed '$d' | grep -o '"expires_in": *"[^"]*"' | cut -d'"' -f4)
    [ -z "$exp" ] && exp=$(echo "$resp" | sed '$d' | grep -o '"expires_in": *[0-9]*' | awk '{print $2}')
    if [ -n "$exp" ] && [ "$exp" -gt 60 ] 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

resolve_gdrive_access_token() {
  local current_token="$1"
  local raw_access_token="$2"
  local sa_input="$3"

  if is_gdrive_token_valid "$current_token"; then
    echo "$current_token"
    return 0
  fi

  if [ -n "$sa_input" ]; then
    get_gdrive_access_token_from_sa "$sa_input"
  elif [ -n "$raw_access_token" ]; then
    if [ -f "$raw_access_token" ]; then
      if [[ "$raw_access_token" == *.json ]] || grep -q '"type": *"service_account"' "$raw_access_token" 2>/dev/null; then
        get_gdrive_access_token_from_sa "$raw_access_token"
      else
        local file_tok
        file_tok=$(tr -d '\r\n' < "$raw_access_token")
        if is_gdrive_token_valid "$file_tok"; then
          echo "$file_tok"
        elif [ -n "$sa_input" ]; then
          get_gdrive_access_token_from_sa "$sa_input"
        else
          echo "$file_tok"
        fi
      fi
    elif [[ "$raw_access_token" =~ ^\{.*\}$ ]]; then
      get_gdrive_access_token_from_sa "$raw_access_token"
    else
      echo "$raw_access_token"
    fi
  fi
}

cleanup_gdrive_old_snapshots() {
  local access_token="$1"
  local folder_id="$2"
  local service_name="$3"
  local max_backups="$4"
  local raw_access_token="${5:-$access_token}"
  local sa_input="$6"

  if [ -z "$max_backups" ] || ! [[ "$max_backups" =~ ^[0-9]+$ ]] || [ "$max_backups" -le 0 ]; then
    return 0
  fi

  local valid_token
  valid_token=$(resolve_gdrive_access_token "$access_token" "$raw_access_token" "$sa_input")
  [ -n "$valid_token" ] && access_token="$valid_token"

  log_info "Running Google Drive lifecycle retention (keeping latest $max_backups snapshot(s) for $service_name)..."

  local query
  if [ -n "$folder_id" ]; then
    query="'$folder_id' in parents and name contains 'snapshot-$service_name' and trashed = false"
  else
    query="name contains 'snapshot-$service_name' and trashed = false"
  fi

  local list_response
  list_response=$(curl -s -X GET \
    -H "Authorization: Bearer $access_token" \
    "https://www.googleapis.com/drive/v3/files?q=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null || echo "")&orderBy=createdTime%20desc&fields=files(id,name,createdTime)")

  local files_to_delete
  files_to_delete=$(echo "$list_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    files = data.get('files', [])
    if len(files) > $max_backups:
        for f in files[$max_backups:]:
            print(f['id'] + '\t' + f['name'])
except Exception:
    pass
" 2>/dev/null || true)

  if [ -n "$files_to_delete" ]; then
    while IFS=$'\t' read -r file_id file_name; do
      [ -z "$file_id" ] && continue
      log_warn "Deleting old snapshot: $file_name ($file_id)..."
      local del_status
      del_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer $access_token" \
        "https://www.googleapis.com/drive/v3/files/$file_id")
      if [ "$del_status" = "204" ] || [ "$del_status" = "200" ]; then
        log_success "Deleted old snapshot $file_name"
      else
        log_warn "Failed to delete old snapshot $file_name (HTTP $del_status)"
      fi
    done <<< "$files_to_delete"
  else
    log_info "Snapshot retention check: No older snapshots require deletion."
  fi
}
