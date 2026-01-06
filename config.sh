#!/bin/bash
# Configuration for agent-based OpenShift installation
# Uses local registry at registry.gw.lo

# Paths (relative to config.sh location)
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Registry settings
export LOCAL_REGISTRY='registry.gw.lo'
export LOCAL_REPOSITORY='openshift/release'
export RELEASE_NAME="ocp-release"
export ARCHITECTURE='x86_64'

# Registry credentials (loaded from .env file)
if [[ -f "${CONFIG_DIR}/.env" ]]; then
    source "${CONFIG_DIR}/.env"
    export REGISTRY_USER
    export REGISTRY_PASSWORD
else
    echo "Warning: .env file not found. Run ./generate-secrets.sh to create it." >&2
fi
export PULL_SECRET_JSON="${CONFIG_DIR}/pullsecret.json"
export KUBECONFIG_DIR="${HOME}/.kube"

# Proxmox settings
export PVE_HOST='pve.gw.lo'
export PVE_USER='root'
export ISO_PATH='/var/lib/vz/template/iso'
export ISO_NAME='coreos-x86_64.iso'

# LVM settings (same as qpve - production-lvm, thick provisioned)
export LVM_VG='production-lvm'
export LVM_STORAGE='production-lvm'
export DEFAULT_DISK_SIZE='100G'

# Cluster settings
export CLUSTER_NAME='gw'
export BASE_DOMAIN='gw.lo'
export RENDEZVOUS_IP='192.168.1.201'

# VM ID ranges (same as qpve: 700-706)
export BOOTSTRAP_VM_ID=700
export CONTROL_VM_IDS=(701 702 703)
export WORKER_VM_IDS=(704 705 706)

# VM specs
export CONTROL_CORES=8
export CONTROL_MEMORY=17000
export WORKER_CORES=4
export WORKER_MEMORY=16000

# Network
export NETWORK_BRIDGE='vmbr0'
