#!/bin/bash
# Delete all VMs created for agent-based installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

echo "Deleting cluster VMs..."

for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    delete_vm "$vmid" || true
done

echo "VMs deleted."
