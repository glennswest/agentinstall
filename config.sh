#!/bin/bash
# Configuration for agent-based OpenShift installation
# Uses local registry at registry.gw.lo

# Registry settings
export LOCAL_REGISTRY='registry.gw.lo:8443'
export LOCAL_REPOSITORY='ocp4/openshift4'
export RELEASE_NAME="ocp-release"
export ARCHITECTURE='x86_64'

# Registry credentials (update these or use pull-secret file)
export REGISTRY_USER='init'
export REGISTRY_PASSWORD='REDACTED'

# Paths
export PULL_SECRET_JSON="${HOME}/gw.lo/pull-secret-registry.txt"
export KUBECONFIG_DIR="${HOME}/.kube"

# Proxmox settings
export PVE_HOST='pve.gw.lo'
export PVE_USER='root'
export ISO_PATH='/var/lib/vz/template/iso'
export ISO_NAME='coreos-x86_64.iso'

# LVM settings
export LVM_POOL='test-lvm-thin/test-lvm-thin'
export DEFAULT_DISK_SIZE='200G'

# Cluster settings
export CLUSTER_NAME='gw'
export BASE_DOMAIN='gw.lo'
export RENDEZVOUS_IP='192.168.1.201'

# VM ID ranges (separate from qpve's 700-714)
export CONTROL_VM_IDS=(750 751 752)
export WORKER_VM_IDS=(753 754 755)

# VM specs
export CONTROL_CORES=8
export CONTROL_MEMORY=17000
export WORKER_CORES=4
export WORKER_MEMORY=16000

# Network
export NETWORK_BRIDGE='vmbr0'
