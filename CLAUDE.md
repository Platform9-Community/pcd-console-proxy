# PCD Console Proxy — Claude Code Instructions

## Common naming
- Use "PCD" instead of "OpenStack" in documentation, because this appliance is PCD-specific.
- Use "console proxy" instead of "noVNC proxy" in documentation, because this appliance is a PCD-specific console proxy that happens to use noVNC as the backend.
- favor pcdctl commands over openstack CLI commands in documentation, because pcdctl is the preferred tool for PCD users. Use openstack CLI only when pcdctl doesn't support a feature (e.g. fixed IP deployment).

## What This Is
An Alpine Linux QCOW2 appliance that sits in front of PCD's `nova-novncproxy` backend.
- nginx proxies HTTPS/WSS on port 6080 to one or more noVNC backends (ip_hash upstream)
- `pcd-auth` (Go daemon on :9000) gates all requests via nginx `auth_request` — requires valid Keystone login + session cookie
- Root's login shell is a Gum-based TUI (`tui/main.sh`) for management
- Built with Packer + QEMU from an Alpine NoCloud cloud image

## Build

```bash
make -C build          # compiles pcd-auth (CGO_ENABLED=0, static) + runs packer
make -C build clean    # removes build/output/ and generated build artifacts
```

Requires: `packer`, `qemu-system-x86_64`, KVM access, Go (`/usr/local/go/bin/go`).
Output: `build/output/pcd-console-<VERSION>.qcow2`

**Version**: bump `VERSION` file before building a new release.

## Deploy to OpenStack (PCD Staging)

```bash
source /home/jeff/pcdctl.rc          # sets OS_AUTH_URL, OS_USERNAME (jscott@platform9.com), etc.
# Auth URL: https://jscott-se-dallas.app.staging-pcd.platform9.com/keystone/v3

# Upload image — all three UEFI properties are required or the VM won't boot
pcdctl image create --insecure \
  --container-format bare --disk-format qcow2 \
  --property os_type=Linux \
  --property hw_firmware_type=uefi \
  --property hw_machine_type=q35 \
  --property os_secure_boot=disabled \
  --private \
  --file build/output/pcd-console-<VERSION>.qcow2 \
  pcd-console-<VERSION>

# Launch VM with fixed IP
pcdctl server create \
  --image pcd-console-<VERSION> \
  --flavor bfc4fa1e-bb18-4538-b204-86a44e9211cc \
  --nic net-id=afa3028a-c5c3-4107-954e-1fda94743fbd,v4-fixed-ip=10.0.0.254 \
  --key-name jscott-sshkey \
  --security-group 0d0c47ac-2938-4df6-a4af-36e27a644419 \
  --user-data /home/jeff/projects/pcd-console-proxy/cloud-init-dev.yaml \
  pcd-console-proxy
```

**Note**: there are two security groups named "any-any" — always use the ID `0d0c47ac-2938-4df6-a4af-36e27a644419`.

**Note**: `pcdctl server delete` doesn't exist; use `openstack --insecure server delete <id>`.

**Note**: before redeploying, check for orphaned ports: `openstack --insecure port list --fixed-ip ip-address=10.0.0.254` and delete any found.

## Test VM Details
| Field | Value |
|---|---|
| Name | pcd-console-proxy |
| Nova ID | changes each deploy — check via `openstack server list` |
| Network | locallan (10.0.0.0/8) |
| Fixed IP | 10.0.0.254 |
| DNS | console-proxy.pf9.zone |
| Flavor | m1.small (`bfc4fa1e-bb18-4538-b204-86a44e9211cc`) |
| Keypair | jscott-sshkey (injected by Nova into `alpine` user) |
| SSH | `ssh -i build/packer/files/packer_key alpine@10.0.0.254` (packer_key, not jscott-sshkey — private key location unknown) |
| Console access | root / `Pl@tform9!` — drops straight into TUI |
| Root SSH | disabled (`PermitRootLogin no`) |
| Hypervisor | pf9hyp01 |
| locallan net-id | `afa3028a-c5c3-4107-954e-1fda94743fbd` |
| locallan subnet-id | `7b8503ab-cc40-430f-a0b1-e46f4aeac27f` |
| Project ID | `363e868ee1404600afe2f87ecf9284dc` |
| Security group ID | `0d0c47ac-2938-4df6-a4af-36e27a644419` |

## PCD URL Scheme
```
https://<infra>-<region>.app.staging-pcd.platform9.com/
```
- **infra** = deployment identifier (e.g. `jscott-se`)
- **region** = infra region name (e.g. `dallas`)
- **fq-region** = `<infra>-<region>` (e.g. `jscott-se-dallas`)

Dev environment: fq-region = `jscott-se-dallas`, region = `dallas`

## SSH During Packer Build
Packer uses `build/packer/files/packer_key` (ed25519) for the `alpine` user during provisioning. This key is NOT in deployed images — Nova injects `jscott-sshkey` at deploy time. The packer_key remains in `alpine`'s authorized_keys and can be used to SSH into deployed VMs.

## Architecture

```
Browser → nginx:6080 (HTTPS/WSS)
               │
               ├─ auth_request → pcd-auth:9000 /auth_verify
               │     no cookie → set pcd-next cookie → 302 /login
               │     POST /login → Keystone validate → set pcd-session cookie
               │     valid cookie → 200 → continue
               │
               └─ proxy_pass https://novnc_backend (upstream ip_hash)
                     server 10.x.x.x:6080;
                     server 10.x.x.y:6080;
```

**pcd-auth** (`auth/`): Go static binary, session TTL 480 min (configurable via `SESSION_TTL_MINUTES` in state.conf), in-memory sync.Map session store. Validates against `OS_AUTH_URL` from state.conf.

**nginx** pid: `/run/nginx/nginx.pid` — the `/run/nginx/` directory must exist (OpenRC init script requires it; nginx.conf and provision.sh must agree).

## State File
`/etc/pcd-proxy/state.conf` — sourced as shell env by TUI scripts:
```
OS_AUTH_URL=""
ALLOWED_PROJECTS=""       # comma-separated project names; empty = any valid project
SESSION_TTL_MINUTES="480"
DOMAIN=""
BACKEND_IPS=""            # space-separated ip:port pairs e.g. "10.0.0.11:6080 10.0.0.12:6080"
CERT_METHOD=""            # http01 | dns01 | manual
CERT_DNS_PROVIDER=""      # display name (ClouDNS, Cloudflare, etc.)
CERT_DNS_HOOK=""          # acme.sh hook name (dns_cloudns, dns_cf, etc.)
CERT_EMAIL=""
ETH0_IP=""                # set dynamically by network.sh
ETH0_PREFIX=""
ETH0_GW=""
ETH0_MODE=""              # dhcp | static
```

## Cloud-Init Injection
Pre-configure the proxy at deploy time via Nova user-data. See `docs/cloud-init-sample.yaml` for the full template. Key files injectable via `write_files`:

| File | Purpose |
|---|---|
| `/etc/pcd-proxy/cloud-init.conf` | Subset of state.conf values merged on boot by `05-merge-cloud-init.start` |
| `/etc/pcd-proxy/app-credential.env` | OpenStack app credential for backend auto-discovery |
| `/etc/pcd-proxy/dns-credentials.conf` | DNS provider credentials for DNS-01 cert (exported env var format) |

**Dev example**: `cloud-init-dev.yaml` (gitignored — fill in app credential ID/secret before use).

### Creating an Application Credential

```bash
source /home/jeff/pcdctl.rc
openstack --insecure application credential create pcd-proxy-discover \
  --role admin \
  --description "noVNC backend auto-discovery for pcd-console-proxy"
# Copy the printed id and secret into cloud-init-dev.yaml
```

The credential needs admin (or compute-admin) role to call `GET /os-services?binary=nova-novncproxy`.

## Boot Sequence (local.d scripts)
| Script | Runs when | Purpose |
|---|---|---|
| `05-merge-cloud-init.start` | `cloud-init.conf` is non-empty | Merges cloud-init config into state.conf |
| `20-discover-backends.start` | `app-credential.env` is non-empty | Auto-discovers nova-novncproxy backends |
| `30-letsencrypt-init.start` | DOMAIN + CERT_EMAIL + CERT_METHOD set, no cert yet | Issues Let's Encrypt cert on first boot |

## Key Files
| Path | Purpose |
|---|---|
| `build/packer/scripts/provision.sh` | Main image provisioning |
| `build/packer/scripts/cleanup.sh` | Wipes SSH host keys + free space |
| `build/packer/alpine.pkr.hcl` | Packer template (QEMU builder) |
| `tui/main.sh` | Root login shell → TUI main menu (shows per-NIC IPs) |
| `tui/common.sh` | `load_state`, `save_state`, `apply_nginx_config` |
| `tui/network.sh` | Dynamic NIC enumeration, DHCP/static config, auto-detects Nova-injected IPs |
| `tui/backend.sh` | Multi-backend list manager (Add/Remove/Refresh from PCD) |
| `tui/discover-backends.sh` | Auto-discover nova-novncproxy hosts via app credential |
| `tui/tls.sh` | Let's Encrypt (HTTP-01, DNS-01) + manual cert; acme.sh logs to `/var/log/pcd-acme.log` |
| `auth/` | Go pcd-auth daemon source |
| `config/nginx.conf.tmpl` | nginx template; `@@UPSTREAM_SERVERS@@` expanded by `apply_nginx_config` |
| `docs/cloud-init-sample.yaml` | Client-facing deployment user-data template |
| `cloud-init-dev.yaml` | Dev/staging user-data (gitignored — fill in credentials) |

## Known Gotchas

**gum**: `--width` only works on `gum style`, NOT `gum choose`. Using it on `gum choose` causes immediate exit with usage text, making the TUI flash endlessly with no menu.

**Alpine musl libc**: Go binaries must be built with `CGO_ENABLED=0` or they'll fail with `/lib64/ld-linux-x86-64.so.2 not found`.

**cloud-init datasource**: Base Alpine NoCloud image restricts to `["NoCloud"]`. Override in `cloud.cfg.d/99-packer.cfg` with `['OpenStack', 'ConfigDrive', 'Ec2', 'None']` so Nova injects the keypair.

**SSH TERM forwarding**: Alpine sshd doesn't forward TERM by default. Add `AcceptEnv TERM COLORTERM LINES COLUMNS` to `sshd_config`; also set `export TERM="${TERM:-xterm-256color}"` in main.sh as fallback.

**nginx pid directory**: OpenRC init script expects `/run/nginx/nginx.pid`. The subdirectory `/run/nginx/` must be created at boot (nginx doesn't create it). Ensure nginx.conf and provision.sh both use this path.

**OpenRC commands in TUI**: Alpine uses `doas`, not `sudo`. Packer execute_command: `doas sh -c '{{.Vars}} {{.Path}}'`.

**openstack CLI timeouts**: Write operations (server create, port create) can exceed 2-minute tool timeout. Use the Nova REST API directly with a token for fixed-IP deployments.

**DNS credentials must be exported**: acme.sh DNS hooks need vars in the environment. `dns-credentials.conf` uses `export KEY="value"` format so `. dns-credentials.conf` exports them to child processes. The `_set_cred()` function in tls.sh writes this format automatically.

## Backend Auto-Discovery
If `/etc/pcd-proxy/app-credential.env` is non-empty at boot, `20-discover-backends.start` runs `discover-backends.sh` which:
1. Authenticates to Keystone with application credential
2. Finds Nova compute endpoint (`type=compute`, `interface=$OS_INTERFACE`)
3. Queries `GET /os-services?binary=nova-novncproxy` for hosts
4. TCP health-checks each host on port 6080
5. Writes reachable hosts to `BACKEND_IPS` and reloads nginx

## Authentication Security Model
Browser session requires valid Keystone credentials (username/password/project). This prevents unauthenticated console access even if someone obtains the console URL. After login, a signed session cookie (8hr TTL by default) avoids re-prompting. There is no per-instance authorization — the Nova console token is the instance-level credential. `/logout` clears the session server-side.
