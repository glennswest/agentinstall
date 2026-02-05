#!/bin/bash
# Mirror OpenShift release by calling mirror-local.sh on registry server
# Operator catalog is NOT mirrored by default (use --with-operators to include)
# Usage: ./mirror.sh <version> [--wipe] [--with-operators]
# Example: ./mirror.sh 4.18.10
# Example: ./mirror.sh 4.18.10 --wipe            # Wipe existing mirror first
# Example: ./mirror.sh 4.18.10 --with-operators  # Include operator catalog
# Example: ./mirror.sh 4.18.z                    # Mirror latest 4.18.x release
# Example: ./mirror.sh 4.18                      # Mirror latest 4.18.x release

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

WIPE=""
WITH_OPERATORS=""
VERSION=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --wipe)
            WIPE="--wipe"
            ;;
        --with-operators)
            WITH_OPERATORS="--with-operators"
            ;;
        *)
            VERSION="$arg"
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--wipe] [--with-operators]"
    echo "Example: $0 4.18.10"
    echo "Example: $0 4.18.10 --wipe            # Wipe existing mirror first"
    echo "Example: $0 4.18.10 --with-operators  # Include operator catalog"
    echo "Example: $0 4.18.z                    # Mirror latest 4.18.x release"
    echo "Example: $0 4.18                      # Mirror latest 4.18.x release"
    exit 1
fi

VERSION=$(resolve_latest_version "$VERSION")

echo "=== Mirror OpenShift ${VERSION} ==="
echo "Registry: ${LOCAL_REGISTRY}"
if [ -n "$WIPE" ] && [ -n "$WITH_OPERATORS" ]; then
    echo "Mode: Wipe + Mirror (with operators)"
elif [ -n "$WIPE" ]; then
    echo "Mode: Wipe + Mirror"
elif [ -n "$WITH_OPERATORS" ]; then
    echo "Mode: Mirror (with operators)"
else
    echo "Mode: Mirror"
fi
echo ""

# Call mirror-local.sh on the registry server
ssh $SSH_OPTS root@${REGISTRY_HOST} "/root/mirror-local.sh ${VERSION} ${WIPE} ${WITH_OPERATORS}"

echo ""
echo "=== Mirror Complete ==="
echo "Run ./install.sh ${VERSION} to install"
