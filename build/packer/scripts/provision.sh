#!/bin/sh
set -ex

# --- Package installation ---

ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release)

# Enable community repo (needed for gum)
if ! grep -q "^http.*community" /etc/apk/repositories; then
    echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories
fi

apk update
apk add --no-cache \
    nginx \
    gum \
    openssl \
    curl \
    envsubst \
    jq

# --- acme.sh (Let's Encrypt client) ---
# Full install (not single-script) so DNS hook scripts are present in ~/.acme.sh/dnsapi/
curl -fsSL https://get.acme.sh -o /tmp/install-acme.sh && sh /tmp/install-acme.sh
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

# --- pcd-auth daemon ---
install -m 755 /tmp/packer-files/pcd-auth    /usr/local/bin/pcd-auth
install -m 755 /tmp/packer-files/pcd-auth.initd /etc/init.d/pcd-auth

# --- TUI scripts ---
mkdir -p /usr/local/lib/pcd-proxy
install -m 755 /tmp/tui/*.sh /usr/local/lib/pcd-proxy/

# --- Config templates ---
mkdir -p /etc/pcd-proxy/certs
install -m 644 /tmp/config/nginx.conf.tmpl /etc/pcd-proxy/nginx.conf.tmpl

# --- Root console access ---
echo "root:Pl@tform9!" | chpasswd

# --- Version ---
echo "${PCD_VERSION:-dev}" > /etc/pcd-proxy/version

# --- Initial state ---
cat > /etc/pcd-proxy/state.conf << 'EOF'
# PCD Console Proxy — runtime configuration
# Edit values via the TUI (login shell) after first boot.
OS_AUTH_URL=""
ALLOWED_PROJECTS=""
SESSION_TTL_MINUTES="480"
DOMAIN=""
BACKEND_IPS=""
CERT_METHOD=""
CERT_DNS_PROVIDER=""
CERT_DNS_HOOK=""
CERT_EMAIL=""
AUTO_LOGOUT_MINUTES="15"
EOF

# Empty DNS credentials file (populated via TUI)
touch /etc/pcd-proxy/dns-credentials.conf
chmod 600 /etc/pcd-proxy/dns-credentials.conf

# Empty app credential file — injected via cloud-init user-data at deploy time
touch /etc/pcd-proxy/app-credential.env
chmod 600 /etc/pcd-proxy/app-credential.env

# Empty cloud-init config overlay — inject state.conf values at deploy time
touch /etc/pcd-proxy/cloud-init.conf
chmod 600 /etc/pcd-proxy/cloud-init.conf

mkdir -p /var/www/acme /var/log/nginx

# --- nginx placeholder config (replaced by TUI once configured) ---
cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events { worker_connections 512; }

http {
    server {
        listen 80 default_server;
        return 503 "PCD Console Proxy not configured — log in via console and run the TUI setup.\n";
    }
}
EOF

# --- Cloud-init datasource for OpenStack deployment ---
# The base nocloud image restricts cloud-init to NoCloud only; update so
# that Nova's config drive / metadata API injects the operator's SSH key
# into the alpine user on first boot in OpenStack.
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-packer.cfg << 'CLOUDCFG'
datasource_list: ['OpenStack', 'ConfigDrive', 'Ec2', 'None']
CLOUDCFG

# --- sshd: forward TERM so gum/Bubble Tea works over SSH ---
# Alpine sshd does not forward any env vars by default; without TERM,
# gum choose (Bubble Tea) cannot initialize the terminal and exits immediately.
echo 'AcceptEnv TERM COLORTERM LINES COLUMNS' >> /etc/ssh/sshd_config
echo 'PermitRootLogin no' >> /etc/ssh/sshd_config

# --- Boot-time cloud-init config merge (runs before discovery) ---
cat > /etc/local.d/05-merge-cloud-init.start << 'SCRIPT'
#!/bin/sh
# Merge /etc/pcd-proxy/cloud-init.conf into state.conf on first boot.
# Operators inject this file via cloud-init user-data write_files.
CLOUD="/etc/pcd-proxy/cloud-init.conf"
STATE="/etc/pcd-proxy/state.conf"
[ -s "$CLOUD" ] || exit 0
. "$CLOUD"
for KEY in OS_AUTH_URL ALLOWED_PROJECTS SESSION_TTL_MINUTES DOMAIN BACKEND_IPS \
           CERT_METHOD CERT_DNS_PROVIDER CERT_DNS_HOOK CERT_EMAIL; do
    eval "VAL=\${$KEY:-}"
    [ -n "$VAL" ] || continue
    if grep -q "^${KEY}=" "$STATE" 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=\"${VAL}\"|" "$STATE"
    else
        printf '%s="%s"\n' "$KEY" "$VAL" >> "$STATE"
    fi
done
SCRIPT
chmod +x /etc/local.d/05-merge-cloud-init.start

# --- Boot-time cert auto-provisioning (runs after merge + discovery) ---
# Generates a self-signed cert by default; issues Let's Encrypt if CERT_METHOD
# is explicitly set to http01 or dns01. Requires only DOMAIN to be set.
cat > /etc/local.d/30-cert-init.start << 'SCRIPT'
#!/bin/sh
. /usr/local/lib/pcd-proxy/common.sh
load_state
CERT_DIR="/etc/pcd-proxy/certs"
ACME_LOG="/var/log/pcd-acme.log"
[ -n "$DOMAIN" ] || exit 0
[ -f "$CERT_DIR/fullchain.pem" ] && exit 0

mkdir -p "$CERT_DIR"

case "${CERT_METHOD:-selfsigned}" in
    selfsigned|"")
        logger -t pcd-tls "Generating self-signed cert for $DOMAIN"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/key.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName=DNS:$DOMAIN" >> /var/log/pcd-cert.log 2>&1
        openssl x509 -in "$CERT_DIR/fullchain.pem" -out "$CERT_DIR/cert.pem" 2>/dev/null
        save_state CERT_METHOD "selfsigned"
        apply_nginx_config
        logger -t pcd-tls "Self-signed cert installed for $DOMAIN"
        ;;
    http01)
        [ -n "$CERT_EMAIL" ] || { logger -t pcd-tls "CERT_EMAIL not set for http01"; exit 1; }
        logger -t pcd-tls "Requesting LE cert for $DOMAIN via HTTP-01"
        mkdir -p /var/www/acme
        apply_nginx_config
        /usr/local/bin/acme.sh --issue -d "$DOMAIN" --webroot /var/www/acme \
            --accountemail "$CERT_EMAIL" --server letsencrypt >"$ACME_LOG" 2>&1
        if [ $? -eq 0 ]; then
            /usr/local/bin/acme.sh --install-cert -d "$DOMAIN" \
                --cert-file      "$CERT_DIR/cert.pem" \
                --key-file       "$CERT_DIR/key.pem" \
                --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd      "rc-service nginx reload" >>"$ACME_LOG" 2>&1
            /usr/local/bin/acme.sh --install-cronjob
            apply_nginx_config
            logger -t pcd-tls "LE cert issued and installed for $DOMAIN"
        else
            logger -t pcd-tls "LE cert issuance failed for $DOMAIN — see $ACME_LOG"
        fi
        ;;
    dns01)
        [ -n "$CERT_EMAIL" ] || { logger -t pcd-tls "CERT_EMAIL not set for dns01"; exit 1; }
        DNS_CREDS="/etc/pcd-proxy/dns-credentials.conf"
        [ -s "$DNS_CREDS" ] || { logger -t pcd-tls "DNS creds missing"; exit 1; }
        . "$DNS_CREDS"
        [ -n "$CERT_DNS_HOOK" ] || { logger -t pcd-tls "CERT_DNS_HOOK not set"; exit 1; }
        logger -t pcd-tls "Requesting LE cert for $DOMAIN via DNS-01 ($CERT_DNS_HOOK)"
        /usr/local/bin/acme.sh --issue --dns "$CERT_DNS_HOOK" -d "$DOMAIN" \
            --accountemail "$CERT_EMAIL" --server letsencrypt --dnssleep 120 >"$ACME_LOG" 2>&1
        if [ $? -eq 0 ]; then
            /usr/local/bin/acme.sh --install-cert -d "$DOMAIN" \
                --cert-file      "$CERT_DIR/cert.pem" \
                --key-file       "$CERT_DIR/key.pem" \
                --fullchain-file "$CERT_DIR/fullchain.pem" \
                --reloadcmd      "rc-service nginx reload" >>"$ACME_LOG" 2>&1
            /usr/local/bin/acme.sh --install-cronjob
            apply_nginx_config
            logger -t pcd-tls "LE cert issued and installed for $DOMAIN"
        else
            logger -t pcd-tls "LE cert issuance failed for $DOMAIN — see $ACME_LOG"
        fi
        ;;
    *) exit 0 ;;
esac
SCRIPT
chmod +x /etc/local.d/30-cert-init.start

# --- Boot-time backend auto-discovery ---
cat > /etc/local.d/20-discover-backends.start << 'SCRIPT'
#!/bin/sh
if [ -s /etc/pcd-proxy/app-credential.env ]; then
    /usr/local/lib/pcd-proxy/discover-backends.sh
fi
SCRIPT
chmod +x /etc/local.d/20-discover-backends.start

# --- SSH host key regeneration on first boot ---
# Keys are wiped by cleanup.sh; this script recreates them.
mkdir -p /etc/local.d
cat > /etc/local.d/10-sshd-keygen.start << 'SCRIPT'
#!/bin/sh
if ! [ -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A
    rc-service sshd restart 2>/dev/null || true
fi
SCRIPT
chmod +x /etc/local.d/10-sshd-keygen.start

# --- Enable services ---
rc-update add nginx    default
rc-update add pcd-auth default
rc-update add local    default

# --- Set TUI as root's login shell ---
echo "/usr/local/lib/pcd-proxy/main.sh" >> /etc/shells
# Match the last colon-delimited field regardless of current shell name (/bin/ash or /bin/sh)
sed -i 's|^\(root:.*:\)[^:]*$|\1/usr/local/lib/pcd-proxy/main.sh|' /etc/passwd
# Verify the change took effect
grep "^root:" /etc/passwd

echo "Provisioning complete."
