#!/bin/bash
set -e

# --- Diagnostics: ensure caido-cli is available ------------------------------
if ! command -v caido-cli >/dev/null 2>&1; then
  echo "ERROR: caido-cli not found in PATH. Checking common locations..."
  echo "PATH: $PATH"
  ls -l /usr/bin/caido-cli 2>/dev/null || echo "/usr/bin/caido-cli not found"
  ls -l /usr/local/bin/caido-cli 2>/dev/null || echo "/usr/local/bin/caido-cli not found"
  ls -l /home/pentester/.local/bin/caido-cli 2>/dev/null || echo "~/.local/bin/caido-cli not found"
fi

# --- Require CAIDO_PORT for local proxying -----------------------------------
if [ -z "$CAIDO_PORT" ]; then
  echo "Error: CAIDO_PORT must be set."
  exit 1
fi

# Start Caido quietly in background
caido-cli --listen 127.0.0.1:${CAIDO_PORT} \
          --allow-guests \
          --no-logging \
          --no-open \
          --import-ca-cert /app/certs/ca.p12 \
          --import-ca-cert-pass "" > /dev/null 2>&1 &

echo "Waiting for Caido API to be ready..."
for i in {1..30}; do
  if curl -s -o /dev/null "http://127.0.0.1:${CAIDO_PORT}/graphql"; then
    echo "Caido API is ready."
    break
  fi
  sleep 1
done

# Fetch guest token
echo "Fetching API token..."
TOKEN=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation LoginAsGuest { loginAsGuest { token { accessToken } } }"}' \
  "http://127.0.0.1:${CAIDO_PORT}/graphql" | jq -r '.data.loginAsGuest.token.accessToken' || true)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to get API token from Caido."
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{"query":"mutation { loginAsGuest { token { accessToken } } }"}' \
    "http://127.0.0.1:${CAIDO_PORT}/graphql" || true
  # do not exit hard; allow tool server to run without Caido
else
  export CAIDO_API_TOKEN="$TOKEN"
  echo "Caido API token has been set."

  echo "Creating a new Caido project..."
  CREATE_PROJECT_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"query":"mutation CreateProject { createProject(input: {name: \"sandbox\", temporary: true}) { project { id } } }"}' \
    "http://127.0.0.1:${CAIDO_PORT}/graphql")

  PROJECT_ID=$(echo "$CREATE_PROJECT_RESPONSE" | jq -r '.data.createProject.project.id')

  if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
    echo "Caido project created with ID: $PROJECT_ID"

    echo "Selecting Caido project..."
    SELECT_RESPONSE=$(curl -s -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -d '{"query":"mutation SelectProject { selectProject(id: \"'"$PROJECT_ID"'\") { currentProject { project { id } } } }"}' \
      "http://127.0.0.1:${CAIDO_PORT}/graphql")

    SELECTED_ID=$(echo "$SELECT_RESPONSE" | jq -r '.data.selectProject.currentProject.project.id')

    if [ "$SELECTED_ID" = "$PROJECT_ID" ]; then
      echo "✅ Caido project selected successfully."
    else
      echo "Failed to select Caido project. Response: $SELECT_RESPONSE"
    fi
  else
    echo "Failed to create Caido project. Response: $CREATE_PROJECT_RESPONSE"
  fi
fi

# Configure basic proxy environment (non-fatal if sudo not available)
if command -v sudo >/dev/null 2>&1; then
  echo "Configuring system-wide proxy settings..."
  cat << EOF | sudo tee /etc/profile.d/proxy.sh >/dev/null
export http_proxy=http://127.0.0.1:${CAIDO_PORT}
export https_proxy=http://127.0.0.1:${CAIDO_PORT}
export HTTP_PROXY=http://127.0.0.1:${CAIDO_PORT}
export HTTPS_PROXY=http://127.0.0.1:${CAIDO_PORT}
export ALL_PROXY=http://127.0.0.1:${CAIDO_PORT}
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
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

# Trust CA in browser store
if command -v certutil >/dev/null 2>&1; then
  mkdir -p /home/pentester/.pki/nssdb
  certutil -N -d sql:/home/pentester/.pki/nssdb --empty-password || true
  certutil -A -n "Testing Root CA" -t "C,," -i /app/certs/ca.crt -d sql:/home/pentester/.pki/nssdb || true
  echo "✅ CA added to browser trust store"
fi

echo "Container initialization complete - starting tool server..."
cd /workspace

# Hand off to CMD (FastAPI tool_server via uvicorn inside Python module)
exec "$@"
