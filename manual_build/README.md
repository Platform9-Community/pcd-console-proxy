# pcd-console-proxy — Manual Deployment

This folder contains the files needed to manually deploy a pcd-console-proxy test VM in OpenStack using a pre-built Alpine Linux cloud-init image from Glance. It is intended for testing and validation of the proxy configuration.

## Files

- `cloud-init.sample` — cloud-init user-data; edit all placeholders before deploying
- `test_image.rc` — reference spec for the VM (name, IP, flavor, keypair, etc.)

---

## Before You Deploy

Edit `cloud-init.sample` and replace every placeholder:

| Placeholder | What to set |
|---|---|
| `YourSecurePasswordHere` | Root password for the VM |
| `REPLACE_WITH_AUTH_ID` | ClouDNS account/sub-user ID |
| `REPLACE_WITH_API_PASSWORD` | ClouDNS API password |
| `REPLACE_WITH_DOMAIN` | Public DNS name for this proxy (e.g. `console-proxy.example.com`) |
| `REPLACE_WITH_EMAIL` | Email for Let's Encrypt registration |
| `10.0.0.11` | IP of the noVNC backend this proxy will forward to |

---

## Alpine Linux Image Requirements

You must use a **UEFI cloudinit** image. BIOS-layout images fail Nova's disk safety check (`SafetyCheckFailed: mbr`) and will not boot.

- Tested image: `alpine-3.24.1-x86_64-uefi-cloudinit-r0`
- Download from: https://alpinelinux.org/cloud/

The following Glance properties **must** be set at upload time:

```
hw_firmware_type = uefi
hw_machine_type  = q35
```

---

## pcdctl Commands

### 1. Authenticate

```bash
source <path-to-your-openstack-rc-file>
```

### 2. Upload the image

```bash
pcdctl image create \
  --insecure \
  --container-format bare \
  --disk-format qcow2 \
  --property os_type=Linux \
  --property hw_firmware_type=uefi \
  --property hw_machine_type=q35 \
  --public \
  --file <path-to-alpine-3.24.1-x86_64-uefi-cloudinit-r0.qcow2> \
  alpine-3.24.1-x86_64-uefi-cloudinit-r0
```

### 3. Deploy the VM

```bash
pcdctl server create \
  --image alpine-3.24.1-x86_64-uefi-cloudinit-r0 \
  --flavor m1.small \
  --network <public-network> \
  --network <console-network> \
  --key-name <keypair-name> \
  --security-group <security-group> \
  --user-data cloud-init.sample \
  --property tenant=<tenant-name> \
  pcd-console-proxy
```

---

## What cloud-init Configures on First Boot

1. Installs `nginx`, `openssh`, `openssl`, `curl`
2. Issues a Let's Encrypt certificate via `acme.sh` using ClouDNS DNS-01 challenge (no public IP required)
3. Configures nginx to terminate SSL on port `6080` and proxy WebSocket traffic to the noVNC backend over HTTPS
4. Enables root SSH login with password

Cloud-init runs at first boot and takes 2–3 minutes. Watch progress via the OpenStack console.

---

## Verification

```bash
# SSH access (key-based)
ssh alpine@<vm-ip>

# Confirm proxy is serving a valid cert
curl -sv https://<ACME_DOMAIN>:6080/ 2>&1 | grep -E "issuer|subject|HTTP"
```

Expected responses:
- `HTTP 200` or `HTTP 404` — proxy is working, passthrough from noVNC backend
- `HTTP 502` — proxy is up but cannot reach the noVNC backend (check `proxy_pass` IP)
- `SSL handshake failure` — cert not yet issued; check cloud-init logs via `doas cat /var/log/cloud-init-output.log`
