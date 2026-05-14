#!/usr/bin/env bash
#
# utils.sh — Multi-command utility dispatcher.
#
# Usage:
#   ./scripts/utils.sh <command> [args...]
#
# Existing commands:
#   verify <snapshot-file>   Verify an etcd snapshot (.snap or .snap.gz) via docker.
#   help                     Show usage.
#
# Adding a new command:
#   1) define `cmd_<name>() { ... }`
#   2) add a `case` branch in the dispatcher at the bottom
#   3) update `usage()` to describe it
#
# Only the requested command runs — the dispatcher exits right after.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

ETCD_IMAGE="${ETCD_IMAGE:-gcr.io/etcd-development/etcd:v3.5.18}"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
_TMP=""
cleanup() {
  if [[ -n "${_TMP}" && -d "${_TMP}" ]]; then
    rm -rf "${_TMP}"
  fi
}
trap cleanup EXIT INT TERM

log()  { printf '\033[1;36m[%s]\033[0m %s\n'   "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n'  "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }

confirm() {
  local prompt="${1:-Proceed?}"
  read -r -p "${prompt} [type 'yes' to continue] " ans
  [[ "${ans}" == "yes" ]] || { err "aborted by user"; return 1; }
}

file_size() {
  # cross-platform stat (BSD on macOS vs GNU on Linux)
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

make_tmpdir() {
  # Portable mktemp — explicit template works on both macOS and Linux.
  _TMP="$(mktemp -d "${TMPDIR:-/tmp}/etcd-utils.XXXXXX")"
  # Loosen perms so rootless / userns-remapped docker can read the mount.
  chmod 755 "${_TMP}" 2>/dev/null || true
  echo "${_TMP}"
}

usage() {
  cat <<EOF
Usage: ./scripts/utils.sh <command> [args...]

Commands:
  verify <snapshot-file>          Verify an etcd snapshot (.snap or .snap.gz) via docker.
                                  Prints hash, revision, key count, total size.
                                  No local etcd install required.
  clean-disk <node-ip> <disk>     Wipe a disk on a Talos node, recursively wiping
                                  any dependent device-mapper / partitions first.
                                  Refuses to wipe the node's system disk.
  disk-info <node-ip>             Show disk inventory for a Talos node: system
                                  disk, hardware disks (model/serial/size),
                                  discovered volumes and volume statuses.
  help                            Show this message.

Environment:
  ETCD_IMAGE   Docker image to use (default: ${ETCD_IMAGE})

Examples:
  ./scripts/utils.sh verify backups/etcd/etcd-192.168.2.101-20260514-085600.snap.gz
  ./scripts/utils.sh verify backups/etcd/etcd-192.168.2.101-20260514-090435.snap
  ./scripts/utils.sh clean-disk 192.168.2.103 nvme0n1
  ./scripts/utils.sh disk-info 192.168.2.101
EOF
}

# ---------------------------------------------------------------------------
# Command: verify
# ---------------------------------------------------------------------------
cmd_verify() {
  if [[ $# -ne 1 ]]; then
    err "verify requires exactly one argument: <snapshot-file>"
    err "usage: ./scripts/utils.sh verify <snapshot-file>"
    return 1
  fi

  local file="$1"
  [[ -f "${file}" ]] || { err "file not found: ${file}"; return 1; }
  command -v docker >/dev/null || { err "docker not in PATH"; return 1; }
  command -v gunzip >/dev/null || { err "gunzip not in PATH"; return 1; }

  local tmpdir
  tmpdir="$(make_tmpdir)"

  local basename_no_gz
  basename_no_gz="$(basename "${file}")"
  basename_no_gz="${basename_no_gz%.gz}"

  local target="${tmpdir}/${basename_no_gz}"

  if [[ "${file}" == *.gz ]]; then
    log "Decompressing ${file}"
    gunzip -c "${file}" > "${target}"
  else
    log "Copying ${file}"
    cp "${file}" "${target}"
  fi
  chmod 644 "${target}" 2>/dev/null || true

  log "Prepared snapshot: ${target} ($(file_size "${target}") bytes)"
  log "Running etcdutl snapshot status (image: ${ETCD_IMAGE})"
  echo

  docker run --rm -v "${tmpdir}:/snap:ro" "${ETCD_IMAGE}" \
    etcdutl snapshot status "/snap/${basename_no_gz}" --write-out=table
}

# ---------------------------------------------------------------------------
# Command: clean-disk
#
# Wipes a disk on a Talos node, but first wipes any dependent block devices
# (device-mapper LVs from a leftover LVM PV, child partitions, etc.) that
# would otherwise cause `talosctl wipe disk` to fail with:
#   FailedPrecondition desc = blockdevice "<disk>" is in use by disk "dm-0"
#
# Detection strategy:
#   1) Pull `talosctl get discoveredvolumes` and parse for dm-* devices and
#      partitions matching `<disk>p[0-9]+`.
#   2) Confirm the disk is NOT the node's system disk.
#   3) Show the wipe plan, require interactive confirmation.
#   4) Wipe leaf devices first (dm-*), then partitions, then the disk itself.
# ---------------------------------------------------------------------------
cmd_clean_disk() {
  if [[ $# -ne 2 ]]; then
    err "clean-disk requires: <node-ip> <disk>"
    err "example: ./scripts/utils.sh clean-disk 192.168.2.103 nvme0n1"
    return 1
  fi
  local node="$1"
  local disk="$2"

  command -v talosctl >/dev/null || { err "talosctl not in PATH"; return 1; }

  log "Reachability check for ${node}"
  talosctl -n "${node}" version --short >/dev/null \
    || { err "node ${node} unreachable via Talos API"; return 1; }

  log "Resolving system disk on ${node}"
  local system_disk
  # Talos yaml uses `diskID:` (legacy: `disk:`) under SystemDisk spec.
  system_disk="$(talosctl -n "${node}" get systemdisk -o yaml 2>/dev/null \
                | awk '$1=="diskID:" || $1=="disk:" {print $2; exit}')"
  if [[ -z "${system_disk}" ]]; then
    warn "could not determine system disk — refusing without that safety check"
    return 1
  fi
  if [[ "${disk}" == "${system_disk}" ]]; then
    err "refusing to wipe system disk: ${disk}"
    return 1
  fi
  log "System disk on ${node} is ${system_disk} (not the target — good)"

  log "Discovering volumes on ${node}"
  talosctl -n "${node}" get discoveredvolumes

  # Confirm target disk actually exists.
  if ! talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
      | awk -v d="${disk}" 'NR>1 && $4==d {f=1} END {exit !f}'; then
    err "disk ${disk} not found in discoveredvolumes on ${node}"
    return 1
  fi

  # Detect device-mapper devices on the node — leftovers from LVM/dm activation.
  local dm_devs
  dm_devs="$(talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
            | awk 'NR>1 && $4 ~ /^dm-/ {print $4}' | sort -u)"

  # Detect partitions of the target disk (e.g. nvme0n1p1, nvme0n1p2).
  local partitions
  partitions="$(talosctl -n "${node}" get discoveredvolumes 2>/dev/null \
               | awk -v d="${disk}" 'NR>1 && $4 ~ "^"d"p[0-9]+$" {print $4}' \
               | sort -u)"

  # Build wipe plan: leaves first (dm-* and partitions), then the disk itself.
  local plan=()
  if [[ -n "${dm_devs}" ]];     then while IFS= read -r x; do plan+=("$x"); done <<< "${dm_devs}"; fi
  if [[ -n "${partitions}" ]];  then while IFS= read -r x; do plan+=("$x"); done <<< "${partitions}"; fi
  plan+=("${disk}")

  echo
  warn "WILL WIPE the following devices on ${node} (DESTRUCTIVE, --drop-partition):"
  local d
  for d in "${plan[@]}"; do
    warn "  - ${d}"
  done
  echo
  confirm "Proceed?" || return 1

  # Wipe leaves first — single call per group lets Talos resolve ordering.
  if [[ -n "${dm_devs}" ]]; then
    log "Wiping device-mapper devices: ${dm_devs}"
    # shellcheck disable=SC2086
    talosctl -n "${node}" wipe disk ${dm_devs} \
      || warn "wipe of dm devices returned non-zero — continuing"
    sleep 2
  fi

  if [[ -n "${partitions}" ]]; then
    log "Wiping partitions on ${disk}: ${partitions}"
    # shellcheck disable=SC2086
    talosctl -n "${node}" wipe disk ${partitions} --drop-partition \
      || warn "wipe of partitions returned non-zero — continuing"
    sleep 2
  fi

  log "Wiping disk ${disk}"
  talosctl -n "${node}" wipe disk "${disk}" \
    || { err "wipe of ${disk} failed — inspect 'talosctl get discoveredvolumes' on ${node}"; return 1; }

  sleep 3
  echo
  log "Post-wipe state on ${node}:"
  talosctl -n "${node}" get discoveredvolumes
}

# ---------------------------------------------------------------------------
# Command: disk-info
#
# Aggregates disk-related info from a Talos node into a single readable report:
#   - system disk (which physical device holds the OS)
#   - hardware disks (model, serial, size, type — rotational/SSD/NVMe)
#   - discovered volumes (partitions and filesystems Talos sees)
#   - volume statuses (mount/ready state of Talos-managed volumes)
# ---------------------------------------------------------------------------
cmd_disk_info() {
  if [[ $# -ne 1 ]]; then
    err "disk-info requires: <node-ip>"
    err "example: ./scripts/utils.sh disk-info 192.168.2.101"
    return 1
  fi
  local node="$1"

  command -v talosctl >/dev/null || { err "talosctl not in PATH"; return 1; }

  log "Reachability check for ${node}"
  talosctl -n "${node}" version --short >/dev/null \
    || { err "node ${node} unreachable via Talos API"; return 1; }

  echo
  log "System disk on ${node}:"
  talosctl -n "${node}" get systemdisk -o yaml 2>/dev/null \
    | awk '$1=="diskID:" || $1=="disk:" {print "  " $0}' \
    || warn "could not read systemdisk resource"

  echo
  log "Hardware disks on ${node} (talosctl get disks):"
  talosctl -n "${node}" get disks \
    || warn "could not read disks resource"

  echo
  log "Discovered volumes on ${node} (partitions/filesystems):"
  talosctl -n "${node}" get discoveredvolumes \
    || warn "could not read discoveredvolumes resource"

  echo
  log "Volume statuses on ${node} (Talos-managed mounts):"
  talosctl -n "${node}" get volumestatuses 2>/dev/null \
    || warn "could not read volumestatuses resource (older Talos?)"
}

# ---------------------------------------------------------------------------
# Dispatcher — runs ONLY the requested command, then exits
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }

CMD="$1"
shift

case "${CMD}" in
  verify)         cmd_verify "$@" ;;
  clean-disk)     cmd_clean_disk "$@" ;;
  disk-info)      cmd_disk_info "$@" ;;
  help|-h|--help) usage ;;
  *)
    err "unknown command: ${CMD}"
    echo >&2
    usage >&2
    exit 1
    ;;
esac
