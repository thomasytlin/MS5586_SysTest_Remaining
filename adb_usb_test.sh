#!/usr/bin/env bash
# Host-side script to test USB-mounted storage on Android via adb
# Usage: ./adb_usb_test.sh [mount_point_or_uuid]

set -euo pipefail

MOUNT_ARG=${1:-}
TMPFILE="adb_usb_test_tmp_$$.txt"
CONTENT="hello-from-adb-test-$(date +%s)"

check_adb() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb not found in PATH"
    exit 2
  fi
  if [ -z "$(adb devices | awk 'NR>1 && $2=="device"{print $1}')" ]; then
    echo "ERROR: no adb device connected"
    adb devices
    exit 3
  fi
}

choose_mount() {
  local mounts
  # 相容某些不支援 su -c 的系統，改用 sh -c 配合 su
  mounts=$(MSYS_NO_PATHCONV=1 adb shell "ls /storage 2>/dev/null || su sh -c 'ls /storage'" | tr -d '\r')
  
  if [ -z "$mounts" ]; then
    echo "ERROR: /storage listing failed or permission denied" >&2
    exit 4
  fi
  echo -e "Detected mounts under /storage:\n$mounts" >&2
  
  local choice
  choice=$(printf "%s\n" "$mounts" | tr ' ' '\n' | grep -E '^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$' | head -n1 || true)
  
  if [ -z "$choice" ]; then
    choice=$(printf "%s\n" "$mounts" | tr ' ' '\n' | grep -Ev 'emulated|self|sdcard' | head -n1 || true)
  fi
  
  if [ -z "$choice" ]; then
    choice=$(printf "%s\n" "$mounts" | tr ' ' '\n' | head -n1)
  fi
  
  echo "$choice"
}

main() {
  check_adb

  if [ -n "$MOUNT_ARG" ]; then
    case "$MOUNT_ARG" in
      /storage/*)
        REMOTE_DIR="$MOUNT_ARG"
        ;;
      *)
        REMOTE_DIR="/storage/$MOUNT_ARG"
        ;;
    esac
  else
    MOUNT_POINT=$(choose_mount)
    REMOTE_DIR="/storage/$MOUNT_POINT"
  fi
  
  echo "Using target directory: $REMOTE_DIR"

  echo "$CONTENT" > "$TMPFILE"
  BASENAME="$TMPFILE"

  TEMP_REMOTE_PATH="/data/local/tmp/$BASENAME"
  echo "Pushing $TMPFILE -> $TEMP_REMOTE_PATH"
  MSYS_NO_PATHCONV=1 adb push "$TMPFILE" "$TEMP_REMOTE_PATH"

  REMOTE_PATH="$REMOTE_DIR/$BASENAME"
  echo "Moving file to USB mount: $REMOTE_PATH"
  # 使用 su sh -c 或直接串接指令
  MSYS_NO_PATHCONV=1 adb shell "su sh -c \"cp '$TEMP_REMOTE_PATH' '$REMOTE_PATH' && rm '$TEMP_REMOTE_PATH'\""

  echo "Reading back content from device:" 
  MSYS_NO_PATHCONV=1 adb shell "su sh -c \"cat '${REMOTE_PATH}'\"" | tr -d '\r' || true

  echo "Removing remote file"
  MSYS_NO_PATHCONV=1 adb shell "su sh -c \"rm '${REMOTE_PATH}'\""

  echo "Verifying deletion"
  if MSYS_NO_PATHCONV=1 adb shell "su sh -c \"ls '$REMOTE_DIR/'\"" | tr -d '\r' | grep -q "^$BASENAME$"; then
    echo "FAIL: file still present"
    rm -f "$TMPFILE"
    exit 6
  else
    echo "PASS: file removed"
    rm -f "$TMPFILE"
    exit 0
  fi
}

main "$@"