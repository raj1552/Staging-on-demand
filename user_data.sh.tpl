#!/bin/bash
set -euo pipefail

DEVICE_NAME="${device_name}"
MOUNT_POINT="${mount_point}"

apt-get update -y

# Wait for the lifecycle-hook Lambda to finish attaching the volume
for i in $(seq 1 60); do
  [ -e "$DEVICE_NAME" ] && break
  sleep 5
done

if [ ! -e "$DEVICE_NAME" ]; then
  echo "ERROR: $DEVICE_NAME never appeared — lifecycle hook attach may have failed" >&2
  exit 1
fi

# Format only if the volume has no filesystem yet (first-ever boot)
if ! blkid "$DEVICE_NAME" > /dev/null 2>&1; then
  mkfs -t ext4 "$DEVICE_NAME"
fi

mkdir -p "$MOUNT_POINT"
mount "$DEVICE_NAME" "$MOUNT_POINT"

# Persist across reboots — nofail so a missing volume never blocks boot
if ! grep -q "$DEVICE_NAME" /etc/fstab; then
  echo "$DEVICE_NAME  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

# --- Base packages -------------------------------------------------------
apt-get install -y nginx

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
usermod -aG docker ubuntu

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
