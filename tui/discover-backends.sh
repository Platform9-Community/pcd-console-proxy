#!/bin/sh
# Auto-discover nova-novncproxy backends via OpenStack Application Credential.
# Installed to /usr/local/lib/pcd-proxy/discover-backends.sh

set -e

CRED_FILE="/etc/pcd-proxy/app-credential.env"
LIBDIR="/usr/local/lib/pcd-proxy"
NOVNC_PORT="${OS_NOVNC_PORT:-6080}"

# Source credential env; exit silently if not configured
. "$CRED_FILE" 2>/dev/null || exit 0
[ -n "$OS_APPLICATION_CREDENTIAL_ID" ] || exit 0
[ -n "$OS_AUTH_URL" ] || exit 0

INTERFACE="${OS_INTERFACE:-public}"
AUTH_ENDPOINT="${OS_AUTH_URL%/}/auth/tokens"

# Authenticate with application credential
AUTH_BODY=$(printf '{"auth":{"identity":{"methods":["application_credential"],"application_credential":{"id":"%s","secret":"%s"}}}}' \
    "$OS_APPLICATION_CREDENTIAL_ID" "$OS_APPLICATION_CREDENTIAL_SECRET")

AUTH_RESP=$(curl -si -X POST "$AUTH_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "$AUTH_BODY" 2>/dev/null)

TOKEN=$(printf '%s' "$AUTH_RESP" | grep -i '^x-subject-token:' | tr -d '\r' | awk '{print $2}')
BODY=$(printf '%s' "$AUTH_RESP" | sed -n '/^\r*$/,$ p' | tail -n +2)

if [ -z "$TOKEN" ]; then
    logger -t pcd-discover "ERROR: Keystone authentication failed"
    exit 1
fi

# Extract Nova endpoint matching the configured interface type and region
REGION="${OS_REGION_NAME:-}"
NOVA_URL=$(printf '%s' "$BODY" | jq -r --arg iface "$INTERFACE" --arg region "$REGION" '
    .token.catalog[]
    | select(.type == "compute")
    | .endpoints[]
    | select(.interface == $iface and ($region == "" or .region == $region or .region_id == $region))
    | .url' | head -1)

if [ -z "$NOVA_URL" ]; then
    logger -t pcd-discover "ERROR: Nova compute endpoint not found (interface=$INTERFACE)"
    exit 1
fi

# Query nova-novncproxy service hosts
HOSTS=$(curl -sf "${NOVA_URL%/}/os-services?binary=nova-novncproxy" \
    -H "X-Auth-Token: $TOKEN" 2>/dev/null \
    | jq -r '.services[].host' 2>/dev/null)

if [ -z "$HOSTS" ]; then
    logger -t pcd-discover "WARN: No nova-novncproxy services found"
    exit 0
fi

# TCP health-check each host and collect reachable ones
REACHABLE=""
for host in $HOSTS; do
    if nc -z -w3 "$host" "$NOVNC_PORT" 2>/dev/null; then
        REACHABLE="${REACHABLE:+$REACHABLE }${host}:${NOVNC_PORT}"
    else
        logger -t pcd-discover "WARN: $host:$NOVNC_PORT unreachable, skipping"
    fi
done

if [ -z "$REACHABLE" ]; then
    logger -t pcd-discover "WARN: All nova-novncproxy hosts unreachable — leaving BACKEND_IPS unchanged"
    exit 0
fi

COUNT=0
for _ in $REACHABLE; do COUNT=$((COUNT+1)); done

. "$LIBDIR/common.sh"
save_state BACKEND_IPS "$REACHABLE"
apply_nginx_config

logger -t pcd-discover "OK: $COUNT backend(s) configured: $REACHABLE"
