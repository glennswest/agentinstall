#!/bin/bash
# Watch installation progress

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Watching cluster operators..."
watch -n 10 "oc get clusteroperators 2>/dev/null || echo 'Cluster not yet available'"
