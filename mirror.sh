#!/bin/bash
# Mirror OpenShift release by calling mirror-local.sh on registry server
# Includes Red Hat operator catalog by default
# Usage: ./mirror.sh <version> [--wipe]
# Example: ./mirror.sh 4.18.10
# Example: ./mirror.sh 4.18.10 --wipe  # Wipe existing mirror first
# Example: ./mirror.sh 4.18.z          # Mirror latest 4.18.x release
# Example: ./mirror.sh 4.18            # Mirror latest 4.18.x release

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

WIPE=""
VERSION=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --wipe)
            WIPE="--wipe"
            ;;
        *)
            VERSION="$arg"
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--wipe]"
    echo "Example: $0 4.18.10"
    echo "Example: $0 4.18.10 --wipe  # Wipe existing mirror first"
    echo "Example: $0 4.18.z          # Mirror latest 4.18.x release"
    echo "Example: $0 4.18            # Mirror latest 4.18.x release"
    exit 1
fi

VERSION=$(resolve_latest_version "$VERSION")

echo "=== Mirror OpenShift ${VERSION} ==="
echo "Registry: ${LOCAL_REGISTRY}"
if [ -n "$WIPE" ]; then
    echo "Mode: Wipe + Mirror (with operators)"
else
    echo "Mode: Mirror (with operators)"
fi
echo ""

# Call mirror-local.sh on the registry server
ssh $SSH_OPTS root@${REGISTRY_HOST} "/root/mirror-local.sh ${VERSION} ${WIPE}"

echo ""
echo "=== Mirror Complete ==="
echo "Run ./install.sh ${VERSION} to install"
