#!/bin/zsh
# Gather debug information from an agent-based OpenShift install
# Usage: ./gatherdebug.sh [output-dir]

set -eo pipefail

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/config.sh"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
KUBECONFIG="${SCRIPT_DIR}/gw/auth/kubeconfig"

# Node IPs (matches agent-config.yaml)
typeset -A NODE_IPS=(
    control0 192.168.1.201
    control1 192.168.1.202
    control2 192.168.1.203
    worker0 192.168.1.204
    worker1 192.168.1.205
    worker2 192.168.1.206
)

# Output directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="${1:-${SCRIPT_DIR}/debug-${TIMESTAMP}}"
mkdir -p "$OUTDIR"

echo "=========================================="
echo "Agent Install Debug Gather"
echo "Output: ${OUTDIR}"
echo "=========================================="

# ---------------------------------------------------------------------------
# Helper: run a command, save output, don't fail the script
# ---------------------------------------------------------------------------
gather() {
    local file="$1"
    shift
    echo "  Gathering: ${file}"
    "$@" > "${OUTDIR}/${file}" 2>&1 || true
}

# ---------------------------------------------------------------------------
# 1. VM Status from Proxmox
# ---------------------------------------------------------------------------
echo ""
echo "[1/6] Proxmox VM status..."
mkdir -p "${OUTDIR}/proxmox"
gather "proxmox/qm-list.txt" \
    ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "qm list"

for node in "${(k)NODE_IPS[@]}"; do
    vmid=$(echo "${node}" | sed 's/control/70/;s/worker/70/' | sed 's/control//;s/worker//')
    # Map node name to VMID
    case "$node" in
        control0) vmid=701 ;; control1) vmid=702 ;; control2) vmid=703 ;;
        worker0)  vmid=704 ;; worker1)  vmid=705 ;; worker2)  vmid=706 ;;
    esac
    gather "proxmox/${node}-vm-status.txt" \
        ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "qm status ${vmid} && echo '---' && qm config ${vmid}"
done

# ---------------------------------------------------------------------------
# 2. Network reachability
# ---------------------------------------------------------------------------
echo ""
echo "[2/6] Network reachability..."
mkdir -p "${OUTDIR}/network"

for node in "${(k)NODE_IPS[@]}"; do
    ip="${NODE_IPS[$node]}"
    {
        echo "=== ${node} (${ip}) ==="
        if ping -c 1 -t 2 "$ip" >/dev/null 2>&1; then
            echo "PING: ok"
        else
            echo "PING: unreachable"
        fi
        for port in 22 6443 2379 2380 22623 22624; do
            if nc -z -w2 "$ip" "$port" 2>/dev/null; then
                echo "PORT ${port}: open"
            else
                echo "PORT ${port}: closed"
            fi
        done
    } >> "${OUTDIR}/network/reachability.txt" 2>&1
done

# API endpoint
{
    echo "=== API Endpoints ==="
    echo -n "api.gw.lo:6443/readyz: "
    curl -sk --connect-timeout 5 https://api.gw.lo:6443/readyz 2>&1 || echo "unreachable"
    echo ""
    echo -n "api-int.gw.lo:6443/readyz: "
    curl -sk --connect-timeout 5 https://api-int.gw.lo:6443/readyz 2>&1 || echo "unreachable"
    echo ""
} >> "${OUTDIR}/network/reachability.txt" 2>&1

# ---------------------------------------------------------------------------
# 3. Per-node logs and state (via SSH)
# ---------------------------------------------------------------------------
echo ""
echo "[3/6] Node logs and state..."

for node in "${(k)NODE_IPS[@]}"; do
    ip="${NODE_IPS[$node]}"
    nodedir="${OUTDIR}/nodes/${node}"
    mkdir -p "$nodedir"

    # Try core user first, fall back to root
    SSH_USER="core"
    if ! ssh $SSH_OPTS "${SSH_USER}@${ip}" "true" 2>/dev/null; then
        SSH_USER="root"
        if ! ssh $SSH_OPTS "${SSH_USER}@${ip}" "true" 2>/dev/null; then
            echo "  ${node} (${ip}): unreachable via SSH"
            echo "UNREACHABLE" > "${nodedir}/status.txt"
            continue
        fi
    fi

    echo "  ${node} (${ip}) as ${SSH_USER}..."

    # Basic info
    gather "nodes/${node}/hostname-uptime.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "hostname; uptime; uname -r; cat /etc/os-release 2>/dev/null | head -5"

    # Service status
    gather "nodes/${node}/services.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "\
            for svc in kubelet crio agent assisted-service bootkube machine-config-daemon-firstboot; do
                echo \"=== \${svc} ===\"
                sudo systemctl is-active \${svc} 2>/dev/null || echo 'not found'
                sudo systemctl is-enabled \${svc} 2>/dev/null || echo 'not found'
                echo ''
            done"

    # Kubelet logs (last 200 lines)
    gather "nodes/${node}/kubelet.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -u kubelet --no-pager -n 200 2>&1"

    # Agent logs (last 200 lines)
    gather "nodes/${node}/agent.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -u agent --no-pager -n 200 2>&1"

    # Bootkube logs
    gather "nodes/${node}/bootkube.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -u bootkube --no-pager -n 200 2>&1"

    # MCD firstboot logs
    gather "nodes/${node}/mcd-firstboot.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -u machine-config-daemon-firstboot --no-pager 2>&1"

    # CRI-O logs (last 100 lines)
    gather "nodes/${node}/crio.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -u crio --no-pager -n 100 2>&1"

    # Container list
    gather "nodes/${node}/containers.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "\
            echo '=== crictl ===' && sudo crictl ps -a 2>/dev/null; \
            echo '' && echo '=== podman ===' && sudo podman ps -a 2>/dev/null"

    # Network state
    gather "nodes/${node}/network.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "\
            echo '=== ip addr ===' && ip addr; \
            echo '' && echo '=== ip route ===' && ip route; \
            echo '' && echo '=== resolv.conf ===' && cat /etc/resolv.conf; \
            echo '' && echo '=== ss -tlnp ===' && sudo ss -tlnp"

    # Kubernetes config files
    gather "nodes/${node}/kube-config.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "\
            echo '=== /etc/kubernetes/ ===' && sudo ls -la /etc/kubernetes/ 2>&1; \
            echo '' && echo '=== /var/lib/kubelet/pki/ ===' && sudo ls -la /var/lib/kubelet/pki/ 2>&1; \
            echo '' && echo '=== kubelet.conf ===' && sudo cat /etc/kubernetes/kubelet.conf 2>&1"

    # MachineConfig state on node
    gather "nodes/${node}/machineconfig-state.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "\
            echo '=== currentConfig ===' && sudo cat /etc/machine-config-daemon/currentconfig 2>/dev/null || echo 'not found'; \
            echo '' && echo '=== rpm-ostree status ===' && sudo rpm-ostree status 2>&1"

    # Disk usage
    gather "nodes/${node}/disk.txt" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "df -h; echo '---'; sudo du -sh /var/lib/containers 2>/dev/null"

    # Recent system journal errors
    gather "nodes/${node}/journal-errors.log" \
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo journalctl -p err --no-pager -n 100 2>&1"
done

# ---------------------------------------------------------------------------
# 4. Cluster state (if API is up)
# ---------------------------------------------------------------------------
echo ""
echo "[4/6] Cluster state..."
mkdir -p "${OUTDIR}/cluster"

if KUBECONFIG="$KUBECONFIG" oc get nodes >/dev/null 2>&1; then
    echo "  API server is reachable"

    gather "cluster/nodes.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get nodes -o wide

    gather "cluster/clusterversion.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get clusterversion -o yaml

    gather "cluster/clusteroperators.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get co

    gather "cluster/clusteroperators-detail.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get co -o yaml

    gather "cluster/mcp.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get mcp -o wide

    gather "cluster/mcp-master-describe.txt" \
        env KUBECONFIG="$KUBECONFIG" oc describe mcp master

    gather "cluster/machineconfigs.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get mc

    gather "cluster/node-annotations.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}currentConfig={.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}{"\t"}desiredConfig={.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}{"\t"}state={.metadata.annotations.machineconfiguration\.openshift\.io/state}{"\n"}{end}'

    gather "cluster/csr.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get csr

    gather "cluster/etcd.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get etcd -o yaml

    gather "cluster/events.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get events -A --sort-by='.lastTimestamp'

    gather "cluster/pods-not-running.txt" \
        env KUBECONFIG="$KUBECONFIG" oc get pods -A --field-selector='status.phase!=Running,status.phase!=Succeeded'

    # MCD pod logs
    for pod in $(env KUBECONFIG="$KUBECONFIG" oc get pods -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -o name 2>/dev/null); do
        podname=$(basename "$pod")
        gather "cluster/mcd-${podname}.log" \
            env KUBECONFIG="$KUBECONFIG" oc logs -n openshift-machine-config-operator "$podname" -c machine-config-daemon --tail=200
    done

    # Etcd pod logs
    for pod in $(env KUBECONFIG="$KUBECONFIG" oc get pods -n openshift-etcd -l app=etcd -o name 2>/dev/null); do
        podname=$(basename "$pod")
        gather "cluster/etcd-${podname}.log" \
            env KUBECONFIG="$KUBECONFIG" oc logs -n openshift-etcd "$podname" -c etcd --tail=100
    done
else
    echo "  API server not reachable - skipping cluster state"
    echo "API UNREACHABLE" > "${OUTDIR}/cluster/status.txt"
fi

# ---------------------------------------------------------------------------
# 5. Registry state
# ---------------------------------------------------------------------------
echo ""
echo "[5/6] Registry state..."
mkdir -p "${OUTDIR}/registry"
REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"

if ssh $SSH_OPTS "root@${REGISTRY_HOST}" "true" 2>/dev/null; then
    gather "registry/nginx-error.log" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "tail -100 /var/log/nginx/error.log 2>/dev/null"

    gather "registry/nginx-access-tail.log" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "tail -100 /var/log/nginx/access.log 2>/dev/null"

    gather "registry/quay-logs.txt" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "sudo journalctl -u quay --no-pager -n 100 2>/dev/null || sudo podman logs quay --tail 100 2>/dev/null || echo 'could not get quay logs'"

    gather "registry/nginx-config.txt" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "cat /etc/nginx/conf.d/quay.conf 2>/dev/null"

    gather "registry/cert-info.txt" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "openssl x509 -in /etc/nginx/ssl/registry.crt -noout -subject -dates -fingerprint 2>/dev/null"

    gather "registry/disk.txt" \
        ssh $SSH_OPTS "root@${REGISTRY_HOST}" "df -h; echo '---'; du -sh /var/lib/quay/storage 2>/dev/null"
else
    echo "  Registry host unreachable"
    echo "UNREACHABLE" > "${OUTDIR}/registry/status.txt"
fi

# ---------------------------------------------------------------------------
# 6. Local installer state
# ---------------------------------------------------------------------------
echo ""
echo "[6/6] Local installer state..."
mkdir -p "${OUTDIR}/installer"

if [ -f "${SCRIPT_DIR}/gw/.openshift_install.log" ]; then
    cp "${SCRIPT_DIR}/gw/.openshift_install.log" "${OUTDIR}/installer/openshift_install.log"
    echo "  Copied install log"
fi

if [ -f "${SCRIPT_DIR}/gw/.iso_checksum" ]; then
    cp "${SCRIPT_DIR}/gw/.iso_checksum" "${OUTDIR}/installer/iso_checksum.txt"
fi

if [ -f "$INSTALL_HISTORY_FILE" ]; then
    cp "$INSTALL_HISTORY_FILE" "${OUTDIR}/installer/install-history.json"
fi

# Check if wait-for is still running
gather "installer/wait-for-process.txt" \
    bash -c "ps aux | grep 'openshift-install.*wait-for' | grep -v grep"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
FILE_COUNT=$(find "$OUTDIR" -type f | wc -l | tr -d ' ')
DIR_SIZE=$(du -sh "$OUTDIR" | awk '{print $1}')
echo "Debug gathered: ${FILE_COUNT} files, ${DIR_SIZE}"
echo "Output: ${OUTDIR}"
echo "=========================================="

# Create tarball
TARBALL="${OUTDIR}.tar.gz"
tar czf "$TARBALL" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"
echo "Tarball: ${TARBALL}"
