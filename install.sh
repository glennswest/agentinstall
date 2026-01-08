#!/bin/bash
# Agent-based OpenShift installation using local registry
# Usage: ./install.sh <version>
# Example: ./install.sh 4.14.10

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

# Add ~/.local/bin to PATH for openshift-install
export PATH="${HOME}/.local/bin:${PATH}"

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

# Record install start
record_install_start "${OCP_VERSION}"

# Trap to record failure on exit
trap 'if [ $? -ne 0 ]; then record_install_end false; fi' EXIT

# Step 0: Stop all VMs first (must complete before anything else)
echo ""
echo "[Step 0] Stopping all VMs..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweroff_vm "$vmid"
done

# Verify all VMs are stopped
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    status=$(ssh root@${PVE_HOST} "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
    if [ "$status" != "stopped" ]; then
        echo "ERROR: VM ${vmid} is still ${status}! Cannot proceed."
        exit 1
    fi
done
echo "All VMs stopped."

# Pre-flight check: Verify key registry artifacts exist
echo ""
echo "[Pre-flight] Checking registry artifacts..."
REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
RELEASE_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_VERSION}-${ARCHITECTURE}"

# Check release image exists
if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@${REGISTRY_HOST}" "oc image info ${RELEASE_IMAGE} --insecure >/dev/null 2>&1"; then
    echo "ERROR: Release image not found: ${RELEASE_IMAGE}"
    echo "Run mirror first to sync the release to your registry."
    exit 1
fi
echo "  ✓ Release image exists"

# Get machine-os-images digest and verify it exists
MOS_DIGEST=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@${REGISTRY_HOST}" "oc adm release info ${RELEASE_IMAGE} --insecure 2>/dev/null | grep machine-os-images | awk '{print \$2}'" 2>/dev/null)
if [ -n "$MOS_DIGEST" ]; then
    MOS_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}@${MOS_DIGEST}"
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@${REGISTRY_HOST}" "oc image info ${MOS_IMAGE} --insecure >/dev/null 2>&1"; then
        echo "ERROR: machine-os-images not found: ${MOS_IMAGE}"
        echo "This component is required for ISO generation."
        echo "Re-run mirror to sync all release components."
        exit 1
    fi
    echo "  ✓ machine-os-images exists"
else
    echo "  ! Could not verify machine-os-images (may be older release)"
fi

echo "Registry pre-flight checks passed."

# Step 1: Pull installer from local registry
echo ""
echo "[Step 1] Pulling openshift-install from registry..."
"${SCRIPT_DIR}/pull-from-registry.sh" "${OCP_VERSION}"

# Step 2: Prepare installation directory
echo ""
echo "[Step 2] Preparing installation directory..."
rm -rf "${SCRIPT_DIR}/gw"
mkdir -p "${SCRIPT_DIR}/gw"

# Copy and prepare install-config
if [ ! -f "${SCRIPT_DIR}/install-config.yaml" ]; then
    echo "ERROR: install-config.yaml not found!"
    echo "Please create install-config.yaml from install-config.yaml.template"
    exit 1
fi

cp "${SCRIPT_DIR}/install-config.yaml" "${SCRIPT_DIR}/gw/install-config.yaml"
cp "${SCRIPT_DIR}/agent-config.yaml" "${SCRIPT_DIR}/gw/"

# Step 3: Create agent ISO and prepare VMs
echo ""
echo "[Step 3] Creating agent ISO..."

# Delete old ISO from Proxmox (VMs already stopped in Step 0)
echo "Deleting old ISO from Proxmox..."
ssh root@${PVE_HOST} "rm -f ${ISO_PATH}/${ISO_NAME}"

# Wipe all disks (must complete before ISO generation to ensure clean state)
echo "Wiping disks..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    erase_disk "$vmid"
done

# Verify all disks are wiped (check first 512 bytes are zero - no MBR/GPT)
echo "Verifying disks are wiped..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    lvmname="vm-${vmid}-disk-0"
    # Check if disk has any non-zero bytes in first 512 bytes
    nonzero=$(ssh root@${PVE_HOST} "dd if=/dev/${LVM_VG}/${lvmname} bs=512 count=1 2>/dev/null | xxd -p | tr -d '\n' | sed 's/0//g'" 2>/dev/null || true)
    if [ -n "$nonzero" ]; then
        echo "ERROR: Disk ${lvmname} still has data! Wipe failed."
        exit 1
    fi
    echo "  ${lvmname}: clean"
done
echo "All disks verified clean."

# Generate ISO (foreground so we see progress)
generate_iso_remote "${OCP_VERSION}" "${SCRIPT_DIR}/gw/install-config.yaml" "${SCRIPT_DIR}/gw/agent-config.yaml"
ISO_RESULT=$?
if [ $ISO_RESULT -eq 0 ]; then
    echo "Remote ISO generation successful"
elif [ $ISO_RESULT -eq 2 ]; then
    echo "ERROR: ISO checksum verification failed - aborting"
    exit 1
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


# Step 4: Setup kubeconfig
echo ""
echo "[Step 4] Setting up kubeconfig..."
mkdir -p "${KUBECONFIG_DIR}"
rm -f "${KUBECONFIG_DIR}/config"
cp "${SCRIPT_DIR}/gw/auth/kubeconfig" "${KUBECONFIG_DIR}/config"

# Step 5: Verify ISO checksum and power on all nodes
echo ""
echo "[Step 5] Verifying ISO checksum before starting nodes..."
EXPECTED_CHECKSUM=$(cat "${SCRIPT_DIR}/gw/.iso_checksum" 2>/dev/null || echo "")
if [ -z "$EXPECTED_CHECKSUM" ]; then
    echo "WARNING: No saved checksum found, using size check only"
    ISO_SIZE=$(ssh root@${PVE_HOST} "stat -c%s ${ISO_PATH}/${ISO_NAME} 2>/dev/null || echo 0")
    if [ "$ISO_SIZE" -lt 1000000000 ]; then
        echo "ERROR: ISO missing or too small on Proxmox (${ISO_SIZE} bytes)"
        exit 1
    fi
    echo "ISO size verified: ${ISO_SIZE} bytes"
else
    ACTUAL_CHECKSUM=$(ssh root@${PVE_HOST} "sha256sum ${ISO_PATH}/${ISO_NAME} 2>/dev/null | cut -d' ' -f1 || echo ''")
    if [ -z "$ACTUAL_CHECKSUM" ]; then
        echo "ERROR: ISO missing on Proxmox!"
        exit 1
    fi
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        echo "ERROR: ISO checksum mismatch!"
        echo "  Expected: ${EXPECTED_CHECKSUM}"
        echo "  Actual:   ${ACTUAL_CHECKSUM}"
        echo "The ISO on Proxmox does not match the generated ISO."
        exit 1
    fi
    echo "ISO checksum verified: ${ACTUAL_CHECKSUM:0:16}..."
fi

echo ""
echo "[Step 5] Attaching ISO and starting all nodes..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    attach_iso "$vmid"
done

# Verify ISO is attached to all VMs
echo "Verifying ISO attachment..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    ide2=$(ssh root@${PVE_HOST} "qm config ${vmid} | grep ide2")
    if ! echo "$ide2" | grep -q "${ISO_NAME}"; then
        echo "ERROR: ISO not attached to VM ${vmid}!"
        echo "  Got: $ide2"
        exit 1
    fi
    echo "  VM ${vmid}: ISO attached"
done

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

# Use stdbuf to force line buffering on output
if command -v stdbuf &>/dev/null; then
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for bootstrap-complete
else
    openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for bootstrap-complete
fi

# Step 6.5: Hold control0 while control1/control2 stabilize
echo ""
echo "[Step 6.5] Holding control0 to let control1/control2 stabilize..."
CONTROL0_HOSTNAME="control0.gw.lo"
for i in {1..30}; do
    CURRENT_RENDERED=$(oc get mc -o name 2>/dev/null | grep rendered-master | head -1 | sed 's|machineconfig.machineconfiguration.openshift.io/||')
    if [ -n "$CURRENT_RENDERED" ]; then
        if oc get node "$CONTROL0_HOSTNAME" &>/dev/null; then
            oc patch node "$CONTROL0_HOSTNAME" --type merge -p "{\"metadata\":{\"annotations\":{\"machineconfiguration.openshift.io/desiredConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/currentConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/state\":\"Done\",\"machineconfiguration.openshift.io/reason\":\"\"}}}" 2>/dev/null && echo "  control0 held (state=Done)" && break
        fi
    fi
    sleep 5
done

# Wait for control1/control2 to be Ready
echo "Waiting for control1/control2 to be Ready..."
for i in {1..60}; do
    READY_COUNT=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    echo "  Control plane nodes Ready: ${READY_COUNT}/3"
    if [ "$READY_COUNT" -ge 2 ]; then
        break
    fi
    sleep 10
done

# Wait for MCO to stabilize on control1/control2
echo "Waiting for MCO to stabilize..."
for i in {1..60}; do
    DEGRADED=$(oc get mcp master -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "unknown")
    UPDATED=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "unknown")
    echo "  Master MCP: degraded=${DEGRADED}, updated=${UPDATED}"
    if [ "$DEGRADED" = "0" ] && [ "$UPDATED" = "True" ]; then
        echo "  Master MCP healthy"
        break
    fi
    sleep 10
done

# Release control0
echo "Releasing control0 for MCD processing..."
oc annotate node "$CONTROL0_HOSTNAME" machineconfiguration.openshift.io/state- 2>/dev/null || true

# Step 7: Wait for install completion
echo ""
echo "[Step 7] Waiting for installation to complete..."
if command -v stdbuf &>/dev/null; then
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for install-complete
else
    openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for install-complete
fi

# Record successful install
record_install_end true

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "Kubeconfig: ${KUBECONFIG_DIR}/config"
echo "=========================================="

# Show install history
show_install_history
