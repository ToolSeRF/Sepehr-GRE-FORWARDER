#!/usr/bin/env bash

set +e
set +u
export LC_ALL=C
LOG_LINES=()
LOG_MIN=3
LOG_MAX=10

banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════╗
║                                                     ║
║   ███████╗███████╗██████╗ ███████╗██╗  ██╗██████╗   ║
║   ██╔════╝██╔════╝██╔══██╗██╔════╝██║  ██║██╔══██╗  ║
║   ███████╗█████╗  ██████╔╝█████╗  ███████║██████╔╝  ║
║   ╚════██║██╔══╝  ██╔═══╝ ██╔══╝  ██╔══██║██╔══██╗  ║
║   ███████║███████╗██║     ███████╗██║  ██║██║  ██║  ║
║   ╚══════╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝  ║
║                                                     ║
║               k O J A I   B A B A ?                 ║
║                                                     ║
╚═════════════════════════════════════════════════════╝
EOF
}

add_log() {
  local msg="$1"
  local ts
  ts="$(date +"%H:%M:%S")"
  LOG_LINES+=("[$ts] $msg")
  if ((${#LOG_LINES[@]} > LOG_MAX)); then
    LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
  fi
}

render() {
  clear
  banner
  echo
  local shown_count="${#LOG_LINES[@]}"
  local height=$shown_count
  ((height < LOG_MIN)) && height=$LOG_MIN
  ((height > LOG_MAX)) && height=$LOG_MAX

  echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
  local start_index=0
  if ((${#LOG_LINES[@]} > height)); then
    start_index=$((${#LOG_LINES[@]} - height))
  fi

  local i line
  for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
    line="${LOG_LINES[$i]}"
    printf "│ %-68s │\n" "$line"
  done

  local missing=$((height - (${#LOG_LINES[@]} - start_index)))
  for ((i=0; i<missing; i++)); do
    printf "│ %-68s │\n" ""
  done

  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo
}

pause_enter() {
  echo
  read -r -p "Press ENTER to return to menu..." _
}

die_soft() {
  add_log "ERROR: $1"
  render
  pause_enter
}
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255))
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

valid_port() {
  local p="$1"
  is_int "$p" || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}
ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    read -r -e -p "$prompt " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
      add_log "Please enter a valid value."
    fi
  done
}

ask_ports() {
  local prompt="ForWard PORT (80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid ports: $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports accepted: ${PORT_LIST[*]}"
    return 0
  done
}
ensure_iproute_only() {
  add_log "Checking required package: iproute2"
  render

  if command -v ip >/dev/null 2>&1; then
    add_log "iproute2 is already installed."
    return 0
  fi

  add_log "Installing missing package: iproute2"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iproute2 >/dev/null 2>&1 && add_log "iproute2 installed successfully." || return 1
  return 0
}

valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  ((m>=576 && m<=1600))
}

ensure_mtu_line_in_unit() {
  local id="$1" mtu="$2" file="$3"

  [[ -f "$file" ]] || return 0

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}|" "$file"
    add_log "Updated MTU line in: $file"
    return 0
  fi

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} up$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} up$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}\nExecStart=/sbin/ip link set gre${id} up|" "$file"
    add_log "Inserted MTU line in: $file"
    return 0
  fi
  printf "\nExecStart=/sbin/ip link set gre%s mtu %s\n" "$id" "$mtu" >> "$file"
  add_log "WARNING: 'ip link set gre${id} up' not found; appended MTU line at end: $file"
}


ensure_packages() {
  add_log "Checking required packages: iproute2, socat"
  render
  local missing=()
  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v socat >/dev/null 2>&1 || missing+=("socat")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }

unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }

enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

stop_disable() {
  systemctl stop "$1" >/dev/null 2>&1
  systemctl disable "$1" >/dev/null 2>&1
}

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}

make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" mtu="${6:-}"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Service already exists: $unit"
    return 2
  fi

  add_log "Creating: $path"
  render

  local mtu_line=""
  if [[ -n "$mtu" ]]; then
    mtu_line="ExecStart=/sbin/ip link set gre${id} mtu ${mtu}"
  fi

  cat >"$path" <<EOF
[Unit]
Description=GRE Tunnel to (${remote_ip})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "/sbin/ip tunnel del gre${id} 2>/dev/null || true"
ExecStart=/sbin/ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} key ${key} nopmtudisc
ExecStart=/sbin/ip addr add ${local_gre_ip}/30 dev gre${id}
${mtu_line}
ExecStart=/sbin/ip link set gre${id} up
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "GRE service created: $unit" || return 1
  return 0
}


make_fw_service() {
  local id="$1" port="$2" target_ip="$3"
  local unit="fw-gre${id}-${port}.service"
  local path="/etc/systemd/system/${unit}"

  if unit_exists "$unit"; then
    add_log "Forwarder exists, skip: $unit"
    return 0
  fi

  add_log "Creating forwarder: fw-gre${id}-${port}"
  render

  cat >"$path" <<EOF
[Unit]
Description=forward gre${id} ${port}
After=network-online.target gre${id}.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${port},reuseaddr,fork TCP:${target_ip}:${port}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "Forwarder created: fw-gre${id}-${port}" || add_log "Failed writing forwarder: $unit"
}
iran_setup() {
  local ID IRANIP KHAREJIP GREBASE
  local -a PORT_LIST=()

  ask_until_valid "GRE Number :" is_int ID
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0):" valid_gre_base GREBASE
  ask_ports
  local use_mtu="n" MTU_VALUE=""

  while true; do
    render
    read -r -p "set custom mtu? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes)
        ask_until_valid "input your custom mtu for gre (576-1600):" valid_mtu MTU_VALUE
        break
        ;;
      n|no|"")
        MTU_VALUE=""
        break
        ;;
      *)
        add_log "Invalid input. Please enter y or n."
        ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN=${local_gre_ip} | KHAREJ=${peer_gre_ip}"

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Creating forwarders..."
  local p
  for p in "${PORT_LIST[@]}"; do
    make_fw_service "$ID" "$p" "$peer_gre_ip"
  done

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID} + forwarders..."
  enable_now "gre${ID}.service"
  for p in "${PORT_LIST[@]}"; do
    enable_now "fw-gre${ID}-${p}.service"
  done

  render
  echo "GRE IPs:"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo
  echo "Status:"
  show_unit_status_brief "gre${ID}.service"
  for p in "${PORT_LIST[@]}"; do
    echo
    show_unit_status_brief "fw-gre${ID}-${p}.service"
  done
  pause_enter
}

kharej_setup() {
  local ID KHAREJIP IRANIP GREBASE
  local use_mtu="n" MTU_VALUE=""

  ask_until_valid "GRE Number(Like IRAN PLEASE) :" is_int ID
  ask_until_valid "KHAREJ IP :" valid_ipv4 KHAREJIP
  ask_until_valid "IRAN IP :" valid_ipv4 IRANIP
  ask_until_valid "GRE IP RANG (Example : 10.80.70.0) Like IRAN PLEASE:" valid_gre_base GREBASE

  while true; do
    render
    read -r -p "set custom mtu? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes)
        ask_until_valid "input your custom mtu for gre (576-1600):" valid_mtu MTU_VALUE
        break
        ;;
      n|no|"")
        MTU_VALUE=""
        break
        ;;
      *)
        add_log "Invalid input. Please enter y or n."
        ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ=${local_gre_ip} | IRAN=${peer_gre_ip}"

  ensure_iproute_only || { die_soft "Package installation failed (iproute2)."; return 0; }

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  render
  echo "GRE IPs:"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo
  show_unit_status_brief "gre${ID}.service"
  pause_enter
}

get_gre_ids() {
  local ids=()

  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)

  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

get_fw_units_for_id() {
  local id="$1"
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre${id}-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E "^fw-gre${id}-[0-9]+\.service$" \
    | sort -V || true
}

get_all_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre*-*.service" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -E '^fw-gre[0-9]+-[0-9]+\.service$' \
    | sort -V || true
}
MENU_SELECTED=-1

menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo "$title"
    echo

    if ((${#items[@]} == 0)); then
      echo "No service found."
      echo
      read -r -p "Press ENTER to go back..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${items[$i]}"
    done
    echo "0) Back"
    echo

    read -r -e -p "$prompt " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      MENU_SELECTED=-1
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]})); then
      MENU_SELECTED=$((choice-1))
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}
service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: $unit"
    echo
    echo "1) Enable & Start"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Status"
    echo "0) Back"
    echo

    read -r -e -p "Select action: " action
    action="$(trim "$action")"

    case "$action" in
      1)
        add_log "Enable & Start: $unit"
        systemctl enable "$unit" >/dev/null 2>&1 && add_log "Enabled: $unit" || add_log "Enable failed: $unit"
        systemctl start "$unit"  >/dev/null 2>&1 && add_log "Started: $unit" || add_log "Start failed: $unit"
        ;;
      2)
        add_log "Restart: $unit"
        systemctl restart "$unit" >/dev/null 2>&1 && add_log "Restarted: $unit" || add_log "Restart failed: $unit"
        ;;
      3)
        add_log "Stop & Disable: $unit"
        systemctl stop "$unit"    >/dev/null 2>&1 && add_log "Stopped: $unit" || add_log "Stop failed: $unit"
        systemctl disable "$unit" >/dev/null 2>&1 && add_log "Disabled: $unit" || add_log "Disable failed: $unit"
        ;;
      4)
        render
        echo "---- STATUS ($unit) ----"
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,16p'
        echo "------------------------"
        pause_enter
        ;;
      0) return 0 ;;
      *) add_log "Invalid action: $action" ;;
    esac
  done
}

services_management() {
  local sel=""

  while true; do
    render
    echo "Services ManageMent"
    echo
    echo "1) GRE"
    echo "2) Forwarder"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a GRE_LABELS=()
        local id
        for id in "${GRE_IDS[@]}"; do
          GRE_LABELS+=("GRE${id}")
        done

        if menu_select_index "GRE Services" "Select GRE:" "${GRE_LABELS[@]}"; then
          local idx="$MENU_SELECTED"
          id="${GRE_IDS[$idx]}"
          add_log "GRE selected: GRE${id}"
          service_action_menu "gre${id}.service"
        fi
        ;;

      2)
        mapfile -t FW_UNITS < <(get_all_fw_units)
        local -a FW_LABELS=()
        local u gid port

        for u in "${FW_UNITS[@]}"; do
          if [[ "$u" =~ ^fw-gre([0-9]+)-([0-9]+)\.service$ ]]; then
            gid="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
            FW_LABELS+=("GRE${gid}:${port}")
          else
            FW_LABELS+=("${u%.service}")
          fi
        done

        if menu_select_index "Forwarder Services" "Select Forwarder:" "${FW_LABELS[@]}"; then
          local fidx="$MENU_SELECTED"
          u="${FW_UNITS[$fidx]}"
          add_log "Forwarder selected: ${FW_LABELS[$fidx]}"
          service_action_menu "$u"
        fi
        ;;

      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"

  while true; do
    render
    echo "Uninstall & Clean"
    echo
    echo "Target: GRE${id}"
    echo "This will remove:"
    echo "  - /etc/systemd/system/gre${id}.service"
    echo "  - /etc/systemd/system/fw-gre${id}-*.service"
    echo "  - cron + /usr/local/bin/sepehr-recreate-gre${id}.sh (if exists)"
    echo "  - /var/log/sepehr-gre${id}.log (if exists)"
    echo "  - /root/gre-backup/gre${id}.service (if exists)"
    echo "  - /root/gre-backup/fw-gre${id}-*.service (if exists)"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  add_log "Disabling gre${id}.service"
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  mapfile -t FW_UNITS < <(get_fw_units_for_id "$id")
  if ((${#FW_UNITS[@]} > 0)); then
    local u
    for u in "${FW_UNITS[@]}"; do
      add_log "Stopping $u"
      systemctl stop "$u" >/dev/null 2>&1 || true
      add_log "Disabling $u"
      systemctl disable "$u" >/dev/null 2>&1 || true
    done
  else
    add_log "No forwarders found for GRE${id}"
  fi

  add_log "Removing unit files..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/fw-gre${id}-*.service >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  add_log "Removing automation (cron/script/log/backup) for GRE${id}..."

  remove_gre_automation_cron "$id"
  add_log "Cron entry removed (if existed)."

  local a_script a_log
  a_script="$(automation_script_path "$id")"
  a_log="$(automation_log_path "$id")"

  if [[ -f "$a_script" ]]; then
    rm -f "$a_script" >/dev/null 2>&1 || true
    add_log "Removed: $a_script"
  else
    add_log "No automation script found."
  fi

  if [[ -f "$a_log" ]]; then
    rm -f "$a_log" >/dev/null 2>&1 || true
    add_log "Removed: $a_log"
  else
    add_log "No automation log found."
  fi

  remove_gre_automation_backups "$id"

  add_log "Uninstall completed for GRE${id}"
  render
  pause_enter
}

get_gre_cidr() {
  local id="$1"
  ip -4 addr show dev "gre${id}" 2>/dev/null \
    | awk '/inet /{print $2}' \
    | head -n1
}

gre_target_ip_from_cidr() {
  local cidr="$1"
  local ip mask
  ip="${cidr%/*}"
  mask="${cidr#*/}"

  valid_ipv4 "$ip" || return 1
  [[ "$mask" == "30" ]] || return 2

  IFS='.' read -r a b c d <<<"$ip"

  local base_last=$(( d & 252 ))
  local target_last=$(( base_last + 2 ))

  ((target_last>=0 && target_last<=255)) || return 3

  echo "${a}.${b}.${c}.${target_last}"
  return 0
}

add_tunnel_port() {
  local -a PORT_LIST=()
  local id cidr target_ip

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local gid
  for gid in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${gid}")
  done

  if ! menu_select_index "Add Tunnel Port" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "GRE selected: GRE${id}"

  ask_ports

  cidr="$(get_gre_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Cannot detect inet on gre${id}. Is gre${id} UP?"
    return 0
  fi
  add_log "Detected gre${id} inet: ${cidr}"

  target_ip="$(gre_target_ip_from_cidr "$cidr")"
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    die_soft "gre${id} mask is not /30 (found: ${cidr})."
    return 0
  elif [[ $rc -ne 0 || -z "$target_ip" ]]; then
    die_soft "Failed to compute target IP from: ${cidr}"
    return 0
  fi
  add_log "Target IP (network+2): ${target_ip}"

  add_log "Creating forwarders for GRE${id}..."
  local p
  for p in "${PORT_LIST[@]}"; do
    make_fw_service "$id" "$p" "$target_ip"
  done

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Enable & Start forwarders..."
  for p in "${PORT_LIST[@]}"; do
    enable_now "fw-gre${id}-${p}.service"
  done

  render
  echo "GRE${id}:"
  echo "  inet   : ${cidr}"
  echo "  target : ${target_ip}"
  echo
  echo "Status:"
  for p in "${PORT_LIST[@]}"; do
    echo
    show_unit_status_brief "fw-gre${id}-${p}.service"
  done
  pause_enter
}


select_and_set_timezone() {
  local choice tz=""
  while true; do
    render
    echo "WARNING: You need set mutual Time to IRAN and Kharej Server"
    echo "select your server clock"
    echo
    echo "1) Germany (Europe/Berlin)"
    echo "2) Turkey (Europe/Istanbul)"
    echo "3) France (Europe/Paris)"
    echo "4) Netherlands (Europe/Amsterdam)"
    echo "5) Finland (Europe/Helsinki)"
    echo "6) England (Europe/London)"
    echo "7) Sweden (Europe/Stockholm)"
    echo "8) Russia (Europe/Moscow)"
    echo "9) USA (America/New_York)"
    echo "10) Canada (America/Toronto)"
    echo "11) UTC (Etc/UTC)"
    echo "0) Skip (no change)"
    echo

    read -r -p "Select: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) tz="Europe/Berlin" ;;
      2) tz="Europe/Istanbul" ;;
      3) tz="Europe/Paris" ;;
      4) tz="Europe/Amsterdam" ;;
      5) tz="Europe/Helsinki" ;;
      6) tz="Europe/London" ;;
      7) tz="Europe/Stockholm" ;;
      8) tz="Europe/Moscow" ;;
      9) tz="America/New_York" ;;
      10) tz="America/Toronto" ;;
      11) tz="Etc/UTC" ;;
      0) add_log "Timezone setup skipped."; return 0 ;;
      *) add_log "Invalid selection: $choice"; continue ;;
    esac

    add_log "Setting timezone: $tz"
    render

    timedatectl set-timezone "$tz" >/dev/null 2>&1 || { add_log "ERROR: failed set-timezone"; return 1; }
    timedatectl set-ntp true >/dev/null 2>&1 || { add_log "ERROR: failed set-ntp true"; return 1; }

    local now
    now="$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')"
    add_log "Timezone set OK: $tz | Now: $now"
    return 0
  done
}


recreate_automation() {
  local id side mode val script cron_line

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Regenerate Automation" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done
  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }
  while true; do
    render
    echo "Time Mode"
    echo "1) Hourly time (1-12)"
    echo "2) Minute time (15-45)"
    echo
    read -r -p "Select: " mode
    [[ "$mode" == "1" || "$mode" == "2" ]] && break
    add_log "Invalid mode"
  done

  while true; do
    render
    read -r -p "how much time set for cron? " val
    if [[ "$mode" == "1" && "$val" =~ ^([1-9]|1[0-2])$ ]]; then break; fi
    if [[ "$mode" == "2" && "$val" =~ ^(1[5-9]|[2-3][0-9]|4[0-5])$ ]]; then break; fi
    add_log "Invalid time value"
  done

  script="/usr/local/bin/sepehr-recreate-gre${id}.sh"

  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ID="${id}"
SIDE="${side}"

UNIT="/etc/systemd/system/gre\${ID}.service"
LOG_FILE="/var/log/sepehr-gre\${ID}.log"
TZ="Europe/Berlin"

mkdir -p /var/log >/dev/null 2>&1 || true
touch "\$LOG_FILE" >/dev/null 2>&1 || true

log() {
  echo "[\$(TZ="\$TZ" date '+%Y-%m-%d %H:%M %Z')] \$1" >> "\$LOG_FILE"
}

[[ -f "\$UNIT" ]] || { log "ERROR: GRE\${ID} unit not found: \$UNIT"; exit 1; }

DAY=\$(TZ="\$TZ" date +%d)
HOUR=\$(TZ="\$TZ" date +%H)
AMPM=\$(TZ="\$TZ" date +%p)

DAY_DEC=\$((10#\$DAY))
HOUR_DEC=\$((10#\$HOUR))
datetimecountnumber=\$((DAY_DEC + HOUR_DEC))

old_ip=\$(grep -oP 'ip addr add \\K([0-9.]+)' "\$UNIT" | head -n1 || true)
[[ -n "\$old_ip" ]] || { log "ERROR: Cannot detect old IP in unit"; exit 1; }

IFS='.' read -r b1 oldblocknumb b3 b4 <<< "\$old_ip"

if (( oldblocknumb > 230 )); then
  oldblock_calc=4
else
  oldblock_calc=\$oldblocknumb
fi

if (( DAY_DEC <= 15 )); then
  if [[ "\$AMPM" == "AM" ]]; then
    newblock=\$((datetimecountnumber + oldblock_calc + 7))
  else
    newblock=\$((datetimecountnumber + oldblock_calc - 13))
  fi
else
  if [[ "\$AMPM" == "AM" ]]; then
    newblock=\$((datetimecountnumber + oldblock_calc + 3))
  else
    newblock=\$((datetimecountnumber + oldblock_calc - 5))
  fi
fi

(( newblock > 245 )) && newblock=245
(( newblock < 0 )) && newblock=0

new_ip="\${b1}.\${newblock}.\${datetimecountnumber}.\${b4}"

sed -i.bak -E "s/ip addr add [0-9.]+\\/30/ip addr add \${new_ip}\\/30/" "\$UNIT"

if [[ "\$SIDE" == "IRAN" ]]; then
  for fw in /etc/systemd/system/fw-gre\${ID}-*.service; do
    [[ -f "\$fw" ]] || continue
    sed -i.bak -E "s/TCP:[0-9.]+:/TCP:\${new_ip}:/" "\$fw"
  done
fi


systemctl stop "gre\${ID}.service"
systemctl disable "gre\${ID}.service"
ip link set "gre\${ID}" down 2>/dev/null || true
ip addr flush dev "gre\${ID}" 2>/dev/null || true
ip tunnel del "gre\${ID}" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
systemctl daemon-reload
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."gre\${ID}".rp_filter=0 >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable "gre\${ID}.service"
systemctl restart "gre\${ID}.service"

if [[ "\$SIDE" == "IRAN" ]]; then
  for fw_unit in /etc/systemd/system/fw-gre\${ID}-*.service; do
    [[ -f "\$fw_unit" ]] || continue
    systemctl restart "\$(basename "\$fw_unit")" >/dev/null 2>&1 || true
  done
fi


PORTS=""
if [[ "\$SIDE" == "IRAN" ]]; then
  PORTS=\$(
    find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre\${ID}-*.service" 2>/dev/null \
      | sed -n 's/.*-\\([0-9]\\+\\)\\.service/\\1/p' \
      | sort -n \
      | paste -sd, - \
      || true
  )
fi

log "GRE\${ID} | SIDE=\$SIDE | OLD IP=\$old_ip | NEW IP=\$new_ip | PORTS=\$PORTS"
EOF

  chmod +x "$script"

  if [[ "$mode" == "1" ]]; then
    cron_line="0 */${val} * * * ${script}"
  else
    cron_line="*/${val} * * * * ${script}"
  fi

  (crontab -l 2>/dev/null | grep -vF "$script" || true; echo "$cron_line") | crontab -

  add_log "Automation created for GRE${id}"
  add_log "Script: ${script}"
  add_log "Log   : /var/log/sepehr-gre${id}.log"
  add_log "Cron  : ${cron_line}"
  pause_enter
}

automation_backup_dir() {
  echo "/root/gre-backup"
}

automation_script_path() {
  local id="$1"
  echo "/usr/local/bin/sepehr-recreate-gre${id}.sh"
}

automation_log_path() {
  local id="$1"
  echo "/var/log/sepehr-gre${id}.log"
}

remove_gre_automation_cron() {
  local id="$1"
  local script
  script="$(automation_script_path "$id")"

  crontab -l >/dev/null 2>&1 || return 0

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$script" > "$tmp" || true
  crontab "$tmp" 2>/dev/null || true
  rm -f "$tmp" >/dev/null 2>&1 || true
}
remove_gre_automation_backups() {
  local id="$1"
  local bakdir
  bakdir="$(automation_backup_dir)"

  [[ -d "$bakdir" ]] || { add_log "Backup dir not found: $bakdir"; return 0; }

  local removed_any=0

  if [[ -f "$bakdir/gre${id}.service" ]]; then
    rm -f "$bakdir/gre${id}.service" >/dev/null 2>&1 || true
    add_log "Removed backup: $bakdir/gre${id}.service"
    removed_any=1
  fi

  local fw
  shopt -s nullglob
  for fw in "$bakdir"/fw-gre${id}-*.service; do
    rm -f "$fw" >/dev/null 2>&1 || true
    add_log "Removed backup: $fw"
    removed_any=1
  done
  shopt -u nullglob

  [[ $removed_any -eq 0 ]] && add_log "No backup files found for GRE${id}."
}


recreate_automation_mode() {
  local id side mode val script cron_line

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Rebuild Automation" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done

  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }

  while true; do
    render
    echo "Time Mode"
    echo "1) Hourly time (1-12)"
    echo "2) Minute time (15-45)"
    echo
    read -r -p "Select: " mode
    [[ "$mode" == "1" || "$mode" == "2" ]] && break
    add_log "Invalid mode"
  done

  while true; do
    render
    read -r -p "how much time set for cron? " val
    if [[ "$mode" == "1" && "$val" =~ ^([1-9]|1[0-2])$ ]]; then break; fi
    if [[ "$mode" == "2" && "$val" =~ ^(1[5-9]|[2-3][0-9]|4[0-5])$ ]]; then break; fi
    add_log "Invalid time value"
  done

  script="/usr/local/bin/sepehr-recreate-gre${id}.sh"

  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ID="${id}"
SIDE="${side}"

UNIT="/etc/systemd/system/gre\${ID}.service"
LOG_FILE="/var/log/sepehr-gre\${ID}.log"
BACKUP_DIR="/root/gre-backup"
TZ="Europe/Berlin"

mkdir -p /var/log >/dev/null 2>&1 || true
touch "\$LOG_FILE" >/dev/null 2>&1 || true
mkdir -p "\$BACKUP_DIR" >/dev/null 2>&1 || true

log() { echo "[\$(TZ="\$TZ" date '+%Y-%m-%d %H:%M %Z')] \$1" >> "\$LOG_FILE"; }

list_fw_units() {
  find /etc/systemd/system -maxdepth 1 -type f -name "fw-gre\${ID}-*.service" 2>/dev/null | sort -V || true
}

if [[ ! -f "\$UNIT" ]]; then
  log "ERROR: gre unit not found: \$UNIT"
  exit 1
fi

GRE_BAK="\$BACKUP_DIR/gre\${ID}.service"
if [[ ! -f "\$GRE_BAK" ]]; then
  cp -a "\$UNIT" "\$GRE_BAK"
  log "BACKUP created: \$GRE_BAK"
else
  log "BACKUP exists: \$GRE_BAK"
fi

FW_COUNT=0
if [[ "\$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "\$fw_path" ]] || continue
    fw_base="\$(basename "\$fw_path")"
    fw_bak="\$BACKUP_DIR/\$fw_base"
    if [[ ! -f "\$fw_bak" ]]; then
      cp -a "\$fw_path" "\$fw_bak"
      log "BACKUP created: \$fw_bak"
    else
      log "BACKUP exists: \$fw_bak"
    fi
    ((FW_COUNT++)) || true
  done < <(list_fw_units)
fi

systemctl stop "gre\${ID}.service" >/dev/null 2>&1 || true
systemctl disable "gre\${ID}.service" >/dev/null 2>&1 || true
ip link set "gre\${ID}" down 2>/dev/null || true
ip addr flush dev "gre\${ID}" 2>/dev/null || true
ip tunnel del "gre\${ID}" 2>/dev/null || true
ip route flush cache 2>/dev/null || true

if [[ "\$SIDE" == "IRAN" ]]; then
  while IFS= read -r fw_path; do
    [[ -n "\$fw_path" ]] || continue
    fw_unit="\$(basename "\$fw_path")"
    systemctl stop "\$fw_unit" >/dev/null 2>&1 || true
    systemctl disable "\$fw_unit" >/dev/null 2>&1 || true
  done < <(list_fw_units)
fi

rm -f "\$UNIT" >/dev/null 2>&1 || true

if [[ "\$SIDE" == "IRAN" ]]; then
  rm -f /etc/systemd/system/fw-gre\${ID}-*.service >/dev/null 2>&1 || true
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed  >/dev/null 2>&1 || true

if [[ ! -f "\$GRE_BAK" ]]; then
  log "ERROR: missing gre backup: \$GRE_BAK"
  exit 1
fi
cp -a "\$GRE_BAK" "\$UNIT"

RESTORED_FW=0
if [[ "\$SIDE" == "IRAN" ]]; then
  for fw_bak in "\$BACKUP_DIR"/fw-gre\${ID}-*.service; do
    [[ -f "\$fw_bak" ]] || continue
    cp -a "\$fw_bak" "/etc/systemd/system/\$(basename "\$fw_bak")"
    ((RESTORED_FW++)) || true
  done
fi



systemctl daemon-reload >/dev/null 2>&1 || true

systemctl enable --now "gre\${ID}.service" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."gre\${ID}".rp_filter=0 >/dev/null 2>&1 || true

if [[ "\$SIDE" == "IRAN" ]]; then
  for fw_unit in /etc/systemd/system/fw-gre\${ID}-*.service; do
    [[ -f "\$fw_unit" ]] || continue
    systemctl enable --now "\$(basename "\$fw_unit")" >/dev/null 2>&1 || true
  done
fi

log "Rebuild OK | GRE\${ID} | SIDE=\$SIDE | restored gre + fw from backups | fw_backup_seen=\$FW_COUNT | fw_restored=\$RESTORED_FW"
EOF

  chmod +x "$script"

  if [[ "$mode" == "1" ]]; then
    cron_line="0 */${val} * * * ${script}"
  else
    cron_line="*/${val} * * * * ${script}"
  fi

  (crontab -l 2>/dev/null | grep -vF "$script" || true; echo "$cron_line") | crontab -

  add_log "Automation created for GRE${id}"
  add_log "Script: ${script}"
  add_log "Backup: /root/gre-backup/ (gre${id}.service + fw-gre${id}-*.service)"
  add_log "Log   : /var/log/sepehr-gre${id}.log"
  add_log "Cron  : ${cron_line}"
  pause_enter
}

change_mtu() {
  local id mtu

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Change MTU" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  ask_until_valid "input your new mtu for gre (576-1600):" valid_mtu mtu

  add_log "Setting MTU on interface gre${id} to ${mtu}..."
  render
  ip link set "gre${id}" mtu "$mtu" >/dev/null 2>&1 || add_log "WARNING: gre${id} interface not found or not up (will still patch unit)."

  local unit="/etc/systemd/system/gre${id}.service"
  local backup="/root/gre-backup/gre${id}.service"

  add_log "Patching unit file: $unit"
  render
  if [[ -f "$unit" ]]; then
    ensure_mtu_line_in_unit "$id" "$mtu" "$unit"
  else
    die_soft "Unit file not found: $unit"
    return 0
  fi

  if [[ -f "$backup" ]]; then
    add_log "Patching backup unit: $backup"
    render
    ensure_mtu_line_in_unit "$id" "$mtu" "$backup"
  else
    add_log "No backup unit found (skip): $backup"
  fi

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Restarting gre${id}.service..."
  systemctl restart "gre${id}.service" >/dev/null 2>&1 || add_log "WARNING: restart failed for gre${id}.service"

  add_log "Done: GRE${id} MTU changed to ${mtu}"
  render
  pause_enter
}

main_menu() {
  local choice=""
  while true; do
    render
    echo "1 > IRAN SETUP"
    echo "2 > KHAREJ SETUP"
    echo "3 > Services ManageMent"
    echo "4 > Unistall & Clean"
	echo "5 > ADD TUNNEL PORT"
	echo "6 > Rebuild Automation"
	echo "7 > Regenerate Automation"
	echo "8 > Change MTU"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: IRAN SETUP"; iran_setup ;;
      2) add_log "Selected: KHAREJ SETUP"; kharej_setup ;;
      3) add_log "Selected: Services ManageMent"; services_management ;;
      4) add_log "Selected: Unistall & Clean"; uninstall_clean ;;
	  5) add_log "Selected: add tunnel port"; add_tunnel_port ;;
	  6) add_log "Selected: Rebuild Automation"; recreate_automation_mode ;;
	  7) add_log "Selected: Regenerate Automation"; recreate_automation ;;
	  8) add_log "Selected: change mtu"; change_mtu ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}
ensure_root "$@"
add_log "SEPEHR GRE+FORWARDER installer."
main_menu
