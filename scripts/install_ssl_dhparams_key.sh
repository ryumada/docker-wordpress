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

  log_info "Create ssl-dhparams key file..."
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
  log_success "ssl-dhparams key is already created."
}

main
