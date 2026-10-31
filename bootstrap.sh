#!/bin/sh
set -eu

unset startup_stage dsh_bootstrap_exit_status
startup_stage=bootstrap_init

bootstrap_exit_trap() {
  dsh_bootstrap_exit_status=$?
  trap - 0
  if [ "$dsh_bootstrap_exit_status" -ne 0 ]; then
    printf 'dsh-bootstrap: failed stage=%s exit=%s\n' "$startup_stage" "$dsh_bootstrap_exit_status" >&2 || :
  fi
  exit "$dsh_bootstrap_exit_status"
}
trap 'bootstrap_exit_trap' 0

unset dsh_ssh_password_value dsh_ssh_port_value
dsh_ssh_password_value=${SSH_PASSWORD:-}
dsh_ssh_port_value=${SSH_PORT:-22}
# SSH access is fixed to root; ignore any legacy username override.
unset SSH_PASSWORD SSH_USERNAME SSH_PORT

case "$dsh_ssh_port_value" in
  ''|*[!0-9]*|0|0*)
    printf '%s\n' 'SSH_PORT must be a canonical decimal port without leading zeros from 1 to 65535.' >&2
    exit 2
    ;;
esac
if [ "${#dsh_ssh_port_value}" -gt 5 ] || [ "$dsh_ssh_port_value" -gt 65535 ]; then
  printf '%s\n' 'SSH_PORT must be a canonical decimal port without leading zeros from 1 to 65535.' >&2
  exit 2
fi

startup_stage=data_volume
if [ ! -r /data ] || [ ! -w /data ]; then
  printf '%s\n' '/data must be a readable and writable volume.' >&2
  exit 1
fi
startup_stage=openssh_runtime_install
if ! command -v ssh >/dev/null 2>&1 || [ ! -x /usr/sbin/sshd ] || ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v chpasswd >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' 'OpenSSH startup installation requires apt-get.' >&2
    exit 1
  fi
  startup_stage=openssh_runtime_repository_update
  if ! apt-get update; then
    printf '%s\n' 'Could not update package metadata for OpenSSH startup installation.' >&2
    exit 1
  fi
  startup_stage=openssh_runtime_package_install
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client openssh-server passwd; then
    printf '%s\n' 'Could not install OpenSSH startup packages.' >&2
    exit 1
  fi
  rm -rf /var/lib/apt/lists/*
fi
startup_stage=sshd_runtime_dir
install -d -m 0755 /run/sshd
startup_stage=authorized_keys_source
if ! mkdir -p /data/.ssh; then
  printf '%s\n' 'Could not create the SSH key source directory under /data.' >&2
  exit 1
fi
authorized_keys_source=/data/.ssh/authorized_keys
if [ ! -f "$authorized_keys_source" ] && ! touch "$authorized_keys_source"; then
  printf '%s\n' 'Could not create /data/.ssh/authorized_keys.' >&2
  exit 1
fi
if [ ! -r "$authorized_keys_source" ] || [ ! -f "$authorized_keys_source" ]; then
  printf '%s\n' '/data/.ssh/authorized_keys must be a readable regular file.' >&2
  exit 1
fi
startup_stage=authorized_keys_snapshot
if ! install -o root -g root -m 0600 "$authorized_keys_source" /run/sshd/authorized_keys; then
  printf '%s\n' 'Could not prepare the root-owned runtime authorized_keys snapshot.' >&2
  exit 1
fi
startup_stage=host_keys
if ! ssh-keygen -A; then
  printf '%s\n' 'Could not create missing SSH host keys.' >&2
  exit 1
fi
ssh_password_auth=no
startup_stage=password_validation
if [ -n "$dsh_ssh_password_value" ]; then
  carriage_return=$(printf '\r')
  case "$dsh_ssh_password_value" in
    *'
'*|*"$carriage_return"*)
      unset dsh_ssh_password_value
      printf '%s\n' 'SSH_PASSWORD must not contain line breaks.' >&2
      exit 2
      ;;
  esac
  startup_stage=password_setup
  if ! printf 'root:%s\n' "$dsh_ssh_password_value" | chpasswd; then
    unset dsh_ssh_password_value
    printf '%s\n' 'Could not set the root password from SSH_PASSWORD.' >&2
    exit 1
  fi
  ssh_password_auth=yes
fi
unset dsh_ssh_password_value

startup_stage=version_resolution
requested_dsh_version="${DSH_VERSION:-latest}"
case "$requested_dsh_version" in
  ''|*[!A-Za-z0-9._+-]*)
    printf '%s\n' 'Invalid DSH_VERSION; use latest, an npm dist-tag, or an exact version.' >&2
    exit 2
    ;;
esac

dsh_package='@deepseek-ai/dsh'
current_dsh_version=$(dsh --version 2>/dev/null || true)
resolved_dsh_version=$(npm view "${dsh_package}@${requested_dsh_version}" version --json --silent 2>/dev/null | tr -d '\"[:space:]' || true)
if [ -z "$resolved_dsh_version" ]; then
  if [ "$requested_dsh_version" = latest ] && [ -n "$current_dsh_version" ]; then
    resolved_dsh_version=$current_dsh_version
    printf 'NPM registry unavailable; keeping installed DSH %s.\n' "$current_dsh_version" >&2
  else
    printf 'Could not resolve requested DSH version %s.\n' "$requested_dsh_version" >&2
    exit 1
  fi
fi

startup_stage=dsh_install
if [ "$current_dsh_version" != "$resolved_dsh_version" ]; then
  printf 'Installing DSH %s (requested %s).\n' "$resolved_dsh_version" "$requested_dsh_version"
  npm install --global --no-audit --no-fund \
    --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
    "${dsh_package}@${resolved_dsh_version}"
fi

startup_stage=profile_initialize
profile_dir="$DSH_HOME/profiles/web"
mkdir -p "$DSH_HOME"

startup_stage=profile_configuration
if [ ! -f "$profile_dir/package.json" ]; then
  dsh --profile web --dump-config >/dev/null
fi

test -f "$profile_dir/package.json"
node - "$profile_dir/package.json" <<'NODE'
const fs = require('node:fs')
const path = process.argv[2]
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'))
pkg.packageManager ??= 'pnpm@11.7.0'
pkg.dependencies ??= {}
pkg.dependencies['dsh-codex-subscription'] ??= '3.1.4'
pkg.dsh ??= {}
pkg.dsh.profile ??= {}
pkg.dsh.profile.bundles ??= []
if (!pkg.dsh.profile.bundles.includes('dsh-codex-subscription')) {
  pkg.dsh.profile.bundles.push('dsh-codex-subscription')
}
fs.writeFileSync(path, `${JSON.stringify(pkg, null, 2)}\n`)
NODE

startup_stage=profile_dependencies
cd "$profile_dir"
if [ -f pnpm-lock.yaml ]; then
  pnpm install --frozen-lockfile
else
  pnpm install
fi

startup_stage=home_patch
if [ ! -f "$DSH_HOME/cordis.patch.yml" ] && [ -f /opt/dsh-home.patch.yml ]; then
  cp /opt/dsh-home.patch.yml "$DSH_HOME/cordis.patch.yml"
fi

startup_stage=runner_configuration
bind_host="${DSH_BIND_HOST:-$(hostname -i | awk '{print $1}')}"
public_url="${DSH_PUBLIC_URL:?set DSH_PUBLIC_URL}"
trusted_host="${DSH_TRUSTED_HOST:?set DSH_TRUSTED_HOST}"
export DSH_TOKEN_REGISTER_URL="${DSH_TOKEN_REGISTER_URL:-}"
export SSH_PASSWORD_AUTH="$ssh_password_auth"
export DSH_SSH_PORT="$dsh_ssh_port_value"
startup_stage=runner_handoff
exec node /usr/local/bin/dsh-web-runner.mjs --profile web --no-open --host "$bind_host" --port 3080 --public-url "$public_url" --trusted-host "$trusted_host"
