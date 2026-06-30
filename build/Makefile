VERSION    := $(shell cat ../VERSION)
QCOW2      = output/pcd-console-$(VERSION).qcow2
GOARCH     = amd64
GOOS       = linux
GO        ?= $(shell which go || echo /usr/local/go/bin/go)

# Alpine UEFI NoCloud cloud image used as the Packer base disk.
# Set CLOUD_IMAGE on the command line to use a local file, otherwise
# 'make download-base' fetches the default version from the Alpine CDN.
ALPINE_CLOUD_VERSION ?= 3.21.7
CLOUD_IMAGE_URL = https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-$(ALPINE_CLOUD_VERSION)-x86_64-uefi-cloudinit-r0.qcow2
CLOUD_IMAGE ?= packer/files/alpine-cloud.qcow2

.PHONY: build auth-build packer-build init clean download-base

build: auth-build packer-build

auth-build:
	cd ../auth && CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -ldflags="-s -w" -o $(CURDIR)/packer/files/pcd-auth .

packer-build: init packer/files/packer_key packer/files/ovmf-vars.fd packer/files/cloud-seed.iso
	packer build -var "version=$(VERSION)" -var "cloud_image_path=$(CLOUD_IMAGE)" packer/alpine.pkr.hcl

download-base: $(CLOUD_IMAGE)

$(CLOUD_IMAGE):
	curl -L --progress-bar -o $@ $(CLOUD_IMAGE_URL)

packer/files/packer_key:
	ssh-keygen -t ed25519 -N "" -f packer/files/packer_key -C "packer-build-key"
	cp packer/files/packer_key.pub packer/http/packer_key.pub

packer/files/ovmf-vars.fd:
	cp /usr/share/OVMF/OVMF_VARS.fd packer/files/ovmf-vars.fd

packer/files/cloud-seed.iso: packer/files/packer_key
	packer/scripts/make-cloud-seed.sh packer/files/packer_key.pub packer/files/cloud-seed.iso

init:
	packer init packer/

clean:
	rm -rf output/ \
		packer/files/pcd-auth \
		packer/files/packer_key \
		packer/files/packer_key.pub \
		packer/http/packer_key.pub \
		packer/files/ovmf-vars.fd \
		packer/files/cloud-seed.iso
