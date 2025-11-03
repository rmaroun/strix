#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"; }

# -----------------------------------------------------------------------------------
# 0) Environment sanity
# -----------------------------------------------------------------------------------
: "${REQUESTS_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}"
: "${SSL_CERT_FILE:=/etc/ssl/certs/ca-certificates.crt}"
export REQUESTS_CA_BUNDLE SSL_CERT_FILE

# Helpful defaults if not set (won't break anything if set by Railway)
: "${XDG_RUNTIME_DIR:=/home/pentester/.docker/run}"
: "${DOCKER_HOST:=unix:///home/pentester/.docker/run/docker.sock}"
export XDG_RUNTIME_DIR DOCKER_HOST

# -----------------------------------------------------------------------------------
# 1) Optional: Start Caido local proxy if available
#    - Skips cleanly if 'caido-cli' not present or CAIDO_PORT not set
# -----------------------------------------------------------------------------------
CAIDO_OK=false
if command -v caido-cli >/dev/null 2>&1 && [[ -n "${CAIDO_PORT:-}" ]]; then
  log "Starting Caido on 127.0.0.1:${CAIDO_PORT} ..."
  caido-cli \
    --listen "127.0.0.1:${CAIDO_PORT}" \
    --allow-guests \
    --no-logging \
    --no-open \
    --import-ca-cert /app/certs/ca.p12 \
    --import-ca-cert-pass "" > /tmp/caido.log 2>&1 &
  
  # Wait for GraphQL up (max ~40s)
  for i in $(seq 1 40); do
    if curl -sSf "http://127.0.0.1:${CAIDO_PORT}/graphql" >/dev/null 2>&1; then
      log "Caido API is ready."
      CAIDO_OK=true
      break
    fi
    sleep 1
  done

  if $CAIDO_OK; then
    # Fetch guest token with retries
    TOKEN=""
    for i in $(seq 1 5); do
      TOKEN="$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"query":"mutation LoginAsGuest { loginAsGuest { token { accessToken } } }"}' \
        "http://127.0.0.1:${CAIDO_PORT}/graphql" | jq -r '.data.loginAsGuest.token.accessToken' || true)"
      [[ -n "$TOKEN" && "$TOKEN" != "null" ]] && break
      sleep 1
    done

    if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
      export CAIDO_API_TOKEN="$TOKEN"
      log "Caido API token has been set."

      # Create project (retry lightly)
      CREATE_PROJECT_RESPONSE="$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"query":"mutation CreateProject { createProject(input: {name: \"sandbox\", temporary: true}) { project { id } } }"}' \
        "http://127.0.0.1:${CAIDO_PORT}/graphql" || true)"
      PROJECT_ID="$(echo "$CREATE_PROJECT_RESPONSE" | jq -r '.data.createProject.project.id' 2>/dev/null || true)"

      if [[ -n "$PROJECT_ID" && "$PROJECT_ID" != "null" ]]; then
        log "Caido project created: $PROJECT_ID"
        SELECT_RESPONSE="$(curl -s -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -d '{"query":"mutation SelectProject { selectProject(id: \"'"$PROJECT_ID"'\") { currentProject { project { id } } } }"}' \
          "http://127.0.0.1:${CAIDO_PORT}/graphql" || true)"
        SELECTED_ID="$(echo "$SELECT_RESPONSE" | jq -r '.data.selectProject.currentProject.project.id' 2>/dev/null || true)"
        if [[ "$SELECTED_ID" == "$PROJECT_ID" ]]; then
          log "✅ Caido project selected."
        else
          log "WARN: Failed to select Caido project (response: $SELECT_RESPONSE)"
        fi
      else
        log "WARN: Failed to create Caido project (response: $CREATE_PROJECT_RESPONSE)"
      fi

      # Light proxy env for processes launched from here
      export http_proxy="http://127.0.0.1:${CAIDO_PORT}"
      export https_proxy="http://127.0.0.1:${CAIDO_PORT}"
      export HTTP_PROXY="$http_proxy"
      export HTTPS_PROXY="$https_proxy"
      export ALL_PROXY="$http_proxy"

      # Persist (best-effort) to system env files if sudo exists
      if command -v sudo >/dev/null 2>&1; then
        log "Writing proxy env to /etc/profile.d and /etc/environment (best-effort)."
        cat << EOF | sudo tee /etc/profile.d/proxy.sh >/dev/null
export http_proxy=http://127.0.0.1:${CAIDO_PORT}
export https_proxy=http://127.0.0.1:${CAIDO_PORT}
export HTTP_PROXY=http://127.0.0.1:${CAIDO_PORT}
export HTTPS_PROXY=http://127.0.0.1:${CAIDO_PORT}
export ALL_PROXY=http://127.0.0.1:${CAIDO_PORT}
export REQUESTS_CA_BUNDLE=${REQUESTS_CA_BUNDLE}
export SSL_CERT_FILE=${SSL_CERT_FILE}
export CAIDO_API_TOKEN=${TOKEN}
EOF
        cat << EOF | sudo tee /etc/environment >/dev/null
http_proxy=http://127.0.0.1:${CAIDO_PORT}
https_proxy=http://127.0.0.1:${CAIDO_PORT}
HTTP_PROXY=http://127.0.0.1:${CAIDO_PORT}
HTTPS_PROXY=http://127.0.0.1:${CAIDO_PORT}
ALL_PROXY=http://127.0.0.1:${CAIDO_PORT}
CAIDO_API_TOKEN=${TOKEN}
EOF
        cat << EOF | sudo tee /etc/wgetrc >/dev/null
use_proxy=yes
http_proxy=http://127.0.0.1:${CAIDO_PORT}
https_proxy=http://127.0.0.1:${CAIDO_PORT}
EOF
      fi

      # Trust CA into NSS store (non-fatal)
      if command -v certutil >/dev/null 2>&1; then
        mkdir -p /home/pentester/.pki/nssdb || true
        certutil -N -d sql:/home/pentester/.pki/nssdb --empty-password 2>/dev/null || true
        certutil -A -n "Testing Root CA" -t "C,," -i /app/certs/ca.crt -d sql:/home/pentester/.pki/nssdb || true
        log "✅ CA added to NSS trust store."
      fi
    else
      log "WARN: Could not obtain Caido token; continuing without Caido auth."
    fi
  else
    log "WARN: Caido API did not come up in time; continuing without Caido."
  fi
else
  if ! command -v caido-cli >/dev/null 2>&1; then
    log "INFO: caido-cli not found in PATH — skipping Caido setup."
  elif [[ -z "${CAIDO_PORT:-}" ]]; then
    log "INFO: CAIDO_PORT not set — skipping Caido setup."
  fi
fi

# -----------------------------------------------------------------------------------
# 2) Optional: Start rootless Docker if available (non-fatal if it fails)
# -----------------------------------------------------------------------------------
if command -v dockerd-rootless.sh >/dev/null 2>&1; then
  log "Starting rootless Docker ..."
  mkdir -p "${XDG_RUNTIME_DIR}" || true
  chmod 700 "${XDG_RUNTIME_DIR}" || true

  # Start in background; logs to file
  dockerd-rootless.sh --storage-driver=fuse-overlayfs > /tmp/dockerd-rootless.log 2>&1 &

  # Wait briefly for readiness
  for i in $(seq 1 60); do
    if docker version >/dev/null 2>&1; then
      log "Docker is ready: $(docker info --format '{{.ServerVersion}}' || echo '?')"
      break
    fi
    sleep 1
  done

  if ! docker version >/dev/null 2>&1; then
    log "WARN: Rootless Docker failed to start. Tail follows:"
    tail -n 200 /tmp/dockerd-rootless.log || true
    log "Continuing without Docker (some Strix features may be disabled)."
  fi
else
  log "dockerd-rootless.sh not found — skipping rootless Docker."
fi

# -----------------------------------------------------------------------------------
# 3) Hand off to app (CMD)
# -----------------------------------------------------------------------------------
log "Container initialization complete — starting tool server (CMD)..."
cd /workspace
exec "$@"
