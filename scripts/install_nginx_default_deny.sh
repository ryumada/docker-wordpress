#!/bin/bash
#
# This script automates the installation and activation of a secure default-deny
# Nginx server block. This block acts as a catch-all for any traffic that
# doesn't match a specific domain, returning a 403 Forbidden response.
#
# It performs the following steps:
# 1. Creates the default-deny.conf file in /etc/nginx/sites-available/.
# 2. Creates a symbolic link to enable the configuration in /etc/nginx/sites-enabled/.
# 3. Tests the Nginx configuration syntax.
# 4. Reloads the Nginx service to apply the new changes.
#
# Requires root privileges to run.

# Exit script immediately on a non-zero status.
set -e

# --- ANSI Color Codes ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[1;37m'
RESET='\033[0m'

# --- Simple Logging Functions with Colors ---
log_info() {
  echo -e "${WHITE}[$(date +"%Y-%m-%d %H:%M:%S")] 🟦 $1${RESET}"
}

log_success() {
  echo -e "${GREEN}[$(date +"%Y-%m-%d %H:%M:%S")] ✅ $1${RESET}"
}

log_warning() {
  echo -e "${YELLOW}[$(date +"%Y-%m-%d %H:%M:%S")] ⚠️ $1${RESET}"
}

log_error() {
  >&2 echo -e "${RED}[$(date +"%Y-%m-%d %H:%M:%S")] 🔴 $1${RESET}"
}
# --- End Logging Functions ---

# --- Error Handler ---
error_handler() {
  # The `LINENO` variable holds the line number of the failed command.
  log_error "An error occurred on line $1. Exiting."
  exit 1
}
# Trap any command that exits with a non-zero status and call the error_handler.
trap 'error_handler $LINENO' ERR

function amIRoot() {
  if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script using sudo."
    exit 1
  fi
}

function main() {
  amIRoot

  log_info "Starting the Nginx default-deny configuration script..."

  # --- Step 1: Define paths and configuration content ---
  NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
  NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
  CONF_FILE="default-deny.conf"
  CONF_PATH="${NGINX_SITES_AVAILABLE}/${CONF_FILE}"
  SYMLINK_PATH="${NGINX_SITES_ENABLED}/${CONF_FILE}"

  # The Nginx configuration content for the default deny block.
  # We use 'cat <<EOF' to write a multi-line string to the file.
  NGINX_CONF_CONTENT=$(cat <<'EOF'
  server {
      listen 80 default_server;
      listen 443 ssl http2 default_server;
      server_name _;
      return 403;
  }
EOF
  )

  log_info "Creating Nginx configuration file: ${CONF_PATH}"
  echo "${NGINX_CONF_CONTENT}" | sudo tee "${CONF_PATH}" > /dev/null
  log_success "Configuration file created successfully."

  log_info "Creating symbolic link to enable the configuration: ${SYMLINK_PATH}"
  # Check if the symlink already exists before attempting to create it.
  if [ -L "${SYMLINK_PATH}" ]; then
    log_warning "Symbolic link already exists. Skipping link creation."
  else
    sudo ln -s "${CONF_PATH}" "${SYMLINK_PATH}"
    log_success "Symbolic link created successfully."
  fi

  log_info "Testing Nginx configuration..."
  # The 'nginx -t' command will exit with an error on a syntax failure,
  # which the `trap` handler will catch.
  sudo nginx -t

  # If the command above succeeds, the trap isn't triggered, and we log success.
  log_success "Nginx configuration syntax is OK."

  log_info "Reloading Nginx service..."
  sudo systemctl reload nginx
  log_success "Nginx service reloaded. The default-deny configuration is now active."

  log_success "Script finished successfully."
}

main
