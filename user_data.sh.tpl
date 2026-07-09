#!/bin/bash
set -euo pipefail

DEVICE_NAME="${device_name}"
MOUNT_POINT="${mount_point}"
EBS_VOLUME_ID="${ebs_volume_id}"

apt-get update -y
apt-get install -y e2fsprogs

VOLUME_ID_NO_DASHES=$(echo "$EBS_VOLUME_ID" | tr -d '-')
STABLE_PATH="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$${VOLUME_ID_NO_DASHES}"

for i in $(seq 1 60); do
  [ -e "$STABLE_PATH" ] && break
  sleep 5
done

if [ ! -e "$STABLE_PATH" ]; then
  echo "ERROR: $STABLE_PATH never appeared, lifecycle hook attach may have failed" >&2
  exit 1
fi

REAL_DEVICE=$(readlink -f "$STABLE_PATH")

if ! blkid "$REAL_DEVICE" > /dev/null 2>&1; then
  mkfs -t ext4 "$REAL_DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mount "$REAL_DEVICE" "$MOUNT_POINT"

resize2fs "$REAL_DEVICE"

if ! grep -q "$STABLE_PATH" /etc/fstab; then
  echo "$STABLE_PATH  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

apt-get install -y nginx

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
usermod -aG docker ubuntu

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

if [ -f "$MOUNT_POINT/docker-compose.yml" ]; then
  cd "$MOUNT_POINT"
  docker compose up -d
fi

if [ -f "$MOUNT_POINT/nginx.conf" ]; then
  cp "$MOUNT_POINT/nginx.conf" /etc/nginx/sites-available/default
  systemctl reload nginx
fi