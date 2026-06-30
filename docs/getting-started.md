# Getting Started with PCD Console Proxy

PCD Console Proxy is an Virtual Linux appliance that sits in front of your PCD environment's VM console backend. It authenticates users against Keystone before proxying WebSocket console traffic, adding an additional layer of security and control to console access.

---

## Prerequisites

- Access to a PCD environment with image upload permissions
- The `pcdctl` CLI configured for your environment (`source <pcdctl.rc>`)
- A network where the proxy VM can reach your nova-novncproxy backend on port 6080
- A DNS name for the proxy (e.g. `console.example.com`) — required for TLS

---

## Step 1: Upload the Image

The image requires three UEFI properties to boot correctly. All three must be present.

```bash
pcdctl image create --insecure \
  --container-format bare \
  --disk-format qcow2 \
  --property os_type=Linux \
  --property hw_firmware_type=uefi \
  --property hw_machine_type=q35 \
  --property os_secure_boot=disabled \
  --private \
  --file pcd-console-<VERSION>.qcow2 \
  pcd-console-<VERSION>
```

Note the image ID from the output — you'll need it when launching the VM.

---

## Step 2: Prepare Cloud-Init User Data

Cloud-init user-data lets you pre-configure the proxy before first boot. The only required field is `OS_AUTH_URL`; everything else can be set later via the management TUI.

### Minimum configuration

Create a file (e.g. `user-data.yaml`) with at minimum:

```yaml
#cloud-config
write_files:
  - path: /etc/pcd-proxy/cloud-init.conf
    permissions: '0600'
    content: |
      OS_AUTH_URL="https://<fq-region>.app.staging-pcd.platform9.com/keystone/v3"
      DOMAIN="console.example.com"
```

Replace `<fq-region>` with your PCD deployment's fully-qualified region (e.g. `acme-us-east`), and set `DOMAIN` to the DNS name your users will browse to. A self-signed TLS certificate is automatically generated for this domain on first boot.

### Optional: restrict to specific projects

```yaml
      ALLOWED_PROJECTS="service"   # comma-separated; empty = any valid project
```

### Optional: backend auto-discovery (work in progress — not yet functional)

> **Note:** Backend auto-discovery is not yet functional. Skip this section and configure backends manually via the TUI after first boot (see Step 6).

If you have an application credential with compute-admin role, the proxy can discover nova-novncproxy backends automatically at boot:

```bash
# Create the credential once (requires admin or compute-admin role)
openstack --insecure application credential create pcd-proxy-discover \
  --role admin \
  --description "noVNC backend auto-discovery for pcd-console-proxy"
```

Then add to your user-data:

```yaml
  - path: /etc/pcd-proxy/app-credential.env
    permissions: '0600'
    content: |
      export OS_AUTH_TYPE=v3applicationcredential
      export OS_AUTH_URL="https://<fq-region>.app.staging-pcd.platform9.com/keystone/v3"
      export OS_REGION_NAME="<region>"
      export OS_APPLICATION_CREDENTIAL_ID="<id>"
      export OS_APPLICATION_CREDENTIAL_SECRET="<secret>"
      export OS_INTERFACE=public
```

See [cloud-init-sample.yaml](cloud-init-sample.yaml) for the full template including DNS-01 certificate credentials.

---

## Step 3: Deploy the VM

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

Omit `v4-fixed-ip` to use DHCP instead.

> **Note:** Before redeploying with the same fixed IP, check for orphaned ports:
> `openstack --insecure port list --fixed-ip ip-address=<ip>` and delete any found.

### Security group requirements

The VM's security group must allow:

| Direction | Protocol | Port | Purpose |
|-----------|----------|------|---------|
| Inbound | TCP | 6080 | User browser access (HTTPS/WSS) |
| Outbound | TCP | 6080 | Proxy to nova-novncproxy backends |
| Outbound | TCP | 5000 / 443 | Keystone authentication |

---

## Step 4: First Boot

On first boot, the proxy automatically:

1. Merges cloud-init configuration into its runtime state
2. Auto-discovers nova-novncproxy backends (if an app credential was provided)
3. Generates a self-signed TLS certificate for the configured domain

The self-signed certificate is sufficient to get started. Browsers will show a security warning — you can replace it with a trusted certificate via the TUI after the VM is running.

Boot completes in approximately 60–90 seconds.

---

## Step 5: Connect to the Management TUI

**Via the PCD console** (recommended for first access):

```
User: root
Password: Pl@tform9!
```

The login shell drops directly into the management TUI main menu.

**Via SSH** (requires a keypair injected at deploy time):

```bash
ssh alpine@<vm-ip>
sudo -i   # or: sudo /usr/local/lib/pcd-proxy/main.sh
```

**Change the root password** on first login: the TUI main menu includes a "Change Root Password" option.

---

## Step 6: Configure the Backend

If you did not use auto-discovery, add the nova-novncproxy backend manually:

1. From the TUI main menu, select **Backend Target**
2. Select **Add Backend**
3. Enter the IP address and port of your nova-novncproxy service (default port: `6080`)

The proxy supports multiple backends with ip_hash load balancing. Nginx is reloaded automatically after each change.

A yellow warning on the main menu indicates no backend is configured — the proxy cannot forward console traffic until at least one backend is added.

---

## Step 7: TLS Certificate (optional, work in progress)

> **Note:** TLS certificate management is functional but still being tested. HTTP-01 and manual install are the most reliable paths. DNS-01 is available but not all DNS providers have been fully tested — use with caution and verify the cert was issued before relying on it.

The self-signed certificate works for testing but browsers will warn users. Replace it with a trusted certificate via **TLS / Certificate** in the TUI:

| Method | When to use |
|--------|-------------|
| **Let's Encrypt (HTTP-01)** | VM has a public IP reachable on port 80 from the internet |
| **Let's Encrypt (DNS-01)** | VM is on a private network; requires DNS provider API credentials |
| **Manual** | You already have a certificate; provide the PEM file paths |

For DNS-01, the TUI will prompt for your DNS provider and API credentials. Certificates are auto-renewed via cron.

---

## Step 8: Verify

Browse to `https://<DOMAIN>:6080/` (or `https://<DOMAIN>/` if port 6080 is your default).

You should see the PCD Console Proxy login page. Log in with your PCD username, password, and project name (default: `service`). On success, you are redirected to the noVNC console.

If the console connects but shows a blank screen, verify the nova-novncproxy backend is reachable from the proxy VM on port 6080.
