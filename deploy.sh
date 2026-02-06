#!/bin/bash
# One-click deploy the Supabase stack and generate the required .env file.
# Ensure Docker and docker-compose are installed before running this script.

set -euo pipefail

# -------------------------
# helpers
# -------------------------

base64url() {
  # Encode stdin to base64url (no padding).
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

jwt_hs256() {
  # Args: payload_json
  local payload_json="$1"
  local header_json='{"alg":"HS256","typ":"JWT"}'
  local header payload signing_input signature

  header="$(printf '%s' "$header_json" | base64url)"
  payload="$(printf '%s' "$payload_json" | base64url)"
  signing_input="${header}.${payload}"
  signature="$(printf '%s' "$signing_input" | openssl dgst -binary -sha256 -hmac "$JWT_SECRET" | base64url)"
  printf '%s.%s' "$signing_input" "$signature"
}

looks_like_jwt() {
  local token="${1:-}"
  [[ "$token" == *.*.* ]]
}

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
    log_error "Need root privileges for Docker installation, but sudo is not available."
    exit 1
  fi
}

ensure_docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
            log_error "docker command not found and curl is missing; cannot auto-install Docker."
            exit 1
        fi
        log_warn "Docker not found. Installing with get.docker.com..."
        curl -fsSL https://get.docker.com | run_as_root bash -s docker
        if command -v systemctl >/dev/null 2>&1; then
            run_as_root systemctl enable --now docker >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker installation failed."
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
            log_error "docker compose plugin not found and curl is missing; cannot auto-install Docker."
            exit 1
        fi
        log_warn "docker compose plugin not found. Re-running Docker installer..."
        curl -fsSL https://get.docker.com | run_as_root bash -s docker
        if command -v systemctl >/dev/null 2>&1; then
            run_as_root systemctl enable --now docker >/dev/null 2>&1 || true
        fi
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "docker compose plugin is still unavailable after installation."
        exit 1
    fi
}

wait_for_service() {
  local name="$1"
  local check_cmd="$2"
  local max_wait="${3:-60}"

  log_info "Waiting for $name to be ready..."
  for ((i = 1; i <= max_wait; i++)); do
    if eval "$check_cmd" >/dev/null 2>&1; then
      log_info "$name is ready (${i}s)"
      return 0
    fi
    if (( i % 10 == 0 )); then
      echo "  ...waited ${i}s"
    fi
    sleep 1
  done
  log_error "$name did not become ready within ${max_wait}s"
  return 1
}

ensure_runtime_dirs() {
  local functions_dir="$DIR/volumes/functions"
  local snippets_dir="$DIR/volumes/snippets"

  mkdir -p "$functions_dir/main" "$functions_dir/hello" "$snippets_dir"

  if [ ! -f "$functions_dir/main/index.ts" ]; then
    cat > "$functions_dir/main/index.ts" <<'EOF_MAIN'
import { serve } from "https://deno.land/std@0.177.1/http/server.ts";

serve(async () => {
  return new Response(
    JSON.stringify({ msg: "Hello from main Edge Function" }),
    { headers: { "Content-Type": "application/json" } }
  );
});
EOF_MAIN
  fi

  if [ ! -f "$functions_dir/hello/index.ts" ]; then
    cat > "$functions_dir/hello/index.ts" <<'EOF_HELLO'
import { serve } from "https://deno.land/std@0.177.1/http/server.ts";

serve(async () => {
  return new Response(
    JSON.stringify({ msg: "Hello from Edge Functions!" }),
    { headers: { "Content-Type": "application/json" } }
  );
});
EOF_HELLO
  fi
}

# Resolve the script directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

ENV_FILE="$DIR/.env"
DOCKER_COMPOSE_FILE="$DIR/docker-compose.yml"

# Parse command-line arguments
SKIP_START=false
FORCE_RECREATE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --config-only)
      SKIP_START=true
      shift
      ;;
    --recreate)
      FORCE_RECREATE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --config-only  Generate config only, do not start services"
      echo "  --recreate     Force recreate all containers"
      echo "  -h, --help     Show help"
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

ensure_docker_ready

# Load existing .env (if present) so missing fields can be filled in
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

log_info "Generating/updating .env file..."

# Generate random secrets (requires openssl). Install it if missing.
if ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl not found; cannot generate secrets automatically. Please install openssl."
    exit 1
fi

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"

# Derive public domain from Caddyfile as a suggested default
derived_domain="example.com"
if [ -f "$DIR/Caddyfile" ]; then
    derived_domain="$(awk 'NF && $1 !~ /^#/ { gsub("{","",$1); print $1; exit }' "$DIR/Caddyfile" || true)"
    derived_domain="${derived_domain:-example.com}"
fi

if [ -z "${SUPABASE_PUBLIC_DOMAIN:-}" ]; then
    if [ -t 0 ]; then
        if [ -n "$derived_domain" ]; then
            read -r -p "Enter SUPABASE_PUBLIC_DOMAIN [$derived_domain]: " SUPABASE_PUBLIC_DOMAIN
            SUPABASE_PUBLIC_DOMAIN="${SUPABASE_PUBLIC_DOMAIN:-$derived_domain}"
        else
            read -r -p "Enter SUPABASE_PUBLIC_DOMAIN [example.com]: " SUPABASE_PUBLIC_DOMAIN
            SUPABASE_PUBLIC_DOMAIN="${SUPABASE_PUBLIC_DOMAIN:-example.com}"
        fi
    else
        SUPABASE_PUBLIC_DOMAIN="${derived_domain:-example.com}"
        log_warn "SUPABASE_PUBLIC_DOMAIN not set; using ${SUPABASE_PUBLIC_DOMAIN}. Set it in the environment to override."
    fi
fi
ANALYTICS_ENABLED="${ANALYTICS_ENABLED:-false}"
SNIPPETS_MANAGEMENT_FOLDER="${SNIPPETS_MANAGEMENT_FOLDER:-/app/snippets}"
EDGE_FUNCTIONS_MANAGEMENT_FOLDER="${EDGE_FUNCTIONS_MANAGEMENT_FOLDER:-/app/edge-functions}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# Migrate legacy Studio folder defaults from the old named-volume layout.
if [ "$SNIPPETS_MANAGEMENT_FOLDER" = "/var/lib/supabase/snippets" ]; then
    SNIPPETS_MANAGEMENT_FOLDER="/app/snippets"
fi
if [ "$EDGE_FUNCTIONS_MANAGEMENT_FOLDER" = "/var/lib/supabase/edge-functions" ]; then
    EDGE_FUNCTIONS_MANAGEMENT_FOLDER="/app/edge-functions"
fi

# Supabase ANON_KEY / SERVICE_ROLE_KEY must be JWTs (used by PostgREST/GoTrue).
# Older scripts generated random strings; this corrects them to JWTs.
now_ts="$(date +%s)"
exp_ts="$((now_ts + 315360000))" # 10 years

if [ -z "${ANON_KEY:-}" ] || ! looks_like_jwt "${ANON_KEY:-}"; then
    log_info "Generating ANON_KEY (JWT)..."
    anon_payload="$(printf '{"role":"anon","iss":"supabase","ref":"default","aud":"authenticated","iat":%s,"exp":%s}' "$now_ts" "$exp_ts")"
    ANON_KEY="$(jwt_hs256 "$anon_payload")"
fi

if [ -z "${SERVICE_ROLE_KEY:-}" ] || ! looks_like_jwt "${SERVICE_ROLE_KEY:-}"; then
    log_info "Generating SERVICE_ROLE_KEY (JWT)..."
    service_payload="$(printf '{"role":"service_role","iss":"supabase","ref":"default","aud":"authenticated","iat":%s,"exp":%s}' "$now_ts" "$exp_ts")"
    SERVICE_ROLE_KEY="$(jwt_hs256 "$service_payload")"
fi

DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-admin}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-$(openssl rand -hex 16)}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -hex 16)}"
PG_META_CRYPTO_KEY="${PG_META_CRYPTO_KEY:-$(openssl rand -hex 32)}"
SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -hex 32)}"
VAULT_ENC_KEY="${VAULT_ENC_KEY:-$(openssl rand -hex 32)}"

# Default database user and name
POSTGRES_USER="${POSTGRES_USER:-supabase_admin}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
JWT_EXP="${JWT_EXP:-3600}"

cat > "$ENV_FILE" <<EOF_ENV
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_USER=$POSTGRES_USER
POSTGRES_DB=$POSTGRES_DB
JWT_SECRET=$JWT_SECRET
JWT_EXP=$JWT_EXP
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_KEY=$SERVICE_ROLE_KEY
DASHBOARD_USERNAME=$DASHBOARD_USERNAME
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
MINIO_ROOT_USER=$MINIO_ROOT_USER
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY
SECRET_KEY_BASE=$SECRET_KEY_BASE
VAULT_ENC_KEY=$VAULT_ENC_KEY
SUPABASE_PUBLIC_DOMAIN=$SUPABASE_PUBLIC_DOMAIN
ANALYTICS_ENABLED=$ANALYTICS_ENABLED
SNIPPETS_MANAGEMENT_FOLDER=$SNIPPETS_MANAGEMENT_FOLDER
EDGE_FUNCTIONS_MANAGEMENT_FOLDER=$EDGE_FUNCTIONS_MANAGEMENT_FOLDER
OPENAI_API_KEY=$OPENAI_API_KEY
EOF_ENV

log_info ".env generated/updated."

# Generate Kong config from template
mkdir -p "$DIR/config"
KONG_TEMPLATE="$DIR/config/kong.yml.template"
KONG_CONFIG="$DIR/config/kong.yml"

if [ -f "$KONG_TEMPLATE" ]; then
    log_info "Generating Kong config..."
    if [ -d "$KONG_CONFIG" ]; then
        log_warn "Detected $KONG_CONFIG is a directory; cleaning up..."
        rm -rf "$KONG_CONFIG"
    fi
    export SUPABASE_ANON_KEY="$ANON_KEY"
    export SUPABASE_SERVICE_KEY="$SERVICE_ROLE_KEY"
    export DASHBOARD_USERNAME="$DASHBOARD_USERNAME"
    export DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD"

    if command -v python3 >/dev/null 2>&1; then
        KONG_TEMPLATE="$KONG_TEMPLATE" KONG_CONFIG="$KONG_CONFIG" python3 - <<'PY'
import os
from pathlib import Path

template_path = Path(os.environ["KONG_TEMPLATE"])
output_path = Path(os.environ["KONG_CONFIG"])
data = template_path.read_text()
for key in ("SUPABASE_ANON_KEY", "SUPABASE_SERVICE_KEY", "DASHBOARD_USERNAME", "DASHBOARD_PASSWORD"):
    data = data.replace(f"${key}", os.environ.get(key, ""))
output_path.write_text(data)
PY
    elif command -v envsubst >/dev/null 2>&1; then
        envsubst < "$KONG_TEMPLATE" > "$KONG_CONFIG"
    else
        log_error "Missing python3 or envsubst; cannot render config/kong.yml"
        exit 1
    fi
else
    log_error "Missing config/kong.yml.template; please pull the latest code."
    exit 1
fi

ensure_runtime_dirs
log_info "Kong config is ready. Runtime bind-mount directories are initialized under ./volumes."

# If config-only, stop here
if [ "$SKIP_START" = true ]; then
    log_info "Skipped service startup (--config-only mode)"
    exit 0
fi

# Ensure docker-compose file exists
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    log_error "docker-compose.yml not found; place it in the script directory."
    exit 1
fi

# docker compose wrapper (always use the same env-file)
compose() {
  docker compose -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# Build up command arguments
UP_ARGS="-d"
if [ "$FORCE_RECREATE" = true ]; then
    UP_ARGS="$UP_ARGS --force-recreate"
fi

# Start or update all services
log_info "Starting services via docker compose..."

# Phase 1: start database and MinIO
log_info "Starting database and object storage..."
compose up $UP_ARGS db minio

# Wait for database to be ready
wait_for_service "PostgreSQL" \
  "compose exec -T -e PGPASSWORD='$POSTGRES_PASSWORD' db psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -c 'SELECT 1'" \
  180

# Wait for Supabase DB initialization (create default roles)
log_info "Waiting for Supabase DB initialization (default roles)..."
role_wait_seconds="${ROLE_WAIT_SECONDS:-600}"
role_count=""
for ((i = 1; i <= role_wait_seconds; i++)); do
  role_count="$(compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM pg_roles WHERE rolname IN ('supabase_auth_admin','supabase_storage_admin')" 2>/dev/null || true)"
  role_count="$(printf '%s' "$role_count" | tr -d '[:space:]')"
  if [ "$role_count" = "2" ]; then
    log_info "Database roles initialized (${i}s)"
    break
  fi
  if (( i % 10 == 0 )); then
    echo "  ...waited ${i}s, current role count: ${role_count:-unknown} (target=2)"
  fi
  sleep 1
done

if [ "$role_count" != "2" ]; then
  log_error "Supabase initialization timed out: supabase_auth_admin / supabase_storage_admin roles not detected."
  log_error "Check supabase-db logs (last 200 lines):"
  compose logs --tail=200 db || true
  exit 1
fi

log_info "Syncing system DB and service account passwords..."
compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v owner="$POSTGRES_USER" -v pgpass="$POSTGRES_PASSWORD" <<'SQL'
-- Supavisor requires the _supabase database (create if missing)
SELECT format('CREATE DATABASE _supabase OWNER %I', :'owner')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '_supabase')
\gexec

-- Realtime requires the _realtime schema (create if missing)
SELECT format('CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION %I', :'owner')
\gexec

-- If POSTGRES_PASSWORD changed in .env, sync related service role passwords
SELECT format('ALTER ROLE supabase_auth_admin WITH PASSWORD %L', :'pgpass')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin')
\gexec

SELECT format('ALTER ROLE supabase_storage_admin WITH PASSWORD %L', :'pgpass')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin')
\gexec
SQL

# Wait for MinIO and create bucket
wait_for_service "MinIO" \
  "compose exec -T minio mc alias set local http://localhost:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' 2>/dev/null || curl -sf http://127.0.0.1:13790/minio/health/live" \
  60

log_info "Initializing MinIO bucket..."
compose exec -T minio sh -c "
  mc alias set local http://localhost:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' 2>/dev/null || true
  mc mb local/supabase-storage --ignore-existing 2>/dev/null || true
  mc anonymous set download local/supabase-storage 2>/dev/null || true
" || log_warn "MinIO bucket initialization may have failed; Storage may be affected"

# Phase 2: start all services
log_info "Starting all services..."
compose up $UP_ARGS

log_info "Deployment complete."
echo ""
echo "=========================================="
echo "  Supabase self-hosted deployment info"
echo "=========================================="
echo ""
echo "Access URLs:"
echo "  Studio (recommended): https://$SUPABASE_PUBLIC_DOMAIN/"
echo "  Kong gateway:         http://127.0.0.1:13780"
echo ""
echo "Database connections:"
echo "  Direct:  postgresql://$POSTGRES_USER:****@127.0.0.1:13732/$POSTGRES_DB"
echo "  Pooler:  postgresql://$POSTGRES_USER:****@127.0.0.1:13743/$POSTGRES_DB"
echo ""
echo "Dashboard login:"
echo "  Username: $DASHBOARD_USERNAME"
echo "  Password: $DASHBOARD_PASSWORD"
echo ""
echo "API Keys (saved in .env):"
echo "  ANON_KEY:         ${ANON_KEY:0:20}..."
echo "  SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY:0:20}..."
echo ""
echo "Tips:"
echo "  - View service logs: docker compose logs -f [service]"
echo "  - Restart services:  docker compose restart [service]"
echo "  - Stop all services: docker compose down"
echo "=========================================="
