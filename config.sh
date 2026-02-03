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
export DEFAULT_DISK_SIZE='150G'

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

# Install history file
export INSTALL_HISTORY_FILE="${CONFIG_DIR}/install-history.json"

# Record install start
record_install_start() {
    local version="$1"
    local start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_date=$(date +"%Y-%m-%d")

    # Create history file if it doesn't exist
    if [ ! -f "$INSTALL_HISTORY_FILE" ]; then
        echo '[]' > "$INSTALL_HISTORY_FILE"
    fi

    # Append to array using python (handles JSON properly)
    python3 -c "
import json
with open('$INSTALL_HISTORY_FILE', 'r') as f:
    history = json.load(f)
history.append({
    'version': '${version}',
    'start_time': '${start_time}',
    'start_date': '${start_date}',
    'end_time': None,
    'end_date': None,
    'completed': False
})
with open('$INSTALL_HISTORY_FILE', 'w') as f:
    json.dump(history, f, indent=2)
"
    echo "Install started: ${version} at ${start_time}"
}

# Record install end
record_install_end() {
    local completed="${1:-true}"
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local end_date=$(date +"%Y-%m-%d")

    if [ ! -f "$INSTALL_HISTORY_FILE" ]; then
        echo "Warning: No install history file found"
        return 1
    fi

    # Update the last record
    python3 -c "
import json
with open('$INSTALL_HISTORY_FILE', 'r') as f:
    history = json.load(f)
if history:
    history[-1]['end_time'] = '${end_time}'
    history[-1]['end_date'] = '${end_date}'
    history[-1]['completed'] = '${completed}' == 'true'
with open('$INSTALL_HISTORY_FILE', 'w') as f:
    json.dump(history, f, indent=2)
"
    echo "Install ended: ${end_time} (completed: ${completed})"
}

# Resolve partial version (e.g., 4.18.z or 4.18) to latest release
resolve_latest_version() {
    local input_version="$1"
    local major_minor

    # Strip .z suffix if present
    if [[ "$input_version" =~ ^([0-9]+\.[0-9]+)\.z$ ]]; then
        major_minor="${BASH_REMATCH[1]}"
    # Check if only major.minor provided (no patch)
    elif [[ "$input_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        major_minor="$input_version"
    else
        # Full version provided, return as-is
        echo "$input_version"
        return
    fi

    echo "Looking up latest ${major_minor}.x release..." >&2

    # Query Quay.io for available tags matching the major.minor version
    local api_url="https://quay.io/api/v1/repository/openshift-release-dev/ocp-release/tag/?filter_tag_name=like:${major_minor}&limit=100"

    local response
    response=$(curl -sL "$api_url")

    if [ -z "$response" ]; then
        echo "Error: Could not fetch releases for ${major_minor}" >&2
        exit 1
    fi

    # Extract x86_64 versions, sort, and get the latest
    local resolved_version
    resolved_version=$(echo "$response" | jq -r '.tags[].name' 2>/dev/null | \
        grep "^${major_minor}\.[0-9]*-x86_64$" | \
        sed 's/-x86_64//' | \
        sort -V | \
        tail -1)

    if [ -z "$resolved_version" ]; then
        echo "Error: No releases found for ${major_minor}" >&2
        exit 1
    fi

    echo "Resolved to version: ${resolved_version}" >&2
    echo "$resolved_version"
}

# Show install history
show_install_history() {
    if [ ! -f "$INSTALL_HISTORY_FILE" ]; then
        echo "No install history found"
        return
    fi

    echo "Install History:"
    echo "================"
    python3 -c "
import json
from datetime import datetime

with open('$INSTALL_HISTORY_FILE', 'r') as f:
    history = json.load(f)

for i, h in enumerate(history, 1):
    status = 'COMPLETE' if h.get('completed') else 'INCOMPLETE'
    start = h.get('start_time', '')
    end = h.get('end_time', '')

    # Calculate duration
    duration = 'N/A'
    if start and end:
        try:
            start_dt = datetime.fromisoformat(start.replace('Z', '+00:00'))
            end_dt = datetime.fromisoformat(end.replace('Z', '+00:00'))
            delta = end_dt - start_dt
            hours, remainder = divmod(int(delta.total_seconds()), 3600)
            minutes, seconds = divmod(remainder, 60)
            if hours > 0:
                duration = f'{hours}h {minutes}m {seconds}s'
            elif minutes > 0:
                duration = f'{minutes}m {seconds}s'
            else:
                duration = f'{seconds}s'
        except:
            duration = 'N/A'

    end_display = end or 'in progress'
    print(f\"{i}. {h['version']} | {h.get('start_date', 'N/A')} | Start: {start} | End: {end_display} | Duration: {duration} | {status}\")
"
}
