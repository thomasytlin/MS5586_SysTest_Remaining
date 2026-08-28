#!/usr/bin/env bash
# Host-side orchestrator: fully automated flow
# - discover DUT IP (via USB adb or provided)
# - enable adb tcp on DUT and connect to DUT over network
# - start SoftAP on DUT (2G/5G/6G)
# - wait for client(s) to connect and discover their IPs
# - instruct clients to run `adb connect DUT_IP:PORT` and monitor DUT for incoming adb connections

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SCRIPT_DIR/test_config.conf"
[ -f "$CONF" ] && source "$CONF"

# Defaults (can be overridden by test_config.conf or CLI)
DUT_IP_ARG="${ORCH_DUT_IP:-}"
MODE="${ORCH_MODE:-both}" # wired | wireless | both
BAND="${ORCH_BAND:-2G}"
SSID="${ORCH_SSID:-wifitest_2G}"
PWD="${ORCH_PWD:-00000000}"
AP_TIMEOUT=${ORCH_TIMEOUT:-60}
ADB_PORT=${ORCH_ADB_PORT:-55555}
ORCH_FORCE_LOCAL=${ORCH_FORCE_LOCAL:-0}

usage() {
  cat <<EOF
Usage: $0 [--dut-ip IP] [--mode wired|wireless|both] [--band 2G|5G|6G] [--ssid SSID] [--pwd PASS] [--timeout N]

Examples:
  $0                # auto detect DUT (USB adb) -> start 2G TestAP
  $0 --dut-ip 192.168.0.50 --mode wired --band 5G --ssid MyAP --pwd secret
  $0 --local-only    # force host to run adb connect (no SSH)
EOF
  exit 1
}

check_adb() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb not found in PATH" >&2
    exit 2
  fi
}

has_usb_device() {
  # return 0 if there is at least one non-network adb device (serial without colon)
  local lines
  lines=$(adb devices 2>/dev/null | sed '1d' || true)
  while read -r line; do
    [ -z "$line" ] && continue
    serial=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if echo "$serial" | grep -q ':'; then
      continue
    fi
    if [ "$state" = "device" ]; then
      return 0
    fi
  done <<< "$lines"
  return 1
}

select_usb_serial() {
  # Prefer user-specified ORCH_USB_SERIAL, else pick first non-network device
  if [ -n "${ORCH_USB_SERIAL:-}" ]; then
    echo "${ORCH_USB_SERIAL}"
    return 0
  fi
  local lines
  lines=$(adb devices 2>/dev/null | sed '1d' || true)
  while read -r line; do
    [ -z "$line" ] && continue
    serial=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if echo "$serial" | grep -q ':'; then
      continue
    fi
    if [ "$state" = "device" ]; then
      echo "$serial" && return 0
    fi
  done <<< "$lines"
  return 1
}

adb_exec() {
  # wrapper to call adb optionally with -s <serial>
  if [ -n "${USB_SERIAL:-}" ]; then
    adb -s "${USB_SERIAL}" "$@"
  else
    adb "$@"
  fi
}

clean_ip() {
  # trim whitespace, remove CR/LF, return first token (useful when functions return multiline)
  local raw="$1"
  # remove CR, replace newlines with spaces, squeeze spaces, print first field
  echo "$raw" | tr -d '\r' | tr '\n' ' ' | awk '{print $1}'
}

get_dut_ip_via_usb() {
  sanitize_ip() {
    local raw="$1"
    # remove 'addr:' prefix if present, remove CIDR /xx, trim
    raw=${raw#addr:}
    raw=${raw%%/*}
    raw=$(echo "$raw" | tr -d '\r' | tr -d ' ')
    echo "$raw"
  }

  # Try modern `ip` output first
  ip_output=$(adb_exec shell ip -4 -o addr show scope global 2>/dev/null | tr -d '\r' || true)
  if [ -n "$ip_output" ]; then
    echo "$ip_output" | awk '{print $2 " " $4}' | while read -r iface cidr; do
      ip=${cidr%%/*}
      ip=$(sanitize_ip "$ip")
      if echo "$iface" | grep -Eqi 'eth|rndis|usb|enp'; then
        # skip loopback
        if echo "$ip" | grep -qE '^127\.'; then
          continue
        fi
        echo "$ip" && return 0
      fi
    done
    echo "$ip_output" | awk '{print $2 " " $4}' | while read -r iface cidr; do
      ip=${cidr%%/*}
      ip=$(sanitize_ip "$ip")
      if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^127\.'; then
        echo "$ip" && return 0
      fi
    done
  fi

  # Fallback: try parsing ifconfig output (some devices lack `ip`)
  ifconfig_out=$(adb_exec shell ifconfig 2>/dev/null | tr -d '\r' || true)
  if [ -n "$ifconfig_out" ]; then
    # prefer wired-like interfaces
    ip=$(echo "$ifconfig_out" | awk '
    /^[^[:space:]]/ { iface=$1 }
    /inet / {
      for(i=1;i<=NF;i++) if($i=="inet") print iface, $(i+1)
    }
    /inet addr:/ {
      for(i=1;i<=NF;i++) if($i ~ /addr:/){ split($i,a,":"); print iface, a[2] }
    }
    ' | grep -E 'eth|rndis|usb|enp' | awk '{print $2}' | head -n1 || true)
    if [ -n "$ip" ]; then
      ip=$(sanitize_ip "$ip")
      if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^127\.'; then
        echo "$ip" && return 0
      fi
    fi
    # otherwise any non-loopback inet
    ip=$(echo "$ifconfig_out" | awk '
    /^[^[:space:]]/ { iface=$1 }
    /inet / {
      for(i=1;i<=NF;i++) if($i=="inet") print iface, $(i+1)
    }
    /inet addr:/ {
      for(i=1;i<=NF;i++) if($i ~ /addr:/){ split($i,a,":"); print iface, a[2] }
    }
    ' | awk '{print $2}' | head -n1 || true)
    if [ -n "$ip" ]; then
      ip=$(sanitize_ip "$ip")
      if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^127\.'; then
        echo "$ip" && return 0
      fi
    fi
  fi

  # Last resort: ip route src
  src=$(adb_exec shell ip route get 8.8.8.8 2>/dev/null | tr -d '\r' | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
  [ -n "$src" ] && echo "$src" && return 0
  return 1
}

get_dut_wifi_ip() {
  wlan_out=$(adb_exec shell ip -4 -o addr show dev wlan0 2>/dev/null | tr -d '\r' || true)
  if [ -n "$wlan_out" ]; then
    ip=$(echo "$wlan_out" | awk '{print $4}' | cut -d'/' -f1 | head -n1)
    [ -n "$ip" ] && echo "$ip" && return 0
  fi

  # Fallback to ifconfig parsing for wlan0
  ifconfig_wlan=$(adb_exec shell ifconfig wlan0 2>/dev/null | tr -d '\r' || true)
  if [ -n "$ifconfig_wlan" ]; then
    ip=$(echo "$ifconfig_wlan" | awk '
    /inet / {
      for(i=1;i<=NF;i++) if($i=="inet") print $(i+1)
    }
    /inet addr:/ {
      for(i=1;i<=NF;i++) if($i ~ /addr:/){ split($i,a,":"); print a[2] }
    }
    ' | head -n1 || true)
    if [ -n "$ip" ]; then
      echo "$ip" && return 0
    fi
  fi

  ip_route=$(adb_exec shell ip route get 8.8.8.8 2>/dev/null | tr -d '\r' || true)
  if [ -n "$ip_route" ]; then
    ip=$(echo "$ip_route" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    [ -n "$ip" ] && echo "$ip" && return 0
  fi
  return 1
}

adb_switch_to_tcp_and_connect() {
  local ip=$1
  echo "Enabling adb TCP on device (via USB): port=$ADB_PORT"
  adb_exec tcpip "$ADB_PORT" >/dev/null 2>&1 || true
  echo "Connecting to $ip:$ADB_PORT"
  adb_exec connect "${ip}:$ADB_PORT"
  sleep 1
  adb devices
}

start_softap_on_dut() {
  local band=$1
  local ssid=$2
  local pwd=$3
  echo "Starting SoftAP on DUT: band=$band ssid=$ssid"
  adb_exec shell svc wifi enable >/dev/null 2>&1 || true
  sleep 1
  case "$band" in
    2G)
      adb_exec shell cmd wifi start-softap "$ssid" wpa2 "$pwd" -b 2 -w 20 >/dev/null 2>&1 || return 1
      ;;
    5G)
      adb_exec shell cmd wifi start-softap "$ssid" wpa2 "$pwd" -b 5 -w 80 >/dev/null 2>&1 || return 1
      ;;
    6G)
      adb_exec shell cmd wifi start-softap "$ssid" wpa3 "$pwd" -b 6 -w 160 >/dev/null 2>&1 || return 1
      ;;
    *)
      echo "Unknown band: $band"; return 1
      ;;
  esac
  sleep 3
}

get_ap_iface() {
  adb_exec shell iw dev 2>/dev/null | awk '
    $1=="Interface"{iface=$2}
    $1=="type" && $2=="AP"{print iface; exit}
  '
}

wait_for_ap_client_and_get_ips() {
  local ap_iface=$1
  local timeout=$2
  local required=${3:-1}
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    ips=$(adb_exec shell ip neigh show dev "$ap_iface" 2>/dev/null | tr -d '\r' | awk '/lladdr/ && $0 !~ /(FAILED|INCOMPLETE)/ {print $1}' | sort -u)
    count=$(printf '%s
' "$ips" | grep -c . || true)
    if [ "$count" -ge "$required" ] && [ "$count" -gt 0 ]; then
      echo "$ips"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  return 1
}

monitor_adb_connections_on_dut() {
  local timeout=${1:-60}
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    conn=$(adb_exec shell ss -tn 2>/dev/null | tr -d '\r' | grep ":${ADB_PORT} " | grep ESTAB || true)
    if [ -z "$conn" ]; then
      conn=$(adb_exec shell netstat -tn 2>/dev/null | tr -d '\r' | grep ":${ADB_PORT} " | grep ESTABLISHED || true)
    fi
    if [ -n "$conn" ]; then
      echo "$conn"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  return 1
}

get_dut_eth_ip() {
  # Try to find a wired-like IP (eth, enp, rndis)
  out=$(adb_exec shell ip -4 -o addr show scope global 2>/dev/null | tr -d '\r' || true)
  if [ -n "$out" ]; then
    echo "$out" | awk '{print $2 " " $4}' | while read -r iface cidr; do
      ip=${cidr%%/*}
      ip=$(echo "$ip" | sed 's/^addr://;s#/.*##')
      if echo "$iface" | grep -Eqi 'eth|enp|rndis|usb'; then
        if ! echo "$ip" | grep -qE '^127\.'; then
          echo "$ip" && return 0
        fi
      fi
    done
  fi

  # Fallback to ifconfig parsing
  ifconfig_out=$(adb_exec shell ifconfig 2>/dev/null | tr -d '\r' || true)
  if [ -n "$ifconfig_out" ]; then
    ip=$(echo "$ifconfig_out" | awk '/^[^[:space:]]/ { iface=$1 } /inet / { for(i=1;i<=NF;i++) if($i=="inet") print iface, $(i+1) }' | grep -E 'eth|enp|rndis|usb' | awk '{print $2}' | head -n1 || true)
    ip=$(echo "$ip" | sed 's/^addr://;s#/.*##')
    if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^127\.'; then
      echo "$ip" && return 0
    fi
  fi
  return 1
}

try_adb_connect_with_retries() {
  local ip=$1
  # normalize ip input
  ip=$(clean_ip "$ip")
  if [ -z "$ip" ]; then
    return 1
  fi
  echo "Enabling adb TCP on device (via USB): port=${ADB_PORT}"
  adb_exec tcpip "${ADB_PORT}" >/dev/null 2>&1 || true
  sleep 1

  if command -v ping >/dev/null 2>&1; then
    if ! ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      echo "Warning: DUT $ip not reachable by ICMP from host"
    fi
  fi

  local connected=1
    for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "Attempt $i: adb connect ${ip}:${ADB_PORT}"
    if adb connect "${ip}:${ADB_PORT}" 2>&1 | tee /dev/stderr | grep -q -E 'connected to|already connected'; then
      connected=0
      break
    fi
    sleep 2
  done

  return $connected
}

stop_softap() {
  adb_exec shell cmd wifi stop-softap >/dev/null 2>&1 || true
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dut-ip) DUT_IP_ARG="$2"; shift 2 ;;
      --mode) MODE="$2"; shift 2 ;;
      --client-number) ORCH_CLIENT_NUMBER="$2"; shift 2 ;;
      --local-only) ORCH_FORCE_LOCAL=1; shift 1 ;;
      --band) BAND="$2"; shift 2 ;;
      --ssid) SSID="$2"; shift 2 ;;
      --pwd) PWD="$2"; shift 2 ;;
      --timeout) AP_TIMEOUT="$2"; shift 2 ;;
      --ssh-user) ORCH_SSH_USER="$2"; shift 2 ;;
      --ssh-key) ORCH_SSH_KEY="$2"; shift 2 ;;
      --ssh-pass) ORCH_SSH_PASS="$2"; shift 2 ;;
      --ssh-port) ORCH_SSH_PORT="$2"; shift 2 ;;
      -h|--help) usage ;;
      *) echo "Unknown arg: $1"; usage ;;
    esac
  done
}

ssh_run_cmd() {
  # ssh_run_cmd <ip> <cmd>
  local ip="$1"; shift
  local cmd="$*"

  if [ -n "${ORCH_SSH_KEY:-}" ] && [ -f "${ORCH_SSH_KEY}" ]; then
    ssh -oStrictHostKeyChecking=no -oBatchMode=yes -i "${ORCH_SSH_KEY}" -p "${ORCH_SSH_PORT:-22}" "${ORCH_SSH_USER}@${ip}" "$cmd"
    return $?
  fi

  if [ "${ORCH_SSH_USE_SSHPASS:-0}" -eq 1 ] && [ -n "${ORCH_SSH_PASS:-}" ]; then
    if command -v sshpass >/dev/null 2>&1; then
      sshpass -p "${ORCH_SSH_PASS}" ssh -oStrictHostKeyChecking=no -p "${ORCH_SSH_PORT:-22}" "${ORCH_SSH_USER}@${ip}" "$cmd"
      return $?
    else
      echo "sshpass not installed on host; cannot use password-based SSH." >&2
      return 2
    fi
  fi

  # fallback to plain ssh (uses agent or pre-shared key on host)
  ssh -oStrictHostKeyChecking=no -p "${ORCH_SSH_PORT:-22}" "${ORCH_SSH_USER}@${ip}" "$cmd"
  return $?
}

ssh_adb_connect_clients() {
  local ips="$1"
  local dut_ip="$2"
  local any_ok=1

  if [ -z "${ORCH_SSH_USER:-}" ]; then
    echo "No ORCH_SSH_USER configured; cannot SSH into clients for automated adb connect." >&2
    return 2
  fi

  while read -r ip; do
    ip=$(echo "$ip" | tr -d '\r')
    [ -z "$ip" ] && continue
    echo "Attempting SSH -> ${ORCH_SSH_USER}@${ip} to run adb connect ${dut_ip}:${ADB_PORT}"
    # remote command: try to run adb connect; we wrap in sh -c to ensure proper quoting
    if ssh_run_cmd "$ip" "adb connect ${dut_ip}:${ADB_PORT} >/dev/null 2>&1 && echo CONNECT_OK || echo CONNECT_FAIL" | grep -q CONNECT_OK; then
      echo "Client ${ip}: remote adb connect succeeded"
      any_ok=0
    else
      echo "Client ${ip}: remote adb connect failed or unreachable"
    fi
  done <<< "$ips"

  return $any_ok
}

main() {
  check_adb
  parse_args "$@"

  # If a USB adb device exists, pick its serial so adb_exec can target it when needed
  if serial=$(select_usb_serial 2>/dev/null); then
    USB_SERIAL="$serial"
    echo "Using USB adb serial: $USB_SERIAL"
  fi

  if [ -n "$DUT_IP_ARG" ]; then
    DUT_IP="$DUT_IP_ARG"
  else
    echo "Detecting DUT IP via existing adb (USB)..."
    DUT_IP=$(get_dut_ip_via_usb) || true
  fi
  # normalize DUT_IP if present
  if [ -n "${DUT_IP:-}" ]; then
      DUT_IP=$(clean_ip "$DUT_IP")
      echo "Wired: DUT IP: $DUT_IP"
  fi

  if [ "$MODE" = "wired" ] || [ "$MODE" = "both" ]; then
    # Preference: if a USB device is attached, use it to enable adb TCP and to read DUT IP
    if has_usb_device; then
      echo "USB device detected. Prefer USB for adb tcpip operations."
      if [ -z "${DUT_IP:-}" ]; then
        echo "Attempting to read DUT IP via USB..."
        DUT_IP=$(get_dut_ip_via_usb) || true
      fi

      if [ -n "${DUT_IP:-}" ]; then
        echo "Using DUT IP: $DUT_IP (from USB or arg)"
        echo "Enabling adb TCP on device (via USB): port=${ADB_PORT}"
        adb tcpip "${ADB_PORT}" >/dev/null 2>&1 || true
        sleep 1
        if try_adb_connect_with_retries "$DUT_IP"; then
            echo "Wired adb connect succeeded: $DUT_IP:${ADB_PORT}"
          DUT_TARGET_IP="$DUT_IP"
        else
          echo "Wired adb connect failed for $DUT_IP:${ADB_PORT}. Continuing." >&2
        fi
      else
        echo "ERROR: could not determine DUT IP via USB" >&2
      fi
    else
      # No USB available: try to detect wired IP via network interfaces on DUT
      if [ -z "${DUT_IP:-}" ]; then
        echo "No USB device. Trying wired interface detection."
        DUT_IP=$(get_dut_eth_ip) || true
      fi

      if [ -n "${DUT_IP:-}" ]; then
          echo "Wired: DUT IP: $DUT_IP"
        if try_adb_connect_with_retries "$DUT_IP"; then
          echo "Wired adb connect succeeded: $DUT_IP:${ADB_PORT}"
          DUT_TARGET_IP="$DUT_IP"
        else
          echo "Wired adb connect failed for $DUT_IP:${ADB_PORT}." >&2
        fi
      else
        echo "ERROR: no DUT IP for wired mode. Provide --dut-ip or connect via USB adb." >&2
      fi
    fi
  fi

  if [ "$MODE" = "wireless" ] || [ "$MODE" = "both" ]; then
    echo "Attempting to detect DUT Wi-Fi IP..."
    WIFI_IP=$(get_dut_wifi_ip) || true
    if [ -n "$WIFI_IP" ]; then
      WIFI_IP=$(clean_ip "$WIFI_IP")
      echo "DUT Wi-Fi IP: $WIFI_IP"
      echo "Trying adb connect to DUT over Wi-Fi: $WIFI_IP:$ADB_PORT"
      adb connect "${WIFI_IP}:$ADB_PORT" || true
      adb devices
    else
      echo "WARNING: could not determine DUT Wi‑Fi IP"
    fi
  fi

  if [ "$MODE" != "wired" ]; then
    start_softap_on_dut "$BAND" "$SSID" "$PWD" || { echo "Failed to start SoftAP" >&2; stop_softap; exit 5; }

    ap_iface=$(get_ap_iface)
    if [ -z "$ap_iface" ]; then
      echo "ERROR: cannot find AP interface on DUT" >&2
      stop_softap
      exit 6
    fi
    echo "AP iface: $ap_iface"

    echo "Waiting up to ${AP_TIMEOUT}s for client(s) to connect to AP... (need ${ORCH_CLIENT_NUMBER:-1})"
    ips=$(wait_for_ap_client_and_get_ips "$ap_iface" "$AP_TIMEOUT" "${ORCH_CLIENT_NUMBER:-1}") || {
      echo "No client connected within timeout" >&2
      stop_softap
      exit 7
    }

    echo -e "Client IP(s) detected:\n$ips"

    # Decide DUT IP to use for adb connect: prefer wired DUT_IP, else WIFI_IP
    DUT_TARGET_IP="${DUT_IP:-${WIFI_IP:-}}"

    # If still empty, try to get IP assigned to the AP interface (e.g. ap0)
    if [ -z "$DUT_TARGET_IP" ] && [ -n "$ap_iface" ]; then
      ap_ip=$(adb shell ip -4 -o addr show dev "$ap_iface" 2>/dev/null | tr -d '\r' | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)
      if [ -n "$ap_ip" ]; then
        DUT_TARGET_IP="$ap_ip"
        echo "Using DUT IP from AP iface $ap_iface: $DUT_TARGET_IP"
      fi
    fi

    # Ensure DUT adbd listens on TCP port BEFORE clients attempt to connect
    if [ -n "$DUT_TARGET_IP" ]; then
      DUT_TARGET_IP=$(clean_ip "$DUT_TARGET_IP")
      echo "Setting DUT adbd to listen on TCP port ${ADB_PORT} (adb tcpip ${ADB_PORT})"
      adb_exec tcpip "${ADB_PORT}" >/dev/null 2>&1 || true
      sleep 1
    else
      echo "Warning: no DUT IP available to set adbd tcpip" >&2
    fi

    # Trigger client-side adb connect
    if [ "${ORCH_FORCE_LOCAL:-0}" -eq 1 ]; then
      echo "Forced local mode: running adb connect on this host"
      if [ -n "$DUT_TARGET_IP" ]; then
        echo "Local: adb connect ${DUT_TARGET_IP}:${ADB_PORT}"
        # Check basic network reachability first
        if command -v ping >/dev/null 2>&1; then
          if ! ping -c 1 -W 1 "$DUT_TARGET_IP" >/dev/null 2>&1; then
            echo "Warning: DUT $DUT_TARGET_IP not reachable by ICMP from host"
          fi
        fi

        # Try multiple adb connect attempts (allow adbd to restart and bind)
        connected=1
        for i in 1 2 3 4 5 6 7 8 9 10; do
          echo "Attempt $i: adb connect ${DUT_TARGET_IP}:${ADB_PORT}"
          if adb connect "${DUT_TARGET_IP}:${ADB_PORT}" 2>&1 | tee /dev/stderr | grep -q -E 'connected to|already connected'; then
            connected=0
            break
          fi
          sleep 2
        done
        if [ "$connected" -ne 0 ]; then
          echo "Failed to adb connect to ${DUT_TARGET_IP}:${ADB_PORT} after multiple attempts"
        fi
      else
        echo "No DUT IP available; cannot run local adb connect."
      fi
    elif [ -n "${ORCH_SSH_USER:-}" ]; then
      echo "Attempting remote adb connect on clients via SSH (user=${ORCH_SSH_USER})..."
      if ssh_adb_connect_clients "$ips" "$DUT_TARGET_IP"; then
        echo "At least one client reported remote adb connect succeeded."
      else
        echo "Remote adb connect attempts failed or none succeeded. Falling back to local adb connect."
        if [ -n "$DUT_TARGET_IP" ]; then
          echo "Local: adb connect ${DUT_TARGET_IP}:${ADB_PORT}"
          adb connect "${DUT_TARGET_IP}:${ADB_PORT}" || true
        else
          echo "No DUT IP available for local connect."
        fi
      fi
    else
      # No SSH configured: assume the client is this host and run local adb connect to DUT
      if [ -n "$DUT_TARGET_IP" ]; then
        echo "No SSH config found; assuming this host is the client. Running local: adb connect ${DUT_TARGET_IP}:${ADB_PORT}"
        adb connect "${DUT_TARGET_IP}:${ADB_PORT}" || true
      else
        echo "No DUT IP available; cannot run local adb connect."
      fi
    fi

    echo "Waiting up to ${AP_TIMEOUT}s for a client to establish adb connection to DUT..."
    if monitor_adb_connections_on_dut "$AP_TIMEOUT"; then
      echo "Detected at least one established adb connection to DUT on port ${ADB_PORT}."
    else
      echo "No adb connections to DUT detected within timeout."
    fi

    stop_softap
    echo "Done."
  else
    echo "MODE is wired; skipping SoftAP/start-wait steps."
    echo "Waiting up to ${AP_TIMEOUT}s for adb connections to DUT..."
    if monitor_adb_connections_on_dut "$AP_TIMEOUT"; then
      echo "Detected at least one established adb connection to DUT on port ${ADB_PORT}."
    else
      echo "No adb connections to DUT detected within timeout."
    fi
    echo "Done."
  fi
}

main "$@"
