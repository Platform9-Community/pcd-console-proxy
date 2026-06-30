# PCD Console Proxy

An Alpine Linux appliance that adds Keystone authentication in front of PCD's VM console backend. Users log in with their existing PCD credentials before gaining WebSocket console access — no unauthenticated console URLs, no per-instance ACL configuration required.

```
Browser → nginx:6080 (HTTPS/WSS)
               │
               ├─ auth_request → pcd-auth:9000
               │     no session  → redirect to /login (Keystone)
               │     valid session → continue
               │
               └─ proxy_pass → nova-novncproxy:6080
```

## Download

Grab the latest QCOW2 from the [Releases](https://github.com/Platform9-Community/pcd-console-proxy/releases) page.

## Quick Start

Full deployment walkthrough: **[docs/getting-started.md](docs/getting-started.md)**

### 1. Upload the image

```bash
pcdctl image create --insecure \
  --container-format bare --disk-format qcow2 \
  --property os_type=Linux \
  --property hw_firmware_type=uefi \
  --property hw_machine_type=q35 \
  --property os_secure_boot=disabled \
  --private \
  --file pcd-console-<VERSION>.qcow2 \
  pcd-console-<VERSION>
```

### 2. Prepare cloud-init user data

Minimum configuration — everything else can be set via the TUI after first boot:

```yaml
#cloud-config
write_files:
  - path: /etc/pcd-proxy/cloud-init.conf
    permissions: '0600'
    content: |
      OS_AUTH_URL="https://<fq-region>.app.staging-pcd.platform9.com/keystone/v3"
      DOMAIN="console.example.com"
```

See [docs/cloud-init-sample.yaml](docs/cloud-init-sample.yaml) for the full template.

### 3. Deploy the VM

```bash
pcdctl server create \
  --image pcd-console-<VERSION> \
  --flavor <flavor-id> \
  --nic net-id=<network-id>,v4-fixed-ip=<ip-address> \
  --key-name <keypair-name> \
  --security-group <security-group-id> \
  --user-data user-data.yaml \
  pcd-console-proxy
```

Security group must allow **TCP 6080 inbound** (users) and **TCP 6080 + 443 outbound** (backends + Keystone).

### 4. First boot

The proxy automatically generates a self-signed TLS cert for the configured domain. Boot completes in ~60–90 seconds.

### 5. Log in to the management TUI

Access via the PCD console tab:

```
User:     root
Password: Pl@tform9!
```

Change the root password immediately using the **Change Root Password** option in the main menu.

### 6. Add a backend

Select **Backend Target** → **Add Backend** and enter your nova-novncproxy IP and port (`6080`). A yellow warning on the main menu indicates no backend is configured yet.

### 7. (Optional) Replace the self-signed cert

Select **TLS / Certificate** in the TUI. Options: Let's Encrypt HTTP-01, DNS-01, or manual install.

## Security

- Sessions require valid Keystone credentials; unauthenticated requests are blocked at the proxy
- Session cookies are `HttpOnly` and `Secure`; sessions are in-memory only (cleared on restart)
- Root SSH is disabled; management is console or SSH via the `alpine` user
- SSH host keys are wiped at build time and regenerated uniquely on each first boot

## Contributing / Building

See [CONTRIBUTING.md](CONTRIBUTING.md).
