# Fix: Stale MachineConfig Annotation Deadlock in Agent-Based Installer

## Problem Description

During agent-based OpenShift installations, the bootstrap node (control0) can reboot before the other control plane nodes (control1, control2) have consistent MachineConfig annotations. This creates a deadlock situation:

### The Issue

1. During installation, the Machine Config Operator (MCO) creates "rendered" MachineConfigs (e.g., `rendered-master-abc123`)
2. Nodes receive annotations pointing to these rendered configs:
   - `machineconfiguration.openshift.io/currentConfig`
   - `machineconfiguration.openshift.io/desiredConfig`
3. If MCO regenerates a new rendered config while nodes are still processing, the old rendered config may be garbage collected
4. Nodes end up with annotations pointing to **non-existent** MachineConfigs
5. MCO marks these nodes as "Degraded" with reason: `missing MachineConfig rendered-master-xxx`
6. MCO refuses to update Degraded nodes, creating a permanent deadlock

### Why Bootstrap Reboot Timing Matters

The existing code in `installer.go` waits for:
- 2 master nodes to be kubernetes "Ready" (`waitForMinMasterNodes`)
- Bootkube completion
- ETCD bootstrap completion
- Controller ready

However, **kubernetes "Ready" does not mean MCO-healthy**. A node can be Ready but have stale MC annotations, causing it to be MCO Degraded.

When bootstrap reboots while control1/control2 have stale annotations:
- etcd loses quorum temporarily
- The stale annotation deadlock persists
- Cluster installation fails or hangs

## Solution

Add a new check before bootstrap reboot that verifies all master nodes have MachineConfig annotations pointing to **existing** MachineConfig objects.

### Changes Made

1. **New method `GetMachineConfig(name)`** in K8SClient interface to fetch MachineConfig objects
2. **New function `waitForMCAnnotationsConsistent()`** that:
   - Lists all master nodes
   - For each node, reads `currentConfig` and `desiredConfig` annotations
   - Verifies each referenced MachineConfig actually exists in the cluster
   - Waits until all annotations are consistent
3. **Call the new function** in the bootstrap path, after `waitForWorkers()` and before `finalize()` (reboot)

## Files Modified

- `src/k8s_client/k8s_client.go` - Added `GetMachineConfig()` interface method and implementation
- `src/k8s_client/mock_k8s_client.go` - Added mock for testing
- `src/installer/installer.go` - Added `waitForMCAnnotationsConsistent()` and integrated into bootstrap flow

## Diff

```diff
diff --git a/src/installer/installer.go b/src/installer/installer.go
index 22fd20d..b428534 100644
--- a/src/installer/installer.go
+++ b/src/installer/installer.go
@@ -201,6 +201,18 @@ func (i *installer) InstallNode() error {
 		if err = i.waitForWorkers(ctx); err != nil {
 			return err
 		}
+
+		// Wait for MachineConfig annotations on all master nodes to be consistent
+		// before rebooting the bootstrap. This prevents the stale annotation deadlock
+		// where nodes point to non-existent MachineConfigs.
+		kc, err := i.kcBuilder(KubeconfigPath, i.log)
+		if err != nil {
+			i.log.Error(err)
+			return err
+		}
+		if err = i.waitForMCAnnotationsConsistent(ctx, kc); err != nil {
+			return err
+		}
 	}

 	//upload host logs and report log status before reboot
@@ -899,6 +911,59 @@ func (i *installer) waitForNodes(ctx context.Context, minNodes int, role string,
 	}
 }

+const (
+	mcCurrentConfigAnnotation = "machineconfiguration.openshift.io/currentConfig"
+	mcDesiredConfigAnnotation = "machineconfiguration.openshift.io/desiredConfig"
+	mcStateAnnotation         = "machineconfiguration.openshift.io/state"
+)
+
+// waitForMCAnnotationsConsistent waits for all master nodes to have MachineConfig annotations
+// that reference existing MachineConfig objects. This prevents the bootstrap from rebooting
+// while nodes have stale annotations pointing to non-existent MachineConfigs.
+func (i *installer) waitForMCAnnotationsConsistent(ctx context.Context, kc k8s_client.K8SClient) error {
+	i.log.Infof("Waiting for MachineConfig annotations to be consistent on all master nodes")
+
+	return utils.WaitForPredicate(waitForeverTimeout, generalWaitInterval, func() bool {
+		nodes, err := kc.ListNodesByRole("master")
+		if err != nil {
+			i.log.Warnf("Failed to list master nodes: %v", err)
+			return false
+		}
+
+		for _, node := range nodes.Items {
+			currentConfig := node.Annotations[mcCurrentConfigAnnotation]
+			desiredConfig := node.Annotations[mcDesiredConfigAnnotation]
+			state := node.Annotations[mcStateAnnotation]
+
+			// Skip if annotations are not set yet
+			if currentConfig == "" || desiredConfig == "" {
+				i.log.Infof("Node %s has no MC annotations yet, waiting...", node.Name)
+				return false
+			}
+
+			// Check if currentConfig exists
+			if _, err := kc.GetMachineConfig(currentConfig); err != nil {
+				i.log.Warnf("Node %s has currentConfig %s which does not exist (state=%s), waiting...",
+					node.Name, currentConfig, state)
+				return false
+			}
+
+			// Check if desiredConfig exists
+			if _, err := kc.GetMachineConfig(desiredConfig); err != nil {
+				i.log.Warnf("Node %s has desiredConfig %s which does not exist (state=%s), waiting...",
+					node.Name, desiredConfig, state)
+				return false
+			}
+
+			i.log.Infof("Node %s MC annotations are consistent (current=%s, desired=%s, state=%s)",
+				node.Name, currentConfig, desiredConfig, state)
+		}
+
+		i.log.Infof("All master nodes have consistent MachineConfig annotations")
+		return true
+	})
+}
+
 func (i *installer) getInventoryHostsMap(hostsMap map[string]inventory_client.HostData) (map[string]inventory_client.HostData, error) {
 	var err error
 	if hostsMap == nil {
diff --git a/src/k8s_client/k8s_client.go b/src/k8s_client/k8s_client.go
index 584fda6..b0913bb 100644
--- a/src/k8s_client/k8s_client.go
+++ b/src/k8s_client/k8s_client.go
@@ -89,6 +89,7 @@ type K8SClient interface {
 	IsClusterCapabilityEnabled(configv1.ClusterVersionCapability) (bool, error)
 	UntaintNode(name string) error
 	PatchMachineConfigPoolPaused(pause bool, mcpName string) error
+	GetMachineConfig(name string) (*mcfgv1.MachineConfig, error)
 }

 type K8SClientBuilder func(configPath string, logger logrus.FieldLogger) (K8SClient, error)
@@ -713,3 +714,12 @@ func (c *k8sClient) PatchMachineConfigPoolPaused(pause bool, mcpName string) err
 	c.log.Infof("Setting pause MCP %s to %t", mcpName, pause)
 	return c.runtimeClient.Patch(context.TODO(), mcp, runtimeclient.RawPatch(types.MergePatchType, pausePatch))
 }
+
+func (c *k8sClient) GetMachineConfig(name string) (*mcfgv1.MachineConfig, error) {
+	mc := &mcfgv1.MachineConfig{}
+	err := c.runtimeClient.Get(context.TODO(), types.NamespacedName{Name: name}, mc)
+	if err != nil {
+		return nil, err
+	}
+	return mc, nil
+}
diff --git a/src/k8s_client/mock_k8s_client.go b/src/k8s_client/mock_k8s_client.go
index b27a5b2..9534009 100644
--- a/src/k8s_client/mock_k8s_client.go
+++ b/src/k8s_client/mock_k8s_client.go
@@ -17,6 +17,7 @@ import (
 	v1 "github.com/openshift/api/config/v1"
 	v1beta1 "github.com/openshift/api/machine/v1beta1"
 	ops "github.com/openshift/assisted-installer/src/ops"
+	mcfgv1 "github.com/openshift/machine-config-operator/pkg/apis/machineconfiguration.openshift.io/v1"
 	v1alpha10 "github.com/operator-framework/api/pkg/operators/v1alpha1"
 	gomock "go.uber.org/mock/gomock"
 	v10 "k8s.io/api/batch/v1"
@@ -551,6 +552,21 @@ func (mr *MockK8SClientMockRecorder) PatchMachineConfigPoolPaused(pause, mcpName
 	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "PatchMachineConfigPoolPaused", reflect.TypeOf((*MockK8SClient)(nil).PatchMachineConfigPoolPaused), pause, mcpName)
 }

+// GetMachineConfig mocks base method.
+func (m *MockK8SClient) GetMachineConfig(name string) (*mcfgv1.MachineConfig, error) {
+	m.ctrl.T.Helper()
+	ret := m.ctrl.Call(m, "GetMachineConfig", name)
+	ret0, _ := ret[0].(*mcfgv1.MachineConfig)
+	ret1, _ := ret[1].(error)
+	return ret0, ret1
+}
+
+// GetMachineConfig indicates an expected call of GetMachineConfig.
+func (mr *MockK8SClientMockRecorder) GetMachineConfig(name any) *gomock.Call {
+	mr.mock.ctrl.T.Helper()
+	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetMachineConfig", reflect.TypeOf((*MockK8SClient)(nil).GetMachineConfig), name)
+}
+
 // PatchNamespace mocks base method.
 func (m *MockK8SClient) PatchNamespace(namespace string, data []byte) error {
 	m.ctrl.T.Helper()
```

## Deployment

To use this fix:

1. Build the patched image:
   ```bash
   cd upstream/assisted-installer
   podman build --platform linux/amd64 -f Dockerfile.assisted-installer . -t registry.gw.lo/openshift/release:baremetal-installer
   ```

2. Push to local registry:
   ```bash
   podman push --tls-verify=false registry.gw.lo/openshift/release:baremetal-installer
   ```

3. The next agent-based install will use the patched installer automatically.

## Related Issues

- OCPBUGS-5988: etcd race condition (existing 1-minute reboot delay addresses this)
- This fix addresses a different but related timing issue with MCO annotations
