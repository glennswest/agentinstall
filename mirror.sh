#!/bin/bash
# Mirror OpenShift release via FastRegistry admin API
# Usage: ./mirror.sh <version>
# Example: ./mirror.sh 4.18.10
# Example: ./mirror.sh 4.18.z                    # Mirror latest 4.18.x release
# Example: ./mirror.sh 4.18                      # Mirror latest 4.18.x release

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERSION=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        -h|--help)
            echo "Usage: $0 <version>"
            echo ""
            echo "Mirrors an OpenShift release via the FastRegistry API."
            echo "Automatically discovers, clones, and extracts artifacts."
            echo ""
            echo "Examples:"
            echo "  $0 4.18.10    Mirror a specific version"
            echo "  $0 4.18.z     Mirror latest 4.18.x release"
            echo "  $0 4.18       Mirror latest 4.18.x release"
            exit 0
            ;;
        *)
            VERSION="$arg"
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 4.18.10"
    echo "Example: $0 4.18.z     # Mirror latest 4.18.x release"
    echo "Example: $0 4.18       # Mirror latest 4.18.x release"
    exit 1
fi

VERSION=$(resolve_latest_version "$VERSION")
TAG="${VERSION}-${ARCHITECTURE}"

echo "=== Mirror OpenShift ${VERSION} ==="
echo "Registry: ${FASTREGISTRY_URL}"
echo ""

# Trigger clone via FastRegistry admin API
echo "Starting clone..."
RESULT=$(curl -s -X POST "${FASTREGISTRY_URL}/admin/releases/clone" \
    -H 'Content-Type: application/json' \
    -d "{\"version\":\"${TAG}\"}")

# Check for error
if echo "$RESULT" | grep -q '"error"'; then
    echo "Error: $(echo "$RESULT" | jq -r '.error // .message // .')"
    exit 1
fi

echo "Clone started: $(echo "$RESULT" | jq -r '.message // .')"
echo ""

# Poll until ready
echo "Waiting for completion..."
while true; do
    STATUS=$(curl -s "${FASTREGISTRY_URL}/admin/releases/${TAG}/status")
    STATE=$(echo "$STATUS" | jq -r '.release.state // "unknown"')

    case "$STATE" in
        ready)
            printf "\r%-40s\n" ""
            echo "Release ${TAG} is ready"
            echo ""
            ARTIFACTS=$(echo "$STATUS" | jq -r '.release.artifacts[]?.name // empty' 2>/dev/null)
            if [ -n "$ARTIFACTS" ]; then
                echo "Artifacts:"
                echo "$ARTIFACTS" | while read -r name; do
                    echo "  ${FASTREGISTRY_URL}/files/releases/${VERSION}/${name}"
                done
            fi
            echo ""
            echo "=== Mirror Complete ==="
            echo "Release image: ${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${TAG}"
            echo "Run ./install.sh ${VERSION} to install"
            exit 0
            ;;
        failed)
            printf "\r%-40s\n" ""
            ERROR=$(echo "$STATUS" | jq -r '.release.error // "unknown error"')
            echo "Failed: ${ERROR}"
            exit 1
            ;;
        cloning|extracting)
            PROGRESS=$(echo "$STATUS" | jq -r '.progress.percent_done // 0' 2>/dev/null)
            PHASE=$(echo "$STATUS" | jq -r '.progress.phase // .release.state' 2>/dev/null)
            printf "\r  %-20s %s%%" "$PHASE" "$PROGRESS"
            sleep 5
            ;;
        *)
            printf "\r  %-20s" "$STATE"
            sleep 5
            ;;
    esac
done
