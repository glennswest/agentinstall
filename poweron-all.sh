#!/bin/bash
# Power on all cluster VMs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

echo "Powering on all cluster VMs..."

for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweron_vm "$vmid"
done

echo "Done."
