#!/bin/bash
# Pull OpenShift installer from local registry (registry.gw.lo)
# Usage: ./pull-from-registry.sh <version>
# Example: ./pull-from-registry.sh 4.14.10

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ -z "$1" ]; then
    echo "Usage: $0 <ocp-version>"
    echo "Example: $0 4.14.10"
    exit 1
fi

OCP_RELEASE="$1"

echo "Extracting openshift-install ${OCP_RELEASE} from ${LOCAL_REGISTRY}..."

# Extract openshift-install binary from release image
oc adm release extract \
    --insecure=true \
    -a "${PULL_SECRET_JSON}" \
    --command=openshift-install \
    "${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE}-${ARCHITECTURE}"

# Install the binary
sudo rm -f /usr/local/bin/openshift-install
sudo mv openshift-install /usr/local/bin/openshift-install
sudo chmod +x /usr/local/bin/openshift-install

echo "Installed openshift-install:"
openshift-install version
