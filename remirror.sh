#!/bin/bash
# Wipe and re-mirror OpenShift release with operators
# Usage: ./remirror.sh <version>
# Example: ./remirror.sh 4.18.10

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 4.18.10"
    echo ""
    echo "This will wipe the existing mirror and do a fresh mirror"
    echo "including the Red Hat operator catalog."
    exit 1
fi

VERSION="$1"

echo "=== Re-Mirror OpenShift ${VERSION} ==="
echo "This will WIPE the existing mirror and start fresh."
echo ""

# Call mirror.sh with --wipe flag
exec "${SCRIPT_DIR}/mirror.sh" "${VERSION}" --wipe
