#!/bin/bash
# Agent-based OpenShift installation using FastRegistry + PXE boot
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
    echo "Example: $0 4.18.10"
    echo "Example: $0 4.18.z   # Install latest 4.18.x release"
    echo "Example: $0 4.18     # Install latest 4.18.x release"
    exit 1
fi

OCP_VERSION=$(resolve_latest_version "$1")

echo "=========================================="
echo "Agent-Based OpenShift Installation"
echo "Version: ${OCP_VERSION}"
echo "Registry: ${LOCAL_REGISTRY}"
echo "PXE Manager: ${PXE_MANAGER_URL}"
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

# Pre-flight check: Verify release exists in registry
echo ""
echo "[Pre-flight] Checking release image in FastRegistry..."
RELEASE_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_VERSION}-${ARCHITECTURE}"

# Check release image exists via oc image info (HTTP, no auth needed)
if ! oc image info "${RELEASE_IMAGE}" --insecure >/dev/null 2>&1; then
    echo "ERROR: Release image not found: ${RELEASE_IMAGE}"
    echo "Run mirror first: ./mirror.sh ${OCP_VERSION}"
    exit 1
fi
echo "  ✓ Release image exists"
echo ""
echo "Registry pre-flight checks passed."

# Step 1: Pull installer from FastRegistry
echo ""
echo "[Step 1] Pulling openshift-install from registry..."
"${SCRIPT_DIR}/pull-from-registry.sh" "${OCP_VERSION}"

# Step 2: Prepare installation directory
echo ""
echo "[Step 2] Preparing installation directory..."
rm -rf "${SCRIPT_DIR}/${CLUSTER_NAME}"
mkdir -p "${SCRIPT_DIR}/${CLUSTER_NAME}"

# Copy and prepare install-config
if [ ! -f "${SCRIPT_DIR}/install-config.yaml" ]; then
    echo "ERROR: install-config.yaml not found!"
    echo "Please create install-config.yaml from install-config.yaml.template"
    exit 1
fi

cp "${SCRIPT_DIR}/install-config.yaml" "${SCRIPT_DIR}/${CLUSTER_NAME}/install-config.yaml"
cp "${SCRIPT_DIR}/agent-config.yaml" "${SCRIPT_DIR}/${CLUSTER_NAME}/"

# Step 3: Generate configs locally and create ISO via FastRegistry
echo ""
echo "[Step 3] Generating configs and creating ISO..."

# Generate config-image locally (fast - just creates configs, no ISO download)
# This gives us kubeconfig and state file needed for wait-for commands
echo "Generating local configs (kubeconfig, state file)..."
cd "${SCRIPT_DIR}/${CLUSTER_NAME}"
openshift-install agent create config-image
cd "${SCRIPT_DIR}"
echo "  ✓ Local configs generated"

# POST config files to FastRegistry - it generates the full agent ISO
# This is faster than generating locally since FastRegistry has the base ISO cached
echo "Creating agent ISO via FastRegistry..."
ISO_RESPONSE=$(curl -s -X POST "${FASTREGISTRY_URL}/admin/releases/${OCP_VERSION}-${ARCHITECTURE}/iso" \
    -H "Content-Type: application/json" \
    -d "{
        \"install_config\": $(cat "${SCRIPT_DIR}/install-config.yaml" | jq -Rs),
        \"agent_config\": $(cat "${SCRIPT_DIR}/agent-config.yaml" | jq -Rs)
    }")

# Check for error
if echo "$ISO_RESPONSE" | grep -q '"error"'; then
    echo "ERROR: FastRegistry ISO creation failed:"
    echo "$ISO_RESPONSE" | jq -r '.error'
    exit 1
fi

ISO_URL=$(echo "$ISO_RESPONSE" | jq -r '.full_url // .url')
ISO_ID=$(echo "$ISO_RESPONSE" | jq -r '.id')
echo "  ✓ ISO created: ${ISO_URL}"

# Save ISO URL for reference
echo "$ISO_URL" > "${SCRIPT_DIR}/${CLUSTER_NAME}/.iso_url"

# Step 4: Configure VMs for PXE boot and wipe disks
echo ""
echo "[Step 4] Configuring VMs for PXE boot..."

# Wipe all disks
echo "Wiping disks..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    erase_disk "$vmid"
done

# Verify all disks are wiped
echo "Verifying disks are wiped..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    lvmname="vm-${vmid}-disk-0"
    nonzero=$(ssh root@${PVE_HOST} "dd if=/dev/${LVM_VG}/${lvmname} bs=512 count=1 2>/dev/null | xxd -p | tr -d '\n' | sed 's/0//g'" 2>/dev/null || true)
    if [ -n "$nonzero" ]; then
        echo "ERROR: Disk ${lvmname} still has data! Wipe failed."
        exit 1
    fi
    echo "  ${lvmname}: clean"
done
echo "All disks verified clean."

# Configure VMs for PXE boot
echo "Configuring boot order..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    configure_pxe_boot "$vmid"
done

# Step 5: Register ISO and hosts with PXE Manager
echo ""
echo "[Step 5] Configuring PXE Manager..."

# Create unique image name for this install
ISO_IMAGE_NAME="ocp-${OCP_VERSION}-$(date +%Y%m%d%H%M%S)"

# Add ISO to PXE Manager
echo "Registering ISO with PXE Manager..."
pxe_add_iso "$ISO_IMAGE_NAME" "$ISO_URL"
echo "  ✓ ISO registered as: ${ISO_IMAGE_NAME}"

# Parse agent-config.yaml to get host MACs and hostnames
echo "Registering hosts with PXE Manager..."
python3 -c "
import yaml
import subprocess
import os

pxe_url = os.environ.get('PXE_MANAGER_URL', 'http://pxe.g10.lo:8080')
image_name = '${ISO_IMAGE_NAME}'

with open('${SCRIPT_DIR}/agent-config.yaml') as f:
    config = yaml.safe_load(f)

for host in config.get('hosts', []):
    hostname = host.get('hostname', '')
    for iface in host.get('interfaces', []):
        mac = iface.get('macAddress', '')
        if mac:
            # Add host to PXE Manager
            subprocess.run([
                'curl', '-s', '-X', 'POST', f'{pxe_url}/api/hosts',
                '-H', 'Content-Type: application/json',
                '-d', '{\"mac\": \"' + mac + '\", \"hostname\": \"' + hostname + '\", \"current_image\": \"' + image_name + '\"}'
            ], capture_output=True)
            print(f'  ✓ {hostname} ({mac})')
            break
"

# Step 6: Setup kubeconfig
echo ""
echo "[Step 6] Setting up kubeconfig..."
mkdir -p "${KUBECONFIG_DIR}"
rm -f "${KUBECONFIG_DIR}/config"
cp "${SCRIPT_DIR}/${CLUSTER_NAME}/auth/kubeconfig" "${KUBECONFIG_DIR}/config"

# Remove config files from cluster work directory
rm -f "${SCRIPT_DIR}/${CLUSTER_NAME}/install-config.yaml" "${SCRIPT_DIR}/${CLUSTER_NAME}/agent-config.yaml"

# Step 7: Power on all nodes
echo ""
echo "[Step 7] Starting all nodes (PXE boot)..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweron_vm "$vmid"
done

# Start monitor GUI in background
echo ""
echo "Starting installation monitor..."
"${SCRIPT_DIR}/venv/bin/python3" "${SCRIPT_DIR}/monitor.py" &
disown 2>/dev/null || true

# Step 8: Wait for bootstrap completion
echo ""
echo "[Step 8] Waiting for bootstrap to complete..."

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
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/${CLUSTER_NAME}" agent wait-for bootstrap-complete
else
    openshift-install --dir="${SCRIPT_DIR}/${CLUSTER_NAME}" agent wait-for bootstrap-complete
fi

# Step 8.5: Fix MachineConfig bootstrap desync
echo ""
echo "[Step 8.5] Applying MachineConfig bootstrap desync fix..."
MC_FIX_RETRIES=0
MC_FIX_MAX=12  # 2 minutes max (12 x 10s)
while [ $MC_FIX_RETRIES -lt $MC_FIX_MAX ]; do
    if KUBECONFIG="${SCRIPT_DIR}/${CLUSTER_NAME}/auth/kubeconfig" oc get mcp master >/dev/null 2>&1; then
        "${SCRIPT_DIR}/fix-mc-desync.sh"
        break
    fi
    MC_FIX_RETRIES=$((MC_FIX_RETRIES + 1))
    echo "  Waiting for API... (${MC_FIX_RETRIES}/${MC_FIX_MAX})"
    sleep 10
done
if [ $MC_FIX_RETRIES -ge $MC_FIX_MAX ]; then
    echo "WARNING: Could not apply MC desync fix (API not reachable)"
    echo "Run manually: ./fix-mc-desync.sh"
fi

# Step 9: Wait for install completion
echo ""
echo "[Step 9] Waiting for installation to complete..."
if command -v stdbuf &>/dev/null; then
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/${CLUSTER_NAME}" agent wait-for install-complete
else
    openshift-install --dir="${SCRIPT_DIR}/${CLUSTER_NAME}" agent wait-for install-complete
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
