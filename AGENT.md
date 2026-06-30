# Infrastructure Setup
This is a platform9 PCD Private Cloud

REGION: https://jscott-se-dallas.app.staging-pcd.platform9.com/
Credentials: /home/jeff/pcdctl.rc

# Establish authentication token
source /home/jeff/pcdctl.rc
TOKEN=$(openstack token issue -c id -f value)

# upload image to OpenStack Glance
pcdctl image create --insecure --container-format bare --disk-format qcow2 --property os_type=[Linux | Windows | Other] [--public |
              --private] [--protected | --unprotected] [--property <key=value>] --file
              <image-file-path> <image-name>

# Alpine Linux UEFI Image Properties
  --property hw_firmware_type=uefi \
  --property os_secure_boot=disabled \
  --property hw_machine_type=q35 \

# Deploy VM in PCD Private Cloud
use pcdctl server create --image <image-name> --flavor <flavor> --network <public-network> --network <console-network> --key-name <keypair-name> --security-group <security-group> --property tenant=<tenant-name> <vm-name>

# Test Image Deployment
Name: pcd-console-proxy
IP: 10.0.0.254 (locallan)
DNS Name: console-proxy.pf9.zone
Image: alpine-3.24.1-x86_64-uefi-cloudinit-r0
Flavor: m1.small (1 vCPU, 2GB RAM, 20GB disk)
Keypair: jscott-sshkey
tenant: service
Security group: any-any