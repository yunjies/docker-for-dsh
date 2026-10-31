#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
: "${DSH_SESSION_ID:?set DSH_SESSION_ID so generated keys and container state stay in the session directory}"
case "$DSH_SESSION_ID" in
  session-????????-????-????-????-????????????)
    session_uuid=${DSH_SESSION_ID#session-}
    case "$session_uuid" in
      *[!0-9a-f-]*) printf '%s\n' 'Invalid DSH_SESSION_ID; expected session-<lowercase UUID>.' >&2; exit 2 ;;
    esac
    ;;
  *) printf '%s\n' 'Invalid DSH_SESSION_ID; expected session-<lowercase UUID>.' >&2; exit 2 ;;
esac

host_port=${DSH_TEST_SSH_PORT:-2222}
container_test_port=${DSH_TEST_CONTAINER_SSH_PORT:-2223}
validate_test_port() {
  port_name=$1
  port_value=$2
  case "$port_value" in
    ''|*[!0-9]*|0|0*) printf '%s must be a decimal port from 1 to 65535.\n' "$port_name" >&2; exit 2 ;;
  esac
  if [ "${#port_value}" -gt 5 ] || [ "$port_value" -gt 65535 ]; then
    printf '%s must be a decimal port from 1 to 65535.\n' "$port_name" >&2
    exit 2
  fi
}
validate_test_port DSH_TEST_SSH_PORT "$host_port"
validate_test_port DSH_TEST_CONTAINER_SSH_PORT "$container_test_port"

if [ -n "${DSH_TEST_SESSION_DIR:-}" ]; then
  case "$DSH_TEST_SESSION_DIR" in
    */.sessions/"$DSH_SESSION_ID") sessions_root=${DSH_TEST_SESSION_DIR%/"$DSH_SESSION_ID"} ;;
    *) printf '%s\n' 'DSH_TEST_SESSION_DIR must end in .sessions/$DSH_SESSION_ID.' >&2; exit 2 ;;
  esac
else
  sessions_root="$repo_dir/.sessions"
fi
sessions_parent=$(CDPATH= cd -P "$(dirname "$sessions_root")" && pwd -P) || { printf '%s\n' 'Could not resolve .sessions parent.' >&2; exit 2; }
case "$repo_dir/" in
  "$sessions_parent/"*) ;;
  *) printf '%s\n' 'Refusing a .sessions root outside the project workspace ancestry.' >&2; exit 2 ;;
esac
if [ -L "$sessions_root" ]; then
  printf '%s\n' 'Refusing a symlinked .sessions root.' >&2
  exit 2
fi
if [ ! -d "$sessions_root" ]; then
  mkdir -m 700 "$sessions_root" || { printf '%s\n' 'Could not create .sessions root.' >&2; exit 2; }
fi
sessions_real=$(CDPATH= cd -P "$sessions_root" && pwd -P) || { printf '%s\n' 'Could not resolve .sessions root.' >&2; exit 2; }
[ "${sessions_real##*/}" = .sessions ] && [ "$sessions_real" = "$sessions_parent/.sessions" ] || { printf '%s\n' 'Refusing .sessions root outside its physical parent.' >&2; exit 2; }

session_dir="$sessions_real/$DSH_SESSION_ID"
if [ -L "$session_dir" ]; then
  printf '%s\n' 'Refusing a symlinked session directory.' >&2
  exit 2
fi
if [ ! -d "$session_dir" ]; then
  mkdir -m 700 "$session_dir" || { printf '%s\n' 'Could not create session directory.' >&2; exit 2; }
fi
session_real=$(CDPATH= cd -P "$session_dir" && pwd -P) || { printf '%s\n' 'Could not resolve session directory.' >&2; exit 2; }
[ "$session_real" = "$sessions_real/$DSH_SESSION_ID" ] || { printf '%s\n' 'Session directory escapes .sessions.' >&2; exit 2; }

auth_marker_state() {
  marker_file=$1
  if [ ! -e "$marker_file" ]; then
    printf '%s' 'absent'
    return 0
  fi
  if [ -f "$marker_file" ] && grep -Fqx 'askpass-used' "$marker_file"; then
    printf '%s' 'used'
  else
    printf '%s' 'invalid'
  fi
}

assert_ssh_auth_outcome() {
  auth_mode=$1
  auth_status=$2
  auth_marker_file=$3
  auth_stderr_file=$4
  auth_carriage_return=$(printf '\r')
  case "$auth_status" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$auth_stderr_file" ] || return 1
  marker_status=$(auth_marker_state "$auth_marker_file") || return 1
  if grep -Eiq 'connection reset|connection refused|connection timed out|operation timed out|no route to host|network is unreachable|kex_exchange_identification|banner exchange|could not resolve hostname|connection closed by' "$auth_stderr_file"; then
    return 1
  fi
  case "$auth_mode" in
    password-success)
      if [ "$auth_status" -eq 0 ] && [ "$marker_status" = used ] && ! grep -Fq 'Permission denied' "$auth_stderr_file"; then return 0; fi
      ;;
    password-enabled-denied)
      if [ "$auth_status" -ne 0 ] && [ "$marker_status" = used ] && tr -d "$auth_carriage_return" < "$auth_stderr_file" | grep -Eiq '^root@127\.0\.0\.1: Permission denied \([^)]*password[^)]*\)\.$'; then return 0; fi
      ;;
    password-disabled-denied)
      if [ "$auth_status" -ne 0 ] && [ "$marker_status" = absent ] && tr -d "$auth_carriage_return" < "$auth_stderr_file" | grep -Eiq '^root@127\.0\.0\.1: Permission denied \(publickey\)\.$'; then return 0; fi
      ;;
    *) return 1 ;;
  esac
  return 1
}

cleanup_auth_fixtures() {
  [ -n "${auth_fixture_dir:-}" ] || return 0
  [ -d "$auth_fixture_dir" ] && [ ! -L "$auth_fixture_dir" ] || return 0
  auth_fixture_real=$(CDPATH= cd -P "$auth_fixture_dir" && pwd -P) || return 0
  [ "$auth_fixture_real" = "$session_real/auth-fixtures-$$" ] || return 0
  rm -rf -- "$auth_fixture_real"
}

run_auth_fixture_case() {
  fixture_name=$1
  expectation=$2
  auth_mode=$3
  auth_status=$4
  marker_value=$5
  stderr_value=$6
  marker_file="$auth_fixture_dir/$fixture_name.marker"
  stderr_file="$auth_fixture_dir/$fixture_name.stderr"
  rm -f "$marker_file"
  : > "$stderr_file"
  chmod 600 "$stderr_file"
  if [ "$marker_value" = used ]; then
    printf '%s\n' 'askpass-used' > "$marker_file"
    chmod 600 "$marker_file"
  fi
  printf '%s\n' "$stderr_value" > "$stderr_file"
  if [ "$expectation" = accept ]; then
    if assert_ssh_auth_outcome "$auth_mode" "$auth_status" "$marker_file" "$stderr_file"; then return 0; fi
    printf 'SSH auth fixture unexpectedly rejected: %s\n' "$fixture_name" >&2
    return 1
  fi
  if assert_ssh_auth_outcome "$auth_mode" "$auth_status" "$marker_file" "$stderr_file"; then
    printf 'SSH auth fixture unexpectedly accepted: %s\n' "$fixture_name" >&2
    return 1
  fi
  return 0
}

run_auth_fixtures() {
  command -v grep >/dev/null 2>&1 || { printf '%s\n' 'Required command missing: grep' >&2; return 2; }
  command -v tr >/dev/null 2>&1 || { printf '%s\n' 'Required command missing: tr' >&2; return 2; }
  auth_fixture_dir="$session_real/auth-fixtures-$$"
  if [ -L "$auth_fixture_dir" ] || [ -e "$auth_fixture_dir" ]; then
    printf '%s\n' 'Refusing to reuse an existing auth fixture directory.' >&2
    return 2
  fi
  mkdir -m 700 "$auth_fixture_dir" || { printf '%s\n' 'Could not create auth fixture directory.' >&2; return 2; }
  auth_fixture_real=$(CDPATH= cd -P "$auth_fixture_dir" && pwd -P) || { printf '%s\n' 'Could not resolve auth fixture directory.' >&2; return 2; }
  [ "$auth_fixture_real" = "$session_real/auth-fixtures-$$" ] || { printf '%s\n' 'Auth fixture directory escapes the current session.' >&2; return 2; }
  trap 'cleanup_auth_fixtures' 0
  auth_carriage_return=$(printf '\r')
  run_auth_fixture_case wrong-password-permission-denied accept password-enabled-denied 255 used 'root@127.0.0.1: Permission denied (password).'
  run_auth_fixture_case wrong-password-permission-crlf accept password-enabled-denied 255 used "root@127.0.0.1: Permission denied (publickey,password).${auth_carriage_return}"
  run_auth_fixture_case wrong-password-connection-reset reject password-enabled-denied 255 used 'kex_exchange_identification: Connection reset by peer'
  run_auth_fixture_case wrong-password-connection-refused reject password-enabled-denied 255 used 'ssh: connect to host 127.0.0.1 port 2222: Connection refused'
  run_auth_fixture_case wrong-password-connection-timeout reject password-enabled-denied 255 used 'ssh: connect to host 127.0.0.1 port 2222: Connection timed out'
  run_auth_fixture_case wrong-password-permission-with-reset reject password-enabled-denied 255 used 'root@127.0.0.1: Permission denied (password).
kex_exchange_identification: Connection reset by peer'
  run_auth_fixture_case wrong-password-no-askpass reject password-enabled-denied 255 absent 'root@127.0.0.1: Permission denied (password).'
  run_auth_fixture_case wrong-password-zero-exit reject password-enabled-denied 0 used 'root@127.0.0.1: Permission denied (password).'
  run_auth_fixture_case password-disabled-permission-denied accept password-disabled-denied 255 absent 'root@127.0.0.1: Permission denied (publickey).'
  run_auth_fixture_case password-disabled-permission-crlf accept password-disabled-denied 255 absent "root@127.0.0.1: Permission denied (publickey).${auth_carriage_return}"
  run_auth_fixture_case password-disabled-askpass reject password-disabled-denied 255 used 'root@127.0.0.1: Permission denied (publickey).'
  run_auth_fixture_case password-disabled-connection-reset reject password-disabled-denied 255 absent 'kex_exchange_identification: Connection reset by peer'
  run_auth_fixture_case password-disabled-zero-exit reject password-disabled-denied 0 absent 'root@127.0.0.1: Permission denied (publickey).'
  run_auth_fixture_case correct-password-success accept password-success 0 used ''
  run_auth_fixture_case correct-password-marker-required reject password-success 0 absent ''
  printf '%s\n' 'SSH auth assertion fixtures passed (15 cases).'
}

cleanup_diagnostic_fixtures() {
  [ -n "${diagnostic_fixture_dir:-}" ] || return 0
  [ -d "$diagnostic_fixture_dir" ] && [ ! -L "$diagnostic_fixture_dir" ] || return 0
  diagnostic_fixture_real=$(CDPATH= cd -P "$diagnostic_fixture_dir" && pwd -P) || return 0
  [ "$diagnostic_fixture_real" = "$session_real/diagnostic-fixtures-$$" ] || return 0
  rm -rf -- "$diagnostic_fixture_real"
}

run_diagnostic_fixture_case() {
  fixture_name=$1
  input_line=$2
  expected=$3
  input_file="$diagnostic_fixture_dir/$fixture_name.input"
  output_file="$diagnostic_fixture_dir/$fixture_name.output"
  printf '%s\n' "$input_line" > "$input_file"
  chmod 600 "$input_file"
  filter_safe_diagnostics < "$input_file" > "$output_file"
  chmod 600 "$output_file"
  if ! grep -Fqx "$expected" "$output_file"; then
    printf 'Diagnostic fixture classification mismatch: %s\n' "$fixture_name" >&2
    return 1
  fi
  if grep -E 'FIXTURE_(PASSWORD|TOKEN|KEY)|/tmp/fixture-private-path' "$output_file" >/dev/null 2>&1 || grep -F "$diagnostic_nonce" "$output_file" >/dev/null 2>&1; then
    printf 'Diagnostic fixture leaked sentinel material: %s\n' "$fixture_name" >&2
    return 1
  fi
}

run_state_fixture_case() {
  fixture_name=$1
  state_record=$2
  expected_status=$3
  state_file="$diagnostic_fixture_dir/$fixture_name.state"
  state_output="$diagnostic_fixture_dir/$fixture_name.output"
  printf '%s\n' "$state_record" > "$state_file"
  chmod 600 "$state_file"
  if parse_container_state_record "$(cat "$state_file")" > "$state_output" 2>/dev/null; then
    actual_status=0
  else
    actual_status=$?
  fi
  [ "$actual_status" -eq "$expected_status" ] || {
    printf 'Container-state fixture acceptance mismatch: %s\n' "$fixture_name" >&2
    return 1
  }
  if [ "$expected_status" -eq 0 ] && ! grep -Eq '^Container state: exit=[0-9]+ init-pid=[0-9]+ oom-killed=(true|false) docker-error-present=(true|false)$' "$state_output"; then
    printf 'Container-state fixture output was not numeric/boolean: %s\n' "$fixture_name" >&2
    return 1
  fi
}

filter_safe_diagnostics() {
  awk '
    function emit(code) { print "diagnostic=" code; found = 1 }
    function peer_exit(component, status) { print "runner-peer-exit component=" component " " status; found = 1 }
    BEGIN {
      stage_map["bootstrap_init"] = "bootstrap-init"
      stage_map["openssh_runtime_install"] = "openssh-runtime-install"
      stage_map["openssh_runtime_repository_update"] = "openssh-runtime-repository-update"
      stage_map["openssh_runtime_package_install"] = "openssh-runtime-package-install"
      stage_map["data_volume"] = "data-volume"
      stage_map["sshd_runtime_dir"] = "sshd-runtime-dir"
      stage_map["authorized_keys_source"] = "authorized-keys-source"
      stage_map["authorized_keys_snapshot"] = "authorized-keys-snapshot"
      stage_map["host_keys"] = "host-keys"
      stage_map["password_validation"] = "password-validation"
      stage_map["password_setup"] = "password-setup"
      stage_map["version_resolution"] = "version-resolution"
      stage_map["dsh_install"] = "dsh-install"
      stage_map["profile_initialize"] = "profile-initialize"
      stage_map["profile_configuration"] = "profile-configuration"
      stage_map["profile_dependencies"] = "profile-dependencies"
      stage_map["home_patch"] = "home-patch"
      stage_map["runner_configuration"] = "runner-configuration"
      stage_map["runner_handoff"] = "runner-handoff"
    }
    {
      if (index($0, "dsh-bootstrap: failed stage=") == 1) {
        if ($0 ~ /^dsh-bootstrap: failed stage=[a-z_]+ exit=[0-9]+$/) {
          stage = $3
          code = $4
          sub(/^stage=/, "", stage)
          sub(/^exit=/, "", code)
          if ((stage in stage_map) && length(code) <= 3 && code + 0 > 0 && code + 0 <= 255) {
            emit("bootstrap-stage-" stage_map[stage] "-exit-" (code + 0))
          }
        }
        next
      }
      if ($0 == "OpenSSH startup installation requires apt-get.") { emit("bootstrap-openssh-apt-get-unavailable"); next }
      if ($0 == "Could not update package metadata for OpenSSH startup installation.") { emit("bootstrap-openssh-repository-update-failed"); next }
      if ($0 == "Could not install OpenSSH startup packages.") { emit("bootstrap-openssh-package-install-failed"); next }
      if ($0 == "SSH_PORT must be a canonical decimal port without leading zeros from 1 to 65535.") { emit("bootstrap-ssh-port-invalid"); next }
      if ($0 == "/data must be a readable and writable volume.") { emit("bootstrap-data-volume-invalid"); next }
      if ($0 == "Could not create the SSH key source directory under /data.") { emit("bootstrap-ssh-source-directory-create-failed"); next }
      if ($0 == "Could not create /data/.ssh/authorized_keys.") { emit("bootstrap-authorized-keys-source-create-failed"); next }
      if ($0 == "/data/.ssh/authorized_keys must be a readable regular file.") { emit("bootstrap-authorized-keys-source-invalid"); next }
      if ($0 == "Could not prepare the root-owned runtime authorized_keys snapshot.") { emit("bootstrap-authorized-keys-snapshot-failed"); next }
      if ($0 == "Could not create missing SSH host keys.") { emit("bootstrap-host-key-generation-failed"); next }
      if ($0 == "SSH_PASSWORD must not contain line breaks.") { emit("bootstrap-password-linebreak-rejected"); next }
      if ($0 == "Could not set the root password from SSH_PASSWORD.") { emit("bootstrap-root-password-setup-failed"); next }
      if ($0 == "Invalid DSH_VERSION; use latest, an npm dist-tag, or an exact version.") { emit("bootstrap-dsh-version-invalid"); next }
      if ($0 ~ /^Could not resolve requested DSH version [A-Za-z0-9._+-]+[.]$/) { emit("bootstrap-dsh-version-resolution-failed"); next }
      if ($0 ~ /^NPM registry unavailable; keeping installed DSH [A-Za-z0-9._+-]+[.]$/) { emit("bootstrap-registry-fallback"); next }
      if ($0 ~ /^Installing DSH [A-Za-z0-9._+-]+ \(requested [A-Za-z0-9._+-]+\)[.]$/) { emit("bootstrap-dsh-install-started"); next }
      if ($0 ~ /^sshd startup validation failed:/) { emit("runner-sshd-config-validation-failed"); next }
      if ($0 ~ /^Unable to start sshd:/ || $0 ~ /^Unable to start or control sshd:/ || $0 ~ /^Unable to signal sshd process(group)?:/) { emit("runner-sshd-start-control-failed"); next }
      if ($0 ~ /^Unable to start DSH Web:/ || $0 ~ /^Unable to start or control DSH Web:/ || $0 ~ /^Unable to signal DSH Web process(group)?:/) { emit("runner-dsh-start-control-failed"); next }
      if ($0 ~ /^Runner failed:/) { emit("runner-failed"); next }
      if ($0 == "Graceful shutdown timed out; sending SIGKILL to remaining SSH/DSH process groups.") { emit("runner-graceful-shutdown-timeout"); next }
      if ($0 == "Child processes remained after SIGKILL; exiting the container init process.") { emit("runner-children-remained-after-sigkill"); next }
      if ($0 == "dsh-web-runner: graceful shutdown requested by SIGTERM") { emit("runner-sigterm-received"); next }
      if ($0 == "dsh-web-runner: graceful shutdown requested by SIGINT") { emit("runner-sigint-received"); next }
      if ($0 == "DSH token registration skipped because token format was invalid.") { emit("runner-token-registration-format-rejected"); next }
      if ($0 == "DSH launch token registered with the proxy.") { emit("runner-token-registration-succeeded"); next }
      if ($0 == "DSH launch-token registration failed; the proxy needs a retry.") { emit("runner-token-registration-failed"); next }
      if ($0 ~ /^sshd exited \(exit code [0-9]+\); stopping the other service[.]$/) {
        status=$0; sub(/^sshd exited \(exit code /, "", status); sub(/\); stopping the other service[.]$/, "", status)
        peer_exit("sshd", "exit-code=" status); next
      }
      if ($0 ~ /^sshd exited \([0-9]+\); stopping the other service[.]$/) {
        status=$0; sub(/^sshd exited \(/, "", status); sub(/\); stopping the other service[.]$/, "", status)
        peer_exit("sshd", "exit-code=" status); next
      }
      if ($0 ~ /^sshd exited \(signal SIG[A-Z0-9]+\); stopping the other service[.]$/) {
        status=$0; sub(/^sshd exited \(signal /, "", status); sub(/\); stopping the other service[.]$/, "", status)
        peer_exit("sshd", "signal=" status); next
      }
      if ($0 ~ /^DSH Web exited \(exit code [0-9]+\); stopping the other service[.]$/) {
        status=$0; sub(/^DSH Web exited \(exit code /, "", status); sub(/\); stopping the other service[.]$/, "", status)
        peer_exit("DSH-Web", "exit-code=" status); next
      }
      if ($0 ~ /^DSH Web exited \(signal SIG[A-Z0-9]+\); stopping the other service[.]$/) {
        status=$0; sub(/^DSH Web exited \(signal /, "", status); sub(/\); stopping the other service[.]$/, "", status)
        peer_exit("DSH-Web", "signal=" status); next
      }
    }
    END { if (!found) print "no allowlisted diagnostic" }
  '
}

parse_container_state_record() {
  state_record=$1
  set -f
  set -- $state_record
  set +f
  if [ "$#" -ne 4 ]; then
    printf '%s\n' 'Container state record is malformed.' >&2
    return 1
  fi
  case "$1" in ''|*[!0-9]*) printf '%s\n' 'Container exit code is malformed.' >&2; return 1 ;; esac
  case "$2" in ''|*[!0-9]*) printf '%s\n' 'Container init PID is malformed.' >&2; return 1 ;; esac
  case "$3" in true|false) ;; *) printf '%s\n' 'Container OOM state is malformed.' >&2; return 1 ;; esac
  case "$4" in true|false) ;; *) printf '%s\n' 'Container Docker-error presence is malformed.' >&2; return 1 ;; esac
  printf 'Container state: exit=%s init-pid=%s oom-killed=%s docker-error-present=%s\n' "$1" "$2" "$3" "$4"
}

run_diagnostic_fixtures() {
  for command in awk grep od tr; do
    command -v "$command" >/dev/null 2>&1 || { printf 'Required command missing: %s\n' "$command" >&2; return 2; }
  done
  diagnostic_fixture_dir="$session_real/diagnostic-fixtures-$$"
  if [ -L "$diagnostic_fixture_dir" ] || [ -e "$diagnostic_fixture_dir" ]; then
    printf '%s\n' 'Refusing to reuse an existing diagnostic fixture directory.' >&2
    return 2
  fi
  mkdir -m 700 "$diagnostic_fixture_dir" || { printf '%s\n' 'Could not create diagnostic fixture directory.' >&2; return 2; }
  diagnostic_fixture_real=$(CDPATH= cd -P "$diagnostic_fixture_dir" && pwd -P) || { printf '%s\n' 'Could not resolve diagnostic fixture directory.' >&2; return 2; }
  [ "$diagnostic_fixture_real" = "$session_real/diagnostic-fixtures-$$" ] || { printf '%s\n' 'Diagnostic fixture directory escapes the current session.' >&2; return 2; }
  trap 'cleanup_diagnostic_fixtures' 0
  diagnostic_nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n') || { printf '%s\n' 'Could not generate diagnostic fixture sentinel.' >&2; return 2; }
  case "$diagnostic_nonce" in
    ''|*[!0-9a-f]*) printf '%s\n' 'Diagnostic fixture sentinel was malformed.' >&2; return 2 ;;
  esac
  [ "${#diagnostic_nonce}" -eq 16 ] || { printf '%s\n' 'Diagnostic fixture sentinel had an unexpected length.' >&2; return 2; }
  diagnostic_password="FIXTURE_PASSWORD_$diagnostic_nonce"
  diagnostic_token="FIXTURE_TOKEN_$diagnostic_nonce"
  diagnostic_key="FIXTURE_KEY_$diagnostic_nonce"
  diagnostic_path="/tmp/fixture-private-path-$diagnostic_nonce"
  run_state_fixture_case valid-state '1 0 false false' 0
  run_state_fixture_case malformed-exit 'one 0 false false' 1
  run_state_fixture_case malformed-pid '1 pid false false' 1
  run_state_fixture_case extra-state-field '1 0 false false secret' 1
  run_diagnostic_fixture_case data-volume '/data must be a readable and writable volume.' 'diagnostic=bootstrap-data-volume-invalid'
  run_diagnostic_fixture_case openssh-apt-get-unavailable 'OpenSSH startup installation requires apt-get.' 'diagnostic=bootstrap-openssh-apt-get-unavailable'
  run_diagnostic_fixture_case openssh-repository-update 'Could not update package metadata for OpenSSH startup installation.' 'diagnostic=bootstrap-openssh-repository-update-failed'
  run_diagnostic_fixture_case openssh-package-install 'Could not install OpenSSH startup packages.' 'diagnostic=bootstrap-openssh-package-install-failed'
  run_diagnostic_fixture_case ssh-port-invalid 'SSH_PORT must be a canonical decimal port without leading zeros from 1 to 65535.' 'diagnostic=bootstrap-ssh-port-invalid'
  run_diagnostic_fixture_case authkeys-source 'Could not create /data/.ssh/authorized_keys.' 'diagnostic=bootstrap-authorized-keys-source-create-failed'
  run_diagnostic_fixture_case host-key-failure 'Could not create missing SSH host keys.' 'diagnostic=bootstrap-host-key-generation-failed'
  run_diagnostic_fixture_case password-linebreak 'SSH_PASSWORD must not contain line breaks.' 'diagnostic=bootstrap-password-linebreak-rejected'
  run_diagnostic_fixture_case password-chpasswd 'Could not set the root password from SSH_PASSWORD.' 'diagnostic=bootstrap-root-password-setup-failed'
  run_diagnostic_fixture_case dsh-version-invalid 'Invalid DSH_VERSION; use latest, an npm dist-tag, or an exact version.' 'diagnostic=bootstrap-dsh-version-invalid'
  run_diagnostic_fixture_case dsh-version-resolution "Could not resolve requested DSH version ${diagnostic_token}-1.2.3." 'diagnostic=bootstrap-dsh-version-resolution-failed'
  run_diagnostic_fixture_case registry-fallback 'NPM registry unavailable; keeping installed DSH 1.2.3.' 'diagnostic=bootstrap-registry-fallback'
  run_diagnostic_fixture_case dsh-install-started 'Installing DSH 2.3.4 (requested latest).' 'diagnostic=bootstrap-dsh-install-started'
  run_diagnostic_fixture_case sshd-config "sshd startup validation failed: ${diagnostic_path} token=${diagnostic_token} password=${diagnostic_password} key=${diagnostic_key}" 'diagnostic=runner-sshd-config-validation-failed'
  run_diagnostic_fixture_case sshd-control "Unable to start or control sshd: path=${diagnostic_path} token=${diagnostic_token} password=${diagnostic_password} key=${diagnostic_key}" 'diagnostic=runner-sshd-start-control-failed'
  run_diagnostic_fixture_case dsh-control "Unable to start or control DSH Web: path=${diagnostic_path} token=${diagnostic_token} password=${diagnostic_password} key=${diagnostic_key}" 'diagnostic=runner-dsh-start-control-failed'
  run_diagnostic_fixture_case runner-peer-code 'DSH Web exited (exit code 23); stopping the other service.' 'runner-peer-exit component=DSH-Web exit-code=23'
  run_diagnostic_fixture_case runner-peer-signal 'sshd exited (signal SIGTERM); stopping the other service.' 'runner-peer-exit component=sshd signal=SIGTERM'
  run_diagnostic_fixture_case runner-timeout 'Graceful shutdown timed out; sending SIGKILL to remaining SSH/DSH process groups.' 'diagnostic=runner-graceful-shutdown-timeout'
  run_diagnostic_fixture_case runner-failed "Runner failed: path=${diagnostic_path} token=${diagnostic_token} password=${diagnostic_password} key=${diagnostic_key}" 'diagnostic=runner-failed'
  for stage in bootstrap_init openssh_runtime_install openssh_runtime_repository_update openssh_runtime_package_install data_volume sshd_runtime_dir authorized_keys_source authorized_keys_snapshot host_keys password_validation password_setup version_resolution dsh_install profile_initialize profile_configuration profile_dependencies home_patch runner_configuration runner_handoff; do
    stage_label=$(printf '%s' "$stage" | tr '_' '-')
    run_diagnostic_fixture_case "bootstrap-stage-$stage" "dsh-bootstrap: failed stage=$stage exit=1" "diagnostic=bootstrap-stage-$stage_label-exit-1"
  done
  run_diagnostic_fixture_case bootstrap-stage-unknown 'dsh-bootstrap: failed stage=npm_install exit=1' 'no allowlisted diagnostic'
  long_stage=$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "a" }')
  run_diagnostic_fixture_case bootstrap-stage-overlong "dsh-bootstrap: failed stage=${long_stage} exit=1" 'no allowlisted diagnostic'
  run_diagnostic_fixture_case bootstrap-stage-secret "dsh-bootstrap: failed stage=FIXTURE_TOKEN_${diagnostic_nonce} exit=1" 'no allowlisted diagnostic'
  run_diagnostic_fixture_case bootstrap-stage-invalid-exit 'dsh-bootstrap: failed stage=dsh_install exit=999999' 'no allowlisted diagnostic'
  run_diagnostic_fixture_case unknown-secret "unrecognized log password=${diagnostic_password} token=${diagnostic_token} key=${diagnostic_key} path=${diagnostic_path}" 'no allowlisted diagnostic'
  run_diagnostic_fixture_case mixed-secret "sshd startup validation failed: password=${diagnostic_password} token=${diagnostic_token} path=${diagnostic_path}" 'diagnostic=runner-sshd-config-validation-failed'
  printf '%s\n' 'SSH startup diagnostic fixtures passed (45 log cases and 4 state cases).'
}

case "${1:-}" in
  --auth-fixtures)
    [ "$#" -eq 1 ] || { printf '%s\n' 'Usage: docker-integration.sh --auth-fixtures' >&2; exit 2; }
    run_auth_fixtures
    exit 0
    ;;
  --diagnostic-fixtures)
    [ "$#" -eq 1 ] || { printf '%s\n' 'Usage: docker-integration.sh --diagnostic-fixtures' >&2; exit 2; }
    run_diagnostic_fixtures
    exit 0
    ;;
  '') ;;
  *) printf '%s\n' 'Unknown docker-integration.sh argument.' >&2; exit 2 ;;
esac

: "${DSH_TEST_IMAGE:?set DSH_TEST_IMAGE to a unique, unused image tag; the script never chooses or removes it}"

new_random_suffix() {
  suffix=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  case "$suffix" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#suffix}" -eq 32 ] || return 1
  printf '%s' "$suffix"
}

for command in docker ssh ssh-keygen od tr awk grep cat stat; do
  command -v "$command" >/dev/null 2>&1 || { printf 'Required command missing: %s\n' "$command" >&2; exit 2; }
done

run_suffix=$(new_random_suffix) || { printf '%s\n' 'Could not generate a unique test resource suffix.' >&2; exit 2; }
password_container_port=$container_test_port
work_dir="$session_real/docker-integration-$run_suffix"
if [ -L "$work_dir" ]; then
  printf '%s\n' 'Refusing a symlinked integration directory.' >&2
  exit 2
fi
if [ -e "$work_dir" ]; then
  printf '%s\n' 'Refusing to reuse an existing integration directory.' >&2
  exit 2
fi
mkdir -m 700 "$work_dir" || { printf '%s\n' 'Could not create integration directory.' >&2; exit 2; }
work_real=$(CDPATH= cd -P "$work_dir" && pwd -P) || { printf '%s\n' 'Could not resolve integration directory.' >&2; exit 2; }
[ "$work_real" = "$session_real/docker-integration-$run_suffix" ] || { printf '%s\n' 'Integration directory escapes the current session.' >&2; exit 2; }

if docker image inspect "$DSH_TEST_IMAGE" >/dev/null 2>&1; then
  printf 'Refusing to overwrite pre-existing image tag: %s\n' "$DSH_TEST_IMAGE" >&2
  exit 2
fi

data_dir="$work_dir/data"
home_dir="$work_dir/home"
mkdir -p "$work_dir/data/.ssh" "$work_dir/home"
chmod 700 "$work_dir/data" "$work_dir/data/.ssh" "$work_dir/home"
ssh-keygen -q -t ed25519 -N '' -f "$work_dir/id_ed25519"
cp "$work_dir/id_ed25519.pub" "$data_dir/.ssh/authorized_keys"
chmod 600 "$data_dir/.ssh/authorized_keys"
password="ssh-test-$run_suffix"
wrong_password="wrong-ssh-test-$run_suffix"
password_file="$work_dir/askpass-password"
wrong_password_file="$work_dir/askpass-wrong-password"
askpass="$work_dir/askpass.sh"
known_hosts="$work_dir/known_hosts"
correct_marker_file="$work_dir/askpass-correct.marker"
wrong_marker_file="$work_dir/askpass-wrong.marker"
disabled_marker_file="$work_dir/askpass-disabled.marker"
key_ssh_stderr_file="$work_dir/ssh-key-readiness.stderr"
correct_ssh_stderr_file="$work_dir/ssh-correct-password.stderr"
wrong_ssh_stderr_file="$work_dir/ssh-wrong-password.stderr"
disabled_ssh_stderr_file="$work_dir/ssh-password-disabled.stderr"
printf '%s' "$password" > "$password_file"
printf '%s' "$wrong_password" > "$wrong_password_file"
chmod 600 "$password_file" "$wrong_password_file"
cat > "$askpass" <<'ASKPASS_EOF'
#!/bin/sh
set -eu
: "${SSH_ASKPASS_PASSWORD_FILE:?}"
: "${SSH_ASKPASS_MARKER_FILE:?}"
umask 077
printf '%s\n' 'askpass-used' > "$SSH_ASKPASS_MARKER_FILE"
cat "$SSH_ASKPASS_PASSWORD_FILE"
ASKPASS_EOF
chmod 700 "$askpass"

run_ssh_auth_attempt() {
  ssh_password_file=$1
  ssh_marker_file=$2
  ssh_stderr_file=$3
  shift 3
  rm -f "$ssh_marker_file"
  : > "$ssh_stderr_file"
  chmod 600 "$ssh_stderr_file"
  if SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force SSH_ASKPASS_PASSWORD_FILE="$ssh_password_file" \
    SSH_ASKPASS_MARKER_FILE="$ssh_marker_file" DISPLAY=:0 ssh "$@" >/dev/null 2>"$ssh_stderr_file"; then
    ssh_exit_code=0
  else
    ssh_exit_code=$?
  fi
}

docker build -t "$DSH_TEST_IMAGE" "$repo_dir"
# OpenSSH must be installed by the normal bootstrap, not baked into the image.
docker run --rm --entrypoint /bin/sh "$DSH_TEST_IMAGE" -ec '
  if command -v ssh >/dev/null 2>&1; then
    printf "%s\\n" "OpenSSH client is present before container startup." >&2
    exit 1
  fi
  if command -v sshd >/dev/null 2>&1; then
    printf "%s\\n" "OpenSSH server is present before container startup." >&2
    exit 1
  fi
  for host_key in /etc/ssh/ssh_host_*_key; do
    if [ -e "$host_key" ]; then
      printf "%s\\n" "Build-time SSH host key found." >&2
      exit 1
    fi
  done
'

container_id=
cleanup() {
  if [ -n "$container_id" ]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

assert_container_name_unused() {
  if docker container inspect "$1" >/dev/null 2>&1; then
    printf 'Refusing to use pre-existing container name: %s\n' "$1" >&2
    return 1
  fi
}

create_and_start() {
  requested_name=$1
  password_mode=$2
  container_ssh_port=$3
  shift 3
  assert_container_name_unused "$requested_name" || return 2
  if [ -n "$container_ssh_port" ]; then
    set -- -e "SSH_PORT=$container_ssh_port" "$@"
  fi
  case "$password_mode" in
    password)
      if created_id=$(SSH_PASSWORD="$password" docker create --name "$requested_name" -e SSH_PASSWORD "$@"); then :; else
        printf '%s\n' 'Could not create the test container.' >&2
        return 1
      fi
      ;;
    no-password)
      if created_id=$(docker create --name "$requested_name" "$@"); then :; else
        printf '%s\n' 'Could not create the test container.' >&2
        return 1
      fi
      ;;
    *) printf '%s\n' 'Invalid internal password mode.' >&2; return 2 ;;
  esac
  case "$created_id" in
    ''|*[!0-9a-f]*) printf '%s\n' 'Docker create did not return a valid immutable container ID.' >&2; return 1 ;;
  esac
  [ "${#created_id}" -eq 64 ] || { printf '%s\n' 'Docker create returned an unexpected container ID length.' >&2; return 1; }
  container_id=$created_id
  docker start "$container_id" >/dev/null || return 1
}

new_container_name() {
  suffix=$(new_random_suffix) || return 1
  printf 'docker-for-dsh-test-%s-%s' "$session_uuid" "$suffix"
}

write_known_host() {
  docker exec "$container_id" sh -c 'command -v ssh >/dev/null 2>&1 && test -x /usr/sbin/sshd && command -v ssh-keygen >/dev/null 2>&1 && command -v chpasswd >/dev/null 2>&1' >/dev/null 2>&1 || return 1
  docker exec "$container_id" ssh -V >/dev/null 2>&1 || return 1
  docker exec "$container_id" test -s /etc/ssh/ssh_host_ed25519_key.pub >/dev/null 2>&1 || return 1
  public_key=$(docker exec "$container_id" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null) || {
    printf '%s\n' 'SSH host public key is ready but could not be read.' >&2
    return 2
  }
  key_fields=$(printf '%s\n' "$public_key" | awk '
    NR != 1 || NF < 2 || $1 != "ssh-ed25519" || $2 !~ /^[A-Za-z0-9+/=]+$/ { exit 1 }
    { print $1, $2 }
  ') || {
    printf '%s\n' 'SSH host public key has an invalid format.' >&2
    return 2
  }
  key_type=${key_fields%% *}
  key_blob=${key_fields#* }
  printf '[127.0.0.1]:%s %s %s\n' "$host_port" "$key_type" "$key_blob" > "$known_hosts"
  chmod 600 "$known_hosts"
  unset public_key key_fields key_type key_blob
}

check_password_not_logged() {
  logs=$(docker logs "$container_id" 2>&1 || true)
  case "$logs" in
    *"$password"*|*"$wrong_password"*) unset logs; printf '%s\n' 'SSH password material leaked to container logs.' >&2; return 1 ;;
  esac
  unset logs
}

report_container_state() {
  state=$(docker inspect -f '{{.State.ExitCode}} {{.State.Pid}} {{.State.OOMKilled}} {{if .State.Error}}true{{else}}false{{end}}' "$container_id" 2>/dev/null) || {
    printf '%s\n' 'Container exit code, PID, OOM state, and Docker-error presence are unavailable.' >&2
    return
  }
  parse_container_state_record "$state" >&2
}

report_sanitized_logs() {
  printf '%s\n' 'Container did not reach the expected SSH state; raw logs are suppressed.' >&2
  filtered_diagnostics=$(docker logs "$container_id" 2>/dev/null | filter_safe_diagnostics) || filtered_diagnostics='no allowlisted diagnostic'
  printf '%s\n' "$filtered_diagnostics" >&2
  unset filtered_diagnostics
  check_password_not_logged || true
}

proc_identity() {
  awk '{ line=$0; sub(/^.*[)] /, "", line); count=split(line, fields, /[[:space:]]+/); if (count < 20) exit 1; print fields[1] ":" fields[20] }' "/proc/$1/stat"
}

graceful_shutdown_marker='dsh-web-runner: graceful shutdown requested by SIGTERM'
peer_exit_marker='exited ('

stop_and_assert_graceful() {
  process_ids=$(docker top "$container_id" -eo pid | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }')
  [ -n "$process_ids" ] || { printf '%s\n' 'Could not enumerate container processes before stop.' >&2; return 1; }
  process_snapshots=
  for pid in $process_ids; do
    [ -r "/proc/$pid/stat" ] || continue
    identity=$(proc_identity "$pid") || { printf 'Could not snapshot host process %s.\n' "$pid" >&2; return 1; }
    case "$identity" in
      *:*) process_snapshots="$process_snapshots $pid:$identity" ;;
      *) printf 'Malformed host process identity for %s.\n' "$pid" >&2; return 1 ;;
    esac
  done
  [ -n "$process_snapshots" ] || { printf '%s\n' 'No live host process identity could be recorded before stop.' >&2; return 1; }

  stop_started=$(awk '{ print $1 }' /proc/uptime)
  running_before_stop=$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)
  [ "$running_before_stop" = true ] || {
    printf '%s\n' 'Container stopped before the graceful-stop signal; a component exited prematurely.' >&2
    return 1
  }
  docker stop -t 15 "$container_id" >/dev/null
  stop_finished=$(awk '{ print $1 }' /proc/uptime)
  stop_elapsed=$(awk -v start="$stop_started" -v finish="$stop_finished" 'BEGIN { printf "%.3f", finish - start }')
  container_state=$(docker inspect -f '{{.State.ExitCode}} {{.State.Pid}} {{.State.Running}}' "$container_id")
  set -- $container_state
  [ "$#" -eq 3 ] || { printf '%s\n' 'Could not read final container exit code, PID, and running state.' >&2; return 1; }
  container_exit_code=$1
  container_pid=$2
  container_running=$3
  [ "$container_exit_code" -eq 0 ] || { printf 'Container did not exit normally (exit=%s).\n' "$container_exit_code" >&2; return 1; }
  [ "$container_pid" -eq 0 ] || { printf 'Container init PID remained nonzero after stop: %s.\n' "$container_pid" >&2; return 1; }
  [ "$container_running" = false ] || { printf '%s\n' 'Container remained running after stop.' >&2; return 1; }
  if awk -v elapsed="$stop_elapsed" 'BEGIN { exit !(elapsed < 15) }'; then :; else
    printf 'Container stop took %ss, exhausting the 15-second grace period.\n' "$stop_elapsed" >&2
    return 1
  fi
  printf 'Graceful stop completed in %ss (exit=%s, final-pid=%s).\n' "$stop_elapsed" "$container_exit_code" "$container_pid"

  for snapshot in $process_snapshots; do
    pid=${snapshot%%:*}
    expected_identity=${snapshot#*:}
    expected_starttime=${expected_identity#*:}
    if [ -r "/proc/$pid/stat" ]; then
      current_identity=$(proc_identity "$pid") || { printf 'Could not inspect host process %s after stop.\n' "$pid" >&2; return 1; }
      current_state=${current_identity%%:*}
      current_starttime=${current_identity#*:}
      if [ "$current_starttime" = "$expected_starttime" ]; then
        case "$current_state" in
          Z|X) ;;
          *) printf 'Container host process %s remains alive in state %s after stop.\n' "$pid" "$current_state" >&2; return 1 ;;
        esac
      fi
    fi
  done

  container_logs=$(docker logs "$container_id" 2>&1 || true)
  case "$container_logs" in
    *"$graceful_shutdown_marker"*) ;;
    *) unset container_logs; printf '%s\n' 'Runner did not log the SIGTERM graceful-shutdown marker.' >&2; return 1 ;;
  esac
  case "$container_logs" in
    *"$peer_exit_marker"*) unset container_logs; printf '%s\n' 'Runner logged a peer exit before graceful shutdown.' >&2; return 1 ;;
  esac
  unset container_logs
}

docker_name=$(new_container_name) || { printf '%s\n' 'Could not create a unique container name.' >&2; exit 2; }
if ! create_and_start "$docker_name" password "$password_container_port" \
  -p "127.0.0.1:$host_port:$password_container_port" \
  -e DSH_PUBLIC_URL=https://localhost -e DSH_TRUSTED_HOST=localhost \
  -v "$data_dir:/data" -v "$home_dir:/workspace" "$DSH_TEST_IMAGE"; then
  exit 1
fi

: > "$key_ssh_stderr_file"
chmod 600 "$key_ssh_stderr_file"
ready=0
attempt=0
while [ "$attempt" -lt 120 ]; do
  if write_known_host; then
    : > "$key_ssh_stderr_file"
    if ssh -i "$work_dir/id_ed25519" -p "$host_port" -o BatchMode=yes -o ConnectTimeout=2 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" root@127.0.0.1 true >/dev/null 2>"$key_ssh_stderr_file"; then
      ready=1
      break
    fi
  else
    key_status=$?
    [ "$key_status" -eq 1 ] || exit "$key_status"
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != true ]; then
    report_sanitized_logs
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 2
done
[ "$ready" -eq 1 ] || { report_sanitized_logs; printf '%s\n' 'Timed out waiting for key SSH login.' >&2; exit 1; }
root_uid=$(docker exec "$container_id" id -u root 2>/dev/null) || { report_container_state; report_sanitized_logs; printf '%s\n' 'Root login identity is unavailable inside the container.' >&2; exit 1; }
[ "$root_uid" = 0 ] || { printf '%s\n' 'SSH login account root does not have UID 0.' >&2; exit 1; }

run_ssh_auth_attempt "$password_file" "$correct_marker_file" "$correct_ssh_stderr_file" \
  -p "$host_port" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts" root@127.0.0.1 true
if assert_ssh_auth_outcome password-success "$ssh_exit_code" "$correct_marker_file" "$correct_ssh_stderr_file"; then
  :
else
  report_container_state
  report_sanitized_logs
  printf 'Correct-password SSH authentication assertion failed (ssh exit=%s).\n' "$ssh_exit_code" >&2
  exit 1
fi
run_ssh_auth_attempt "$wrong_password_file" "$wrong_marker_file" "$wrong_ssh_stderr_file" \
  -p "$host_port" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts" root@127.0.0.1 true
if assert_ssh_auth_outcome password-enabled-denied "$ssh_exit_code" "$wrong_marker_file" "$wrong_ssh_stderr_file"; then
  :
else
  report_container_state
  report_sanitized_logs
  printf 'Incorrect-password SSH rejection assertion failed (ssh exit=%s).\n' "$ssh_exit_code" >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != true ]; then
  report_container_state
  report_sanitized_logs
  printf '%s\n' 'Password-enabled container stopped before the host-key verification.' >&2
  exit 1
fi
if host_key=$(docker exec "$container_id" sh -c 'test -s /etc/ssh/ssh_host_ed25519_key && ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key' 2>/dev/null); then
  if [ -z "$host_key" ]; then
    report_container_state
    report_sanitized_logs
    printf '%s\n' 'Runtime SSH host key was empty.' >&2
    exit 1
  fi
else
  report_container_state
  report_sanitized_logs
  printf '%s\n' 'Could not verify the runtime SSH host key.' >&2
  exit 1
fi
check_password_not_logged

# Verify the password-enabled container is still running, then stop/remove only its immutable ID.
stop_and_assert_graceful
docker rm "$container_id" >/dev/null
container_id=

docker_name=$(new_container_name) || { printf '%s\n' 'Could not create a unique container name.' >&2; exit 2; }
if ! create_and_start "$docker_name" no-password '' \
  -p "127.0.0.1:$host_port:22" \
  -e DSH_PUBLIC_URL=https://localhost -e DSH_TRUSTED_HOST=localhost \
  -v "$data_dir:/data" -v "$home_dir:/workspace" "$DSH_TEST_IMAGE"; then
  exit 1
fi
: > "$key_ssh_stderr_file"
chmod 600 "$key_ssh_stderr_file"
attempt=0
while [ "$attempt" -lt 120 ]; do
  if write_known_host; then
    : > "$key_ssh_stderr_file"
    if ssh -i "$work_dir/id_ed25519" -p "$host_port" -o BatchMode=yes -o ConnectTimeout=2 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" root@127.0.0.1 true >/dev/null 2>"$key_ssh_stderr_file"; then break; fi
  else
    key_status=$?
    [ "$key_status" -eq 1 ] || exit "$key_status"
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != true ]; then report_sanitized_logs; exit 1; fi
  attempt=$((attempt + 1)); sleep 2
done
[ "$attempt" -lt 120 ] || { report_sanitized_logs; printf '%s\n' 'Timed out waiting for password-disabled container.' >&2; exit 1; }
run_ssh_auth_attempt "$password_file" "$disabled_marker_file" "$disabled_ssh_stderr_file" \
  -p "$host_port" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts" root@127.0.0.1 true
if assert_ssh_auth_outcome password-disabled-denied "$ssh_exit_code" "$disabled_marker_file" "$disabled_ssh_stderr_file"; then
  :
else
  report_container_state
  report_sanitized_logs
  printf 'Password-disabled SSH rejection assertion failed (ssh exit=%s).\n' "$ssh_exit_code" >&2
  exit 1
fi
check_password_not_logged

stop_and_assert_graceful
printf '%s\n' 'Docker SSH integration checks passed.'
