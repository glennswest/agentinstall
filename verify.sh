#!/bin/bash
# Verify OpenShift release by calling verify-local.sh on registry server
# Usage: ./verify.sh <version>
# Example: ./verify.sh 4.18.30

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

echo "=== Verify OpenShift ${VERSION} ==="
echo "Registry: ${LOCAL_REGISTRY}"
echo ""

# Call verify-local.sh on the registry server
ssh $SSH_OPTS root@${REGISTRY_HOST} "/root/verify-local.sh ${VERSION}"
