#!/bin/sh
set -e

# Remove Packer temporary files
rm -rf /tmp/tui /tmp/config /tmp/packer-files

# Remove SSH host keys — regenerated on first boot by /etc/local.d/10-sshd-keygen.start
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

# authorized_keys intentionally preserved for dev/troubleshooting access

# Remove shell history
rm -f /root/.ash_history /root/.bash_history

# Remove APK cache
rm -rf /var/cache/apk/*

# Zero free space to shrink the QCOW2 image after disk compression.
# Ignore "no space left" — that is the expected exit from dd.
dd if=/dev/zero of=/zero bs=1M 2>/dev/null || true
rm -f /zero
sync

echo "Cleanup complete."
