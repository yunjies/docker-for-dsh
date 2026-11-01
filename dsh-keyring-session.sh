#!/bin/sh
set -eu

secret_file=${1:?}
shift
if [ ! -f "$secret_file" ] || [ ! -r "$secret_file" ]; then
  printf '%s\n' 'Keyring unlock file became unavailable before DSH startup.' >&2
  exit 1
fi

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
exec dbus-run-session -- /bin/sh "$script_dir/dsh-keyring-child.sh" "$secret_file" "$@"
