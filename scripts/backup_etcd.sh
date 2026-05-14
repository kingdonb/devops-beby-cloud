#!/usr/bin/env bash
#
# backup_etcd.sh — Take an etcd snapshot from the Talos control plane.
#
# Captures a point-in-time etcd snapshot, verifies it's non-empty, and
# enforces a retention policy on older backups.
#
# Usage:
#   ./scripts/backup_etcd.sh                       # use defaults
#   CP_IP=10.0.0.5 ./scripts/backup_etcd.sh        # custom endpoint
#   RETENTION=30 ./scripts/backup_etcd.sh          # keep 30 snapshots
#   COMPRESS=1 ./scripts/backup_etcd.sh            # gzip the snapshot
#   QUIET=1 ./scripts/backup_etcd.sh               # cron-friendly (errors only)
#
# Cron example (every 6 hours):
#   0 */6 * * * cd /path/to/devops-beby-cloud && QUIET=1 ./scripts/backup_etcd.sh
#
# Exit codes:
#   0  success
#   1  invalid arguments / missing tools
#   2  node unreachable
#   3  snapshot command failed
#   4  snapshot file looks corrupt (too small)
#   5  another backup run already in progress

set -euo pipefail

# --- configuration (overridable via env) ---
CP_IP="${CP_IP:-192.168.2.101}"
BACKUP_DIR="${BACKUP_DIR:-./backups/etcd}"
RETENTION="${RETENTION:-14}"
COMPRESS="${COMPRESS:-0}"
QUIET="${QUIET:-0}"
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-10000}"

# --- paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_BASENAME="etcd-${CP_IP}-${TIMESTAMP}.snap"
SNAPSHOT_PATH="${BACKUP_DIR}/${SNAPSHOT_BASENAME}"
LOCK_FILE="${BACKUP_DIR}/.backup.lock"

# --- logging helpers ---
log()  { [[ "${QUIET}" == "1" ]] || printf '\033[1;36m[%s]\033[0m %s\n'   "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n'  "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

file_size() {
  # cross-platform stat (BSD on macOS vs GNU on Linux)
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# --- preflight ---
command -v talosctl >/dev/null || { err "talosctl not in PATH"; exit 1; }

mkdir -p "${BACKUP_DIR}"

# Prevent overlapping runs (e.g. cron firing while a previous run still going).
if [[ -e "${LOCK_FILE}" ]]; then
  PID="$(cat "${LOCK_FILE}" 2>/dev/null || echo "")"
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    err "another backup run is in progress (PID ${PID})"
    exit 5
  fi
  warn "stale lock file detected — removing"
  rm -f "${LOCK_FILE}"
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

# --- reachability ---
log "Checking node ${CP_IP} reachability"
if ! talosctl -n "${CP_IP}" version --short >/dev/null 2>&1; then
  err "node ${CP_IP} unreachable via Talos API"
  exit 2
fi

# --- snapshot ---
log "Snapshotting etcd → ${SNAPSHOT_PATH}"
if ! talosctl -n "${CP_IP}" etcd snapshot "${SNAPSHOT_PATH}" 2>&1; then
  err "etcd snapshot failed"
  rm -f "${SNAPSHOT_PATH}"
  exit 3
fi

# --- verify ---
SIZE="$(file_size "${SNAPSHOT_PATH}")"
if (( SIZE < MIN_SIZE_BYTES )); then
  err "snapshot too small (${SIZE} bytes < ${MIN_SIZE_BYTES}) — likely corrupt"
  rm -f "${SNAPSHOT_PATH}"
  exit 4
fi
log "Snapshot OK (${SIZE} bytes)"

# --- optional compression ---
if [[ "${COMPRESS}" == "1" ]]; then
  log "Compressing with gzip"
  gzip "${SNAPSHOT_PATH}"
  SNAPSHOT_PATH="${SNAPSHOT_PATH}.gz"
  COMPRESSED_SIZE="$(file_size "${SNAPSHOT_PATH}")"
  log "Compressed size: ${COMPRESSED_SIZE} bytes"
fi

# --- retention: keep newest N snapshots ---
# Portable across bash 3.2 (macOS default) and bash 4+ (Linux) — no `mapfile`.
log "Enforcing retention (keep last ${RETENTION})"
SNAPSHOTS=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && SNAPSHOTS+=("${line}")
done < <(
  find "${BACKUP_DIR}" -maxdepth 1 -type f \
    \( -name 'etcd-*.snap' -o -name 'etcd-*.snap.gz' \) \
    2>/dev/null \
    | sort
)
TOTAL=${#SNAPSHOTS[@]}
if [[ ${TOTAL} -gt ${RETENTION} ]]; then
  REMOVE_COUNT=$(( TOTAL - RETENTION ))
  log "Removing ${REMOVE_COUNT} old snapshot(s)"
  i=0
  while [[ ${i} -lt ${REMOVE_COUNT} ]]; do
    log "  rm ${SNAPSHOTS[${i}]}"
    rm -f "${SNAPSHOTS[${i}]}"
    i=$(( i + 1 ))
  done
else
  log "Retention OK (${TOTAL}/${RETENTION})"
fi

# --- summary ---
log "Done"
log "  path:      ${SNAPSHOT_PATH}"
log "  size:      $(file_size "${SNAPSHOT_PATH}") bytes"
log "  retained:  $(( TOTAL > RETENTION ? RETENTION : TOTAL )) snapshot(s) in ${BACKUP_DIR}"
