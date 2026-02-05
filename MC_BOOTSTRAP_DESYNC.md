# MachineConfig Bootstrap Desync Issue

## Problem Summary

During agent-based OpenShift 4.18.32 installation, the bootstrap pivot completes
successfully but master nodes (control1, control2) are left referencing a
bootstrap-generated rendered MachineConfig that no longer exists. This blocks:

1. MCD (machine-config-daemon) on masters - stuck in "bootstrap mode" loop
2. Master MCP (MachineConfigPool) - degraded, 0 ready machines
3. Control0 (bootstrap node) - cannot complete firstboot/rejoin as 3rd master
4. Authentication operator - requires 3 kube-apiservers, only has 2
5. Cluster install - stuck at "Cluster operator authentication is not available"

## Cluster State at Time of Issue

### Nodes
```
NAME             STATUS   ROLES                  AGE   VERSION
control1.gw.lo   Ready    control-plane,master   26m   v1.31.14
control2.gw.lo   Ready    control-plane,master   26m   v1.31.14
worker0.gw.lo    Ready    worker                 16m   v1.31.14
worker1.gw.lo    Ready    worker                 16m   v1.31.14
worker2.gw.lo    Ready    worker                 16m   v1.31.14
```

control0.gw.lo (192.168.1.201) - VM running, pingable, SSH refused.
Has been unreachable for 10+ minutes after bootstrap pivot reboot.

### ClusterVersion
```
version   False   True   Unable to apply 4.18.32: the cluster operator authentication is not available
```

### Key Cluster Operators
| Operator | Available | Issue |
|----------|-----------|-------|
| authentication | False | need at least 3 kube-apiservers, got 2 |
| etcd | True (Degraded) | quorum of 2, not fault tolerant |
| machine-config | True (Degraded) | syncRequiredMachineConfigPools: context deadline exceeded |
| All others | True | - |

### MachineConfigPool - master
```
UPDATED=False  UPDATING=True  DEGRADED=True  MACHINECOUNT=2  READY=0  DEGRADED=2
```

### MachineConfig Objects
The only rendered master config that exists:
```
rendered-master-9e786f4a442cb50f3dfeec92abb1675f   (current, created by MCC)
```

The bootstrap-generated config that was cleaned up:
```
rendered-master-553d5d527988f8cd22e7791f6013fe42   (DOES NOT EXIST)
```

### Node Annotations (the root cause)
```
control1.gw.lo  currentConfig=rendered-master-553d5d527988f8cd22e7791f6013fe42  state=Degraded
control2.gw.lo  currentConfig=rendered-master-553d5d527988f8cd22e7791f6013fe42  state=Degraded
worker0.gw.lo   currentConfig=rendered-worker-25a1be6c1264c64551ae911d23717173  state=Done
worker1.gw.lo   currentConfig=rendered-worker-25a1be6c1264c64551ae911d23717173  state=Done
worker2.gw.lo   currentConfig=rendered-worker-25a1be6c1264c64551ae911d23717173  state=Done
```

Masters reference `rendered-master-553d5d527988f8cd22e7791f6013fe42` which no longer
exists. Workers reference their rendered config which does exist and are `Done`.

### MCD Logs (both master MCDs in identical loop)
```
daemon.go:1662] In bootstrap mode
writer.go:231] Marking Degraded due to: "missing MachineConfig rendered-master-553d5d527988f8cd22e7791f6013fe42
  machineconfig.machineconfiguration.openshift.io "rendered-master-553d5d527988f8cd22e7791f6013fe42" not found"
```
Repeating every ~10-60 seconds indefinitely.

### etcd
```
2 members available (control1.gw.lo, control2.gw.lo) - both healthy
Bootstrap member already removed
Quorum of 2 - not fault tolerant (needs control0 as 3rd member)
```

## Root Cause

During agent-based install, the bootstrap process generates a temporary rendered
MachineConfig (`rendered-master-553d5d...`). After the bootstrap pivot:

1. The MachineConfig Controller (MCC) takes over and renders a new config
   (`rendered-master-9e786f...`) from the source MachineConfigs
2. The old bootstrap-generated rendered config is cleaned up (deleted)
3. But the node annotations still reference the old config
4. MCD enters "bootstrap mode" to reconcile, finds the old config missing, marks Degraded
5. MCD cannot transition to the new config because it can't load the old one to diff

Additionally, the MCP `status.configuration.name` field stays **empty** after
bootstrap pivot. The MachineConfig Server (MCS, port 22623) uses this field to
determine which config to serve to nodes requesting ignition. An empty status
causes MCS to return HTTP 500:

```
couldn't get config for req: {machineConfigPool:master version:...},
  error: could not fetch config, err: machineconfig.machineconfiguration.openshift.io "" not found
```

This blocks the bootstrap node (control0) from re-joining after its reboot:
- control0 reboots and requests ignition from `https://api-int.gw.lo:22623/config/master`
- pdnsloadbalancer correctly removes control0 from `api-int` (port 22623 is down)
- control0 reaches MCS on control1/control2, but MCS returns 500
- control0 loops forever: `A start job is running for Ignition (fetch) (Xmin Xs / no limit)`

This creates a deadlock:
- MCD won't apply the new config because it can't find the current (old) config
- The old config doesn't exist anymore
- Master MCP stays degraded, blocking machine-config operator
- MCS can't serve ignition because MCP status.configuration.name is empty
- Control0 can't get ignition, can't join cluster
- Without control0, etcd stays at 2 members, authentication needs 3 kube-apiservers

## Fix

Run `fix-mc-desync.sh` which automates all steps, or apply manually:

### Step 1: Patch MCP status.configuration.name

The MCS uses `status.configuration.name` (not `spec`) to serve configs. After
bootstrap pivot it's empty. Patch it:

```bash
CURRENT_MC=$(oc get mcp master -o jsonpath='{.spec.configuration.name}')
oc patch mcp master --type=merge --subresource=status \
  -p "{\"status\":{\"configuration\":{\"name\":\"$CURRENT_MC\"}}}"
```

This makes MCS return 200 instead of 500, unblocking control0's ignition fetch.

### Step 2: Fix node annotations

Update node annotations on existing masters to reference the current rendered
config. This tells the MCD the nodes are already at the new config:

```bash
CURRENT_MC=$(oc get mcp master -o jsonpath='{.spec.configuration.name}')
for node in $(oc get nodes -l node-role.kubernetes.io/master -o name); do
  oc patch $node -p "{\"metadata\":{\"annotations\":{
    \"machineconfiguration.openshift.io/currentConfig\":\"$CURRENT_MC\",
    \"machineconfiguration.openshift.io/desiredConfig\":\"$CURRENT_MC\",
    \"machineconfiguration.openshift.io/state\":\"Done\"}}}" --type=merge
done
```

### Step 3: Approve Control0 CSRs

After control0 gets its ignition and boots, it needs CSR approval:

```bash
oc get csr | grep Pending
oc adm certificate approve <csr-name>
# Wait a few seconds, then approve the second one
oc get csr | grep Pending
oc adm certificate approve <csr-name>
```

After all steps:
1. MCS serves ignition config (200 OK)
2. Control0 boots RHCOS and joins the cluster
3. MCD exits bootstrap mode on control1/control2
4. etcd adds 3rd member, achieves fault tolerance
5. Authentication operator becomes Available (needs 3 kube-apiservers)
6. Cluster install completes

## Symptoms Timeline

1. Install reaches ~93% - all operators available except authentication
2. Authentication reports "need at least 3 kube-apiservers, got 2"
3. Control0 (bootstrap node) is pingable but SSH refused (rebooting for firstboot)
4. `oc get mcp master` shows DEGRADED=True, READY=0
5. MCD logs show "In bootstrap mode" + "missing MachineConfig rendered-master-..."
6. Install stalls indefinitely waiting for authentication operator

## Prevention

This appears to be a race condition in agent-based installs where the MCC renders a
new config before the MCD on masters has completed its initial bootstrap
reconciliation. The bootstrap-generated rendered config gets garbage collected while
nodes still reference it.

Additionally, the machine-approver may not auto-approve CSRs for the bootstrap node
(control0) because it transitions from bootstrap to regular node in a non-standard
way. Manual CSR approval may be needed.
