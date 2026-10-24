#!/bin/sh
set -eu

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

if [ "$current_dsh_version" != "$resolved_dsh_version" ]; then
  printf 'Installing DSH %s (requested %s).\n' "$resolved_dsh_version" "$requested_dsh_version"
  npm install --global --no-audit --no-fund \
    --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
    "${dsh_package}@${resolved_dsh_version}"
fi

profile_dir="$DSH_HOME/profiles/web"
mkdir -p "$DSH_HOME"

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

cd "$profile_dir"
if [ -f pnpm-lock.yaml ]; then
  pnpm install --frozen-lockfile
else
  pnpm install
fi

if [ ! -f "$DSH_HOME/cordis.patch.yml" ] && [ -f /opt/dsh-home.patch.yml ]; then
  cp /opt/dsh-home.patch.yml "$DSH_HOME/cordis.patch.yml"
fi

bind_host="${DSH_BIND_HOST:-$(hostname -i | awk '{print $1}')}"
public_url="${DSH_PUBLIC_URL:?set DSH_PUBLIC_URL}"
trusted_host="${DSH_TRUSTED_HOST:?set DSH_TRUSTED_HOST}"
export DSH_TOKEN_REGISTER_URL="${DSH_TOKEN_REGISTER_URL:-}"
exec node /usr/local/bin/dsh-web-runner.mjs --profile web --no-open --host "$bind_host" --port 3080 --public-url "$public_url" --trusted-host "$trusted_host"
