#!/bin/bash
# Mirror OpenShift release by calling mirror-local.sh on registry server
# Usage: ./mirror.sh <version>
# Example: ./mirror.sh 4.18.30

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 4.18.30"
    exit 1
fi

VERSION="$1"

echo "=== Mirror OpenShift ${VERSION} ==="
echo "Registry: ${LOCAL_REGISTRY}"
echo ""

# Call mirror-local.sh on the registry server
ssh $SSH_OPTS root@${REGISTRY_HOST} "/root/mirror-local.sh ${VERSION}"

echo ""
echo "=== Mirror Complete ==="
echo "Run ./install.sh ${VERSION} to install"
