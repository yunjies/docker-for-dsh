import fcntl
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

UPSTREAM_FILE = '/etc/nginx/conf.d/00-dsh-container-upstream.conf'
RECORD_FILE = '/var/lib/dsh-token-registry/registration.json'
LOCK_FILE = '/run/lock/dsh-token-registry.lock'
TOKEN_UPDATER = '/usr/local/sbin/dsh-update-token-map'
PROXY_LISTENER_PORT = '13832'
REGISTRY_CONFIG = '/etc/dsh-token-registry/config'
TOKEN_PATTERN = re.compile(r'^[A-Za-z0-9_-]{32,128}$')


def configured_value(name):
    with open(REGISTRY_CONFIG, 'r', encoding='ascii') as config:
        entries = [line.partition('=')[2].strip() for line in config if line.startswith(name + '=')]
    if len(entries) != 1:
        raise ValueError('registry configuration is invalid')
    return entries[0]


def configured_allowed_ip():
    return str(ipaddress.ip_address(configured_value('DSH_REGISTRY_ALLOWED_SOURCE_IP')))


def configured_allowed_web_port():
    value = configured_value('DSH_REGISTRY_ALLOWED_WEB_PORT')
    if not re.fullmatch(r'[1-9][0-9]{0,4}', value) or int(value) > 65535:
        raise ValueError('registry web port configuration is invalid')
    return int(value)


def validate_registration(value, allowed_ip=None, allowed_port=None):
    if not isinstance(value, dict) or set(value) != {'ip', 'web_port', 'token'}:
        raise ValueError('registration shape is invalid')
    try:
        ip = ipaddress.ip_address(value['ip'])
    except (TypeError, ValueError):
        raise ValueError('registration IP is invalid')
    if allowed_ip is not None and ip != ipaddress.ip_address(allowed_ip):
        raise ValueError('registration IP is not allowed')
    port = value['web_port']
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535 or (allowed_port is not None and port != allowed_port):
        raise ValueError('registration port is invalid')
    token = value['token']
    if not isinstance(token, str) or not TOKEN_PATTERN.fullmatch(token):
        raise ValueError('registration token is invalid')
    return {'ip': str(ip), 'web_port': port, 'token': token}


def render_upstream(registration):
    ip = ipaddress.ip_address(registration['ip'])
    address = '[{}]'.format(ip) if ip.version == 6 else str(ip)
    return 'upstream dsh_container_backend {{\n    server {}:{};\n}}\n'.format(address, registration['web_port'])


def render_record(registration, registered_at=None):
    value = dict(registration)
    value['registered_at'] = registered_at or datetime.now(timezone.utc).isoformat()
    return (json.dumps(value, sort_keys=True) + '\n').encode('utf-8')


def atomic_write(path, content, mode):
    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix='.dsh-registry-', dir=directory)
    try:
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def restore_upstream(previous):
    if previous is None:
        try:
            os.unlink(UPSTREAM_FILE)
        except FileNotFoundError:
            pass
    else:
        atomic_write(UPSTREAM_FILE, previous, 0o644)


def run_quiet(argv, **kwargs):
    try:
        result = subprocess.run(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
            check=False,
            **kwargs
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def apply_registration(registration):
    registration = validate_registration(registration, configured_allowed_ip(), configured_allowed_web_port())
    os.makedirs(os.path.dirname(RECORD_FILE), mode=0o700, exist_ok=True)
    lock_fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            with open(UPSTREAM_FILE, 'rb') as current:
                previous_upstream = current.read()
        except FileNotFoundError:
            previous_upstream = None

        atomic_write(UPSTREAM_FILE, render_upstream(registration).encode('utf-8'), 0o644)
        if not run_quiet(['/usr/sbin/nginx', '-t']):
            restore_upstream(previous_upstream)
            return False

        updated = run_quiet(
            [TOKEN_UPDATER, PROXY_LISTENER_PORT],
            input=(registration['token'] + '\n').encode('ascii'),
        )
        if not updated:
            restore_upstream(previous_upstream)
            run_quiet(['/usr/sbin/nginx', '-t'])
            run_quiet(['/usr/bin/systemctl', 'reload', 'nginx'])
            return False

        atomic_write(RECORD_FILE, render_record(registration), 0o600)
        return True
    finally:
        os.close(lock_fd)


def main():
    try:
        body = sys.stdin.buffer.read(4097)
        if len(body) > 4096:
            raise ValueError('registration body is too large')
        registration = validate_registration(json.loads(body.decode('utf-8')))
        if apply_registration(registration):
            return 0
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, OSError):
        pass
    sys.stderr.write('proxy registration could not be applied\n')
    return 1


if __name__ == '__main__':
    sys.exit(main())
