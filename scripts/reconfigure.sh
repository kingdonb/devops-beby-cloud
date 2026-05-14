#!/usr/bin/env bash
#
# reconfigure.sh — In-place EPHEMERAL migration from current disk to a new one
#                  on a Talos node, preserving /var contents bit-by-bit.
#
# Tested with: Talos v1.13.0
#
# Subcommands:
#   prepare <node-ip> <volume-config-yaml>
#       Preflight, cordon+drain, deploy a privileged pod that:
#         - partitions the target disk (GPT, PARTLABEL=EPHEMERAL + optional rest)
#         - mkfs.xfs -L EPHEMERAL
#         - rsync -aHAX /var → /mnt/new
#         - umount
#       Does NOT touch the Talos config. Node is still booting from current
#       EPHEMERAL on the old disk after this phase — safe to inspect/rollback.
#
#   apply <node-ip> <volume-config-yaml>
#       Applies the VolumeConfig patch. Talos reboots; on next boot it should
#       discover the existing PARTLABEL=EPHEMERAL on the new disk (matching
#       diskSelector) and mount it as /var.
#       Verifies post-reboot state. Uncordons.
#
# Critical risk:
#   It is ASSUMED Talos will adopt the pre-formatted EPHEMERAL partition on
#   the new disk rather than reformat it. Verify on a non-critical worker
#   first. If Talos reformats, /var is lost (but kubelet certs survive in
#   STATE; containerd cache is auto-repopulated; for CP, etcd needs a
#   separate snapshot — use migrate_cp.sh approach for CPs).
#
# Usage:
#   ./scripts/reconfigure.sh prepare 192.168.2.102 patches/worker-disks.yaml
#   ./scripts/reconfigure.sh apply   192.168.2.102 patches/worker-disks.yaml
#
# Env overrides:
#   CP_IP=192.168.2.101           CP node to fetch kubeconfig from
#   KUBECONFIG_FILE=/tmp/cozypi-kubeconfig
#   MIGRATION_IMAGE=alpine:3.20   image for the privileged migration pod
#   MIGRATION_NS=kube-system      namespace for the migration pod
#   POD_TIMEOUT=1800              seconds to wait for migration pod (default 30m)
#   SKIP_DRAIN=1                  skip cordon+drain (NOT recommended)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

CP_IP="${CP_IP:-192.168.2.101}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-/tmp/cozypi-kubeconfig}"
MIGRATION_IMAGE="${MIGRATION_IMAGE:-alpine:3.20}"
MIGRATION_NS="${MIGRATION_NS:-kube-system}"
POD_TIMEOUT="${POD_TIMEOUT:-1800}"
SKIP_DRAIN="${SKIP_DRAIN:-0}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;36m[%s]\033[0m %s\n'        "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n'  "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() {
  local prompt="${1:-Proceed?}"
  read -r -p "${prompt} [type 'yes' to continue] " ans
  [[ "${ans}" == "yes" ]] || die "aborted by user"
}

usage() {
  cat <<EOF
Usage: ./scripts/reconfigure.sh <subcommand> <args...>

  prepare <node-ip> <yaml>   Quiesce node and rsync /var onto a new EPHEMERAL
                             partition pre-created on the target disk.
                             Does NOT apply Talos config.
  apply   <node-ip> <yaml>   Apply the VolumeConfig patch; Talos reboots;
                             verify new EPHEMERAL is live; uncordon.
  inspect <node-ip>          Compare current live EPHEMERAL with the prepared
                             one (auto-detects both via PARTLABEL=EPHEMERAL).
                             Read-only, non-destructive. Prints totals, per
                             top-level dir breakdown, and a structural diff.
  help                       Show this message.

See script header for env vars and caveats.
EOF
}

# ---------------------------------------------------------------------------
# YAML / disk-selector parsing
#   The patch YAML uses CEL: `disk.transport == "nvme"`.
#   We extract the transport string with a simple regex — robust enough
#   for the shapes in patches/*.yaml.
# ---------------------------------------------------------------------------
parse_target_transport() {
  local file="$1"
  local transport
  transport="$(grep -oE 'disk\.transport[[:space:]]*==[[:space:]]*"[^"]+"' "${file}" \
              | head -1 \
              | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -n "${transport}" ]] || die "could not parse disk.transport from ${file}"
  echo "${transport}"
}

parse_ephemeral_size_gib() {
  # Pulls the minSize from the EPHEMERAL VolumeConfig block.
  # Accepts forms like '60GiB', '60 GiB'. Returns the integer GiB value.
  local file="$1"
  awk '
    /^kind:[[:space:]]*VolumeConfig/         { in_vc=1 }
    in_vc && /^name:[[:space:]]*EPHEMERAL/   { is_eph=1 }
    is_eph && /minSize:/                     { print $2; exit }
    /^---/                                   { in_vc=0; is_eph=0 }
  ' "${file}" | sed -E 's/[Gg]i[Bb]//; s/[[:space:]]//g'
}

has_linstor_block() {
  grep -qE '^kind:[[:space:]]*RawVolumeConfig' "$1"
}

# ---------------------------------------------------------------------------
# Talos queries
# ---------------------------------------------------------------------------
ensure_talosctl() {
  command -v talosctl >/dev/null || die "talosctl not in PATH"
}

node_reachable() {
  talosctl -n "$1" version --short >/dev/null 2>&1
}

# Echoes the disk ID (e.g. nvme0n1) for the first disk whose transport matches.
# Fails if no match.
find_disk_id_by_transport() {
  local node="$1"
  local transport="$2"
  local out
  out="$(talosctl -n "${node}" get disks -o yaml 2>/dev/null \
        | awk -v tx="${transport}" '
            /^node:/        { node_seen=1 }
            /^[[:space:]]*id:/      { id=$2 }
            /^[[:space:]]*transport:/ {
              gsub(/"/, "", $2)
              if ($2 == tx) { print id; exit }
            }
        ')"
  [[ -n "${out}" ]] || return 1
  echo "${out}"
}

current_ephemeral_disk_id() {
  # Find the EPHEMERAL partition row and return the parent disk ID.
  # `discoveredvolumes` has variable column widths because SIZE is "13 GB"
  # (two whitespace-separated fields), so we match by token presence
  # instead of fixed column index. Strips trailing partition suffix:
  # "mmcblk0p6" → "mmcblk0", "nvme0n1p1" → "nvme0n1".
  local node="$1"
  talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
    | awk '
        NR>1 {
          for (i=5; i<=NF; i++) {
            if ($i == "EPHEMERAL") {
              part=$4
              sub(/p?[0-9]+$/, "", part)
              print part
              exit
            }
          }
        }
      '
}

system_disk_id() {
  talosctl -n "$1" get systemdisk -o yaml 2>/dev/null \
    | awk '$1=="diskID:" || $1=="disk:" {print $2; exit}'
}

# Returns 0 if the target disk is NOT clean — i.e. cleanup is required before
# we can repartition it. Triggers on any of:
#   - partitions of the target disk (nvme0n1p1, mmcblk0p3, …)
#   - a filesystem / LVM PV signature on the bare disk itself
#   - presence of device-mapper devices anywhere on the node (likely LVs
#     activated from a PV on the target disk — they hold the disk busy)
disk_needs_cleanup() {
  local node="$1"
  local disk="$2"
  talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
    | awk -v d="${disk}" '
        NR==1                                                     { next }
        $4 ~ "^"d"p[0-9]+$" || $4 ~ "^"d"[0-9]+$"                 { f=1 }
        $4 == d && NF >= 6 && $6 != "" && $6 != "-"               { f=1 }
        $4 ~ /^dm-/                                                { f=1 }
        END                                                        { exit !f }
      '
}

# ---------------------------------------------------------------------------
# Kubernetes glue
# ---------------------------------------------------------------------------
ensure_kubeconfig() {
  command -v kubectl >/dev/null || die "kubectl not in PATH"
  log "Refreshing kubeconfig from ${CP_IP} → ${KUBECONFIG_FILE}"
  talosctl -n "${CP_IP}" kubeconfig --force "${KUBECONFIG_FILE}" \
    || die "kubeconfig refresh failed"
  export KUBECONFIG="${KUBECONFIG_FILE}"
}

resolve_node_name() {
  local node_ip="$1"
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="${node_ip}" '$2==ip{print $1; exit}'
}

# Detect role; emits "worker" or "control-plane".
node_role() {
  local node_name="$1"
  local labels
  labels="$(kubectl get node "${node_name}" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)"
  if [[ "${labels}" == *"node-role.kubernetes.io/control-plane"* ]]; then
    echo "control-plane"
  else
    echo "worker"
  fi
}

# ---------------------------------------------------------------------------
# Migration pod — runs the partition+format+rsync on the target node.
# ---------------------------------------------------------------------------
POD_NAME="reconfigure-ephemeral"

render_pod_yaml() {
  local node_name="$1"
  local disk_dev="$2"      # e.g. /dev/nvme0n1
  local eph_gib="$3"       # e.g. 60
  local with_linstor="$4"  # 0/1
  local with_cleanup="$5"  # 0/1 — tear down LVM/wipe filesystem signatures first

  # Embedded shell that runs inside the privileged pod.
  # Notes:
  #   - The host /var is the live EPHEMERAL — mounted RO into the pod.
  #   - We never touch the host's system disk (caller verifies that).
  #   - If with_cleanup=1, we deactivate any LVM VGs/PVs on the target disk
  #     and clear filesystem signatures. This is required because Talos's
  #     own `talosctl wipe disk dm-N` does not deactivate kernel dm mappings,
  #     so the parent disk stays "in use" until we tear down LVM ourselves.
  local inner
  inner=$(cat <<INNER
set -eux

DISK="${disk_dev}"
EPH_GIB="${eph_gib}"
WITH_LINSTOR="${with_linstor}"
WITH_CLEANUP="${with_cleanup}"

apk add --no-cache rsync parted xfsprogs e2fsprogs util-linux lvm2 eudev
# Verify the tools we depend on are actually present.
for tool in parted mkfs.xfs rsync wipefs lsblk pvremove vgchange; do
  command -v "\${tool}" >/dev/null || { echo "ERROR: \${tool} not installed" >&2; exit 1; }
done

echo "=== initial state ==="
lsblk -p
echo
ls -la /dev/mapper/ 2>/dev/null || true
echo
pvs 2>/dev/null || true
vgs 2>/dev/null || true
lvs 2>/dev/null || true

if [ "\${WITH_CLEANUP}" = "1" ]; then
  echo "=== LVM tear-down on \${DISK} ==="

  # Identify VGs that include our target disk as a PV. We deactivate
  # *only* those, never the host's (Talos has no LVM of its own, but
  # we still scope the operation).
  TARGET_VGS="\$(pvs --noheadings -o vg_name --select "pv_name=\${DISK}" 2>/dev/null | tr -d ' ' | grep -v '^\$' | sort -u || true)"
  echo "VGs on \${DISK}: \${TARGET_VGS:-<none>}"

  for vg in \$TARGET_VGS; do
    echo "--- deactivating VG: \${vg} ---"
    vgchange -an "\${vg}" || true
    echo "--- removing VG: \${vg} ---"
    vgremove -f -y "\${vg}" || true
  done

  # Remove any orphan device-mapper mappings that still reference our disk.
  # (vgchange -an should have handled them, but belt-and-braces.)
  for dm in \$(ls /dev/mapper/ 2>/dev/null | grep -v '^control\$' || true); do
    if dmsetup deps "/dev/mapper/\${dm}" 2>/dev/null | grep -q "\$(stat -c '%t:%T' "\${DISK}")"; then
      echo "--- removing dm mapping: \${dm} ---"
      dmsetup remove "/dev/mapper/\${dm}" || true
    fi
  done

  echo "--- pvremove \${DISK} ---"
  pvremove --force --force --yes "\${DISK}" || true

  echo "--- wipefs -af \${DISK} ---"
  wipefs -af "\${DISK}"

  partprobe "\${DISK}" || true
  udevadm settle || true
  sleep 2

  echo "=== post-cleanup state ==="
  lsblk -p "\${DISK}"
fi

# Safety: at this point the target disk must have no children.
if lsblk -no NAME "\${DISK}" | tail -n +2 | grep -q .; then
  echo "ERROR: target disk \${DISK} still has child devices — aborting" >&2
  lsblk -p "\${DISK}" >&2
  exit 1
fi

echo "=== creating GPT layout ==="
# parted is in alpine main repo and provides everything we need. The partition
# 'name' argument on a GPT-labeled disk becomes the GPT partition name, which
# Talos discovers as PARTITIONLABEL.
parted -s "\${DISK}" mklabel gpt
parted -s "\${DISK}" -- mkpart EPHEMERAL 1MiB "\${EPH_GIB}GiB"
if [ "\${WITH_LINSTOR}" = "1" ]; then
  parted -s "\${DISK}" -- mkpart linstor "\${EPH_GIB}GiB" -1
fi
parted -s "\${DISK}" print

# Force kernel to re-read; partprobe sometimes lags.
partprobe "\${DISK}" || true
udevadm settle || true
sleep 2

# Resolve partition device.
if [ -e "\${DISK}p1" ]; then
  EPH_PART="\${DISK}p1"
else
  EPH_PART="\${DISK}1"
fi
echo "EPHEMERAL partition: \${EPH_PART}"

echo "=== mkfs.xfs ==="
mkfs.xfs -f -L EPHEMERAL "\${EPH_PART}"

echo "=== mount new EPHEMERAL ==="
mkdir -p /mnt/new
mount "\${EPH_PART}" /mnt/new

echo "=== rsync /host-var/ -> /mnt/new/ ==="
# rsync exit 24 = "some files vanished before they could be transferred".
# This is expected on a live /var (kubelet rotates logs, removes pod sandboxes
# etc.) and is non-fatal — the destination still has consistent contents for
# every file that existed at the time rsync read it.
set +e
rsync -aHAX --numeric-ids --info=progress2,stats2 /host-var/ /mnt/new/
rsync_rc=\$?
set -e
if [ "\${rsync_rc}" = "0" ]; then
  echo "rsync completed cleanly"
elif [ "\${rsync_rc}" = "24" ]; then
  echo "rsync exit 24 (vanished files on live /var) — treating as non-fatal"
else
  echo "ERROR: rsync failed with exit \${rsync_rc}" >&2
  exit "\${rsync_rc}"
fi
sync

echo "=== verify ==="
df -h /mnt/new
ls -la /mnt/new | head -20
du -sh /mnt/new

umount /mnt/new
echo "=== DONE ==="
INNER
)

  # Re-indent inner for YAML block scalar.
  # Block-scalar content must be indented MORE than the `- |` list-item dash.
  # The dash sits at column 8 in our template, so we use 10 spaces here.
  local indented
  indented="$(printf '%s\n' "${inner}" | sed 's/^/          /')"

  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${MIGRATION_NS}
  labels:
    app: ${POD_NAME}
spec:
  nodeName: ${node_name}
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: migrate
      image: ${MIGRATION_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      command: ["/bin/sh", "-c"]
      args:
        - |
${indented}
      volumeMounts:
        - name: host-var
          mountPath: /host-var
          readOnly: true
        - name: dev
          mountPath: /dev
        - name: sys
          mountPath: /sys
  volumes:
    - name: host-var
      hostPath:
        path: /var
        type: Directory
    - name: dev
      hostPath:
        path: /dev
    - name: sys
      hostPath:
        path: /sys
YAML
}

run_migration_pod() {
  local node_name="$1"
  local disk_dev="$2"
  local eph_gib="$3"
  local with_linstor="$4"
  local with_cleanup="$5"

  local tmp_yaml
  tmp_yaml="$(mktemp -t reconfigure-pod.XXXXXX.yaml)"
  trap "rm -f '${tmp_yaml}'" RETURN

  render_pod_yaml "${node_name}" "${disk_dev}" "${eph_gib}" "${with_linstor}" "${with_cleanup}" > "${tmp_yaml}"

  log "Pod manifest written to ${tmp_yaml}"
  log "Cleaning any stale pod from previous run"
  kubectl -n "${MIGRATION_NS}" delete pod "${POD_NAME}" --ignore-not-found --wait=true >/dev/null

  log "Creating migration pod ${MIGRATION_NS}/${POD_NAME} on ${node_name}"
  kubectl apply -f "${tmp_yaml}"

  log "Waiting for pod container to start (up to 4m)…"
  local phase=""
  local i
  for i in $(seq 1 120); do
    phase="$(kubectl -n "${MIGRATION_NS}" get pod "${POD_NAME}" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Running|Succeeded|Failed) break ;;
    esac
    sleep 2
  done
  log "Pod phase: ${phase:-<unknown>}"
  [[ "${phase}" =~ ^(Running|Succeeded|Failed)$ ]] \
    || die "pod did not transition out of Pending — check 'kubectl describe pod ${MIGRATION_NS}/${POD_NAME}'"

  log "Streaming pod logs (this may take a while for large /var)…"
  kubectl -n "${MIGRATION_NS}" logs -f "pod/${POD_NAME}" --timestamps=true \
    || warn "log stream returned non-zero — pod status follows"

  log "Waiting for pod completion (timeout ${POD_TIMEOUT}s)"
  if ! kubectl -n "${MIGRATION_NS}" wait --for=jsonpath='{.status.phase}'=Succeeded \
          --timeout="${POD_TIMEOUT}s" "pod/${POD_NAME}"; then
    err "migration pod did NOT reach Succeeded — leaving it in place for inspection"
    err "  kubectl -n ${MIGRATION_NS} describe pod ${POD_NAME}"
    err "  kubectl -n ${MIGRATION_NS} logs ${POD_NAME}"
    return 1
  fi

  log "Pod Succeeded — deleting"
  kubectl -n "${MIGRATION_NS}" delete pod "${POD_NAME}" --wait=true
}

# ---------------------------------------------------------------------------
# Subcommand: prepare
# ---------------------------------------------------------------------------
cmd_prepare() {
  [[ $# -eq 2 ]] || { usage; die "prepare requires: <node-ip> <volume-config-yaml>"; }
  local node="$1"
  local yaml="$2"

  ensure_talosctl
  [[ -f "${yaml}" ]] || die "patch file not found: ${yaml}"

  log "Preflight (node=${node}, patch=${yaml})"
  node_reachable "${node}" || die "node ${node} unreachable via Talos API"

  local transport
  transport="$(parse_target_transport "${yaml}")"
  log "Target disk transport (from YAML): ${transport}"

  local target_disk
  target_disk="$(find_disk_id_by_transport "${node}" "${transport}")" \
    || die "no disk with transport=${transport} found on ${node}"
  local target_dev="/dev/${target_disk}"
  log "Target disk on ${node}: ${target_dev}"

  local sys_disk
  sys_disk="$(system_disk_id "${node}")"
  log "System disk: ${sys_disk}"
  [[ "${sys_disk}" != "${target_disk}" ]] \
    || die "refusing: target disk is also the system disk"

  local cur_eph
  cur_eph="$(current_ephemeral_disk_id "${node}" || true)"
  log "Current EPHEMERAL disk: ${cur_eph:-<unknown>}"
  if [[ -z "${cur_eph}" ]]; then
    warn "could not locate current EPHEMERAL via discoveredvolumes — continuing anyway"
  elif [[ "${cur_eph}" == "${target_disk}" ]]; then
    die "EPHEMERAL already on ${target_disk} — nothing to migrate"
  fi

  grep -qE '^kind:[[:space:]]*VolumeConfig' "${yaml}" \
    || die "${yaml} has no VolumeConfig block — it does not configure EPHEMERAL (use a patch that moves EPHEMERAL, e.g. patches/worker-disks.yaml)"

  local eph_gib
  eph_gib="$(parse_ephemeral_size_gib "${yaml}")"
  [[ -n "${eph_gib}" && "${eph_gib}" =~ ^[0-9]+$ ]] \
    || die "could not parse EPHEMERAL minSize from ${yaml}"
  log "EPHEMERAL size from YAML: ${eph_gib} GiB"

  local with_linstor=0
  if has_linstor_block "${yaml}"; then
    with_linstor=1
    log "RawVolumeConfig 'linstor' present — second partition will be created"
  fi

  local with_cleanup=0
  if disk_needs_cleanup "${node}" "${target_disk}"; then
    warn "${target_dev} is not clean — has partitions, an existing filesystem/PV,"
    warn "or device-mapper LVs that hold it busy."
    talosctl -n "${node}" get discoveredvolumes \
      | awk -v d="${target_disk}" 'NR==1 || $4 ~ "^"d || $4 ~ /^dm-/'
    warn "The migration pod will tear down LVM (vgchange -an, pvremove) and wipe"
    warn "filesystem signatures on ${target_dev} as its first step."
    warn "talosctl wipe disk does NOT deactivate kernel dm mappings, so the LVM"
    warn "tear-down MUST happen inside the privileged pod (with lvm2 tooling)."
    confirm "Destroy all LVM/filesystem state on ${target_dev}?"
    with_cleanup=1
  fi

  ensure_kubeconfig
  local node_name role
  node_name="$(resolve_node_name "${node}")"
  [[ -n "${node_name}" ]] || die "could not find a Kubernetes node for IP ${node}"
  role="$(node_role "${node_name}")"
  log "Kubernetes node: ${node_name} (role: ${role})"

  if [[ "${role}" == "control-plane" ]]; then
    warn "Target is a CONTROL-PLANE node."
    warn "This script does NOT take an etcd snapshot. If you continue and"
    warn "Talos reformats the new EPHEMERAL on 'apply', etcd state is lost."
    warn "Take a snapshot first with:"
    warn "  talosctl -n ${node} etcd snapshot ./backups/etcd-pre-reconfig.snap"
    confirm "Continue anyway?"
  fi

  echo
  log "Plan:"
  log "  - cordon + drain ${node_name}"
  log "  - schedule privileged pod on ${node_name} (image: ${MIGRATION_IMAGE})"
  if [[ ${with_cleanup} -eq 1 ]]; then
    log "    * LVM tear-down on ${target_dev}: vgchange -an, vgremove, pvremove, wipefs"
  fi
  log "    * partition ${target_dev}: ${eph_gib}GiB EPHEMERAL$( [[ ${with_linstor} -eq 1 ]] && echo ' + rest=linstor' )"
  log "    * mkfs.xfs -L EPHEMERAL"
  log "    * rsync -aHAX /var → new EPHEMERAL"
  log "  - NO Talos patch applied — node still boots from current EPHEMERAL"
  echo
  confirm "Proceed with prepare?"

  if [[ "${SKIP_DRAIN}" != "1" ]]; then
    log "Cordoning ${node_name}"
    kubectl cordon "${node_name}" || warn "cordon failed (continuing)"

    log "Draining ${node_name}"
    kubectl drain "${node_name}" \
        --ignore-daemonsets --delete-emptydir-data --timeout=10m \
      || warn "drain reported errors — review before continuing"
  else
    warn "SKIP_DRAIN=1 — node was NOT cordoned/drained"
  fi

  run_migration_pod "${node_name}" "${target_dev}" "${eph_gib}" "${with_linstor}" "${with_cleanup}"

  echo
  log "Post-prepare disk layout on ${node}:"
  talosctl -n "${node}" get discoveredvolumes \
    | awk -v d="${target_disk}" 'NR==1 || $4 ~ "^"d'
  echo
  log "Prepare complete. Node ${node} is still booting from EPHEMERAL on ${cur_eph:-<old>}."
  log "Next: ./scripts/reconfigure.sh apply ${node} ${yaml}"
  log "(node remains cordoned; 'apply' will uncordon after successful reboot)"
}

# ---------------------------------------------------------------------------
# Subcommand: apply
# ---------------------------------------------------------------------------
cmd_apply() {
  [[ $# -eq 2 ]] || { usage; die "apply requires: <node-ip> <volume-config-yaml>"; }
  local node="$1"
  local yaml="$2"

  ensure_talosctl
  [[ -f "${yaml}" ]] || die "patch file not found: ${yaml}"

  log "Preflight (node=${node}, patch=${yaml})"
  node_reachable "${node}" || die "node ${node} unreachable via Talos API"

  local transport
  transport="$(parse_target_transport "${yaml}")"
  local target_disk
  target_disk="$(find_disk_id_by_transport "${node}" "${transport}")" \
    || die "no disk with transport=${transport} found on ${node}"
  log "Target disk: /dev/${target_disk}"

  log "Verifying prepare phase artifacts (PARTLABEL=EPHEMERAL on ${target_disk})"
  local found
  found="$(talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
          | awk -v d="${target_disk}" 'NR>1 && $4 ~ "^"d"p[0-9]+$" && ($5=="EPHEMERAL" || $6=="EPHEMERAL") {print $4; exit}' || true)"
  if [[ -z "${found}" ]]; then
    warn "Did not find a partition labeled EPHEMERAL on ${target_disk}"
    warn "Run prepare first, or proceed knowing Talos will create a fresh empty EPHEMERAL."
    confirm "Continue without confirmed prepare data?"
  else
    log "Found PARTLABEL=EPHEMERAL at ${found} on ${target_disk} ✓"
  fi

  echo
  log "Current disk layout:"
  talosctl -n "${node}" get discoveredvolumes \
    | awk 'NR==1 || /nvme|mmcblk0p|EPHEMERAL|linstor/'
  echo

  log "Dry-run patch"
  talosctl -n "${node}" patch mc --dry-run -p "@${yaml}"

  warn "ABOUT TO APPLY ${yaml} ON ${node}"
  warn "  - Talos will REBOOT after patch"
  warn "  - On boot, Talos discovers volumes per diskSelector"
  warn "  - We EXPECT Talos to adopt the pre-created EPHEMERAL on ${target_disk}"
  warn "  - If Talos reformats it instead, /var contents are LOST"
  confirm "Proceed?"

  log "Applying patch"
  talosctl -n "${node}" patch mc -p "@${yaml}"

  log "Waiting for ${node} Talos API to come back"
  sleep 10
  local i
  for i in $(seq 1 90); do
    if node_reachable "${node}"; then
      log "Node reachable after $((i * 5))s"
      break
    fi
    sleep 5
    [[ $i -eq 90 ]] && die "node ${node} did not return within ~7.5m"
  done

  sleep 5
  log "Post-reboot disk layout:"
  talosctl -n "${node}" get discoveredvolumes \
    | awk 'NR==1 || /nvme|mmcblk0p|EPHEMERAL|linstor/'

  local new_eph
  new_eph="$(current_ephemeral_disk_id "${node}" || true)"
  if [[ "${new_eph}" == "${target_disk}" ]]; then
    log "EPHEMERAL is now on ${target_disk} ✓"
  else
    warn "EPHEMERAL appears to be on ${new_eph:-<unknown>}, expected ${target_disk}"
    warn "Inspect: talosctl -n ${node} get volumestatuses"
  fi

  log "Volume statuses:"
  talosctl -n "${node}" get volumestatuses 2>/dev/null || true

  if command -v kubectl >/dev/null; then
    ensure_kubeconfig
    local node_name
    node_name="$(resolve_node_name "${node}")"
    if [[ -n "${node_name}" ]]; then
      log "Waiting for ${node_name} to become Ready (up to 5m)"
      if kubectl wait --for=condition=Ready "node/${node_name}" --timeout=5m; then
        log "Uncordoning ${node_name}"
        kubectl uncordon "${node_name}" || warn "uncordon failed"
      else
        warn "${node_name} did not become Ready in 5m — left CORDONED"
        warn "Investigate, then: kubectl uncordon ${node_name}"
      fi
      log "Final cluster node status:"
      kubectl get nodes -o wide
    fi
  fi

  log "Apply complete."
}

# ---------------------------------------------------------------------------
# Inspect pod — read-only comparison of two EPHEMERAL partitions.
# ---------------------------------------------------------------------------
INSPECT_POD_NAME="reconfigure-inspect"

render_inspect_pod_yaml() {
  local node_name="$1"
  local prepared_dev="$2"   # e.g. /dev/nvme0n1p1 (the new copy to mount RO)
  local current_dev="$3"    # e.g. /dev/mmcblk0p6 (already mounted as /var — info only)

  local inner
  inner=$(cat <<INNER
set -eu

CUR_DEV="${current_dev}"
NEW_DEV="${prepared_dev}"

apk add --no-cache rsync util-linux xfsprogs e2fsprogs coreutils findutils
for tool in rsync mount umount du find blkid numfmt; do
  command -v "\${tool}" >/dev/null || { echo "ERROR: \${tool} not installed" >&2; exit 1; }
done

mkdir -p /mnt/prepared
mount -o ro "\${NEW_DEV}" /mnt/prepared

human() {
  if [ -n "\$1" ] && [ "\$1" != "0" ]; then
    numfmt --to=iec --suffix=B "\$1" 2>/dev/null || echo "\$1"
  else
    echo "0"
  fi
}

echo
echo "========================================================"
echo "  EPHEMERAL comparison"
echo "========================================================"
echo "Current (live, mounted as /var):  \${CUR_DEV}"
blkid "\${CUR_DEV}" 2>/dev/null || true
echo "Prepared (new copy):              \${NEW_DEV}"
blkid "\${NEW_DEV}" 2>/dev/null || true
echo

cur_used=\$(du -sb /host-var 2>/dev/null | awk '{print \$1}')
new_used=\$(du -sb /mnt/prepared 2>/dev/null | awk '{print \$1}')
cur_files=\$(find /host-var -xdev -type f 2>/dev/null | wc -l)
new_files=\$(find /mnt/prepared -xdev -type f 2>/dev/null | wc -l)
cur_links=\$(find /host-var -xdev -type l 2>/dev/null | wc -l)
new_links=\$(find /mnt/prepared -xdev -type l 2>/dev/null | wc -l)
cur_dirs=\$(find /host-var -xdev -type d 2>/dev/null | wc -l)
new_dirs=\$(find /mnt/prepared -xdev -type d 2>/dev/null | wc -l)

printf '\n----- totals -----\n'
printf '%-25s %15s %15s %15s\n' 'metric' 'current(mmc)' 'prepared(nvme)' 'delta'
printf '%-25s %15s %15s %15s\n' 'bytes used (du -sb)'    "\$(human "\$cur_used")"  "\$(human "\$new_used")"  "\$((new_used - cur_used))"
printf '%-25s %15s %15s %15s\n' 'regular files'         "\$cur_files"  "\$new_files"  "\$((new_files - cur_files))"
printf '%-25s %15s %15s %15s\n' 'directories'           "\$cur_dirs"   "\$new_dirs"   "\$((new_dirs - cur_dirs))"
printf '%-25s %15s %15s %15s\n' 'symlinks'              "\$cur_links"  "\$new_links"  "\$((new_links - cur_links))"

printf '\n----- per top-level entry -----\n'
printf '%-22s %12s %12s %10s %10s\n' 'entry' 'cur-size' 'new-size' 'cur-files' 'new-files'
entries=\$( { ls -A /host-var 2>/dev/null; ls -A /mnt/prepared 2>/dev/null; } | sort -u )
for e in \$entries; do
  cs=\$(du -sb "/host-var/\$e" 2>/dev/null | awk '{print \$1}'); cs=\${cs:-0}
  ns=\$(du -sb "/mnt/prepared/\$e" 2>/dev/null | awk '{print \$1}'); ns=\${ns:-0}
  cf=\$(find "/host-var/\$e" -xdev -type f 2>/dev/null | wc -l)
  nf=\$(find "/mnt/prepared/\$e" -xdev -type f 2>/dev/null | wc -l)
  marker=''
  [ "\$cs" != "\$ns" ] || [ "\$cf" != "\$nf" ] && marker=' *'
  printf '%-22s %12s %12s %10s %10s%s\n' "\$e" "\$(human "\$cs")" "\$(human "\$ns")" "\$cf" "\$nf" "\$marker"
done
echo '(* = differs in size or file count)'

printf '\n----- structural diff (rsync -aniHAX --dry-run) -----\n'
printf '\n>>> items current has and prepared lacks or differs in:\n'
rsync -aniHAX --info=stats0 /host-var/ /mnt/prepared/ 2>/dev/null | head -100 || true
printf '\n>>> items prepared has and current lacks or differs in:\n'
rsync -aniHAX --info=stats0 /mnt/prepared/ /host-var/ 2>/dev/null | head -100 || true

umount /mnt/prepared
echo
echo "=== DONE ==="
INNER
)

  local indented
  indented="$(printf '%s\n' "${inner}" | sed 's/^/          /')"

  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${INSPECT_POD_NAME}
  namespace: ${MIGRATION_NS}
  labels:
    app: ${INSPECT_POD_NAME}
spec:
  nodeName: ${node_name}
  hostPID: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: inspect
      image: ${MIGRATION_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      command: ["/bin/sh", "-c"]
      args:
        - |
${indented}
      volumeMounts:
        - name: host-var
          mountPath: /host-var
          readOnly: true
        - name: dev
          mountPath: /dev
  volumes:
    - name: host-var
      hostPath:
        path: /var
        type: Directory
    - name: dev
      hostPath:
        path: /dev
YAML
}

run_inspect_pod() {
  local node_name="$1"
  local prepared_dev="$2"
  local current_dev="$3"

  local tmp_yaml
  tmp_yaml="$(mktemp -t reconfigure-inspect-pod.XXXXXX.yaml)"
  trap "rm -f '${tmp_yaml}'" RETURN

  render_inspect_pod_yaml "${node_name}" "${prepared_dev}" "${current_dev}" > "${tmp_yaml}"

  log "Inspect pod manifest: ${tmp_yaml}"
  kubectl -n "${MIGRATION_NS}" delete pod "${INSPECT_POD_NAME}" --ignore-not-found --wait=true >/dev/null

  log "Creating inspect pod ${MIGRATION_NS}/${INSPECT_POD_NAME} on ${node_name}"
  kubectl apply -f "${tmp_yaml}"

  # Wait until the container actually starts (or finishes very fast).
  # `kubectl logs -f` returns BadRequest if the container is still
  # ContainerCreating (image pull) — we need it Running/Succeeded/Failed.
  log "Waiting for inspect pod to start…"
  local phase=""
  for i in $(seq 1 120); do
    phase="$(kubectl -n "${MIGRATION_NS}" get pod "${INSPECT_POD_NAME}" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Running|Succeeded|Failed) break ;;
    esac
    sleep 2
  done
  log "Pod phase: ${phase:-<unknown>}"

  kubectl -n "${MIGRATION_NS}" logs -f "pod/${INSPECT_POD_NAME}" --timestamps=false \
    || warn "log stream returned non-zero — pod status follows"

  # Final wait for terminal state.
  if ! kubectl -n "${MIGRATION_NS}" wait --for=jsonpath='{.status.phase}'=Succeeded \
          --timeout=600s "pod/${INSPECT_POD_NAME}"; then
    err "inspect pod did NOT reach Succeeded — leaving in place for inspection"
    err "  kubectl -n ${MIGRATION_NS} logs ${INSPECT_POD_NAME}"
    return 1
  fi

  kubectl -n "${MIGRATION_NS}" delete pod "${INSPECT_POD_NAME}" --wait=true
}

# ---------------------------------------------------------------------------
# Subcommand: inspect
# ---------------------------------------------------------------------------
cmd_inspect() {
  [[ $# -eq 1 ]] || { usage; die "inspect requires: <node-ip>"; }
  local node="$1"

  ensure_talosctl
  log "Preflight (node=${node})"
  node_reachable "${node}" || die "node ${node} unreachable via Talos API"

  # Locate the active EPHEMERAL via volumestatuses. Columns:
  #   NODE NAMESPACE TYPE ID VERSION TYPE PHASE LOCATION SIZE …
  # Field positions don't have spaces in values, so awk's column split is
  # stable enough here.
  local current_dev
  current_dev="$(talosctl -n "${node}" get volumestatuses 2>/dev/null \
                | awk '$4=="EPHEMERAL" {for(i=8;i<=NF;i++) if($i ~ /^\/dev\//){print $i; exit}}')"
  [[ -n "${current_dev}" ]] || die "could not find currently-mounted EPHEMERAL on ${node}"
  log "Current EPHEMERAL: ${current_dev}"

  # Find all partitions on this node with PARTITIONLABEL=EPHEMERAL.
  local all_eph
  all_eph="$(talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
            | awk '
                NR>1 {
                  for (i=5; i<=NF; i++) {
                    if ($i == "EPHEMERAL") {
                      if ($4 ~ /p[0-9]+$/ || $4 ~ /[0-9]+$/) {
                        print "/dev/" $4
                      }
                      break
                    }
                  }
                }' \
            | sort -u)"

  local prepared_dev=""
  local p
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "${current_dev}" ]] && continue
    prepared_dev="${p}"
    break
  done <<< "${all_eph}"

  [[ -n "${prepared_dev}" ]] || die "no second EPHEMERAL partition found — has prepare been run?"
  log "Prepared EPHEMERAL: ${prepared_dev}"

  ensure_kubeconfig
  local node_name
  node_name="$(resolve_node_name "${node}")"
  [[ -n "${node_name}" ]] || die "no Kubernetes node maps to ${node}"
  log "Kubernetes node: ${node_name}"

  run_inspect_pod "${node_name}" "${prepared_dev}" "${current_dev}"

  log "Inspect complete."
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }

CMD="$1"
shift

case "${CMD}" in
  prepare)        cmd_prepare "$@" ;;
  apply)          cmd_apply "$@" ;;
  inspect)        cmd_inspect "$@" ;;
  help|-h|--help) usage ;;
  *)
    err "unknown subcommand: ${CMD}"
    echo >&2
    usage >&2
    exit 1
    ;;
esac
