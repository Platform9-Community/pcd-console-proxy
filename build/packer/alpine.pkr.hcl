packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# Path to the Alpine UEFI NoCloud cloud image used as the base disk.
# Download with: make -C build download-base
variable "cloud_image_path" {
  default = "packer/files/alpine-cloud.qcow2"
}

variable "version" {
  default = "dev"
}

variable "output_name" {
  default = ""
}

locals {
  image_name = var.output_name != "" ? var.output_name : "pcd-console-${var.version}.qcow2"
}

source "qemu" "alpine" {
  # Boot from the pre-built Alpine UEFI cloud image instead of installing
  # from ISO. This avoids all Alpine installer timing/interaction issues and
  # produces a known-good UEFI disk layout identical to what Nova expects.
  iso_url      = var.cloud_image_path
  iso_checksum = "none"
  disk_image   = true

  vm_name          = local.image_name
  output_directory = "output"
  disk_size        = "2048M"
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  disk_compression = true
  format           = "qcow2"

  memory       = 512
  cpus         = 1
  accelerator  = "kvm"
  machine_type = "q35"
  headless     = true

  # When qemuargs is set, Packer does NOT automatically add the main disk drive.
  # We must include it explicitly. The disk path is build/output/<vm_name>.
  # UEFI via pflash requires both code (readonly) and vars (writable) drives.
  # cloud-seed.iso provides the cloud-init NoCloud datasource with the SSH key.
  qemuargs = [
    ["-drive", "file=output/${local.image_name},if=virtio,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,file=packer/files/ovmf-vars.fd"],
    ["-drive", "file=packer/files/cloud-seed.iso,media=cdrom,readonly=on"],
    ["-device", "virtio-rng-pci"]
  ]

  # SSH as the alpine user (the cloud image's default user with passwordless sudo).
  # Root SSH is blocked by disable_root: true in cloud.cfg; using alpine + sudo
  # is the correct pattern for this image.
  ssh_username         = "alpine"
  ssh_private_key_file = "packer/files/packer_key"
  ssh_timeout          = "5m"

  shutdown_command = "doas poweroff"

  # Wait 60s for cloud-init to finish setting up SSH before Packer connects.
  # Manual testing shows cloud-init finishes in ~20s; 60s gives ample margin.
  # No boot_command needed — cloud image boots straight to a running system.
  boot_wait    = "60s"
  boot_command = []
}

build {
  sources = ["source.qemu.alpine"]

  provisioner "shell" {
    inline = ["mkdir -p /tmp/tui /tmp/config /tmp/packer-files"]
  }


  provisioner "file" {
    source      = "packer/files/pcd-auth"
    destination = "/tmp/packer-files/pcd-auth"
  }

  provisioner "file" {
    source      = "packer/files/pcd-auth.initd"
    destination = "/tmp/packer-files/pcd-auth.initd"
  }

  provisioner "file" {
    source      = "../tui/"
    destination = "/tmp/tui/"
  }

  provisioner "file" {
    source      = "../config/"
    destination = "/tmp/config/"
  }

  provisioner "shell" {
    script           = "packer/scripts/provision.sh"
    environment_vars = ["PCD_VERSION=${var.version}"]
    execute_command  = "doas sh -c '{{.Vars}} {{.Path}}'"
  }

  provisioner "shell" {
    script          = "packer/scripts/cleanup.sh"
    execute_command = "doas sh -c '{{.Vars}} {{.Path}}'"
  }
}
