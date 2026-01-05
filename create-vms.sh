#!/bin/bash
# Create VMs for agent-based installation
# Run this once to set up the VM infrastructure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

echo "Creating control plane VMs..."

# Control nodes - MAC addresses in sequence
create_vm_iso 750 "control0.${BASE_DOMAIN}" "00:50:56:1f:a0:50" "$CONTROL_CORES" "$CONTROL_MEMORY"
create_vm_iso 751 "control1.${BASE_DOMAIN}" "00:50:56:1f:a0:51" "$CONTROL_CORES" "$CONTROL_MEMORY"
create_vm_iso 752 "control2.${BASE_DOMAIN}" "00:50:56:1f:a0:52" "$CONTROL_CORES" "$CONTROL_MEMORY"

echo "Creating worker VMs..."

# Worker nodes
create_vm_iso 753 "worker0.${BASE_DOMAIN}" "00:50:56:1f:a0:53" "$WORKER_CORES" "$WORKER_MEMORY"
create_vm_iso 754 "worker1.${BASE_DOMAIN}" "00:50:56:1f:a0:54" "$WORKER_CORES" "$WORKER_MEMORY"
create_vm_iso 755 "worker2.${BASE_DOMAIN}" "00:50:56:1f:a0:55" "$WORKER_CORES" "$WORKER_MEMORY"

echo "VMs created successfully!"
echo "VM IDs: 750-755"
