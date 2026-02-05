#!/bin/bash
# Agent-based OpenShift installation using local registry
# Usage: ./install.sh <version>
# Example: ./install.sh 4.14.10

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/vm.sh"

# Add ~/.local/bin to PATH for openshift-install
export PATH="${HOME}/.local/bin:${PATH}"

if [ -z "$1" ]; then
    echo "Usage: $0 <ocp-version>"
    echo "Example: $0 4.18.10"
    echo "Example: $0 4.18.z   # Install latest 4.18.x release"
    echo "Example: $0 4.18     # Install latest 4.18.x release"
    exit 1
fi

OCP_VERSION=$(resolve_latest_version "$1")

echo "=========================================="
echo "Agent-Based OpenShift Installation"
echo "Version: ${OCP_VERSION}"
echo "Registry: ${LOCAL_REGISTRY}"
echo "=========================================="

# Record install start
record_install_start "${OCP_VERSION}"

# Trap to record failure on exit
trap 'if [ $? -ne 0 ]; then record_install_end false; fi' EXIT

# Step 0: Stop all VMs first (must complete before anything else)
echo ""
echo "[Step 0] Stopping all VMs..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweroff_vm "$vmid"
done

# Verify all VMs are stopped
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    status=$(ssh root@${PVE_HOST} "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null)
    if [ "$status" != "stopped" ]; then
        echo "ERROR: VM ${vmid} is still ${status}! Cannot proceed."
        exit 1
    fi
done
echo "All VMs stopped."

# Pre-flight check: Verify key registry artifacts exist
echo ""
echo "[Pre-flight] Checking registry artifacts..."
REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
RELEASE_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_VERSION}-${ARCHITECTURE}"

# Check release image exists
if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@${REGISTRY_HOST}" "oc image info ${RELEASE_IMAGE} --registry-config=/root/pullsecret-combined.json --insecure >/dev/null 2>&1"; then
    echo "ERROR: Release image not found: ${RELEASE_IMAGE}"
    echo "Run mirror first to sync the release to your registry."
    exit 1
fi
echo "  ✓ Release image exists"

# Get machine-os-images digest and verify it exists
MOS_DIGEST=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@${REGISTRY_HOST}" "oc adm release info ${RELEASE_IMAGE} --registry-config=/root/pullsecret-combined.json --insecure 2>/dev/null | grep machine-os-images | awk '{print \$2}'" 2>/dev/null)
if [ -n "$MOS_DIGEST" ]; then
    MOS_IMAGE="${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}@${MOS_DIGEST}"
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@${REGISTRY_HOST}" "oc image info ${MOS_IMAGE} --registry-config=/root/pullsecret-combined.json --insecure >/dev/null 2>&1"; then
        echo "ERROR: machine-os-images not found: ${MOS_IMAGE}"
        echo "This component is required for ISO generation."
        echo "Re-run mirror to sync all release components."
        exit 1
    fi
    echo "  ✓ machine-os-images exists"
else
    echo "  ! Could not verify machine-os-images (may be older release)"
fi

# Deep verification: check all release image blobs exist in registry
# Catches the case where manifests exist but underlying layer blobs are missing
echo "  Verifying release image blobs..."
BLOB_EXIT=0
BLOB_OUTPUT=$(cat <<'BLOBCHECK' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "root@${REGISTRY_HOST}" "python3 - '${RELEASE_IMAGE}' '${LOCAL_REGISTRY}' '${LOCAL_REPOSITORY}'"
import sys, json, subprocess, ssl, traceback, re
import urllib.request, urllib.error, urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

release_image, registry, repo = sys.argv[1], sys.argv[2], sys.argv[3]

with open('/root/pullsecret-combined.json') as f:
    ps = json.load(f)
basic_auth = None
for k in ps.get('auths', {}):
    if registry in k:
        basic_auth = 'Basic ' + ps['auths'][k]['auth']
        break

if not basic_auth:
    print(f'  WARNING: No auth found for {registry} in pull secret', file=sys.stderr)
    print(f'  Available keys: {list(ps.get("auths", {}).keys())}', file=sys.stderr)

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

error_sample = []

def negotiate_auth():
    """Negotiate registry auth - handles both Basic and Bearer token auth."""
    print(f'  Testing registry API at https://{registry}/v2/...', file=sys.stderr)
    req = urllib.request.Request(f'https://{registry}/v2/', method='GET')
    if basic_auth:
        req.add_header('Authorization', basic_auth)
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        print(f'  Registry API OK (Basic auth, status {resp.status})', file=sys.stderr)
        return basic_auth
    except urllib.error.HTTPError as e:
        if e.code != 401:
            if e.code == 404:
                print(f'  Registry API returned 404 - may not be a v2 registry', file=sys.stderr)
            else:
                print(f'  Registry API returned HTTP {e.code}', file=sys.stderr)
            sys.exit(1)
        # 401 - check for Bearer token auth challenge
        www_auth = e.headers.get('WWW-Authenticate', '')
        if 'Bearer' not in www_auth:
            print(f'  ERROR: Registry returned 401 Unauthorized - auth may be wrong', file=sys.stderr)
            print(f'  Auth header: {"Basic <set>" if basic_auth else "NONE"}', file=sys.stderr)
            sys.exit(1)
        # Parse Bearer realm="...",service="...",scope="..."
        params = dict(re.findall(r'(\w+)="([^"]*)"', www_auth))
        realm = params.get('realm')
        service = params.get('service', '')
        if not realm:
            print(f'  ERROR: Bearer challenge missing realm: {www_auth}', file=sys.stderr)
            sys.exit(1)
        print(f'  Registry uses token auth (realm: {realm})', file=sys.stderr)
        # Request token with pull scope for our repo
        scope = f'repository:{repo}:pull'
        token_url = f'{realm}?service={urllib.parse.quote(service)}&scope={urllib.parse.quote(scope)}'
        token_req = urllib.request.Request(token_url)
        if basic_auth:
            token_req.add_header('Authorization', basic_auth)
        try:
            token_resp = urllib.request.urlopen(token_req, context=ctx, timeout=10)
            token_data = json.loads(token_resp.read())
            token = token_data.get('token') or token_data.get('access_token')
            if not token:
                print(f'  ERROR: Token response missing token field', file=sys.stderr)
                sys.exit(1)
            # Verify token works
            verify_req = urllib.request.Request(f'https://{registry}/v2/', method='GET')
            verify_req.add_header('Authorization', f'Bearer {token}')
            verify_resp = urllib.request.urlopen(verify_req, context=ctx, timeout=10)
            print(f'  Registry API OK (Bearer token, status {verify_resp.status})', file=sys.stderr)
            return f'Bearer {token}'
        except urllib.error.HTTPError as te:
            print(f'  ERROR: Token request failed (HTTP {te.code})', file=sys.stderr)
            print(f'  Token URL: {token_url}', file=sys.stderr)
            sys.exit(1)
        except Exception as te:
            print(f'  ERROR: Token request failed: {type(te).__name__}: {te}', file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f'  ERROR: Cannot reach registry API: {type(e).__name__}: {e}', file=sys.stderr)
        sys.exit(1)

auth = negotiate_auth()

def api(path, method='HEAD'):
    req = urllib.request.Request(
        f'https://{registry}/v2/{repo}/{path}', method=method)
    if auth:
        req.add_header('Authorization', auth)
    req.add_header('Accept',
        'application/vnd.docker.distribution.manifest.v2+json,'
        'application/vnd.oci.image.manifest.v1+json,'
        'application/vnd.docker.distribution.manifest.list.v2+json,'
        'application/vnd.oci.image.index.v1+json')
    try:
        r = urllib.request.urlopen(req, context=ctx, timeout=30)
        return r.status, r.read() if method == 'GET' else b''
    except urllib.error.HTTPError as e:
        if len(error_sample) < 3:
            error_sample.append(f'HTTP {e.code} for {path}')
        return e.code, b''
    except Exception as e:
        if len(error_sample) < 3:
            error_sample.append(f'{type(e).__name__}: {e} for {path}')
        return 0, b''

# Get image pullspecs from release
r = subprocess.run(
    ['oc', 'adm', 'release', 'info', release_image,
     '--pullspecs', '--registry-config=/root/pullsecret-combined.json',
     '--insecure'],
    capture_output=True, text=True)
if r.returncode != 0:
    print(f'Failed to get release info: {r.stderr}', file=sys.stderr)
    sys.exit(1)

digests = set()
for line in r.stdout.split('\n'):
    if '@sha256:' in line:
        for word in line.split():
            if '@sha256:' in word:
                digests.add(word.split('@')[1])
                break

if not digests:
    print('No image digests found in release', file=sys.stderr)
    sys.exit(1)

print(f'  Checking {len(digests)} images...', file=sys.stderr)

# Test first manifest before parallel run
test_digest = next(iter(digests))
print(f'  Testing single manifest fetch: {test_digest[:20]}...', file=sys.stderr)
test_s, test_body = api(f'manifests/{test_digest}', 'GET')
if test_s != 200:
    print(f'  ERROR: Test manifest fetch failed (status {test_s})', file=sys.stderr)
    if error_sample:
        for e in error_sample:
            print(f'    {e}', file=sys.stderr)
    print(f'  URL: https://{registry}/v2/{repo}/manifests/{test_digest}', file=sys.stderr)
    sys.exit(1)
print(f'  Test manifest OK ({len(test_body)} bytes)', file=sys.stderr)

# Fetch manifests in parallel and collect blob digests
blobs = set()
errors = []

def fetch_manifest(digest):
    s, body = api(f'manifests/{digest}', 'GET')
    if s != 200:
        return digest, None
    try:
        m = json.loads(body)
        found = set()
        # Handle manifest list / OCI index (multi-arch)
        if 'manifests' in m:
            for sub in m['manifests']:
                s2, body2 = api(f'manifests/{sub["digest"]}', 'GET')
                if s2 == 200:
                    m2 = json.loads(body2)
                    if 'config' in m2:
                        found.add(m2['config']['digest'])
                    for l in m2.get('layers', []):
                        found.add(l['digest'])
        else:
            if 'config' in m:
                found.add(m['config']['digest'])
            for l in m.get('layers', []):
                found.add(l['digest'])
        return digest, found
    except Exception as e:
        if len(error_sample) < 3:
            error_sample.append(f'Parse error for {digest[:20]}: {e}')
        return digest, None

with ThreadPoolExecutor(max_workers=10) as pool:
    futs = {pool.submit(fetch_manifest, d): d for d in digests}
    done = 0
    for f in as_completed(futs):
        d, layer_set = f.result()
        done += 1
        if layer_set is None:
            errors.append(d)
        else:
            blobs.update(layer_set)
        if done % 50 == 0:
            print(f'  Parsed {done}/{len(digests)} manifests...', file=sys.stderr)

if not blobs and digests:
    print(f'  ERROR: 0 blobs found from {len(digests)} images - registry may be corrupt', file=sys.stderr)
    if error_sample:
        print(f'  Error details:', file=sys.stderr)
        for e in error_sample:
            print(f'    {e}', file=sys.stderr)
    print(f'FAILED:0 blobs from {len(digests)} images, {len(errors)} manifest errors')
    sys.exit(1)

print(f'  Verifying {len(blobs)} unique blobs on disk...', file=sys.stderr)

# Check blob files exist on disk (HTTP HEAD lies - quay returns 200 even for missing files)
import os
storage_root = '/var/lib/quay/storage'
missing = []
for b in blobs:
    # digest format: sha256:abc123... -> storage path: sha256/ab/abc123...
    algo, hashval = b.split(':', 1)
    blob_path = os.path.join(storage_root, algo, hashval[:2], hashval)
    if not os.path.exists(blob_path):
        missing.append(b)

if errors:
    for e in errors:
        print(f'MANIFEST_ERROR:{e}')
if missing:
    for m in missing:
        print(f'MISSING_BLOB:{m}')
    print(f'FAILED:{len(missing)} missing blobs, {len(errors)} manifest errors')
    sys.exit(1)
else:
    print(f'VERIFIED:{len(blobs)}')
    sys.exit(0)
BLOBCHECK
) || BLOB_EXIT=$?

if [ $BLOB_EXIT -ne 0 ]; then
    MISSING_BLOBS=$(echo "$BLOB_OUTPUT" | grep "^MISSING_BLOB:" | cut -d: -f2-)
    MISSING_COUNT=$(echo "$MISSING_BLOBS" | wc -l | tr -d ' ')
    echo ""
    echo "  Found ${MISSING_COUNT} missing blob(s) on disk - attempting auto-repair..."

    # For each missing blob, download from upstream and place in quay storage
    REPAIR_FAILED=0
    UPSTREAM_REGISTRY="quay.io"
    UPSTREAM_REPO="openshift-release-dev/ocp-v4.0-art-dev"
    while IFS= read -r blob_digest; do
        [ -z "$blob_digest" ] && continue
        algo="${blob_digest%%:*}"
        hashval="${blob_digest#*:}"
        storage_dir="/var/lib/quay/storage/${algo}/${hashval:0:2}"
        storage_path="${storage_dir}/${hashval}"
        echo "  Repairing ${hashval:0:16}..."

        # Download blob from upstream via registry API and place directly in storage
        REPAIR_OK=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "root@${REGISTRY_HOST}" "
            mkdir -p '${storage_dir}'
            # Get upstream auth token
            TOKEN=\$(curl -sL 'https://auth.quay.io/v2/auth?service=quay.io&scope=repository:${UPSTREAM_REPO}:pull' \
                --authfile /root/pullsecret-combined.json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('token',''))\" 2>/dev/null) || true
            if [ -z \"\$TOKEN\" ]; then
                # Try with basic auth from pull secret
                AUTH=\$(python3 -c \"import json; ps=json.load(open('/root/pullsecret-combined.json')); print(ps['auths'].get('quay.io',{}).get('auth',''))\" 2>/dev/null)
                TOKEN=\$(curl -sL -H \"Authorization: Basic \$AUTH\" 'https://auth.quay.io/v2/auth?service=quay.io&scope=repository:${UPSTREAM_REPO}:pull' 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('token',''))\" 2>/dev/null) || true
            fi
            if [ -n \"\$TOKEN\" ]; then
                HTTP_CODE=\$(curl -sL -o '${storage_path}' -w '%{http_code}' \
                    -H \"Authorization: Bearer \$TOKEN\" \
                    'https://quay.io/v2/${UPSTREAM_REPO}/blobs/${blob_digest}')
                if [ \"\$HTTP_CODE\" = '200' ] && [ -f '${storage_path}' ] && [ -s '${storage_path}' ]; then
                    # Verify downloaded blob matches expected digest
                    ACTUAL=\$(sha256sum '${storage_path}' | cut -d' ' -f1)
                    if [ \"\$ACTUAL\" = '${hashval}' ]; then
                        echo 'OK'
                    else
                        rm -f '${storage_path}'
                        echo 'CHECKSUM_MISMATCH'
                    fi
                else
                    rm -f '${storage_path}'
                    echo 'DOWNLOAD_FAILED'
                fi
            else
                echo 'AUTH_FAILED'
            fi
        " 2>/dev/null)

        if [ "$REPAIR_OK" = "OK" ]; then
            echo "    ✓ Repaired"
        else
            echo "    ✗ Repair failed: ${REPAIR_OK}"
            REPAIR_FAILED=$((REPAIR_FAILED + 1))
        fi
    done <<< "$MISSING_BLOBS"

    if [ $REPAIR_FAILED -gt 0 ]; then
        echo ""
        echo "ERROR: ${REPAIR_FAILED} blob(s) could not be repaired."
        echo "Re-run: ./mirror.sh ${OCP_VERSION} --wipe"
        exit 1
    fi
    echo "  ✓ All missing blobs repaired from upstream"
fi

BLOB_COUNT=$(echo "$BLOB_OUTPUT" | grep "^VERIFIED:" | cut -d: -f2)
if [ -n "$BLOB_COUNT" ]; then
    echo "  ✓ All ${BLOB_COUNT} blobs verified intact"
else
    # Blobs were repaired, count from output
    TOTAL_BLOBS=$(echo "$BLOB_OUTPUT" | grep -oP 'Verifying \K[0-9]+')
    echo "  ✓ All ${TOTAL_BLOBS} blobs verified (with repairs)"
fi

echo ""
echo "Registry pre-flight checks passed."

# Step 0.5: Update registry certificate in install-config.yaml
# Fetch the cert the registry serves via HTTP - always in sync, no SSH needed.
echo ""
echo "[Pre-flight] Updating registry certificate in install-config..."
REGISTRY_HOST="${LOCAL_REGISTRY%%:*}"
REGISTRY_CERT=$(curl -sf "http://${REGISTRY_HOST}/ca.crt")
if [ -z "$REGISTRY_CERT" ]; then
    echo "ERROR: Could not fetch certificate from http://${REGISTRY_HOST}/ca.crt"
    exit 1
fi
LIVE_FP=$(echo "$REGISTRY_CERT" | openssl x509 -fingerprint -noout 2>/dev/null)
echo "  Live registry cert: ${LIVE_FP}"

# Update the certificate in install-config.yaml using python for reliable YAML handling
python3 -c "
import sys, re

cert = '''${REGISTRY_CERT}'''
indented_cert = '\n'.join('  ' + line for line in cert.strip().split('\n'))

with open('${SCRIPT_DIR}/install-config.yaml', 'r') as f:
    content = f.read()

pattern = r'(additionalTrustBundle: \|)\n(  -----BEGIN CERTIFICATE-----\n.*?  -----END CERTIFICATE-----)'
replacement = r'\1\n' + indented_cert

new_content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
if count == 0:
    print('ERROR: Could not find additionalTrustBundle in install-config.yaml')
    sys.exit(1)

with open('${SCRIPT_DIR}/install-config.yaml', 'w') as f:
    f.write(new_content)

print('Certificate updated successfully')
"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to update certificate in install-config.yaml"
    exit 1
fi

# Verify the cert in install-config.yaml matches what the registry serves
CONFIG_FP=$(python3 -c "
import re
with open('${SCRIPT_DIR}/install-config.yaml') as f:
    content = f.read()
m = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', content, re.DOTALL)
if m:
    print(m.group(0).replace('  ', ''))
" | openssl x509 -fingerprint -noout 2>/dev/null)

if [ "$LIVE_FP" != "$CONFIG_FP" ]; then
    echo "ERROR: Certificate mismatch after update!"
    echo "  Registry serves: ${LIVE_FP}"
    echo "  install-config:  ${CONFIG_FP}"
    exit 1
fi
echo "  ✓ Registry certificate updated and verified"

# Step 1: Pull installer from local registry
echo ""
echo "[Step 1] Pulling openshift-install from registry..."
"${SCRIPT_DIR}/pull-from-registry.sh" "${OCP_VERSION}"

# Step 2: Prepare installation directory
echo ""
echo "[Step 2] Preparing installation directory..."
rm -rf "${SCRIPT_DIR}/gw"
mkdir -p "${SCRIPT_DIR}/gw"

# Copy and prepare install-config
if [ ! -f "${SCRIPT_DIR}/install-config.yaml" ]; then
    echo "ERROR: install-config.yaml not found!"
    echo "Please create install-config.yaml from install-config.yaml.template"
    exit 1
fi

cp "${SCRIPT_DIR}/install-config.yaml" "${SCRIPT_DIR}/gw/install-config.yaml"
cp "${SCRIPT_DIR}/agent-config.yaml" "${SCRIPT_DIR}/gw/"

# Step 3: Create agent ISO and prepare VMs
echo ""
echo "[Step 3] Creating agent ISO..."

# Delete old ISO from Proxmox (VMs already stopped in Step 0)
echo "Deleting old ISO from Proxmox..."
ssh root@${PVE_HOST} "rm -f ${ISO_PATH}/${ISO_NAME}"

# Wipe all disks (must complete before ISO generation to ensure clean state)
echo "Wiping disks..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    erase_disk "$vmid"
done

# Verify all disks are wiped (check first 512 bytes are zero - no MBR/GPT)
echo "Verifying disks are wiped..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    lvmname="vm-${vmid}-disk-0"
    # Check if disk has any non-zero bytes in first 512 bytes
    nonzero=$(ssh root@${PVE_HOST} "dd if=/dev/${LVM_VG}/${lvmname} bs=512 count=1 2>/dev/null | xxd -p | tr -d '\n' | sed 's/0//g'" 2>/dev/null || true)
    if [ -n "$nonzero" ]; then
        echo "ERROR: Disk ${lvmname} still has data! Wipe failed."
        exit 1
    fi
    echo "  ${lvmname}: clean"
done
echo "All disks verified clean."

# Generate ISO (foreground so we see progress)
generate_iso_remote "${OCP_VERSION}" "${SCRIPT_DIR}/gw/install-config.yaml" "${SCRIPT_DIR}/gw/agent-config.yaml"
ISO_RESULT=$?
if [ $ISO_RESULT -eq 0 ]; then
    echo "Remote ISO generation successful"
elif [ $ISO_RESULT -eq 2 ]; then
    echo "ERROR: ISO checksum verification failed - aborting"
    exit 1
else
    echo "Remote generation failed, falling back to local..."
    cd "${SCRIPT_DIR}/gw"
    openshift-install agent create image
    cd "${SCRIPT_DIR}"
    echo "Uploading agent ISO to Proxmox..."
    upload_iso "${SCRIPT_DIR}/gw/agent.x86_64.iso"
fi

# Remove config files from gw directory - they're consumed during ISO generation
# and their presence causes conflicts with the state file during wait-for commands
rm -f "${SCRIPT_DIR}/gw/install-config.yaml" "${SCRIPT_DIR}/gw/agent-config.yaml"


# Step 4: Setup kubeconfig
echo ""
echo "[Step 4] Setting up kubeconfig..."
mkdir -p "${KUBECONFIG_DIR}"
rm -f "${KUBECONFIG_DIR}/config"
cp "${SCRIPT_DIR}/gw/auth/kubeconfig" "${KUBECONFIG_DIR}/config"

# Step 5: Verify ISO checksum and power on all nodes
echo ""
echo "[Step 5] Verifying ISO checksum before starting nodes..."
EXPECTED_CHECKSUM=$(cat "${SCRIPT_DIR}/gw/.iso_checksum" 2>/dev/null || echo "")
if [ -z "$EXPECTED_CHECKSUM" ]; then
    echo "WARNING: No saved checksum found, using size check only"
    ISO_SIZE=$(ssh root@${PVE_HOST} "stat -c%s ${ISO_PATH}/${ISO_NAME} 2>/dev/null || echo 0")
    if [ "$ISO_SIZE" -lt 1000000000 ]; then
        echo "ERROR: ISO missing or too small on Proxmox (${ISO_SIZE} bytes)"
        exit 1
    fi
    echo "ISO size verified: ${ISO_SIZE} bytes"
else
    ACTUAL_CHECKSUM=$(ssh root@${PVE_HOST} "sha256sum ${ISO_PATH}/${ISO_NAME} 2>/dev/null | cut -d' ' -f1 || echo ''")
    if [ -z "$ACTUAL_CHECKSUM" ]; then
        echo "ERROR: ISO missing on Proxmox!"
        exit 1
    fi
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        echo "ERROR: ISO checksum mismatch!"
        echo "  Expected: ${EXPECTED_CHECKSUM}"
        echo "  Actual:   ${ACTUAL_CHECKSUM}"
        echo "The ISO on Proxmox does not match the generated ISO."
        exit 1
    fi
    echo "ISO checksum verified: ${ACTUAL_CHECKSUM:0:16}..."
fi

echo ""
echo "[Step 5] Attaching ISO and starting all nodes..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    attach_iso "$vmid"
done

# Verify ISO is attached to all VMs
echo "Verifying ISO attachment..."
for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    ide2=$(ssh root@${PVE_HOST} "qm config ${vmid} | grep ide2")
    if ! echo "$ide2" | grep -q "${ISO_NAME}"; then
        echo "ERROR: ISO not attached to VM ${vmid}!"
        echo "  Got: $ide2"
        exit 1
    fi
    echo "  VM ${vmid}: ISO attached"
done

for vmid in "${CONTROL_VM_IDS[@]}" "${WORKER_VM_IDS[@]}"; do
    poweron_vm "$vmid"
done

# Start monitor GUI in background
echo ""
echo "Starting installation monitor..."
"${SCRIPT_DIR}/venv/bin/python3" "${SCRIPT_DIR}/monitor.py" &
disown 2>/dev/null || true

# Step 6: Wait for bootstrap completion
echo ""
echo "[Step 6] Waiting for bootstrap to complete..."

# Check for kube-apiserver crash loop (bad ISO detection)
echo "Checking for bootkube health..."
KUBE_ERROR_COUNT=0
for i in {1..6}; do
    sleep 30
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
       core@${RENDEZVOUS_IP} "sudo journalctl -u bootkube.service --no-pager 2>/dev/null | grep -q 'missing operand kubernetes version'" 2>/dev/null; then
        KUBE_ERROR_COUNT=$((KUBE_ERROR_COUNT + 1))
        echo "Warning: kube-apiserver render failing ($KUBE_ERROR_COUNT/3)"
        if [ $KUBE_ERROR_COUNT -ge 3 ]; then
            echo ""
            echo "ERROR: kube-apiserver is crash-looping with 'missing operand kubernetes version'"
            echo "This indicates the ISO was generated with a mismatched openshift-install binary."
            echo "Fix: Re-extract openshift-install from registry and regenerate ISO"
            echo ""
            exit 1
        fi
    else
        break
    fi
done

# Use stdbuf to force line buffering on output
if command -v stdbuf &>/dev/null; then
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for bootstrap-complete
else
    openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for bootstrap-complete
fi

# Step 7: Wait for install completion
echo ""
echo "[Step 7] Waiting for installation to complete..."
if command -v stdbuf &>/dev/null; then
    stdbuf -oL openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for install-complete
else
    openshift-install --dir="${SCRIPT_DIR}/gw" agent wait-for install-complete
fi

# Record successful install
record_install_end true

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "Kubeconfig: ${KUBECONFIG_DIR}/config"
echo "=========================================="

# Show install history
show_install_history
