#!/bin/bash
# Pull OpenShift installer from FastRegistry
# Usage: ./pull-from-registry.sh <version>
# Example: ./pull-from-registry.sh 4.18.30
#
# Downloads from FastRegistry file endpoint. Falls back to oc adm release extract.

set -e

PULL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PULL_SCRIPT_DIR}/config.sh"

BIN_DIR="${PULL_SCRIPT_DIR}/bin"

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

# FastRegistry download URL
DOWNLOAD_URL="${FASTREGISTRY_URL}/files/releases/${OCP_RELEASE}/openshift-install-${LOCAL_OS}-amd64"

echo "Detected OS: ${LOCAL_OS}"
echo "Download URL: ${DOWNLOAD_URL}"

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

# Check if already installed with correct version
CURRENT_VERSION=$("${INSTALL_DIR}/openshift-install" version 2>/dev/null | head -1 | awk '{print $2}' || echo "none")
if [ "$CURRENT_VERSION" == "$OCP_RELEASE" ]; then
    echo "openshift-install ${OCP_RELEASE} already installed"
    "${INSTALL_DIR}/openshift-install" version
    exit 0
fi

# Check for local pre-cached binary
if [ -f "$CACHED_BIN" ]; then
    echo "Found local cached binary: ${CACHED_BIN}"
    cp "$CACHED_BIN" "$INSTALL_DIR/openshift-install"
    chmod +x "$INSTALL_DIR/openshift-install"
    "${INSTALL_DIR}/openshift-install" version
    exit 0
fi

# Download from FastRegistry
echo "Downloading from FastRegistry..."
mkdir -p "$BIN_DIR"
HTTP_CODE=$(curl -s -o "$CACHED_BIN" -w '%{http_code}' "$DOWNLOAD_URL")
if [ "$HTTP_CODE" = "200" ] && [ -f "$CACHED_BIN" ] && [ -s "$CACHED_BIN" ]; then
    echo "Downloaded from FastRegistry"
    LOCAL_HASH=$(calc_sha256 "$CACHED_BIN")
    echo "Binary hash: ${LOCAL_HASH:0:16}..."
    cp "$CACHED_BIN" "$INSTALL_DIR/openshift-install"
    chmod +x "$INSTALL_DIR/openshift-install"
    "${INSTALL_DIR}/openshift-install" version
    exit 0
fi

echo "FastRegistry download failed (HTTP ${HTTP_CODE})"
rm -f "$CACHED_BIN"

# Fallback: Extract from release image
echo "Falling back to oc adm release extract..."
RELEASE_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}-${ARCHITECTURE}"

rm -f "${PULL_SCRIPT_DIR}/openshift-install"

oc adm release extract \
    --command=openshift-install \
    --registry-config="${PULL_SECRET_JSON}" \
    --insecure \
    --to="${PULL_SCRIPT_DIR}" \
    "${RELEASE_IMAGE}"

if [ ! -f "${PULL_SCRIPT_DIR}/openshift-install" ]; then
    echo "ERROR: Failed to extract openshift-install from release image"
    exit 1
fi

# Cache the binary for future use
mkdir -p "$BIN_DIR"
cp "${PULL_SCRIPT_DIR}/openshift-install" "$CACHED_BIN"

LOCAL_HASH=$(calc_sha256 "${PULL_SCRIPT_DIR}/openshift-install")
echo "Extracted binary hash: ${LOCAL_HASH}"

rm -f "$INSTALL_DIR/openshift-install"
mv "${PULL_SCRIPT_DIR}/openshift-install" "$INSTALL_DIR/openshift-install"
chmod +x "$INSTALL_DIR/openshift-install"

echo "Installed openshift-install to ${INSTALL_DIR}:"
"${INSTALL_DIR}/openshift-install" version

if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo "NOTE: Add ${INSTALL_DIR} to your PATH:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi
