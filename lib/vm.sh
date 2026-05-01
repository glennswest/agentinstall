#!/bin/bash
# VM management library functions
# Source this file in other scripts

VM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${VM_LIB_DIR}/../config.sh"

# Get VM ID by name or return the ID if already numeric
get_vmid() {
    local input="$1"
    # If input is numeric, just return it directly
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return
    fi
    # Otherwise lookup by name
    local vmid
    vmid=$(ssh "${PVE_USER}@${PVE_HOST}" "qm list | grep -w '$input' | awk '{print \$1}'" 2>/dev/null)
    if [ -z "${vmid}" ]; then
        vmid="$input"
    fi
    echo "$vmid"
}

# Get disk type for a VM (lvm or qcow)
get_disktype() {
    local vmid="$1"
    local conf
    conf=$(ssh "${PVE_USER}@${PVE_HOST}" "cat /etc/pve/qemu-server/${vmid}.conf 2>/dev/null")
    if echo "$conf" | grep -q "qcow"; then
        echo "qcow"
    elif echo "$conf" | grep -q "${LVM_STORAGE}"; then
        echo "lvm"
    else
        echo "none"
    fi
}

# Configure VM for PXE boot (network first, then disk, remove IDE)
configure_pxe_boot() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Configuring VM ${vmid} for PXE boot..."
    ssh "${PVE_USER}@${PVE_HOST}" "
        qm set ${vmid} --boot order=net0\\;scsi0
        qm set ${vmid} --delete ide2 2>/dev/null || true
    "
}

# Power on a VM
poweron_vm() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Powering on VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm start ${vmid}"
}

# Power off a VM and wait until stopped
poweroff_vm() {
    local vmid
    vmid=$(get_vmid "$1")
    local status

    # Check if already stopped
    status=$(ssh "${PVE_USER}@${PVE_HOST}" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
    if [ "$status" = "stopped" ]; then
        echo "VM ${vmid} already stopped"
        return 0
    fi

    echo "Powering off VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm stop ${vmid}" 2>/dev/null || true

    # Wait for VM to actually stop (max 60 seconds)
    local count=0
    while [ $count -lt 60 ]; do
        status=$(ssh "${PVE_USER}@${PVE_HOST}" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
        if [ "$status" = "stopped" ]; then
            echo "VM ${vmid} stopped"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    echo "WARNING: VM ${vmid} did not stop within 60 seconds"
    return 1
}

# Create LVM disk for VM (thick provisioned, same as qpve)
create_lvm() {
    local vmid="$1"
    local size="${2:-$DEFAULT_DISK_SIZE}"
    local lvmname="vm-${vmid}-disk-0"
    local drivepath="/dev/${LVM_VG}/${lvmname}"

    echo "Creating LVM disk ${lvmname} (${size})..."
    ssh "${PVE_USER}@${PVE_HOST}" "lvremove ${drivepath} -y 2>/dev/null || true"
    ssh "${PVE_USER}@${PVE_HOST}" "lvcreate --yes --wipesignatures y -L${size} -n ${lvmname} ${LVM_VG}"
}

# Erase disk for VM (wipe first 100MB to clear partitions/signatures)
erase_disk() {
    local vmid
    vmid=$(get_vmid "$1")
    local lvmname="vm-${vmid}-disk-0"
    local drivepath="/dev/${LVM_VG}/${lvmname}"

    echo "Wiping disk for VM ${vmid}..."
    # Recreate LV to ensure clean state (handles both thick and thin provisioned)
    ssh "${PVE_USER}@${PVE_HOST}" "
        if lvs ${LVM_VG}/${lvmname} >/dev/null 2>&1; then
            lvremove -f ${LVM_VG}/${lvmname} 2>/dev/null
        fi
        lvcreate -y -L ${DEFAULT_DISK_SIZE} -n ${lvmname} ${LVM_VG} >/dev/null 2>&1
    " || echo "Warning: Could not recreate ${lvmname}"
    echo "Disk recreated: ${lvmname}"
}

# Create a VM with PXE boot
create_vm_pxe() {
    local vmid="$1"
    local name="$2"
    local mac="$3"
    local cores="${4:-$CONTROL_CORES}"
    local memory="${5:-$CONTROL_MEMORY}"
    local disksize="${6:-$DEFAULT_DISK_SIZE}"
    local lvmname="vm-${vmid}-disk-0"

    echo "Creating VM ${vmid} (${name})..."

    # Create LVM disk
    create_lvm "$vmid" "$disksize"

    # Create VM with network boot
    ssh "${PVE_USER}@${PVE_HOST}" "qm create ${vmid} \
        --machine q35 \
        --name ${name} \
        --numa 0 \
        --ostype l26 \
        --cpu cputype=host \
        --cores ${cores} \
        --sockets 1 \
        --memory ${memory} \
        --net0 bridge=${NETWORK_BRIDGE},virtio=${mac} \
        --boot order=net0\\;scsi0 \
        --scsihw virtio-scsi-single \
        --scsi0 ${LVM_STORAGE}:${lvmname},size=${disksize}"
}

# Delete a VM
delete_vm() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Deleting VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm stop ${vmid}" 2>/dev/null || true
    ssh "${PVE_USER}@${PVE_HOST}" "qm destroy ${vmid}" 2>/dev/null || true
}

# --- PXE Manager API Functions ---

# Add or update a host in PXE Manager
pxe_add_host() {
    local mac="$1"
    local hostname="$2"
    local image="${3:-}"

    echo "Adding host ${hostname} (${mac}) to PXE Manager..."
    curl -s -X POST "${PXE_MANAGER_URL}/api/hosts" \
        -H "Content-Type: application/json" \
        -d "{\"mac\": \"${mac}\", \"hostname\": \"${hostname}\", \"current_image\": \"${image}\"}" \
        >/dev/null
}

# Set boot image for a host
pxe_set_image() {
    local mac="$1"
    local image="$2"

    echo "Setting boot image for ${mac} to ${image}..."
    curl -s -X POST "${PXE_MANAGER_URL}/api/host?mac=${mac}&action=set_image" \
        -d "image=${image}" \
        >/dev/null
}

# Add an ISO image to PXE Manager
pxe_add_iso() {
    local name="$1"
    local url="$2"

    echo "Adding ISO ${name} to PXE Manager..."
    curl -s -X POST "${PXE_MANAGER_URL}/api/image/iso" \
        -d "name=${name}" \
        -d "url=${url}"
}

# List hosts in PXE Manager
pxe_list_hosts() {
    curl -s "${PXE_MANAGER_URL}/api/hosts"
}
