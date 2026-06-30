#!/bin/bash
STATIC_IP=10.0.0.254    
VERSION=`cat VERSION`
CONFIG="min"

pcdctl server create \
  --image pcd-console-$VERSION \
  --flavor bfc4fa1e-bb18-4538-b204-86a44e9211cc \
  --nic net-id=afa3028a-c5c3-4107-954e-1fda94743fbd,v4-fixed-ip=$STATIC_IP \
  --key-name jscott-sshkey \
  --security-group 0d0c47ac-2938-4df6-a4af-36e27a644419 \
  --user-data /home/jeff/projects/pcd-console-proxy/cloud-init-$CONFIG.yaml \
  pcd-console-proxy 