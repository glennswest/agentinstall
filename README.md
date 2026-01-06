# Agent-Based OpenShift Installation

Agent-based OpenShift installer optimized for local registry at `registry.gw.lo`.

## Architecture

```
┌─────────────────┐     ┌──────────────────────────────────────────┐
│   Mac (client)  │     │            Proxmox Host (pve.gw.lo)      │
│                 │     │  ┌────────────────────────────────────┐  │
│  agentinstall/  │────▶│  │  Registry VM (registry.gw.lo)     │  │
│  - configs      │     │  │  - Quay registry (:443)           │  │
│  - scripts      │     │  │  - Cached openshift-install       │  │
│                 │     │  │  - ISO generation (fast)          │  │
└─────────────────┘     │  └──────────────┬─────────────────────┘  │
                        │                 │ local copy              │
                        │  ┌──────────────▼─────────────────────┐  │
                        │  │  ISO Storage                       │  │
                        │  │  /var/lib/vz/template/iso/         │  │
                        │  └──────────────┬─────────────────────┘  │
                        │                 │                        │
                        │  ┌──────────────▼─────────────────────┐  │
                        │  │  OpenShift VMs (701-706)           │  │
                        │  │  - control0-2.gw.lo                │  │
                        │  │  - worker0-2.gw.lo                 │  │
                        │  └────────────────────────────────────┘  │
                        └──────────────────────────────────────────┘
```

## Prerequisites

- Proxmox VE access (pve.gw.lo)
- Local registry (registry.gw.lo) with mirrored OCP images
- `oc` CLI tool installed locally
- SSH access to Proxmox host and registry VM
- DNS entries for cluster (api.gw.lo, *.apps.gw.lo, etc.)

## Quick Start

```bash
# 1. Mirror release (run once per version) - from quick-quay project
./mirror.sh 4.18.30

# 2. Install cluster
./install.sh 4.18.30
```

## Setup

### 1. Mirror OpenShift Release

Use the `quick-quay` project to mirror a release:

```bash
cd ~/projects/quick-quay
./mirror.sh 4.18.30
```

This mirrors to `registry.gw.lo` and caches:
- `openshift-install` binary at `/var/lib/openshift-cache/openshift-install-<version>`
- Base RHCOS ISO at `pve.gw.lo:/var/lib/vz/template/iso/rhcos-<version>-x86_64.iso`

### 2. Create VMs (first time only)

```bash
./create-vms.sh
```

Creates VMs 701-706 with:
- Same names as qpve (control0.gw.lo, worker0.gw.lo, etc.)
- production-lvm storage (100G thick provisioned)
- ISO boot enabled

### 3. Configure install-config.yaml

Edit `install-config.yaml` if needed. Key settings:
- `baseDomain: lo` (cluster name "gw" → gw.lo)
- `imageDigestSources` pointing to registry.gw.lo
- `additionalTrustBundle` with registry CA cert

## Installation

```bash
./install.sh <version>
# Example:
./install.sh 4.18.30
```

### Installation Steps

1. **Pull openshift-install** - Downloads from registry cache or extracts from release
2. **Prepare configs** - Copies install-config.yaml and agent-config.yaml
3. **Create agent ISO** - Generated on registry server (fast), falls back to local. VM disk wipe runs in parallel.
4. **Setup kubeconfig** - Installs to ~/.kube/config
5. **Start all nodes** - Powers on all control and worker nodes
6. **Launch monitor** - Starts GUI monitor (monitor.py) in background
7. **Wait for bootstrap** - Monitors bootstrap completion
8. **Wait for install** - Monitors full installation

## Performance Optimizations

### Binary Caching

The `openshift-install` binary is cached at multiple levels:

1. **Registry server**: `/var/lib/openshift-cache/openshift-install-<version>`
2. **Local**: `bin/openshift-install-<version>`
3. **Installed**: `/usr/local/bin/openshift-install`

Priority: installed (if correct version) → local cache → registry cache → extract from release

### Remote ISO Generation

Agent ISO is generated on the registry server instead of locally:

- **Old flow**: Generate locally → upload ~1GB ISO over network (slow)
- **New flow**: Send ~10KB configs → generate on registry → local copy to Proxmox (fast)

Falls back to local generation if registry cache is missing.

### Base ISO Caching

The base RHCOS ISO is cached during mirror:
- Stored at `pve.gw.lo:/var/lib/vz/template/iso/rhcos-<version>-x86_64.iso`
- Registry VM → Proxmox is local transfer (fast)

## Utility Scripts

| Script | Description |
|--------|-------------|
| `install.sh` | Main installation script |
| `monitor.py` | GUI monitor for agent installation (auto-started) |
| `create-vms.sh` | Create VM infrastructure |
| `delete-vms.sh` | Delete all cluster VMs |
| `poweroff-all.sh` | Power off all cluster VMs |
| `poweron-all.sh` | Power on all cluster VMs |
| `pull-from-registry.sh` | Extract openshift-install from registry |
| `approvecsr.sh` | Auto-approve pending CSRs |
| `watch-install.sh` | Watch cluster operator status |

## File Structure

```
agentinstall/
├── config.sh                    # Environment configuration
├── install.sh                   # Main installation script
├── monitor.py                   # GUI monitor for agent installation
├── pull-from-registry.sh        # Extract installer from registry
├── create-vms.sh                # Create VM infrastructure
├── delete-vms.sh                # Delete VMs
├── poweroff-all.sh              # Power off all VMs
├── poweron-all.sh               # Power on all VMs
├── approvecsr.sh                # CSR approval helper
├── watch-install.sh             # Installation monitor (CLI)
├── agent-config.yaml            # Agent configuration
├── install-config.yaml          # Install configuration
├── install-config.yaml.template # Template for install-config
├── pullsecret.json              # Registry pull secrets
├── lib/
│   └── vm.sh                    # VM management functions
├── bin/                         # Cached binaries (gitignored)
│   └── openshift-install-X.Y.Z
└── gw/                          # Generated install dir (gitignored)
    ├── agent.x86_64.iso
    └── auth/kubeconfig
```

## Configuration Reference

### config.sh

| Variable | Default | Description |
|----------|---------|-------------|
| `LOCAL_REGISTRY` | registry.gw.lo | Registry hostname (port 443) |
| `LOCAL_REPOSITORY` | openshift/release | Image repository path |
| `PVE_HOST` | pve.gw.lo | Proxmox host |
| `LVM_VG` | production-lvm | LVM volume group |
| `LVM_STORAGE` | production-lvm | Proxmox storage ID |
| `DEFAULT_DISK_SIZE` | 100G | VM disk size (OCP 4.18+ requires 100GB) |
| `CONTROL_VM_IDS` | (701 702 703) | Control plane VM IDs |
| `WORKER_VM_IDS` | (704 705 706) | Worker VM IDs |
| `CONTROL_CORES` | 8 | Control plane CPU cores |
| `CONTROL_MEMORY` | 17000 | Control plane memory (MB) |
| `WORKER_CORES` | 4 | Worker CPU cores |
| `WORKER_MEMORY` | 16000 | Worker memory (MB) |

### DNS Requirements

| Record | Target | Description |
|--------|--------|-------------|
| `api.gw.lo` | Load balancer IP | Kubernetes API |
| `api-int.gw.lo` | Load balancer IP | Internal API |
| `*.apps.gw.lo` | Ingress IP | Application routes |
| `control0.gw.lo` | 192.168.1.201 | Control node 0 (rendezvous) |
| `control1.gw.lo` | 192.168.1.202 | Control node 1 |
| `control2.gw.lo` | 192.168.1.203 | Control node 2 |
| `worker0.gw.lo` | 192.168.1.204 | Worker node 0 |
| `worker1.gw.lo` | 192.168.1.205 | Worker node 1 |
| `worker2.gw.lo` | 192.168.1.206 | Worker node 2 |

## Troubleshooting

### "No eligible disks" Error

VMs need empty disks of at least 100GB (OCP 4.18+ requirement). The install script erases disks, but if it fails:

```bash
# Manually erase via Proxmox
ssh root@pve.gw.lo "lvremove -f production-lvm/vm-701-disk-0"
ssh root@pve.gw.lo "lvcreate --yes --wipesignatures y -L100G -n vm-701-disk-0 production-lvm"
```

### DNS Resolution Errors

Check that DNS entries are correct:

```bash
dig api.gw.lo
dig api-int.gw.lo
dig test.apps.gw.lo
```

### Registry Connection Issues

Test registry access:

```bash
curl -sk https://registry.gw.lo/v2/_catalog
oc adm release info --insecure registry.gw.lo/openshift/release:4.18.30-x86_64
```

### Remote ISO Generation Fails

If `openshift-install` isn't cached on registry, either:
1. Re-run mirror: `./mirror.sh <version>` (from quick-quay)
2. Install falls back to local generation automatically

## Related Projects

- **qpve**: Traditional (non-agent) OpenShift installation scripts
- **quick-quay**: Quay registry setup and release mirroring
- **pdnsloadbalancer**: PowerDNS-based load balancer for API/ingress endpoints ([GitHub](https://github.com/glennswest/pdnsloadbalancer))
