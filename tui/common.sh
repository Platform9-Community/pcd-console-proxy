#!/bin/sh
# Shared helpers for PCD proxy TUI scripts

STATE_FILE="/etc/pcd-proxy/state.conf"

load_state() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

# save_state KEY VALUE
save_state() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$STATE_FILE"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$STATE_FILE"
    fi
}

# Regenerate /etc/nginx/nginx.conf from template and reload nginx.
# Expands @@UPSTREAM_SERVERS@@ from BACKEND_IPS list, then envsubst for $DOMAIN.
apply_nginx_config() {
    load_state
    local TMP
    TMP=$(mktemp)
    while IFS= read -r line; do
        if [ "$line" = "@@UPSTREAM_SERVERS@@" ]; then
            for ep in $BACKEND_IPS; do
                printf '        server %s;\n' "$ep"
            done
        else
            printf '%s\n' "$line"
        fi
    done < /etc/pcd-proxy/nginx.conf.tmpl \
        | DOMAIN="$DOMAIN" envsubst '$DOMAIN' > "$TMP"
    mv "$TMP" /etc/nginx/nginx.conf
    if rc-service nginx status >/dev/null 2>&1; then
        rc-service nginx reload
    else
        rc-service nginx start
    fi
}

# Print a styled header using gum
header() {
    gum style \
        --border rounded \
        --border-foreground 33 \
        --padding "0 2" \
        --width "${COLUMNS:-120}" \
        --bold \
        "PCD Console Proxy — $1"
}
