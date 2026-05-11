# Plan: Next Interaction - Taking Over the Network

## Goal
Identify the "missing" nodes and prepare the ARM64 Talos cluster for Cozystack.

## Phase 1: Network Diagnosis
- **IPv6 Discovery:** Probing `ff02::1` (all-nodes multicast) to find nodes that didn't get IPv4.
- **DHCP Traffic Analysis:** Use `tcpdump` to watch for `DHCP DISCOVER` packets from the unconfigured nodes.
- **Helper DHCP:** Consider running a minimal DHCP server on `devops3` to assign temporary IPs to the `bb00x` cluster.

## Phase 2: Leveraging Prior Art
- **Review Local Repo:** Investigate `/Users/yebyen/u/c/cozystack-moon-and-back` for:
    - `simple-talos-launch.sh` (The single-pass deployment logic).
    - `time-server-patch.yaml`.
    - ARM64-specific registry mirror configurations.
- **Registry Cache:** Set up a pull-through cache on `devops3` to optimize the deployment (based on the "Hydrogen-6" doc).

## Phase 3: Cluster Bootstrapping
- **Configuration Generation:** Use `talosctl gen config` with the bare-metal/arm64 overrides.
- **Single-Pass Launch:** Implement the single-pass deployment to ensure PKI consistency.
- **Verify "Maintenance" Mode:** Once IPs are assigned, verify nodes are ready for installation.

## Phase 4: Cozystack Preparation
- **CNI Strategy:** Prepare configurations for "bare node" deployment (disabling Flannel/Kube-proxy if required by Cozystack).
- **ARM64 Asset Validation:** Confirm availability of all required Cozystack ARM64 images.
