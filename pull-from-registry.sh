#!/bin/bash
# Pull OpenShift installer from local registry (registry.gw.lo)
# Usage: ./pull-from-registry.sh <version>
# Example: ./pull-from-registry.sh 4.18.30
#
# Checks for pre-cached binary in bin/ first, then extracts from registry if needed.

set -e

PULL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PULL_SCRIPT_DIR}/config.sh"

BIN_DIR="${PULL_SCRIPT_DIR}/bin"

if [ -z "$1" ]; then
    echo "Usage: $0 <ocp-version>"
    echo "Example: $0 4.18.30"
    exit 1
fi

OCP_RELEASE="$1"
CACHED_BIN="${BIN_DIR}/openshift-install-${OCP_RELEASE}"

# Check if already installed with correct version
CURRENT_VERSION=$(openshift-install version 2>/dev/null | head -1 | awk '{print $2}' || echo "none")
if [ "$CURRENT_VERSION" == "$OCP_RELEASE" ]; then
    echo "openshift-install ${OCP_RELEASE} already installed"
    openshift-install version
    exit 0
fi

# Check for local pre-cached binary
if [ -f "$CACHED_BIN" ]; then
    echo "Using local cached binary: ${CACHED_BIN}"
    sudo cp "$CACHED_BIN" /usr/local/bin/openshift-install
    sudo chmod +x /usr/local/bin/openshift-install
    openshift-install version
    exit 0
fi

# Try downloading from registry server cache
REMOTE_CACHE="root@${LOCAL_REGISTRY}:/var/lib/openshift-cache/openshift-install-${OCP_RELEASE}"
echo "Checking registry cache..."
mkdir -p "$BIN_DIR"
if scp -q "$REMOTE_CACHE" "$CACHED_BIN" 2>/dev/null; then
    echo "Downloaded from registry cache"
    sudo cp "$CACHED_BIN" /usr/local/bin/openshift-install
    sudo chmod +x /usr/local/bin/openshift-install
    openshift-install version
    exit 0
fi

echo "Extracting openshift-install ${OCP_RELEASE} from ${LOCAL_REGISTRY}..."

# Clean up any existing binary
rm -f "${PULL_SCRIPT_DIR}/openshift-install"

# Extract openshift-install binary from release image
oc adm release extract \
    --command=openshift-install \
    --registry-config="${PULL_SECRET_JSON}" \
    --insecure \
    --to="${PULL_SCRIPT_DIR}" \
    "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}-${ARCHITECTURE}"

# Cache the binary for future use
mkdir -p "$BIN_DIR"
cp "${PULL_SCRIPT_DIR}/openshift-install" "$CACHED_BIN"
echo "Cached binary: ${CACHED_BIN}"

# Install the binary
sudo rm -f /usr/local/bin/openshift-install
sudo mv "${PULL_SCRIPT_DIR}/openshift-install" /usr/local/bin/openshift-install
sudo chmod +x /usr/local/bin/openshift-install

echo "Installed openshift-install:"
openshift-install version
