#!/bin/bash
# Auto-approve pending CSRs during installation
# Run this in a separate terminal during installation

echo "Watching for pending CSRs..."
while true; do
    pending=$(oc get csr 2>/dev/null | grep Pending | awk '{print $1}')
    if [ -n "$pending" ]; then
        echo "Approving CSRs: $pending"
        echo "$pending" | xargs -r oc adm certificate approve
    fi
    sleep 30
done
