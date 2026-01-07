#!/bin/bash
# Pull OpenShift installer from local registry (registry.gw.lo)
# Usage: ./pull-from-registry.sh <version>
# Example: ./pull-from-registry.sh 4.18.30
#
# Checks for pre-cached binary in bin/ first, then extracts from registry if needed.
# Verifies local binary hash matches registry to prevent version mismatches.

set -e

PULL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PULL_SCRIPT_DIR}/config.sh"

BIN_DIR="${PULL_SCRIPT_DIR}/bin"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"

# Install location (user-writable, no sudo needed)
INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "$INSTALL_DIR"

# Detect OS for correct binary
LOCAL_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
if [ "$LOCAL_OS" = "darwin" ]; then
    LOCAL_OS="mac"
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <ocp-version>"
    echo "Example: $0 4.18.30"
    exit 1
fi

OCP_RELEASE="$1"
CACHED_BIN="${BIN_DIR}/openshift-install-${OCP_RELEASE}-${LOCAL_OS}"

# Registry cache path based on OS
if [ "$LOCAL_OS" = "mac" ]; then
    REGISTRY_CACHE="/var/lib/openshift-cache/openshift-install-${OCP_RELEASE}-mac"
elif [ "$LOCAL_OS" = "windows" ]; then
    REGISTRY_CACHE="/var/lib/openshift-cache/openshift-install-${OCP_RELEASE}.exe"
else
    REGISTRY_CACHE="/var/lib/openshift-cache/openshift-install-${OCP_RELEASE}"
fi

echo "Detected OS: ${LOCAL_OS}"
echo "Registry cache: ${REGISTRY_CACHE}"

# Function to calculate sha256 (works on macOS and Linux)
calc_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo ""
    fi
}

# Function to get registry binary hash (from .sha256 file or calculate)
get_registry_hash() {
    # Try .sha256 file first (faster)
    local hash=$(ssh $SSH_OPTS "root@${REGISTRY_HOST}" "cat ${REGISTRY_CACHE}.sha256 2>/dev/null" 2>/dev/null)
    if [ -n "$hash" ]; then
        echo "$hash"
        return
    fi
    # Fall back to calculating
    ssh $SSH_OPTS "root@${REGISTRY_HOST}" "sha256sum ${REGISTRY_CACHE} 2>/dev/null | cut -d' ' -f1" 2>/dev/null || echo ""
}

# Function to verify local binary matches registry
verify_binary() {
    local local_bin="$1"
    local local_hash=$(calc_sha256 "$local_bin")

    # Check against registry hash
    local expected_hash=$(get_registry_hash)
    if [ -z "$expected_hash" ]; then
        echo "WARNING: Cannot verify - registry binary not found"
        echo "Binary hash: ${local_hash:0:16}..."
        return 0
    fi

    if [ "$local_hash" != "$expected_hash" ]; then
        echo "ERROR: Binary hash mismatch!"
        echo "  Local:    ${local_hash}"
        echo "  Expected: ${expected_hash}"
        return 1
    fi
    echo "Binary hash verified: ${local_hash:0:16}..."
    return 0
}

# Check if already installed with correct version
CURRENT_VERSION=$("${INSTALL_DIR}/openshift-install" version 2>/dev/null | head -1 | awk '{print $2}' || echo "none")
if [ "$CURRENT_VERSION" == "$OCP_RELEASE" ]; then
    echo "openshift-install ${OCP_RELEASE} already installed"
    # Verify it matches registry
    if ! verify_binary "${INSTALL_DIR}/openshift-install"; then
        echo "Installed binary doesn't match registry - will re-download"
    else
        "${INSTALL_DIR}/openshift-install" version
        exit 0
    fi
fi

# Check for local pre-cached binary
if [ -f "$CACHED_BIN" ]; then
    echo "Found local cached binary: ${CACHED_BIN}"
    if verify_binary "$CACHED_BIN"; then
        echo "Using verified local cached binary"
        cp "$CACHED_BIN" "$INSTALL_DIR/openshift-install"
        chmod +x "$INSTALL_DIR/openshift-install"
        "${INSTALL_DIR}/openshift-install" version
        exit 0
    else
        echo "Local cache is stale - removing"
        rm -f "$CACHED_BIN"
    fi
fi

# Download from registry server cache
echo "Downloading from registry cache..."
mkdir -p "$BIN_DIR"
if scp -O $SSH_OPTS "root@${REGISTRY_HOST}:${REGISTRY_CACHE}" "$CACHED_BIN" 2>/dev/null; then
    echo "Downloaded from registry cache"
    if verify_binary "$CACHED_BIN"; then
        cp "$CACHED_BIN" "$INSTALL_DIR/openshift-install"
        chmod +x "$INSTALL_DIR/openshift-install"
        "${INSTALL_DIR}/openshift-install" version
        exit 0
    else
        echo "ERROR: Downloaded binary failed verification!"
        rm -f "$CACHED_BIN"
        exit 1
    fi
fi

# Fallback: Extract from release image (if registry cache not available)
echo "Registry cache not available - extracting from release image..."
echo "NOTE: Run ./mirror.sh ${OCP_RELEASE} to cache binaries for all platforms"

# Clean up any existing binary
rm -f "${PULL_SCRIPT_DIR}/openshift-install"

# Extract openshift-install binary from release image
oc adm release extract \
    --command=openshift-install \
    --registry-config="${PULL_SECRET_JSON}" \
    --insecure \
    --to="${PULL_SCRIPT_DIR}" \
    "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}-${ARCHITECTURE}"

# Verify extraction succeeded
if [ ! -f "${PULL_SCRIPT_DIR}/openshift-install" ]; then
    echo "ERROR: Failed to extract openshift-install from release image"
    exit 1
fi

# Cache the binary for future use
mkdir -p "$BIN_DIR"
cp "${PULL_SCRIPT_DIR}/openshift-install" "$CACHED_BIN"
echo "Cached binary: ${CACHED_BIN}"

# Get hash for display
LOCAL_HASH=$(calc_sha256 "${PULL_SCRIPT_DIR}/openshift-install")
echo "Extracted binary hash: ${LOCAL_HASH}"

# Install the binary
rm -f "$INSTALL_DIR/openshift-install"
mv "${PULL_SCRIPT_DIR}/openshift-install" "$INSTALL_DIR/openshift-install"
chmod +x "$INSTALL_DIR/openshift-install"

echo "Installed openshift-install to ${INSTALL_DIR}:"
"${INSTALL_DIR}/openshift-install" version

# Check if INSTALL_DIR is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo "NOTE: Add ${INSTALL_DIR} to your PATH:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
