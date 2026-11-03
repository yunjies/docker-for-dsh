#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' 'install-proxy.sh must run as root.' >&2
  exit 2
fi
: "${DSH_REGISTRY_ALLOWED_SOURCE_IP:?set the Docker host source IP}"
python3 - "$DSH_REGISTRY_ALLOWED_SOURCE_IP" <<'PY'
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PY

stage_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
backup_dir=/etc/nginx/.dsh-token-registry-backup
server_conf=/etc/nginx/conf.d/deepseek-harness-13832.conf
upstream_conf=/etc/nginx/conf.d/00-dsh-container-upstream.conf
snippet=/etc/nginx/snippets/dsh-token-registry.location.conf
config_file=/etc/dsh-token-registry/config
secret_file=/etc/dsh-token-registry/bearer-token

for path in "$server_conf" /usr/local/sbin/dsh-update-token-map /etc/nginx/conf.d /etc/nginx/snippets /etc/systemd/system; do
  if [ ! -e "$path" ]; then
    printf 'Required proxy path is missing: %s\n' "$path" >&2
    exit 1
  fi
done
allowed_web_port=$(python3 "$stage_dir/configure_nginx.py" port "$server_conf") || {
  printf '%s\n' 'Could not identify the existing DSH upstream port.' >&2
  exit 1
}
if [ -e "$backup_dir" ]; then
  printf 'Refusing to replace existing backup directory: %s\n' "$backup_dir" >&2
  exit 1
fi
if [ -e "$snippet" ] || [ -e "$config_file" ] || [ -e "$secret_file" ] || [ -e /etc/systemd/system/dsh-token-registry.service ] || [ -e /etc/sudoers.d/dsh-token-registry ]; then
  printf '%s\n' 'A DSH token registry installation already exists; inspect it before retrying.' >&2
  exit 1
fi

install -d -o root -g root -m 0700 "$backup_dir"
cp -a "$server_conf" "$backup_dir/deepseek-harness-13832.conf"
if [ -e "$upstream_conf" ]; then
  cp -a "$upstream_conf" "$backup_dir/00-dsh-container-upstream.conf"
  : > "$backup_dir/upstream-existed"
fi

if ! getent group dsh-token-registry >/dev/null 2>&1; then
  groupadd --system dsh-token-registry
fi
if ! getent passwd dsh-token-registry >/dev/null 2>&1; then
  useradd --system --no-create-home --gid dsh-token-registry --shell /usr/sbin/nologin dsh-token-registry
fi

install -d -o root -g root -m 0755 /opt/dsh-token-registry
install -d -o root -g root -m 0755 /usr/local/lib/dsh-token-registry
install -d -o root -g root -m 0755 /etc/dsh-token-registry
install -d -o root -g root -m 0700 /var/lib/dsh-token-registry
install -m 0644 "$stage_dir/server.py" /opt/dsh-token-registry/server.py
install -m 0644 "$stage_dir/apply_registration.py" /usr/local/lib/dsh-token-registry/apply_registration.py
install -m 0750 "$stage_dir/dsh-apply-registration" /usr/local/sbin/dsh-apply-registration
install -m 0440 "$stage_dir/dsh-token-registry.sudoers" /etc/sudoers.d/dsh-token-registry
if ! visudo -cf /etc/sudoers.d/dsh-token-registry >/dev/null; then
  printf '%s\n' 'The DSH registry sudoers rule is invalid.' >&2
  exit 1
fi
install -m 0644 "$stage_dir/dsh-token-registry.service" /etc/systemd/system/dsh-token-registry.service
install -m 0644 "$stage_dir/dsh-token-registry.location.conf" "$snippet"

config_tmp=$(mktemp /etc/dsh-token-registry/.config.XXXXXX)
printf 'DSH_REGISTRY_ALLOWED_SOURCE_IP=%s\nDSH_REGISTRY_ALLOWED_WEB_PORT=%s\nDSH_REGISTRY_LISTEN_PORT=13833\nDSH_REGISTRY_SECRET_FILE=%s\nDSH_REGISTRY_APPLY_COMMAND=/usr/local/sbin/dsh-apply-registration\n' \
  "$DSH_REGISTRY_ALLOWED_SOURCE_IP" "$allowed_web_port" "$secret_file" > "$config_tmp"
chown root:dsh-token-registry "$config_tmp"
chmod 0640 "$config_tmp"
mv -f "$config_tmp" "$config_file"

secret_tmp=$(mktemp /etc/dsh-token-registry/.secret.XXXXXX)
if ! dd of="$secret_tmp" status=none; then
  rm -f "$secret_tmp"
  printf '%s\n' 'Could not receive the registry secret on stdin.' >&2
  exit 1
fi
if ! python3 - "$secret_tmp" <<'PY'
import re
import sys
with open(sys.argv[1], 'r', encoding='ascii') as source:
    value = source.read().strip()
if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', value):
    raise SystemExit(1)
PY
then
  rm -f "$secret_tmp"
  printf '%s\n' 'The registry secret has an invalid format.' >&2
  exit 1
fi
chown root:dsh-token-registry "$secret_tmp"
chmod 0640 "$secret_tmp"
mv -f "$secret_tmp" "$secret_file"

if ! python3 "$stage_dir/configure_nginx.py" patch "$server_conf" "$upstream_conf" "$snippet"; then
  cp -a "$backup_dir/deepseek-harness-13832.conf" "$server_conf"
  if [ -e "$backup_dir/upstream-existed" ]; then
    cp -a "$backup_dir/00-dsh-container-upstream.conf" "$upstream_conf"
  else
    rm -f "$upstream_conf"
  fi
  printf '%s\n' 'Could not add the registry route or upstream to Nginx config.' >&2
  exit 1
fi

if ! /usr/sbin/nginx -t >/dev/null 2>&1; then
  cp -a "$backup_dir/deepseek-harness-13832.conf" "$server_conf"
  if [ -e "$backup_dir/upstream-existed" ]; then
    cp -a "$backup_dir/00-dsh-container-upstream.conf" "$upstream_conf"
  else
    rm -f "$upstream_conf"
  fi
  /usr/sbin/nginx -t >/dev/null 2>&1 || true
  printf '%s\n' 'Nginx config check failed; original route restored.' >&2
  exit 1
fi

systemctl daemon-reload
if ! systemctl enable --now dsh-token-registry.service; then
  cp -a "$backup_dir/deepseek-harness-13832.conf" "$server_conf"
  if [ -e "$backup_dir/upstream-existed" ]; then
    cp -a "$backup_dir/00-dsh-container-upstream.conf" "$upstream_conf"
  else
    rm -f "$upstream_conf"
  fi
  /usr/sbin/nginx -t >/dev/null 2>&1 || true
  printf '%s\n' 'The registry service failed to start; original route restored.' >&2
  exit 1
fi
if ! systemctl reload nginx.service; then
  systemctl disable --now dsh-token-registry.service >/dev/null 2>&1 || true
  cp -a "$backup_dir/deepseek-harness-13832.conf" "$server_conf"
  if [ -e "$backup_dir/upstream-existed" ]; then
    cp -a "$backup_dir/00-dsh-container-upstream.conf" "$upstream_conf"
  else
    rm -f "$upstream_conf"
  fi
  /usr/sbin/nginx -t >/dev/null 2>&1 && systemctl reload nginx.service >/dev/null 2>&1 || true
  printf '%s\n' 'Nginx reload failed; original route restored.' >&2
  exit 1
fi

printf '%s\n' 'DSH token registry installed and Nginx reloaded.'
