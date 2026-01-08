# Install Notes

## MCO Stale Annotation Autofix (removed)

During agent-based installs, there's a race condition where nodes get annotated with a
bootstrap-time MachineConfig that gets garbage collected when the MCO takes over. This
leaves nodes in a degraded state looking for a config that doesn't exist.

The following autofix code was removed from install.sh Step 6.5. It can be re-added if
the sequenced install (powering off workers until control plane is ready) doesn't solve
the issue:

```bash
# Check for missing config issue and fix it
if [ "$DEGRADED" != "0" ] && [ "$DEGRADED" != "unknown" ]; then
    CURRENT_RENDERED=$(oc get mc -o name 2>/dev/null | grep rendered-master | head -1 | sed 's|machineconfig.machineconfiguration.openshift.io/||')
    if [ -n "$CURRENT_RENDERED" ]; then
        for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            DESIRED=$(oc get node "$node" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}' 2>/dev/null)
            # Check if desired config exists
            if [ -n "$DESIRED" ] && ! oc get mc "$DESIRED" &>/dev/null; then
                echo "  Fixing stale MC annotation on $node..."
                oc patch node "$node" --type merge -p "{\"metadata\":{\"annotations\":{\"machineconfiguration.openshift.io/desiredConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/currentConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/state\":\"Done\",\"machineconfiguration.openshift.io/reason\":\"\"}}}" 2>/dev/null || true
            fi
        done
    fi
fi
```

### Manual fix command

If you need to manually fix the stale annotation issue:

```bash
# Get the current valid rendered config
CURRENT_RENDERED=$(oc get mc -o name | grep rendered-master | head -1 | sed 's|machineconfig.machineconfiguration.openshift.io/||')

# Patch each master node
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
    oc patch node "$node" --type merge -p "{\"metadata\":{\"annotations\":{\"machineconfiguration.openshift.io/desiredConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/currentConfig\":\"${CURRENT_RENDERED}\",\"machineconfiguration.openshift.io/state\":\"Done\",\"machineconfiguration.openshift.io/reason\":\"\"}}}"
done
```
