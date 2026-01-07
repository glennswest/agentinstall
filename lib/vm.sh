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

# Attach ISO to a VM
attach_iso() {
    local vmid
    vmid=$(get_vmid "$1")
    echo "Attaching ISO to VM ${vmid}..."
    ssh "${PVE_USER}@${PVE_HOST}" "qm set ${vmid} --ide2 local:iso/${ISO_NAME},media=cdrom"
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

# Upload ISO to Proxmox with compression (fallback if remote generation fails)
upload_iso() {
    local iso_path="$1"
    echo "Uploading ISO to Proxmox (with compression)..."
    scp -O -C "$iso_path" "${PVE_USER}@${PVE_HOST}:${ISO_PATH}/${ISO_NAME}"
    echo "ISO uploaded: ${ISO_PATH}/${ISO_NAME}"
}

# Generate agent ISO on registry server (much faster - local registry access, local Proxmox copy)
# Returns kubeconfig path on success
generate_iso_remote() {
    local version="$1"
    local install_config="$2"
    local agent_config="$3"
    local registry_host="${LOCAL_REGISTRY%%:*}"
    local remote_dir="/tmp/agent-install-$$"
    local cache_dir="/var/lib/openshift-cache"
    local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    echo "Generating agent ISO on registry server (faster)..."

    # Check if openshift-install is cached on registry
    if ! ssh $SSH_OPTS "root@${registry_host}" "test -x ${cache_dir}/openshift-install-${version}"; then
        echo "ERROR: openshift-install-${version} not cached on registry"
        echo "Run mirror first, or fall back to local generation"
        return 1
    fi

    # Create remote working directory
    ssh $SSH_OPTS "root@${registry_host}" "mkdir -p ${remote_dir}"

    # Copy configs to registry (small files, fast)
    # Use -O for legacy SCP protocol (SFTP not enabled on registry)
    scp -O -q $SSH_OPTS "$install_config" "root@${registry_host}:${remote_dir}/install-config.yaml"
    scp -O -q $SSH_OPTS "$agent_config" "root@${registry_host}:${remote_dir}/agent-config.yaml"

    # Generate ISO on registry server
    echo "Running openshift-install on registry server..."
    ssh $SSH_OPTS "root@${registry_host}" "cd ${remote_dir} && ${cache_dir}/openshift-install-${version} agent create image"

    # Verify base ISO in cache matches expected checksum
    echo "Verifying base ISO checksum..."
    local base_iso_ok
    base_iso_ok=$(ssh $SSH_OPTS "root@${registry_host}" '
        EXPECTED=$(python3 -c "import json; d=json.load(open(\"/root/.cache/agent/files_cache/coreos-stream.json\")); print(d[\"architectures\"][\"x86_64\"][\"artifacts\"][\"metal\"][\"formats\"][\"iso\"][\"disk\"][\"sha256\"])")
        ACTUAL=$(sha256sum /root/.cache/agent/image_cache/coreos-x86_64.iso | cut -d" " -f1)
        if [ "$EXPECTED" = "$ACTUAL" ]; then
            echo "OK"
        else
            echo "MISMATCH: expected $EXPECTED, got $ACTUAL"
        fi
    ')
    if [[ "$base_iso_ok" != "OK" ]]; then
        echo "ERROR: Base ISO checksum mismatch!"
        echo "$base_iso_ok"
        return 1
    fi
    echo "Base ISO checksum verified: OK"

    # Get checksum of generated agent ISO on registry (BEFORE copy)
    echo "Calculating agent ISO checksum on registry..."
    local source_checksum
    source_checksum=$(ssh $SSH_OPTS "root@${registry_host}" "sha256sum ${remote_dir}/agent.x86_64.iso | cut -d' ' -f1")
    if [ -z "$source_checksum" ]; then
        echo "ERROR: Failed to calculate source ISO checksum"
        return 1
    fi
    echo "Source ISO checksum: ${source_checksum}"

    # Copy ISO directly to Proxmox (local network, fast)
    echo "Copying ISO to Proxmox..."
    ssh $SSH_OPTS "root@${registry_host}" "scp -O -o StrictHostKeyChecking=no ${remote_dir}/agent.x86_64.iso ${PVE_USER}@${PVE_HOST}:${ISO_PATH}/${ISO_NAME}"

    # Verify ISO checksum on Proxmox matches source (AFTER copy)
    echo "Verifying ISO checksum on Proxmox..."
    local dest_checksum
    dest_checksum=$(ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "sha256sum ${ISO_PATH}/${ISO_NAME} | cut -d' ' -f1")
    if [ -z "$dest_checksum" ]; then
        echo "ERROR: Failed to calculate destination ISO checksum"
        return 1
    fi
    echo "Destination ISO checksum: ${dest_checksum}"

    if [ "$source_checksum" != "$dest_checksum" ]; then
        echo "ERROR: ISO checksum mismatch after copy!"
        echo "  Source (registry): ${source_checksum}"
        echo "  Dest (Proxmox):    ${dest_checksum}"
        echo "Retrying copy..."
        ssh $SSH_OPTS "root@${registry_host}" "scp -O -o StrictHostKeyChecking=no ${remote_dir}/agent.x86_64.iso ${PVE_USER}@${PVE_HOST}:${ISO_PATH}/${ISO_NAME}"
        dest_checksum=$(ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "sha256sum ${ISO_PATH}/${ISO_NAME} | cut -d' ' -f1")
        if [ "$source_checksum" != "$dest_checksum" ]; then
            echo "ERROR: ISO checksum still mismatched after retry!"
            return 2  # Return 2 for checksum errors (don't fallback)
        fi
    fi
    echo "ISO checksum verified: OK"

    # Save checksum for later verification (before VM boot)
    echo "$source_checksum" > "${SCRIPT_DIR}/gw/.iso_checksum"

    # Copy all generated files back to local machine (needed for wait-for commands)
    echo "Retrieving generated assets..."
    mkdir -p "${SCRIPT_DIR}/gw/auth"
    scp -O -q -r $SSH_OPTS "root@${registry_host}:${remote_dir}/auth/" "${SCRIPT_DIR}/gw/"
    scp -O -q $SSH_OPTS "root@${registry_host}:${remote_dir}/.openshift_install_state.json" "${SCRIPT_DIR}/gw/"
    scp -O -q $SSH_OPTS "root@${registry_host}:${remote_dir}/rendezvousIP" "${SCRIPT_DIR}/gw/" 2>/dev/null || true

    # Cleanup remote directory
    ssh $SSH_OPTS "root@${registry_host}" "rm -rf ${remote_dir}"

    echo "ISO generated and uploaded: ${ISO_PATH}/${ISO_NAME}"
    return 0
}
