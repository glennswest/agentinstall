#!/bin/bash
# Agent-based OpenShift installation using local registry
# Usage: ./install.sh <version>
# Example: ./install.sh 4.14.10

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

if [ -z "$1" ]; then
    echo "Usage: $0 <ocp-version>"
    echo "Example: $0 4.14.10"
    exit 1
fi

OCP_VERSION="$1"

echo "=========================================="
echo "Agent-Based OpenShift Installation"
echo "Version: ${OCP_VERSION}"
echo "Registry: ${LOCAL_REGISTRY}"
echo "=========================================="

# Start VM poweroff immediately in background (gives time to shut down)
VM_PREP_LOG=$(mktemp)
(
    echo "Powering off VMs..."
    for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
        poweroff_vm "$vmid" 2>/dev/null || true
    done
) > "$VM_PREP_LOG" 2>&1 &
VM_POWEROFF_PID=$!

# Step 1: Pull installer from local registry
echo ""
echo "[Step 1] Pulling openshift-install from registry..."
"${SCRIPT_DIR}/pull-from-registry.sh" "${OCP_VERSION}"

# Step 2: Prepare installation directory
echo ""
echo "[Step 2] Preparing installation directory..."
rm -rf "${SCRIPT_DIR}/gw"
mkdir -p "${SCRIPT_DIR}/gw"

# Clean up old ISO from Proxmox to ensure fresh generation
ssh root@${PVE_HOST} "rm -f /var/lib/vz/template/iso/coreos-x86_64.iso" 2>/dev/null || true

# Copy and prepare install-config
if [ ! -f "${SCRIPT_DIR}/install-config.yaml" ]; then
    echo "ERROR: install-config.yaml not found!"
    echo "Please create install-config.yaml from install-config.yaml.template"
    exit 1
fi

cp "${SCRIPT_DIR}/install-config.yaml" "${SCRIPT_DIR}/gw/install-config.yaml"
cp "${SCRIPT_DIR}/agent-config.yaml" "${SCRIPT_DIR}/gw/"

# Step 3: Create agent ISO AND prepare VMs in parallel
echo ""
echo "[Step 3] Creating agent ISO..."

# Wait for VM poweroff to complete (started at script beginning)
wait $VM_POWEROFF_PID

# Start disk wipe in background (runs parallel to ISO generation)
(
    sleep 5  # Extra time for VMs to fully stop
    echo ""
    echo "Wiping disks..."
    for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
        erase_disk "$vmid" || true
    done
) >> "$VM_PREP_LOG" 2>&1 &
VM_PREP_PID=$!

# Generate ISO (foreground so we see progress)
if generate_iso_remote "${OCP_VERSION}" "${SCRIPT_DIR}/gw/install-config.yaml" "${SCRIPT_DIR}/gw/agent-config.yaml"; then
    echo "Remote ISO generation successful"
else
    echo "Remote generation failed, falling back to local..."
    cd "${SCRIPT_DIR}/gw"
    openshift-install agent create image
    cd "${SCRIPT_DIR}"
    echo "Uploading agent ISO to Proxmox..."
    upload_iso "${SCRIPT_DIR}/gw/agent.x86_64.iso"
fi

# Remove config files from gw directory - they're consumed during ISO generation
# and their presence causes conflicts with the state file during wait-for commands
rm -f "${SCRIPT_DIR}/gw/install-config.yaml" "${SCRIPT_DIR}/gw/agent-config.yaml"

# Wait for VM preparation and show output
wait $VM_PREP_PID
echo ""
echo "[Step 3b] VM preparation (ran in parallel):"
cat "$VM_PREP_LOG"
rm -f "$VM_PREP_LOG"

# Step 4: Setup kubeconfig
echo ""
echo "[Step 4] Setting up kubeconfig..."
mkdir -p "${KUBECONFIG_DIR}"
rm -f "${KUBECONFIG_DIR}/config"
cp "${SCRIPT_DIR}/gw/auth/kubeconfig" "${KUBECONFIG_DIR}/config"

# Step 5: Verify ISO and power on all nodes
echo ""
echo "[Step 5] Verifying ISO before starting nodes..."
ISO_SIZE=$(ssh root@${PVE_HOST} "stat -c%s ${ISO_PATH}/${ISO_NAME} 2>/dev/null || echo 0")
if [ "$ISO_SIZE" -lt 1000000000 ]; then
    echo "ERROR: ISO missing or too small on Proxmox (${ISO_SIZE} bytes)"
    exit 1
fi
echo "ISO verified: ${ISO_SIZE} bytes on ${PVE_HOST}"

echo ""
echo "[Step 5] Starting all nodes..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweron_vm "$vmid"
done

# Start monitor GUI in background
echo ""
echo "Starting installation monitor..."
"${SCRIPT_DIR}/venv/bin/python3" "${SCRIPT_DIR}/monitor.py" &
disown 2>/dev/null || true

# Step 6: Wait for bootstrap completion
echo ""
echo "[Step 6] Waiting for bootstrap to complete..."

# Check for kube-apiserver crash loop (bad ISO detection)
echo "Checking for bootkube health..."
KUBE_ERROR_COUNT=0
for i in {1..6}; do
    sleep 30
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
       core@${RENDEZVOUS_IP} "sudo journalctl -u bootkube.service --no-pager 2>/dev/null | grep -q 'missing operand kubernetes version'" 2>/dev/null; then
        KUBE_ERROR_COUNT=$((KUBE_ERROR_COUNT + 1))
        echo "Warning: kube-apiserver render failing ($KUBE_ERROR_COUNT/3)"
        if [ $KUBE_ERROR_COUNT -ge 3 ]; then
            echo ""
            echo "ERROR: kube-apiserver is crash-looping with 'missing operand kubernetes version'"
            echo "This indicates the ISO was generated with a mismatched openshift-install binary."
            echo "Fix: Re-extract openshift-install from registry and regenerate ISO"
            echo ""
            exit 1
        fi
    else
        break
    fi
done

openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for bootstrap-complete

# Step 7: Wait for install completion
echo ""
echo "[Step 7] Waiting for installation to complete..."
openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for install-complete

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "Kubeconfig: ${KUBECONFIG_DIR}/config"
echo "=========================================="
