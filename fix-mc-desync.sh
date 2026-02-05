#!/bin/bash
# Fix MachineConfig bootstrap desync after bootstrap pivot
# This fixes two issues:
#   1. MCP status.configuration.name is empty (MCS returns 500)
#   2. Master node annotations reference a deleted rendered MachineConfig
#
# Run after bootstrap-complete when control0 is stuck fetching ignition.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${SCRIPT_DIR}/gw/auth/kubeconfig"

echo "=== MachineConfig Bootstrap Desync Fix ==="

# Verify API is reachable
if ! oc get nodes >/dev/null 2>&1; then
    echo "ERROR: Cannot reach API server"
    exit 1
fi

# Get current rendered master config from MCP spec
CURRENT_MC=$(oc get mcp master -o jsonpath='{.spec.configuration.name}')
if [ -z "$CURRENT_MC" ]; then
    echo "ERROR: No spec.configuration.name found on master MCP"
    exit 1
fi
echo "Current rendered master MC: ${CURRENT_MC}"

# Verify the rendered MC exists
if ! oc get mc "$CURRENT_MC" >/dev/null 2>&1; then
    echo "ERROR: Rendered MachineConfig ${CURRENT_MC} does not exist!"
    exit 1
fi

# Step 1: Patch MCP status.configuration.name
STATUS_MC=$(oc get mcp master -o jsonpath='{.status.configuration.name}')
if [ -z "$STATUS_MC" ]; then
    echo ""
    echo "[1/3] Patching MCP status.configuration.name (was empty)..."
    oc patch mcp master --type=merge --subresource=status \
        -p "{\"status\":{\"configuration\":{\"name\":\"${CURRENT_MC}\"}}}"
    echo "  Patched to: ${CURRENT_MC}"
elif [ "$STATUS_MC" != "$CURRENT_MC" ]; then
    echo ""
    echo "[1/3] Patching MCP status.configuration.name (was ${STATUS_MC})..."
    oc patch mcp master --type=merge --subresource=status \
        -p "{\"status\":{\"configuration\":{\"name\":\"${CURRENT_MC}\"}}}"
    echo "  Patched to: ${CURRENT_MC}"
else
    echo ""
    echo "[1/3] MCP status.configuration.name already correct: ${STATUS_MC}"
fi

# Step 2: Fix master node annotations
echo ""
echo "[2/3] Fixing master node annotations..."
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master -o name 2>/dev/null || true)
if [ -z "$MASTER_NODES" ]; then
    MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null || true)
fi

FIXED=0
for node in $MASTER_NODES; do
    NODE_NAME=$(basename "$node")
    NODE_MC=$(oc get "$node" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}')
    NODE_STATE=$(oc get "$node" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/state}')

    if [ "$NODE_MC" != "$CURRENT_MC" ] || [ "$NODE_STATE" = "Degraded" ]; then
        echo "  Fixing ${NODE_NAME}: ${NODE_MC} (${NODE_STATE}) -> ${CURRENT_MC} (Done)"
        oc patch "$node" --type=merge -p "{\"metadata\":{\"annotations\":{
            \"machineconfiguration.openshift.io/currentConfig\":\"${CURRENT_MC}\",
            \"machineconfiguration.openshift.io/desiredConfig\":\"${CURRENT_MC}\",
            \"machineconfiguration.openshift.io/state\":\"Done\"}}}"
        FIXED=$((FIXED + 1))
    else
        echo "  ${NODE_NAME}: OK (${NODE_MC}, ${NODE_STATE})"
    fi
done
echo "  Fixed ${FIXED} node(s)"

# Step 3: Approve pending CSRs
echo ""
echo "[3/3] Checking for pending CSRs..."
PENDING=$(oc get csr -o name 2>/dev/null | while read csr; do
    status=$(oc get "$csr" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null)
    if [ -z "$status" ]; then
        echo "$csr"
    fi
done)

if [ -n "$PENDING" ]; then
    echo "$PENDING" | while read csr; do
        echo "  Approving $(basename $csr)..."
        oc adm certificate approve "$(basename $csr)"
    done
else
    echo "  No pending CSRs"
fi

# Verify MCS is serving configs
echo ""
echo "Verifying MCS (port 22623)..."
sleep 2
MCS_CODE=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "https://api-int.gw.lo:22623/config/master" 2>/dev/null || echo "000")
if [ "$MCS_CODE" = "200" ]; then
    echo "  MCS returning 200 OK"
else
    echo "  MCS returning ${MCS_CODE} - may need MCS pod restart"
    echo "  Try: oc delete pod -n openshift-machine-config-operator -l k8s-app=machine-config-server"
fi

echo ""
echo "=== Fix applied ==="
echo "Monitor control0 - it should get its ignition config and boot RHCOS."
echo "Run this script again after control0 joins to approve its CSRs."
