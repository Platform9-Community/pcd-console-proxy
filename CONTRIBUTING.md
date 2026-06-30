# Building & Contributing

## Build Requirements

| Tool | Version |
|------|---------|
| Go | 1.21+ |
| Packer | 1.10+ |
| QEMU/KVM | any recent (`qemu-system-x86_64`, `kvm`) |

All three must be in `$PATH`. KVM acceleration requires hardware virtualization enabled in BIOS/UEFI.

## Building

```bash
make -C build
```

This compiles the `pcd-auth` Go daemon (static binary, CGO_ENABLED=0), then runs Packer to produce a QCOW2 image. Output: `build/output/pcd-console-<VERSION>.qcow2`

On first build, download the Alpine base image first:

```bash
make -C build download-base
```

To rebuild from scratch:

```bash
make -C build clean && make -C build
```

Build time is approximately 8–10 minutes.

### Makefile targets

| Target | Description |
|--------|-------------|
| `make -C build` | Full build (auth binary + QCOW2 image) |
| `make -C build auth-build` | Compile `pcd-auth` only |
| `make -C build packer-build` | Build QCOW2 only (auth binary must already exist) |
| `make -C build download-base` | Download the Alpine base cloud image |
| `make -C build init` | Install Packer plugins |
| `make -C build clean` | Remove build artifacts |

## Code Structure

```
auth/               pcd-auth Go daemon (Keystone auth + session management)
build/
  Makefile          Build entrypoint — run as: make -C build
  packer/
    alpine.pkr.hcl  Packer template (QEMU builder)
    scripts/
      provision.sh  Main image provisioning
      cleanup.sh    Wipes SSH host keys + free space before image export
    files/          Generated build artifacts (gitignored)
config/
  nginx.conf.tmpl   nginx config template; @@UPSTREAM_SERVERS@@ expanded at runtime
docs/
  getting-started.md  Operator deployment guide
  cloud-init-sample.yaml  Full cloud-init user-data template
tui/                Shell scripts that form the root login TUI
  main.sh           Main menu (root login shell)
  common.sh         Shared: load_state, save_state, apply_nginx_config
  network.sh        NIC configuration
  backend.sh        Backend list management
  tls.sh            TLS / Let's Encrypt / manual cert
  auth.sh           Keystone URL + project allowlist
  service.sh        Start/stop/restart services
  logs.sh           Log viewer
  discover-backends.sh  Auto-discovery via application credential
VERSION             Current version string — bump before each release
```

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

**pcd-auth** is a static Go binary that validates Keystone credentials, issues a signed session cookie, and responds to nginx `auth_request` subrequests. Session TTL is configurable (default 480 minutes). Sessions are stored in an in-memory `sync.Map` — a daemon restart clears all sessions.

**nginx** proxies HTTPS and WSS on port 6080. The `pcd-next` cookie preserves the original console URL across the login redirect so users land on the right console after authentication.

**TUI** scripts run as root's login shell. They source `/etc/pcd-proxy/state.conf` for runtime config and write changes back via `save_state`. `apply_nginx_config` expands the nginx template and reloads nginx.

## Boot Sequence

| Script | Trigger | Purpose |
|--------|---------|---------|
| `05-merge-cloud-init.start` | `cloud-init.conf` non-empty | Merges cloud-init values into state.conf |
| `10-sshd-keygen.start` | SSH host keys absent | Regenerates unique SSH host keys |
| `20-discover-backends.start` | `app-credential.env` non-empty | Auto-discovers nova-novncproxy backends |
| `30-cert-init.start` | DOMAIN set, no cert yet | Issues self-signed or Let's Encrypt cert |

## Releasing

1. Bump the `VERSION` file
2. Run `make -C build`
3. Commit and tag: `git tag v<VERSION> && git push origin v<VERSION>`
4. Create a GitHub release and attach `build/output/pcd-console-<VERSION>.qcow2` as an asset
