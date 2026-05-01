#!/bin/bash
# Wipe all images from registry.g8.lo by nuking storage
# Usage: ./wipe_registry.sh [--force]

set -e

REGISTRY_HOST="registry.g8.lo"
STORAGE_PATH="/var/lib/quay/storage"

echo "=== Remote Registry Wipe ==="
echo "Target: ${REGISTRY_HOST}"
echo "Method: Stop Quay -> Clear storage -> Start Quay"
echo ""

# Check connectivity
if ! ssh -o ConnectTimeout=5 root@${REGISTRY_HOST} "echo connected" &>/dev/null; then
    echo "ERROR: Cannot connect to ${REGISTRY_HOST}"
    exit 1
fi

# Show current disk usage
echo "Current disk usage on ${REGISTRY_HOST}:"
ssh root@${REGISTRY_HOST} "df -h ${STORAGE_PATH}"
echo ""

# Check for --force flag
if [ "$1" != "--force" ]; then
    echo "WARNING: This will delete ALL images from ${REGISTRY_HOST}!"
    echo "         Storage path: ${STORAGE_PATH}"
    echo ""
    read -p "Are you sure? (type 'yes' to confirm): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

echo "[1/4] Stopping Quay..."
ssh root@${REGISTRY_HOST} "systemctl stop quay || podman stop quay 2>/dev/null || true"
sleep 2

echo "[2/4] Clearing storage at ${STORAGE_PATH}..."
ssh root@${REGISTRY_HOST} "rm -rf ${STORAGE_PATH}/* && echo 'Storage cleared'"

echo "[3/4] Starting Quay..."
ssh root@${REGISTRY_HOST} "systemctl start quay || podman start quay 2>/dev/null"
sleep 3

echo "[4/4] Verifying Quay is running..."
ssh root@${REGISTRY_HOST} "systemctl is-active quay || podman ps | grep quay"

echo ""
echo "=== Wipe Complete ==="
echo "Disk usage after wipe:"
ssh root@${REGISTRY_HOST} "df -h ${STORAGE_PATH}"
