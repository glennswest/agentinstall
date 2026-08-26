# Changelog

## [Unreleased]

### 2026-08-25
- **docs:** Rewrite `README.md` from the actual scripts — FastRegistry + PXE-boot flow on g8 (was stale Quay/`registry.gw.lo` ISO-attach flow); documents install.sh steps, config.sh reference, all scripts, monitoring, and troubleshooting

### 2026-08-08
- **docs:** Add `ECOSYSTEM.md` mapping the OpenShift agent-install components (agentinstall, agent-sno-baremetal, agent-monitor, fastregistry, pxemanager, quick-quay) with repos and usage
- **chore:** Widen `.gitignore` pull-secret pattern to `pullsecret.json*` (covers `.bak` copies)
