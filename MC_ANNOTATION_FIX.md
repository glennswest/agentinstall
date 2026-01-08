# Fix: Stale MachineConfig Annotation Deadlock in Agent-Based Installer

## Status: TESTED AND VERIFIED

Successfully tested on 2026-01-08 with OpenShift 4.18.30. The fix prevents the stale MC annotation deadlock and allows the installation to complete successfully.

## Problem Description

During agent-based OpenShift installations, the bootstrap node—also known as the **rendezvous host** (control0)—can reboot before the other control plane nodes (control1, control2) have consistent MachineConfig annotations. This creates a deadlock situation:

> **Note:** In agent-based installs, one control plane node acts as the "rendezvous host" where assisted-service runs and orchestrates the installation. This node is identified by `isBootstrap=true` in the installer code.

### The Issue

1. During installation, the Machine Config Operator (MCO) creates "rendered" MachineConfigs (e.g., `rendered-master-abc123`)
2. Nodes receive annotations pointing to these rendered configs:
   - `machineconfiguration.openshift.io/currentConfig`
   - `machineconfiguration.openshift.io/desiredConfig`
3. If MCO regenerates a new rendered config while nodes are still processing, the old rendered config may be garbage collected
4. Nodes end up with annotations pointing to **non-existent** MachineConfigs
5. MCO marks these nodes as "Degraded" with reason: `missing MachineConfig rendered-master-xxx`
6. MCO refuses to update Degraded nodes, creating a permanent deadlock

### Why Rendezvous Host Reboot Timing Matters

The existing code in `installer.go` waits for:
- 2 master nodes to be kubernetes "Ready" (`waitForMinMasterNodes`)
- Bootkube completion
- ETCD bootstrap completion
- Controller ready

However, **kubernetes "Ready" does not mean MCO-healthy**. A node can be Ready but have stale MC annotations, causing it to be MCO Degraded.

When the rendezvous host reboots while control1/control2 have stale annotations:
- etcd loses quorum temporarily
- The stale annotation deadlock persists
- Cluster installation fails or hangs

## Solution

Add a new check before the rendezvous host reboots that verifies all master nodes have MachineConfig annotations pointing to **existing** MachineConfig objects.

### Changes Made

1. **New method `GetMachineConfig(name)`** in K8SClient interface to fetch MachineConfig objects

2. **Fixed `runtimeClient` initialization bug** - The original code only initialized `runtimeClient` when `configPath == ""`, but agent-based installs pass a kubeconfig path, leaving `runtimeClient` nil and causing a panic when `GetMachineConfig()` was called

3. **New function `waitForMCAnnotationsConsistent()`** that:
   - Lists all master nodes
   - For each node, reads `currentConfig` and `desiredConfig` annotations
   - Verifies each referenced MachineConfig actually exists in the cluster
   - Waits until all annotations are consistent

4. **Call the new function** in the bootstrap path, after `waitForWorkers()` and before `finalize()` (reboot)

5. **Added `HighAvailabilityMode` flag** - Required by OCP builds but missing in upstream

## Files Modified

- `src/k8s_client/k8s_client.go` - Added `GetMachineConfig()` interface method, implementation, and **fixed runtimeClient initialization**
- `src/k8s_client/mock_k8s_client.go` - Added mock for testing
- `src/installer/installer.go` - Added `waitForMCAnnotationsConsistent()` and integrated into bootstrap flow
- `src/config/config.go` - Added `HighAvailabilityMode` field and flag

## Diff

### src/config/config.go

```diff
diff --git a/src/config/config.go b/src/config/config.go
index cc38179..a9a9bc5 100644
--- a/src/config/config.go
+++ b/src/config/config.go
@@ -41,6 +41,7 @@ type Config struct {
 	EnableSkipMcoReboot         bool
 	NotifyNumReboots            bool
 	CoreosImage                 string
+	HighAvailabilityMode        string
 }

 func printHelpAndExit(err error) {
@@ -81,6 +82,7 @@ func (c *Config) ProcessArgs(args []string) {
 	flagSet.BoolVar(&c.EnableSkipMcoReboot, "enable-skip-mco-reboot", false, "indicate assisted installer to generate settings to match MCO requirements for skipping reboot after firstboot")
 	flagSet.BoolVar(&c.NotifyNumReboots, "notify-num-reboots", false, "indicate number of reboots should be notified as event")
 	flagSet.StringVar(&c.CoreosImage, "coreos-image", "", "CoreOS image to install to the existing root")
+	flagSet.StringVar(&c.HighAvailabilityMode, "high-availability-mode", "", "high-availability expectations, \"Full\" which represents the behavior in a \"normal\" cluster. Use 'None' for single-node deployment. Leave this value as \"\" for workers as we do not care about HA mode for workers.")

 	var installerArgs string
 	flagSet.StringVar(&installerArgs, "installer-args", "", "JSON array of additional coreos-installer arguments")
```

### src/k8s_client/k8s_client.go

```diff
diff --git a/src/k8s_client/k8s_client.go b/src/k8s_client/k8s_client.go
index 584fda6..5862ea7 100644
--- a/src/k8s_client/k8s_client.go
+++ b/src/k8s_client/k8s_client.go
@@ -38,7 +38,6 @@ import (
 	certificatesClient "k8s.io/client-go/kubernetes/typed/certificates/v1"
 	"k8s.io/client-go/tools/clientcmd"
 	runtimeclient "sigs.k8s.io/controller-runtime/pkg/client"
-	runtimeconfig "sigs.k8s.io/controller-runtime/pkg/client/config"

 	"github.com/openshift/assisted-installer/src/ops"
 	"github.com/openshift/assisted-installer/src/utils"
@@ -89,6 +88,7 @@ type K8SClient interface {
 	IsClusterCapabilityEnabled(configv1.ClusterVersionCapability) (bool, error)
 	UntaintNode(name string) error
 	PatchMachineConfigPoolPaused(pause bool, mcpName string) error
+	GetMachineConfig(name string) (*mcfgv1.MachineConfig, error)
 }

 type K8SClientBuilder func(configPath string, logger logrus.FieldLogger) (K8SClient, error)
@@ -133,32 +133,31 @@ func NewK8SClient(configPath string, logger logrus.FieldLogger) (K8SClient, erro
 	if err != nil {
 		return &k8sClient{}, errors.Wrap(err, "creating openshift config client")
 	}
-	var runtimeClient runtimeclient.Client
-	if configPath == "" {
-		scheme := runtime.NewScheme()
-		err = clientgoscheme.AddToScheme(scheme)
-		if err != nil {
-			return &k8sClient{}, errors.Wrap(err, "failed to add scheme to")
-		}
+	// Always create runtime client with full scheme support
+	scheme := runtime.NewScheme()
+	err = clientgoscheme.AddToScheme(scheme)
+	if err != nil {
+		return &k8sClient{}, errors.Wrap(err, "failed to add scheme to")
+	}

-		err = metal3v1alpha1.AddToScheme(scheme)
-		if err != nil {
-			return &k8sClient{}, errors.Wrap(err, "failed to add BMH scheme")
-		}
-		err = machinev1beta1.AddToScheme(scheme)
-		if err != nil {
-			return &k8sClient{}, errors.Wrap(err, "failed to add Machine scheme")
-		}
+	err = metal3v1alpha1.AddToScheme(scheme)
+	if err != nil {
+		return &k8sClient{}, errors.Wrap(err, "failed to add BMH scheme")
+	}
+	err = machinev1beta1.AddToScheme(scheme)
+	if err != nil {
+		return &k8sClient{}, errors.Wrap(err, "failed to add Machine scheme")
+	}

-		err = mcfgv1.AddToScheme(scheme)
-		if err != nil {
-			return &k8sClient{}, errors.Wrap(err, "failed to add MCP scheme")
-		}
+	err = mcfgv1.AddToScheme(scheme)
+	if err != nil {
+		return &k8sClient{}, errors.Wrap(err, "failed to add MCP scheme")
+	}

-		runtimeClient, err = runtimeclient.New(runtimeconfig.GetConfigOrDie(), runtimeclient.Options{Scheme: scheme})
-		if err != nil {
-			return &k8sClient{}, errors.Wrap(err, "failed to create runtime client")
-		}
+	// Use the config we already loaded (works with both in-cluster and kubeconfig)
+	runtimeClient, err := runtimeclient.New(config, runtimeclient.Options{Scheme: scheme})
+	if err != nil {
+		return &k8sClient{}, errors.Wrap(err, "failed to create runtime client")
 	}

 	return &k8sClient{logger, client, ocClient, csvClient, runtimeClient, csrClient,
@@ -713,3 +712,12 @@ func (c *k8sClient) PatchMachineConfigPoolPaused(pause bool, mcpName string) err
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
```

### src/installer/installer.go

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
```

### src/k8s_client/mock_k8s_client.go

```diff
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

1. Build the patched image (note: use `agent-installer-orchestrator` for agent-based installs):
   ```bash
   cd upstream/assisted-installer
   podman build --platform linux/amd64 -f Dockerfile.assisted-installer . \
     -t registry.gw.lo/openshift/release:agent-installer-orchestrator \
     --label "io.openshift.release.operator=true"
   ```

2. Push to local registry:
   ```bash
   podman push --tls-verify=false registry.gw.lo/openshift/release:agent-installer-orchestrator
   ```

3. Create a new release with the patched orchestrator (run on registry host):
   ```bash
   oc adm release new \
     --from-release=registry.gw.lo/openshift/release:4.18.30-x86_64 \
     --to-image=registry.gw.lo/openshift/release:4.18.30-x86_64 \
     --insecure=true \
     agent-installer-orchestrator=registry.gw.lo/openshift/release:agent-installer-orchestrator
   ```

4. Re-extract openshift-install from the new release:
   ```bash
   oc adm release extract --command=openshift-install \
     --to=/var/lib/openshift-cache \
     registry.gw.lo/openshift/release:4.18.30-x86_64 --insecure=true
   ```

5. The next agent-based install will use the patched orchestrator.

## Important Notes

- **Component name**: Agent-based installs use `agent-installer-orchestrator`, NOT `baremetal-installer` (which is for IPI installs)
- Both are built from the same repo (`assisted-installer`) using different Dockerfiles
- The release image embeds the digest, so you must re-extract `openshift-install` after creating a new release

## Related Issues

- This fix addresses a timing issue where MCO annotations become stale before the rendezvous host reboots
- The existing 1-minute reboot delay (for OCPBUGS-5988 RBAC bug) does not prevent this issue
- The original `runtimeClient` initialization bug would cause a nil pointer panic when trying to use `GetMachineConfig()`
