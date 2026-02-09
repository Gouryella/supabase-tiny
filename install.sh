#!/usr/bin/env bash
set -euo pipefail

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log_error "Need root privileges for this step, but sudo is not available."
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Missing required command: $cmd"
    exit 1
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker already installed."
  else
    log_warn "Docker not found. Installing with get.docker.com..."
    curl -fsSL https://get.docker.com | run_as_root bash -s docker
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl enable --now docker >/dev/null 2>&1 || true
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker installation failed."
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log_error "docker compose plugin is not available."
    exit 1
  fi
}

download_file() {
  local rel_path="$1"
  local dest="$INSTALL_DIR/$rel_path"
  local url="$REPO_RAW_BASE/$rel_path"
  mkdir -p "$(dirname "$dest")"
  log_info "Downloading $rel_path"
  curl -fsSL "$url" -o "$dest"
}

download_file_optional() {
  local rel_path="$1"
  local dest="$INSTALL_DIR/$rel_path"
  local url="$REPO_RAW_BASE/$rel_path"
  mkdir -p "$(dirname "$dest")"
  log_info "Downloading (optional) $rel_path"
  if ! curl -fsSL "$url" -o "$dest"; then
    log_warn "Optional file unavailable: $rel_path"
    return 1
  fi
  return 0
}

select_profile_if_needed() {
  if [ "$USER_SELECTED_PROFILE" = true ]; then
    return 0
  fi

  local prompt_fd
  prompt_fd=""

  if [ -t 0 ]; then
    prompt_fd=0
  elif { exec 3</dev/tty; } 2>/dev/null; then
    prompt_fd=3
  else
    log_info "No interactive terminal detected; defaulting to tiny profile."
    return 0
  fi

  close_prompt_fd() {
    if [ "$prompt_fd" = "3" ]; then
      exec 3<&-
    fi
  }

  local choice
  while true; do
    echo >&2
    echo "Choose deployment profile:" >&2
    echo "  1) tiny (Studio Go, lower memory)" >&2
    echo "  2) standard (Official Studio image)" >&2
    printf "Enter choice [1/2] (default: 1): " >&2

    if ! read -r -u "$prompt_fd" choice; then
      log_warn "Unable to read your choice; defaulting to tiny profile."
      close_prompt_fd
      return 0
    fi

    choice="${choice:-1}"
    case "$choice" in
      1)
        USER_SELECTED_PROFILE=true
        SELECTED_PROFILE="tiny"
        PROMPT_DEPLOY_ARGS=("--tiny")
        log_info "Profile selected: tiny"
        close_prompt_fd
        return 0
        ;;
      2)
        USER_SELECTED_PROFILE=true
        SELECTED_PROFILE="standard"
        PROMPT_DEPLOY_ARGS=("--standard")
        log_info "Profile selected: standard"
        close_prompt_fd
        return 0
        ;;
      *)
        echo "Invalid choice. Please enter 1 or 2." >&2
        ;;
    esac
  done
}

confirm_deploy_if_needed() {
  if [ "$AUTO_CONFIRM" = true ]; then
    return 0
  fi

  local prompt_fd
  prompt_fd=""

  if [ -t 0 ]; then
    prompt_fd=0
  elif { exec 4</dev/tty; } 2>/dev/null; then
    prompt_fd=4
  else
    log_info "No interactive terminal detected; proceeding without deploy confirmation."
    return 0
  fi

  local answer
  while true; do
    printf "Proceed with deployment now? [y/N]: " >&2

    if ! read -r -u "$prompt_fd" answer; then
      answer=""
    fi

    case "${answer,,}" in
      y|yes)
        if [ "$prompt_fd" = "4" ]; then
          exec 4<&-
        fi
        return 0
        ;;
      ""|n|no)
        if [ "$prompt_fd" = "4" ]; then
          exec 4<&-
        fi

        local run_later_cmd=(bash "$INSTALL_DIR/deploy.sh")
        run_later_cmd+=("${FALLBACK_DEPLOY_ARGS[@]}")
        run_later_cmd+=("${PROMPT_DEPLOY_ARGS[@]}")
        run_later_cmd+=("${DEPLOY_PASSTHROUGH_ARGS[@]}")

        log_info "Deployment skipped."
        printf "Run later: "
        printf '%q ' "${run_later_cmd[@]}"
        printf "\n"
        exit 0
        ;;
      *)
        echo "Invalid choice. Please enter y or n." >&2
        ;;
    esac
  done
}

DEFAULT_INSTALL_DIR="$HOME/supabase-tiny"
if [ "$(id -u)" -eq 0 ]; then
  DEFAULT_INSTALL_DIR="/root/supabase-tiny"
fi

INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/Gouryella/supabase-tiny/main}"

USER_SELECTED_PROFILE=false
SELECTED_PROFILE=""
PROMPT_DEPLOY_ARGS=()
AUTO_CONFIRM=false
DEPLOY_PASSTHROUGH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --tiny)
      USER_SELECTED_PROFILE=true
      SELECTED_PROFILE="tiny"
      DEPLOY_PASSTHROUGH_ARGS+=("$arg")
      ;;
    --standard)
      USER_SELECTED_PROFILE=true
      SELECTED_PROFILE="standard"
      DEPLOY_PASSTHROUGH_ARGS+=("$arg")
      ;;
    --yes)
      AUTO_CONFIRM=true
      ;;
    *)
      DEPLOY_PASSTHROUGH_ARGS+=("$arg")
      ;;
  esac
done

FALLBACK_DEPLOY_ARGS=()

require_cmd bash
require_cmd curl

log_info "Install directory: $INSTALL_DIR"
log_info "Asset source: $REPO_RAW_BASE"

select_profile_if_needed

ensure_docker

mkdir -p "$INSTALL_DIR/config"

download_file "deploy.sh"
download_file "docker-compose.yml"
if ! download_file_optional "docker-compose.tiny.yml"; then
  if [ "$SELECTED_PROFILE" = "tiny" ]; then
    log_error "Tiny profile was selected, but docker-compose.tiny.yml is unavailable from $REPO_RAW_BASE."
    exit 1
  fi
  if [ "$USER_SELECTED_PROFILE" = false ]; then
    log_warn "Tiny compose is missing; falling back to standard profile."
    FALLBACK_DEPLOY_ARGS=("--standard")
  fi
fi
download_file "config/kong.yml.template"
download_file "Caddyfile"

chmod +x "$INSTALL_DIR/deploy.sh"

log_info "Bootstrap files are ready."
confirm_deploy_if_needed
log_info "Starting deployment..."

cd "$INSTALL_DIR"
exec bash "$INSTALL_DIR/deploy.sh" "${FALLBACK_DEPLOY_ARGS[@]}" "${PROMPT_DEPLOY_ARGS[@]}" "${DEPLOY_PASSTHROUGH_ARGS[@]}"
