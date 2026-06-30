#!/bin/sh
# Creates a cloud-init NoCloud seed ISO for use as a Packer CDROM.
# Injects the given SSH public key into root's authorized_keys and
# ensures root login is permitted (key-only).
#
# Usage: make-cloud-seed.sh <pubkey-file> <output-iso>
set -e

KEYFILE="$1"
OUTFILE="$2"

if [ -z "$KEYFILE" ] || [ -z "$OUTFILE" ]; then
    echo "Usage: $0 <pubkey-file> <output-iso>" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# user-data: inject SSH key into the alpine user (the image's default user
# with passwordless sudo). Using top-level ssh_authorized_keys targets the
# default user, avoiding the disable_root: true restriction in cloud.cfg.
cat > "$TMPDIR/user-data" <<ENDUSERDATA
#cloud-config
ssh_authorized_keys:
  - $(cat "$KEYFILE")
ENDUSERDATA

# meta-data: required by cloud-init NoCloud datasource
cat > "$TMPDIR/meta-data" <<ENDMETADATA
instance-id: packer-build
local-hostname: pcd-proxy
ENDMETADATA

genisoimage -output "$OUTFILE" -volid cidata -rational-rock -joliet -quiet \
    "$TMPDIR/user-data" "$TMPDIR/meta-data"

echo "Created cloud-init seed: $OUTFILE"
