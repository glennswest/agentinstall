#!/bin/bash
# VM management library functions
# Source this file in other scripts

VM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${VM_LIB_DIR}/../config.sh"

# Get VM ID by name or return the ID if already numeric
get_vmid() {
    local input="$1"
    local vmid
    vmid=$(ssh "${PVE_USER}@${PVE_HOST}" "qm list | grep '$input' | awk '{print \$1}'" 2>/dev/null)
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

# Power on a VM
poweron_vm() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Powering on VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm start ${vmid}"
}

# Power off a VM
poweroff_vm() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Powering off VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm stop ${vmid}" 2>/dev/null || true
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

# Erase disk for VM (reinitialize)
erase_disk() {
    local vmid
    vmid=$(get_vmid "$1")
    local disktype
    disktype=$(get_disktype "$vmid")

    case "$disktype" in
        lvm)
            echo "Erasing LVM disk for VM ${vmid}..."
            create_lvm "$vmid" "$DEFAULT_DISK_SIZE"
            ;;
        qcow)
            echo "Erasing qcow disk for VM ${vmid}..."
            # Add qcow handling if needed
            ;;
        *)
            echo "ERROR: Unknown disk type for VM ${vmid}"
            return 1
            ;;
    esac
}

# Create a VM with ISO boot
create_vm_iso() {
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

    # Create VM
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
        --ide2 local:iso/${ISO_NAME},media=cdrom \
        --bootdisk scsi0 \
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

# Upload ISO to Proxmox
upload_iso() {
    local iso_path="$1"
    echo "Uploading ISO to Proxmox..."
    scp "$iso_path" "${PVE_USER}@${PVE_HOST}:${ISO_PATH}/${ISO_NAME}"
}
