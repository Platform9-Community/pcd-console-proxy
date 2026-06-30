# PCD Console Proxy

A self-contained Alpine Linux VM appliance that provides authenticated, multi-tenant noVNC console access via a dual-homed HTTPS reverse proxy. Users authenticate with OpenStack Keystone credentials; per-project scoping prevents cross-tenant access without any additional ACL configuration.

## Architecture

```
[ Users / Browsers ]
        │  HTTPS 6080
        ▼
┌───────────────────────────────────────┐
│           Alpine Proxy VM             │
│                                       │
│  eth0: public IP  (6080 only)       │
│  ┌─────────────────────────────────┐  │
│  │  nginx  ──── auth_request ──►   │  │
│  │                pcd-auth :9000   │  │
│  │                    │            │  │
│  │             Keystone v3 API     │  │
│  └─────────────────────────────────┘  │
│  eth1: private IP  (unrestricted)     │
└───────────────────────────────────────┘
        │  ws:// port 6080
        ▼
[ nova-novncproxy / Websockify ]
```

**Authentication flow:** nginx intercepts every request with `auth_request /auth_verify`. The `pcd-auth` daemon validates the session cookie; unauthenticated requests are redirected to `/login`, which collects username, password, and project name, then performs a Keystone v3 project-scoped token request. Only users who are members of the requested project can authenticate. A configurable project allowlist provides an additional restriction layer.

## Build Requirements

| Tool | Version |
|------|---------|
| Go | 1.21+ |
| Packer | 1.10+ |
| QEMU/KVM | any recent (`qemu-system-x86_64`, `kvm`) |

All three must be in `$PATH`. KVM acceleration requires hardware virtualization enabled in BIOS/UEFI.

Install Packer QEMU plugin before the first build:

```sh
packer init build/packer/
```

Or just run `make build` — the `init` step runs automatically.

## Building

```sh
make build
```

This:
1. Cross-compiles the `pcd-auth` Go daemon for Linux/amd64
2. Generates a throw-away SSH keypair for Packer provisioning
3. Downloads the Alpine Linux 3.21 virt ISO (cached by Packer)
4. Boots a QEMU VM, runs unattended `setup-alpine`, provisions all software
5. Outputs `build/output/pcd-console.qcow2` (~80 MB compressed)

Build time is approximately 8–10 minutes on a typical workstation.

To rebuild from scratch:

```sh
make clean && make build
```

### Makefile targets

| Target | Description |
|--------|-------------|
| `make build` | Full build (auth binary + QCOW2 image) |
| `make auth-build` | Compile `pcd-auth` only |
| `make packer-build` | Build QCOW2 only (auth binary must already exist) |
| `make init` | Install Packer plugins |
| `make clean` | Remove build artifacts |

## Deployment

### Upload to OpenStack

```sh
openstack image create \
  --disk-format qcow2 \
  --container-format bare \
  --file build/output/pcd-console.qcow2 \
  --min-disk 2 \
  --min-ram 512 \
  --property hw_disk_bus=virtio \
  --property hw_vif_model=virtio \
  pcd-console-proxy
```

### Create the instance

The appliance requires exactly **two NICs**:

- **eth0** — public-facing network (receives user HTTPS traffic)
- **eth1** — private/management network (connects to nova-novncproxy)

```sh
openstack server create \
  --image pcd-console-proxy \
  --flavor m1.small \
  --nic net-id=<PUBLIC_NETWORK_ID> \
  --nic net-id=<PRIVATE_NETWORK_ID> \
  --security-group <sec-group-allowing-80-443> \
  pcd-console-proxy-01
```

Security group on eth0 must allow TCP 80, 443, and 6080 inbound. Access to all other ports is controlled via OpenStack security groups — there is no SSH exposure on the public interface by design.

### Assign a floating IP

```sh
openstack floating ip create <PUBLIC_NETWORK>
openstack server add floating ip pcd-console-proxy-01 <FLOATING_IP>
```

Point your DNS record for the proxy domain at this floating IP.

## First-Boot Setup

Access the VM via the OpenStack console (Horizon → "Console" tab, or `openstack console url show`).

Log in as `root` with the initial password: **`packer123`**

The login shell is replaced by the PCD management TUI. You will be dropped directly into the main menu.

**Change the root password immediately:**

From the TUI, select **Emergency Shell**, then:

```sh
passwd
exit
```

### TUI Configuration

Work through each menu item in order:

#### 1. Network Configuration

Configure eth0 (public) and eth1 (private) static IPs. DHCP is used during build; the appliance expects static IPs in production.

- **eth0 IP / prefix / gateway** — public-facing interface
- **eth1 IP / prefix** — private interface (no gateway needed)

#### 2. Backend Target

The noVNC backend that this proxy will forward traffic to.

- **Backend IP** — IP address of your nova-novncproxy service on the private network
- **Backend Port** — default `6080`

This regenerates the nginx config and reloads nginx.

#### 3. Authentication (Keystone)

- **Keystone Auth URL** — e.g. `https://keystone.example.com:5000`
- **Allowed Projects** — comma-separated project names or IDs. Leave blank to allow any valid Keystone project.
- **Session TTL** — how long login sessions last in minutes (default: 10)

This restarts the `pcd-auth` daemon with the new configuration.

#### 4. TLS / Certificate

- **Domain** — the public hostname users will browse to (e.g. `console.example.com`)
- **Email** — used for Let's Encrypt account registration and expiry notifications

Three certificate methods are available:

| Method | Use when |
|--------|----------|
| **Let's Encrypt (HTTP-01)** | The appliance has a public IP reachable on port 80 from the internet |
| **Let's Encrypt (DNS-01)** | The appliance is on a private network; DNS provider API credentials required. Supported providers: ClouDNS, Cloudflare, Route53, DigitalOcean, or any custom acme.sh hook |
| **Manual install** | You already have a certificate; provide paths to the fullchain and key PEM files on the VM |

HTTP-01 and DNS-01 certs are auto-renewed via a cron job. Manual certs display an expiry warning when within 30 days of expiry.

#### 5. Service Management

Start, stop, restart, or check the status of `nginx` and `pcd-auth`.

#### 6. View Logs

Tail nginx access, nginx error, or auth daemon logs from within the TUI.

## Runtime User Access

Once configured, users:

1. Browse to `https://<DOMAIN>/`
2. Are redirected to the login page
3. Enter their OpenStack **username**, **password**, and **project name**
4. On successful Keystone authentication, receive a session cookie valid for the configured TTL
5. Are proxied to the noVNC stream via WebSocket

Cross-tenant access is blocked at two layers:

- **Keystone scoped auth:** Keystone rejects a project-scoped token request if the user is not a member of that project.
- **nova-novncproxy:** Console tokens are issued per-project by Nova; a token for a VM in Project A cannot be used from a session scoped to Project B.

## Configuration Reference

Runtime configuration is stored in `/etc/pcd-proxy/state.conf`:

| Key | Description | Default |
|-----|-------------|---------|
| `OS_AUTH_URL` | Keystone v3 endpoint | _(required)_ |
| `ALLOWED_PROJECTS` | Comma-separated project allowlist | _(empty = any valid project)_ |
| `SESSION_TTL_MINUTES` | Session cookie lifetime | `10` |
| `DOMAIN` | Public hostname for TLS cert | _(required)_ |
| `BACKEND_IP` | nova-novncproxy IP on private network | _(required)_ |
| `BACKEND_PORT` | nova-novncproxy port | `6080` |
| `CERT_METHOD` | Certificate method: `http01`, `dns01`, or `manual` | _(set by TUI)_ |
| `CERT_DNS_PROVIDER` | DNS provider name (dns01 only) | _(set by TUI)_ |
| `CERT_EMAIL` | Email for Let's Encrypt registration | _(set by TUI)_ |

All values are set through the TUI; direct file editing is also supported.

## Security Notes

- **SSH is disabled by design.** There is no SSH exposure on the public interface. Port access is controlled via OpenStack security groups. Console-only management is intentional.
- **DNS credentials** for Let's Encrypt DNS-01 are stored in `/etc/pcd-proxy/dns-credentials.conf` (mode 0600, root-only).
- **Session cookies are `HttpOnly` and `Secure`.** Sessions are stored in memory only; a daemon restart clears all sessions.
- **Change the default password** (`packer123`) immediately on first boot.
- **SSH host keys** are wiped during image build and regenerated on first boot, ensuring each deployed instance has unique keys.

## Troubleshooting

**Proxy returns 503 on port 80:**
The nginx config has not been generated yet. Complete the Backend Target and TLS steps in the TUI.

**Login fails with "Invalid credentials":**
Verify the Keystone Auth URL is reachable from the appliance (check eth1 routing). Test with `curl -v <OS_AUTH_URL>/v3` from the Emergency Shell.

**Login fails with "Not a member of that project":**
The user is not assigned to that project in Keystone. Check project membership in Horizon or via `openstack role assignment list`.

**Certificate issuance fails:**
Ensure the domain resolves to the appliance's eth0 IP and that outbound HTTPS (port 443) is reachable from the appliance. Let's Encrypt must be able to reach `http://<DOMAIN>/.well-known/acme-challenge/`.

**TUI is unresponsive:**
From the OpenStack console, send Ctrl-C to return to the main menu, or select **Emergency Shell** to access a raw shell.
