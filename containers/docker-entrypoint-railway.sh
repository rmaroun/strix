#!/usr/bin/env bash
set -euo pipefail

# Default port if not provided by environment
: "${CAIDO_PORT:=9000}"
export CAIDO_PORT

# Ensure caido-cli exists
if ! command -v caido-cli >/dev/null 2>&1; then
  echo "Error: caido-cli not found in PATH. Install or add to PATH."
  exit 1
fi

# logfile for caido output
CAIDO_LOG="/tmp/caido.log"
rm -f "$CAIDO_LOG"
touch "$CAIDO_LOG"
chmod 600 "$CAIDO_LOG"

# start caido in background and capture pid
echo "🚀 Starting Caido on 127.0.0.1:${CAIDO_PORT} (logs -> ${CAIDO_LOG})"
caido-cli --listen 127.0.0.1:${CAIDO_PORT} \
          --allow-guests \
          --no-logging \
          --no-open \
          --import-ca-cert /app/certs/ca.p12 \
          --import-ca-cert-pass "" >"$CAIDO_LOG" 2>&1 &

CAIDO_PID=$!

# cleanup function to kill caido on exit
_cleanup() {
  echo "Shutting down (cleanup)..."
  if ps -p "$CAIDO_PID" >/dev/null 2>&1; then
    kill "$CAIDO_PID" || true
    wait "$CAIDO_PID" 2>/dev/null || true
  fi
}
trap _cleanup EXIT INT TERM

# wait for GraphQL endpoint to be ready
echo "Waiting up to 60s for Caido API at http://127.0.0.1:${CAIDO_PORT}/graphql ..."
READY=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:${CAIDO_PORT}/graphql"; then
    echo "✅ Caido API is ready after ${i} second(s)."
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" -ne 1 ]; then
  echo "❌ Caido did not become ready within 60s. Last 200 lines of log:"
  tail -n 200 "$CAIDO_LOG" || true
  exit 1
fi

# short pause for stability
sleep 1

# fetch API token
echo "Fetching API token..."
TOKEN=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation LoginAsGuest { loginAsGuest { token { accessToken } } }"}' \
  "http://127.0.0.1:${CAIDO_PORT}/graphql" | jq -r '.data.loginAsGuest.token.accessToken')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Failed to get API token from Caido. Dumping /tmp/caido.log (last 200 lines) and GraphQL response:"
  tail -n 200 "$CAIDO_LOG" || true
  curl -s -X POST -H "Content-Type: application/json" -d '{"query":"mutation { loginAsGuest { token { accessToken } } }"}' "http://127.0.0.1:${CAIDO_PORT}/graphql" || true
  exit 1
fi

export CAIDO_API_TOKEN="$TOKEN"
echo "✅ Caido API token has been set."

# create a temporary project
echo "Creating a new Caido project..."
CREATE_PROJECT_RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"mutation CreateProject { createProject(input: {name: \"sandbox\", temporary: true}) { project { id } } }"}' \
  "http://127.0.0.1:${CAIDO_PORT}/graphql")

PROJECT_ID=$(echo "$CREATE_PROJECT_RESPONSE" | jq -r '.data.createProject.project.id' 2>/dev/null || echo "")

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
  echo "Failed to create Caido project. Response:"
  echo "$CREATE_PROJECT_RESPONSE"
  tail -n 200 "$CAIDO_LOG" || true
  exit 1
fi

echo "Caido project created with ID: $PROJECT_ID"

# select the project
echo "Selecting Caido project..."
SELECT_RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\":\"mutation SelectProject { selectProject(id: \\\"$PROJECT_ID\\\") { currentProject { project { id } } } }\"}" \
  "http://127.0.0.1:${CAIDO_PORT}/graphql")

SELECTED_ID=$(echo "$SELECT_RESPONSE" | jq -r '.data.selectProject.currentProject.project.id' 2>/dev/null || echo "")

if [ "$SELECTED_ID" != "$PROJECT_ID" ]; then
  echo "Failed to select Caido project. Response:"
  echo "$SELECT_RESPONSE"
  tail -n 200 "$CAIDO_LOG" || true
  exit 1
fi

echo "✅ Caido project selected successfully."

# configure system-wide proxy env files (no destructive changes)
echo "Configuring system-wide proxy settings..."
cat <<EOF >/etc/profile.d/proxy.sh
export http_proxy=http://127.0.0.1:${CAIDO_PORT}
export https_proxy=http://127.0.0.1:${CAIDO_PORT}
export HTTP_PROXY=http://127.0.0.1:${CAIDO_PORT}
export HTTPS_PROXY=http://127.0.0.1:${CAIDO_PORT}
export ALL_PROXY=http://127.0.0.1:${CAIDO_PORT}
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export CAIDO_API_TOKEN=${TOKEN}
EOF

cat <<EOF >/etc/environment
http_proxy=http://127.0.0.1:${CAIDO_PORT}
https_proxy=http://127.0.0.1:${CAIDO_PORT}
HTTP_PROXY=http://127.0.0.1:${CAIDO_PORT}
HTTPS_PROXY=http://127.0.0.1:${CAIDO_PORT}
ALL_PROXY=http://127.0.0.1:${CAIDO_PORT}
CAIDO_API_TOKEN=${TOKEN}
EOF

cat <<EOF >/etc/wgetrc
use_proxy=yes
http_proxy=http://127.0.0.1:${CAIDO_PORT}
https_proxy=http://127.0.0.1:${CAIDO_PORT}
EOF

echo "source /etc/profile.d/proxy.sh" >> /home/pentester/.bashrc 2>/dev/null || true
echo "source /etc/profile.d/proxy.sh" >> /home/pentester/.zshrc 2>/dev/null || true

# source the profile for current shell
# shellcheck disable=SC1091
source /etc/profile.d/proxy.sh || true

# add CA to browser NSS DB if certutil available
if command -v certutil >/dev/null 2>&1; then
  echo "Adding CA to pentester NSS DB..."
  sudo -u pentester mkdir -p /home/pentester/.pki/nssdb
  sudo -u pentester certutil -N -d sql:/home/pentester/.pki/nssdb --empty-password || true
  sudo -u pentester certutil -A -n "Testing Root CA" -t "C,," -i /app/certs/ca.crt -d sql:/home/pentester/.pki/nssdb || true
  echo "✅ CA added to browser trust store (if certutil available)"
else
  echo "Note: certutil not found, skipping browser trust store import"
fi

echo "Container init complete. Caido PID=${CAIDO_PID}. Shared container ready for multi-agent use."
echo "🔁 Starting exec of passed command: $*"

# move to workspace and run user's command(s)
cd /workspace || true

# exec passed CMD so PID 1 is the child and trap cleanup works
exec "$@"
