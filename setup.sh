#!/usr/bin/env bash
# setup.sh
# Usage:
#   ./setup.sh iran  <peer_ip> <gre_number>
#   ./setup.sh khrej <peer_ip> <gre_number>
#
# Behavior:
# - Auto-detect local IPv4 from server.
# - GRE base: 10.<n>0.<n>0.0  (n is single digit 0..9)
# - Ports fixed to 80 (IRAN side only)
# - BEFORE setup: remove existing gre{n}.service and fw-gre{n}-*.service (if any), stop/disable, delete files, daemon-reload.
# - Download latest sepehr.sh from GitHub and feed inputs to it (no modification to upstream script).

set -euo pipefail

SEPEHR_URL="https://raw.githubusercontent.com/ToolSeRF/Sepehr-GRE-FORWARDER/main/sepehr.sh"
SEPEHR_FILE="./sepehr.sh"
PORTS="80"

die() { echo "ERROR: $*" >&2; exit 1; }

valid_octet() { local o="$1"; [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255)); }

valid_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

get_local_ipv4() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  valid_ipv4 "$ip" || die "Cannot detect a valid local IPv4 (ip route/hostname -I failed)."
  echo "$ip"
}

build_gre_base() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]$ ]] || die "grenumber must be single digit (0..9). Got: '$n'"
  echo "10.${n}0.${n}0.0"
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

cleanup_existing_services() {
  local id="$1"
  local gre_unit="gre${id}.service"
  local gre_path="/etc/systemd/system/${gre_unit}"

  echo "[CLEAN] Checking existing units for GRE${id}..."

  # Stop/disable GRE unit if exists in systemd listing
  if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${gre_unit}"; then
    echo "[CLEAN] Stop/Disable ${gre_unit}"
    systemctl stop "${gre_unit}" >/dev/null 2>&1 || true
    systemctl disable "${gre_unit}" >/dev/null 2>&1 || true
  fi

  # Stop/disable forwarders
  local fw_units=()
  mapfile -t fw_units < <(systemctl list-unit-files --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E "^fw-gre${id}-[0-9]+\.service$" || true)

  if ((${#fw_units[@]} > 0)); then
    echo "[CLEAN] Stop/Disable forwarders for GRE${id} (${#fw_units[@]} units)"
    local u
    for u in "${fw_units[@]}"; do
      systemctl stop "$u" >/dev/null 2>&1 || true
      systemctl disable "$u" >/dev/null 2>&1 || true
    done
  fi

  # Remove unit files if present
  if [[ -f "$gre_path" ]]; then
    echo "[CLEAN] Remove unit file: $gre_path"
    rm -f "$gre_path" || true
  fi

  local fw_files=()
  mapfile -t fw_files < <(find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null || true)
  if ((${#fw_files[@]} > 0)); then
    echo "[CLEAN] Remove forwarder unit files: ${#fw_files[@]}"
    rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true
  fi

  # Also remove runtime tunnel if exists
  if command -v ip >/dev/null 2>&1; then
    if ip tunnel show 2>/dev/null | awk '{print $1}' | grep -qx "gre${id}:"; then
      echo "[CLEAN] Removing live tunnel gre${id}"
      ip tunnel del "gre${id}" >/dev/null 2>&1 || true
    fi
  fi

  echo "[CLEAN] systemd daemon-reload/reset-failed"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  echo "[CLEAN] Done."
}

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh iran  <peer_ip> <gre_number>
  ./setup.sh khrej <peer_ip> <gre_number>

Examples:
  ./setup.sh iran  45.89.52.101 7
  ./setup.sh khrej 10.10.10.2    7
EOF
}

[[ $# -eq 3 ]] || { usage; exit 1; }

SIDE="$1"
PEER_IP="$2"
GRE_ID="$3"

case "$SIDE" in
  iran|IRAN) SIDE="iran" ;;
  khrej|KHREJ|kharej|KHAREJ) SIDE="khrej" ;;
  *) die "Invalid side '$SIDE'. Use: iran | khrej" ;;
esac

valid_ipv4 "$PEER_IP" || die "Peer IP invalid: $PEER_IP"
[[ "$GRE_ID" =~ ^[0-9]$ ]] || die "grenumber must be single digit (0..9). Got: $GRE_ID"

ensure_root "$@"

LOCAL_IP="$(get_local_ipv4)"
GRE_BASE="$(build_gre_base "$GRE_ID")"

echo "[INFO] SIDE     : $SIDE"
echo "[INFO] LOCAL IP : $LOCAL_IP"
echo "[INFO] PEER IP  : $PEER_IP"
echo "[INFO] GRE NUM  : $GRE_ID"
echo "[INFO] GRE BASE : $GRE_BASE"
echo "[INFO] PORTS    : $PORTS"
echo

# 1) Cleanup old services for this GRE id
cleanup_existing_services "$GRE_ID"

# 2) Download latest sepehr.sh
command -v wget >/dev/null 2>&1 || die "wget not found"
wget -O "$SEPEHR_FILE" "${SEPEHR_URL}?$(date +%s)" >/dev/null
chmod +x "$SEPEHR_FILE"

# 3) Feed answers to sepehr.sh (no prompts)
if [[ "$SIDE" == "iran" ]]; then
  printf "1\n%s\n%s\n%s\n%s\n%s\n\n0\n" \
    "$GRE_ID" "$LOCAL_IP" "$PEER_IP" "$GRE_BASE" "$PORTS" | bash "$SEPEHR_FILE"
else
  printf "2\n%s\n%s\n%s\n%s\n\n0\n" \
    "$GRE_ID" "$LOCAL_IP" "$PEER_IP" "$GRE_BASE" | bash "$SEPEHR_FILE"
fi
