# Agent-Based OpenShift Installation

Agent-based OpenShift installer using local registry at `registry.gw.lo`.

## Prerequisites

- Proxmox VE access (pve.gw.lo)
- Local registry (registry.gw.lo:8443) with mirrored OCP images
- `oc` and `podman` CLI tools installed
- SSH access to Proxmox host
- Pull secret file at `~/gw.lo/pull-secret-registry.txt`

## Setup

1. **Create install-config.yaml from template:**
   ```bash
   cp install-config.yaml.template install-config.yaml
   # Edit install-config.yaml:
   # - Replace PULL_SECRET_PLACEHOLDER with your pull secret
   # - Replace SSH_KEY_PLACEHOLDER with your SSH public key
   # - Update additionalTrustBundle if using self-signed certs
   ```

2. **Create VMs (first time only):**
   ```bash
   ./create-vms.sh
   ```

3. **Update config.sh if needed:**
   - VM IDs (default: 750-755, separate from qpve's 700-714)
   - Registry credentials
   - Cluster settings

## Installation

```bash
./install.sh <version>
# Example:
./install.sh 4.14.10
```

This will:
1. Pull openshift-install from local registry
2. Generate agent ISO
3. Upload ISO to Proxmox
4. Reset and boot VMs
5. Wait for installation to complete

## Utility Scripts

- `poweroff-all.sh` - Power off all cluster VMs
- `poweron-all.sh` - Power on all cluster VMs
- `delete-vms.sh` - Delete all cluster VMs
- `approvecsr.sh` - Auto-approve pending CSRs (run in separate terminal)
- `watch-install.sh` - Watch cluster operator status

## File Structure

```
agentinstall/
├── config.sh                    # Environment configuration
├── install.sh                   # Main installation script
├── pull-from-registry.sh        # Extract installer from registry
├── create-vms.sh               # Create VM infrastructure
├── delete-vms.sh               # Delete VMs
├── poweroff-all.sh             # Power off all VMs
├── poweron-all.sh              # Power on all VMs
├── approvecsr.sh               # CSR approval helper
├── watch-install.sh            # Installation monitor
├── agent-config.yaml           # Agent configuration
├── install-config.yaml.template # Install config template
├── lib/
│   └── vm.sh                   # VM management functions
└── gw/                         # Generated (gitignored)
    ├── agent.x86_64.iso
    └── auth/kubeconfig
```

## Notes

- Uses VM IDs 750-755 to avoid conflicts with qpve (700-714)
- All images pulled from registry.gw.lo:8443
- Kubeconfig automatically installed to ~/.kube/config
