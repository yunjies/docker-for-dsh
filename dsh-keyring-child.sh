#!/bin/sh
set -eu

secret_file=${1:?}
shift
if [ -L "$secret_file" ] || [ ! -f "$secret_file" ] || [ ! -r "$secret_file" ]; then
  printf '%s\n' 'Keyring unlock file became unavailable before DSH startup.' >&2
  exit 1
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  printf '%s\n' 'D-Bus session bus was unavailable for the Secret Service keyring.' >&2
  exit 1
fi

umask 077
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
XDG_DATA_HOME=${XDG_DATA_HOME:-/data/.local/share}
export XDG_RUNTIME_DIR XDG_DATA_HOME
install -d -m 0700 "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME/keyrings"
if ! exec 3< "$secret_file"; then
  printf '%s\n' 'Keyring unlock file became unavailable before DSH startup.' >&2
  exit 1
fi

dsh_pid=
keyring_pid=
cleanup_failed=no

process_is_running() {
  process_state=$(awk '{ line=$0; sub(/^.*[)] /, "", line); split(line, fields, /[[:space:]]+/); print fields[1] }' "/proc/$1/stat" 2>/dev/null || true)
  case "$process_state" in
    ''|Z|X) return 1 ;;
    *) return 0 ;;
  esac
}

wait_for_process_exit() {
  wait_pid=$1
  wait_attempts=40
  while [ "$wait_attempts" -gt 0 ] && process_is_running "$wait_pid"; do
    sleep 0.1
    wait_attempts=$((wait_attempts - 1))
  done
  ! process_is_running "$wait_pid"
}

stop_managed_process() {
  process_pid=$1
  process_label=$2
  [ -n "$process_pid" ] || return 0
  if process_is_running "$process_pid"; then
    kill -TERM "$process_pid" 2>/dev/null || :
    if ! wait_for_process_exit "$process_pid"; then
      kill -KILL "$process_pid" 2>/dev/null || :
      cleanup_failed=yes
      printf '%s did not stop after SIGTERM; sent SIGKILL.\n' "$process_label" >&2
      wait_for_process_exit "$process_pid" || :
    fi
  fi
  if wait "$process_pid"; then :; else :; fi
}

cleanup_children() {
  if [ -n "$dsh_pid" ]; then
    stop_managed_process "$dsh_pid" 'DSH child'
    dsh_pid=
  fi
  if [ -n "$keyring_pid" ]; then
    stop_managed_process "$keyring_pid" 'GNOME Keyring daemon'
    keyring_pid=
  fi
}

cleanup_on_exit() {
  dsh_keyring_exit_status=$?
  trap - 0
  cleanup_children
  if [ "$cleanup_failed" = yes ]; then dsh_keyring_exit_status=1; fi
  exit "$dsh_keyring_exit_status"
}

handle_signal() {
  dsh_keyring_signal_status=$1
  trap - 0 TERM INT
  cleanup_children
  if [ "$cleanup_failed" = yes ]; then dsh_keyring_signal_status=1; fi
  exit "$dsh_keyring_signal_status"
}
trap 'cleanup_on_exit' 0
trap 'handle_signal 143' TERM
trap 'handle_signal 130' INT

gnome-keyring-daemon --foreground --components=secrets --unlock <&3 >/dev/null 2>&1 &
keyring_pid=$!
exec 3<&-
sleep 0.1
if ! process_is_running "$keyring_pid"; then
  if wait "$keyring_pid"; then :; else :; fi
  keyring_pid=
  printf '%s\n' 'Could not start the Secret Service keyring.' >&2
  exit 1
fi

probe_mode=${DSH_KEYRING_PROBE:-health}
unset DSH_KEYRING_PROBE DSH_KEYRING_PROBE_ID DSH_KEYRING_PROBE_VALUE
case "$probe_mode" in
  health|yes|roundtrip)
    probe_id=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(12).toString("hex"))')
    probe_value=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(24).toString("hex"))')
    persist_mode=no
    ;;
  persist-store|persist-verify)
    probe_id=dsh-keyring-persistence-probe
    probe_value=dsh-keyring-persistence-value-v1
    persist_mode=$probe_mode
    ;;
  *)
    printf '%s\n' 'Keyring probe mode was invalid.' >&2
    exit 1
    ;;
esac
if [ "$persist_mode" = persist-verify ]; then
  probe_read=$(secret-tool lookup service dsh-keyring-persistence id "$probe_id" 2>/dev/null || true)
  if [ "$probe_read" != "$probe_value" ]; then
    unset probe_id probe_value probe_read
    printf '%s\n' 'Secret Service keyring persistence read-back failed.' >&2
    exit 1
  fi
  if ! secret-tool clear service dsh-keyring-persistence id "$probe_id" >/dev/null 2>&1; then
    unset probe_id probe_value probe_read
    printf '%s\n' 'Secret Service keyring probe cleanup failed.' >&2
    exit 1
  fi
  unset probe_id probe_value probe_read
  printf '%s\n' 'keyring-secret-service-persistence-verified=passed' >&2
else
  if [ "$persist_mode" = persist-store ]; then
    probe_service=dsh-keyring-persistence
  else
    probe_service=dsh-keyring-probe
  fi
  if ! printf '%s' "$probe_value" | secret-tool store --label='dsh keyring health probe' service "$probe_service" id "$probe_id" >/dev/null 2>&1; then
    unset probe_id probe_value
    printf '%s\n' 'Secret Service keyring round-trip failed.' >&2
    exit 1
  fi
  probe_read=$(secret-tool lookup service "$probe_service" id "$probe_id" 2>/dev/null || true)
  if [ "$probe_read" != "$probe_value" ]; then
    secret-tool clear service "$probe_service" id "$probe_id" >/dev/null 2>&1 || :
    unset probe_id probe_value probe_read
    printf '%s\n' 'Secret Service keyring round-trip failed.' >&2
    exit 1
  fi
  if [ "$persist_mode" != persist-store ] && ! secret-tool clear service "$probe_service" id "$probe_id" >/dev/null 2>&1; then
    unset probe_id probe_value probe_read
    printf '%s\n' 'Secret Service keyring probe cleanup failed.' >&2
    exit 1
  fi
  unset probe_id probe_value probe_read
  case "$persist_mode" in
    persist-store) printf '%s\n' 'keyring-secret-service-persistence-stored=passed' >&2 ;;
    *) if [ "$probe_mode" = health ]; then :; else printf '%s\n' 'keyring-secret-service-probe=passed' >&2; fi ;;
  esac
fi

"$@" &
dsh_pid=$!
if wait "$dsh_pid"; then
  dsh_keyring_child_status=0
else
  dsh_keyring_child_status=$?
fi
dsh_pid=
if [ -n "$keyring_pid" ]; then
  stop_managed_process "$keyring_pid" 'GNOME Keyring daemon'
  keyring_pid=
fi
if [ "$cleanup_failed" = yes ]; then dsh_keyring_child_status=1; fi
exit "$dsh_keyring_child_status"
