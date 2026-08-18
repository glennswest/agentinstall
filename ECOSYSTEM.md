# OpenShift Agent-Install Ecosystem

The components that together provide OpenShift agent-based installs on the home
networks (g8 multi-node on Proxmox, g10 single-node on bare metal). Each is its
own repo; this doc is the map.

There are **two working install flows** sharing the same core services:

| Flow | Project | Target | Registry |
|------|---------|--------|----------|
| Multi-node (3 control + 3 worker VMs) | `agentinstall` | Proxmox `pve.g8.lo`, VMs 700–706 | `fastregistry.g8.lo:5000` |
| Single-node (SNO) bare metal | `agent-sno-baremetal` | `server1.g10.lo` via PXE | `fastregistry.g10.lo:5000` |

Both flows: mirror a release into FastRegistry → generate the agent ISO
server-side on FastRegistry → boot the target → watch progress in agent-monitor.

---

## Components

### agentinstall — multi-node install workflow (this repo)

**Repo:** `git@github.com:glennswest/agentinstall.git`

Shell-script-driven agent-based install of a 6-node cluster (`g8` /
`g8.lo`, rendezvous `192.168.8.201`) as Proxmox VMs on `pve.g8.lo`
(control 701–703, worker 704–706, `production-lvm` storage). All settings
live in `config.sh`. Cached `openshift-install` Mac binaries for 4.18–4.21
are kept in `bin/`.

> **Note:** `README.md` predates the FastRegistry/g8 migration and still
> describes the legacy Quay + `registry.gw.lo` + quick-quay flow. `config.sh`
> and the scripts are the source of truth.

**Usage:**

```bash
./generate-secrets.sh      # first time only — pull secret + SSH key
./mirror.sh 4.18           # mirror release via FastRegistry API (resolves latest 4.18.x)
./create-vms.sh            # first time only — create VMs 700-706
./install.sh 4.18          # generate configs, ISO via FastRegistry, boot nodes, monitor
```

Supporting scripts: `verify.sh` (post-install checks), `watch-install.sh`,
`approvecsr.sh`, `poweron-all.sh` / `poweroff-all.sh`, `delete-vms.sh`,
`gatherdebug.sh`, `wipe_registry.sh`, `remirror.sh`.

### agent-sno-baremetal — single-node bare-metal install workflow

**Repo:** `git@github.com:glennswest/agent-sno-baremetal.git`

Fully API-driven SNO install onto a bare-metal server (`server1.g10.lo`,
cluster `s1.lo`). One script orchestrates the whole g10 service stack:
FastRegistry (release + ISO), PXE Manager (`pxe.g10.lo:8080`) for network
boot, netman (`network.g10.lo`) for DNS/DHCP provisioning, and agent-monitor
for progress. Configuration in `config.sh`, install-config/agent-config
templates in `templates/`.

**Usage:**

```bash
# edit config.sh (server, cluster name, versions), then:
./install-sno.sh
```

### agent-monitor — the install console

**Repo:** `git@github.com:glennswest/agent-monitor.git` (v1.0.1)

Go + HTMX web UI ("Agent Install Monitor") that watches installs live. It
polls the assisted-installer REST API the agent installer exposes on the
rendezvous node (`http://<rendezvous-ip>:8090/api/assisted-install`, JWT via
`Watcher-Authorization` header) through a connect → monitor → terminal
lifecycle. Multi-cluster tabs; per-cluster overview, hosts, validations, and
events views. Deployed as an ARM64 container at `http://agentmonitor.g10.lo`
(port 80) on MikroTik rose via mkpod; images built by GHCR CI.

**Usage:**

```bash
make run                   # local dev on :8080
make redeploy              # build + deploy to rose via mkpod (deploy.sh wraps deploy_agent_monitor.py)
```

In the UI, "Add cluster" takes a name, the rendezvous IP, and the token
(printed by `openshift-install agent create image` / found in the install
workdir auth assets).

### fastregistry — registry, release mirror, and agent-ISO factory

**Repo:** `git@github.com:glennswest/fastregistry.git` (v0.6.x)

Go container registry with a release manager: it discovers and clones OCP
release payloads, extracts client artifacts (`oc`, `openshift-install`,
`coreos.iso`), and — the key piece for agent installs — **generates agent
ISOs server-side** so clients never download the ~1 GB base ISO. Send it
~10 KB of configs; it builds the ignition (`internal/releases/ignition.go`)
and embeds it with `coreos-installer` (`internal/releases/iso.go`).
Instances: `fastregistry.g8.lo:5000` and `fastregistry.g10.lo:5000`
(systemd service; HTTP, no auth).

**Usage (ISO generation API):**

```bash
curl -X POST "http://fastregistry.g8.lo:5000/admin/releases/4.21.0-x86_64/iso" \
  -H "Content-Type: application/json" \
  -d "{
    \"install_config\": $(cat install-config.yaml | jq -Rs),
    \"agent_config\": $(cat agent-config.yaml | jq -Rs)
  }"
# → {"full_url": "http://.../files/installs/<uuid>/agent.iso"}  — PXE-sanboot ready
```

Mirroring and extraction are driven through its admin API (wrapped by
`agentinstall/mirror.sh`); a web UI (releases, repositories, sync, download
stats) runs on the same port.

### pxemanager — PXE boot service (SNO flow)

**Repo:** `github.com/glennswest/pxemanager`

Lightweight PXE boot manager with an HTMX web UI, IPMI integration, and a
Redfish API (Bare Metal Operator compatible). Runs at `pxe.g10.lo:8080`;
`agent-sno-baremetal` points it at the FastRegistry-generated agent ISO to
network-boot the target server.

### quick-quay — legacy registry path (superseded)

**Repo:** `git@github.com:glennswest/quick-quay.git`

Native (non-container) Quay install on Fedora at the old `registry.gw.lo`,
with release-mirroring scripts. This was the registry behind agentinstall
before the FastRegistry migration (`Switch from Quay to FastRegistry`
commit). Kept for reference; new work uses fastregistry.

---

## Related / adjacent

- **rspaced** (`github.com/glennswest/rspace` workspace) — experimental
  bootc-based boot agent intended to replace RHCOS in the agent-installer
  flow (live boot, pull from rspacefs, pivot without reboot). Research
  direction, not part of the working install path.
- **netman** — DNS/DHCP provisioning API used by the SNO flow.
- **microdns** — per-network DNS/DHCP servers backing all of the above
  (cluster records: `api.<cluster>.<domain>`, `*.apps.<cluster>.<domain>`).

## End-to-end: multi-node install on g8

```bash
cd ~/projects/agentinstall
./mirror.sh 4.21                    # once per release
./install.sh 4.21
# watch at http://agentmonitor.g10.lo (rendezvous 192.168.8.201)
./verify.sh
```

## End-to-end: SNO install on g10

```bash
cd ~/projects/agent-sno-baremetal
./install-sno.sh                    # mirrors, ISO, PXE, DNS/DHCP, monitor — all API-driven
```
