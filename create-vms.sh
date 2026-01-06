#!/bin/bash
# Create VMs for agent-based installation
# Run this once to set up the VM infrastructure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

echo "Creating control plane VMs..."

# Control nodes - same IDs/names/MACs as qpve
create_vm_iso 701 "control0.${BASE_DOMAIN}" "00:50:56:1f:26:26" "$CONTROL_CORES" "$CONTROL_MEMORY"
create_vm_iso 702 "control1.${BASE_DOMAIN}" "00:50:56:1f:27:27" "$CONTROL_CORES" "$CONTROL_MEMORY"
create_vm_iso 703 "control2.${BASE_DOMAIN}" "00:50:56:1f:28:28" "$CONTROL_CORES" "$CONTROL_MEMORY"

echo "Creating worker VMs..."

# Worker nodes - same IDs/names/MACs as qpve
create_vm_iso 704 "worker0.${BASE_DOMAIN}" "00:50:56:1f:30:30" "$WORKER_CORES" "$WORKER_MEMORY"
create_vm_iso 705 "worker1.${BASE_DOMAIN}" "00:50:56:1f:31:31" "$WORKER_CORES" "$WORKER_MEMORY"
create_vm_iso 706 "worker2.${BASE_DOMAIN}" "00:50:56:1f:32:32" "$WORKER_CORES" "$WORKER_MEMORY"

echo "VMs created successfully!"
echo "VM IDs: 701-706"
