#!/bin/sh
# TUI screen: TLS certificate management via acme.sh (Let's Encrypt) or manual install

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"
load_state

CERT_DIR="/etc/pcd-proxy/certs"
ACME_WEBROOT="/var/www/acme"
DNS_CREDS="/etc/pcd-proxy/dns-credentials.conf"
ACME_LOG="/var/log/pcd-acme.log"
W=${COLUMNS:-120}

# Write a credential as "export KEY="value"" so sourcing the file exports it
# to child processes (acme.sh DNS hooks need exported env vars).
_set_cred() {
    local key="$1" value="$2"
    if grep -q "^export ${key}=" "$DNS_CREDS" 2>/dev/null; then
        sed -i "s|^export ${key}=.*|export ${key}=\"${value}\"|" "$DNS_CREDS"
    else
        printf 'export %s="%s"\n' "$key" "$value" >> "$DNS_CREDS"
    fi
}

_install_cert() {
    local domain="$1"
    /usr/local/bin/acme.sh --install-cert -d "$domain" \
        --cert-file      "$CERT_DIR/cert.pem" \
        --key-file       "$CERT_DIR/key.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd      "rc-service nginx reload" >> "$ACME_LOG" 2>&1
    /usr/local/bin/acme.sh --install-cronjob
    apply_nginx_config
}

_run_acme() {
    # Runs acme.sh with all args, capturing output to log. Returns acme.sh exit code.
    local title="$1"; shift
    gum spin --title "$title" -- sh -c "/usr/local/bin/acme.sh $* >>'$ACME_LOG' 2>&1"
}

_show_acme_log() {
    if [ -s "$ACME_LOG" ]; then
        gum style --foreground 214 --width "$W" "  Last 40 lines of $ACME_LOG:"
        tail -40 "$ACME_LOG" | gum pager
    fi
}

clear
header "TLS / Certificate"
echo

# Current cert status
if [ -f "$CERT_DIR/fullchain.pem" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    if ! openssl x509 -checkend 2592000 -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null; then
        gum style --foreground 214 --width "$W" "⚠  Expires soon: $EXPIRY — renew now"
    else
        gum style --foreground 82 --width "$W" "✓  ${DOMAIN:-unknown} — expires $EXPIRY"
    fi
    [ "$CERT_METHOD" = "manual" ]      && gum style --faint --width "$W" "  Method: manual (no auto-renewal)"
    [ "$CERT_METHOD" = "selfsigned" ]  && gum style --faint --width "$W" "  Method: self-signed (no auto-renewal — replace before production)"
    [ "$CERT_METHOD" = "dns01" ]       && gum style --faint --width "$W" "  Method: DNS-01  Provider: ${CERT_DNS_PROVIDER:--}  Hook: ${CERT_DNS_HOOK:--}  Auto-renewal: on"
    [ "$CERT_METHOD" = "http01" ]      && gum style --faint --width "$W" "  Method: HTTP-01  Auto-renewal: on"
else
    gum style --foreground 214 --width "$W" "No certificate installed."
fi
echo

CHOICE=$(gum choose \
    --height 10 \
    "Issue / Renew — Let's Encrypt (HTTP-01)" \
    "Issue / Renew — Let's Encrypt (DNS-01)" \
    "Generate Self-Signed Certificate" \
    "Install Manual Certificate" \
    "Force Renew" \
    "View Certificate Details" \
    "View acme.sh Log" \
    "Back")

case "$CHOICE" in

    "Issue / Renew — Let's Encrypt (HTTP-01)")
        DOMAIN=$(gum input \
            --placeholder "e.g. proxy.example.com" \
            --value "${DOMAIN:-}" \
            --prompt "  Domain name: " \
            --width "$W")
        [ -z "$DOMAIN" ] && return

        EMAIL=$(gum input \
            --placeholder "e.g. admin@example.com" \
            --value "${CERT_EMAIL:-}" \
            --prompt "  Email for Let's Encrypt: " \
            --width "$W")
        [ -z "$EMAIL" ] && return

        gum confirm "Issue Let's Encrypt cert for ${DOMAIN} via HTTP-01? (port 80 must be reachable from the internet)" || return

        save_state DOMAIN "$DOMAIN"
        save_state CERT_EMAIL "$EMAIL"
        save_state CERT_METHOD "http01"
        save_state CERT_DNS_HOOK ""
        mkdir -p "$ACME_WEBROOT" "$CERT_DIR"
        apply_nginx_config

        : > "$ACME_LOG"
        _run_acme "Requesting certificate from Let's Encrypt..." \
            "--issue -d \"$DOMAIN\" --webroot \"$ACME_WEBROOT\" --accountemail \"$EMAIL\" --server letsencrypt"

        if [ $? -eq 0 ]; then
            _install_cert "$DOMAIN"
            gum style --foreground 82 --width "$W" "✓  Certificate issued and installed. Auto-renewal cron configured."
        else
            gum style --foreground 196 --width "$W" "✗  Certificate issuance failed. Check that port 80 is reachable from the internet."
            _show_acme_log
        fi
        ;;

    "Issue / Renew — Let's Encrypt (DNS-01)")
        DOMAIN=$(gum input \
            --placeholder "e.g. proxy.example.com" \
            --value "${DOMAIN:-}" \
            --prompt "  Domain name: " \
            --width "$W")
        [ -z "$DOMAIN" ] && return

        EMAIL=$(gum input \
            --placeholder "e.g. admin@example.com" \
            --value "${CERT_EMAIL:-}" \
            --prompt "  Email for Let's Encrypt: " \
            --width "$W")
        [ -z "$EMAIL" ] && return

        echo
        gum style --faint --width "$W" "Select your DNS provider. Credentials are stored in ${DNS_CREDS}."
        echo

        PROVIDER=$(gum choose \
            --height 8 \
            "ClouDNS" \
            "Cloudflare" \
            "Route53 (AWS)" \
            "DigitalOcean" \
            "Other (custom acme.sh hook)")
        [ -z "$PROVIDER" ] && return

        touch "$DNS_CREDS"
        chmod 600 "$DNS_CREDS"

        case "$PROVIDER" in
            "ClouDNS")
                DNS_HOOK="dns_cloudns"
                AUTH_ID=$(gum input \
                    --prompt "  ClouDNS Auth ID: " \
                    --value "$(grep '^export CLOUDNS_AUTH_ID=' "$DNS_CREDS" 2>/dev/null | cut -d= -f2 | tr -d '"')" \
                    --width "$W")
                AUTH_PASS=$(gum input \
                    --prompt "  ClouDNS API Password: " \
                    --password \
                    --width "$W")
                _set_cred CLOUDNS_AUTH_ID "$AUTH_ID"
                _set_cred CLOUDNS_AUTH_PASSWORD "$AUTH_PASS"
                ;;
            "Cloudflare")
                DNS_HOOK="dns_cf"
                CF_TOKEN=$(gum input \
                    --prompt "  Cloudflare API Token: " \
                    --password \
                    --width "$W")
                _set_cred CF_Token "$CF_TOKEN"
                ;;
            "Route53 (AWS)")
                DNS_HOOK="dns_aws"
                AWS_KEY=$(gum input \
                    --prompt "  AWS Access Key ID: " \
                    --value "$(grep '^export AWS_ACCESS_KEY_ID=' "$DNS_CREDS" 2>/dev/null | cut -d= -f2 | tr -d '"')" \
                    --width "$W")
                AWS_SECRET=$(gum input \
                    --prompt "  AWS Secret Access Key: " \
                    --password \
                    --width "$W")
                _set_cred AWS_ACCESS_KEY_ID "$AWS_KEY"
                _set_cred AWS_SECRET_ACCESS_KEY "$AWS_SECRET"
                ;;
            "DigitalOcean")
                DNS_HOOK="dns_dgon"
                DO_KEY=$(gum input \
                    --prompt "  DigitalOcean API Key: " \
                    --password \
                    --width "$W")
                _set_cred DO_API_KEY "$DO_KEY"
                ;;
            "Other (custom acme.sh hook)")
                DNS_HOOK=$(gum input \
                    --prompt "  acme.sh DNS hook name (e.g. dns_gcloud): " \
                    --width "$W")
                [ -z "$DNS_HOOK" ] && return
                gum style --faint --width "$W" "Paste credential export lines (e.g. export KEY=value), one per line:"
                CUSTOM_CREDS=$(gum write --placeholder "export KEY=value" --width "$W")
                if [ -n "$CUSTOM_CREDS" ]; then
                    printf '%s\n' "$CUSTOM_CREDS" >> "$DNS_CREDS"
                fi
                ;;
        esac

        # Persist the hook name so boot scripts and Force Renew can use it
        _set_cred CERT_DNS_HOOK "$DNS_HOOK"

        gum confirm "Issue Let's Encrypt cert for ${DOMAIN} via DNS-01 (${PROVIDER})?" || return

        save_state DOMAIN "$DOMAIN"
        save_state CERT_EMAIL "$EMAIL"
        save_state CERT_METHOD "dns01"
        save_state CERT_DNS_PROVIDER "$PROVIDER"
        save_state CERT_DNS_HOOK "$DNS_HOOK"
        mkdir -p "$CERT_DIR"

        # Source credentials file — vars are now in export format so child processes inherit them
        . "$DNS_CREDS"

        : > "$ACME_LOG"
        _run_acme "Requesting certificate via DNS-01 (waiting for DNS propagation, ~2 min)..." \
            "--issue --dns \"$DNS_HOOK\" -d \"$DOMAIN\" --accountemail \"$EMAIL\" --server letsencrypt --dnssleep 120"

        if [ $? -eq 0 ]; then
            _install_cert "$DOMAIN"
            gum style --foreground 82 --width "$W" "✓  Certificate issued and installed. Auto-renewal cron configured."
        else
            gum style --foreground 196 --width "$W" "✗  Certificate issuance failed."
            _show_acme_log
        fi
        ;;

    "Generate Self-Signed Certificate")
        DOMAIN=$(gum input \
            --placeholder "e.g. proxy.example.com" \
            --value "${DOMAIN:-}" \
            --prompt "  Domain name: " \
            --width "$W")
        [ -z "$DOMAIN" ] && return

        gum confirm "Generate self-signed certificate for ${DOMAIN}? (browsers will warn — replace with a trusted cert before production)" || return

        mkdir -p "$CERT_DIR"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/key.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=${DOMAIN}" \
            -addext "subjectAltName=DNS:${DOMAIN}" 2>/dev/null
        if [ $? -ne 0 ] || [ ! -f "$CERT_DIR/fullchain.pem" ]; then
            gum style --foreground 196 --width "$W" "✗  Failed to generate certificate."
            sleep 2; return
        fi
        openssl x509 -in "$CERT_DIR/fullchain.pem" -out "$CERT_DIR/cert.pem" 2>/dev/null

        save_state DOMAIN "$DOMAIN"
        save_state CERT_METHOD "selfsigned"
        save_state CERT_DNS_HOOK ""
        apply_nginx_config
        gum style --foreground 82 --width "$W" "✓  Self-signed certificate generated. Replace with a trusted cert when ready."
        ;;

    "Install Manual Certificate")
        echo
        gum style --faint --width "$W" "Provide paths to PEM files already present on this VM."
        echo
        FULLCHAIN=$(gum input \
            --placeholder "/path/to/fullchain.pem" \
            --prompt "  Full-chain certificate path: " \
            --width "$W")
        [ -z "$FULLCHAIN" ] && return

        KEYFILE=$(gum input \
            --placeholder "/path/to/private.key" \
            --prompt "  Private key path: " \
            --width "$W")
        [ -z "$KEYFILE" ] && return

        if [ ! -f "$FULLCHAIN" ]; then
            gum style --foreground 196 --width "$W" "✗  File not found: $FULLCHAIN"
            sleep 2; return
        fi
        if [ ! -f "$KEYFILE" ]; then
            gum style --foreground 196 --width "$W" "✗  File not found: $KEYFILE"
            sleep 2; return
        fi

        gum confirm "Install certificate from ${FULLCHAIN}? Note: manual certs are not auto-renewed." || return

        mkdir -p "$CERT_DIR"
        cp "$FULLCHAIN" "$CERT_DIR/fullchain.pem"
        cp "$KEYFILE"   "$CERT_DIR/key.pem"
        openssl x509 -in "$CERT_DIR/fullchain.pem" -out "$CERT_DIR/cert.pem" 2>/dev/null

        save_state CERT_METHOD "manual"
        save_state CERT_DNS_HOOK ""
        apply_nginx_config
        gum style --foreground 82 --width "$W" "✓  Certificate installed. Remember to renew manually before expiry."
        ;;

    "Force Renew")
        if [ -z "$DOMAIN" ]; then
            gum style --foreground 196 --width "$W" "No domain configured. Issue a certificate first."
            sleep 2; return
        fi

        gum confirm "Force-renew certificate for ${DOMAIN}?" || return

        if [ "$CERT_METHOD" = "dns01" ] && [ -f "$DNS_CREDS" ]; then
            . "$DNS_CREDS"
        fi

        : > "$ACME_LOG"
        _run_acme "Force-renewing certificate for ${DOMAIN}..." \
            "--renew --force -d \"$DOMAIN\""

        if [ $? -eq 0 ]; then
            _install_cert "$DOMAIN"
            gum style --foreground 82 --width "$W" "✓  Certificate renewed."
        else
            gum style --foreground 196 --width "$W" "✗  Renewal failed."
            _show_acme_log
        fi
        ;;

    "View Certificate Details")
        if [ -f "$CERT_DIR/fullchain.pem" ]; then
            openssl x509 -text -noout -in "$CERT_DIR/fullchain.pem" | gum pager
        else
            gum style --foreground 196 --width "$W" "No certificate installed."
            sleep 2
        fi
        return
        ;;

    "View acme.sh Log")
        if [ -s "$ACME_LOG" ]; then
            gum pager < "$ACME_LOG"
        else
            gum style --foreground 214 --width "$W" "Log is empty."
            sleep 2
        fi
        return
        ;;

    *) return ;;
esac

sleep 2
