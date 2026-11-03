import collections
import ipaddress
import os
import re
import stat
import sys
import tempfile
from urllib.parse import urlsplit

PROXY_PATTERN = re.compile(r'^\s*proxy_pass http://([^;\s]+);\s*$', re.MULTILINE)
UPSTREAM_NAME = 'dsh_container_backend'
SNIPPET_MARKER = 'dsh-token-registry.location.conf'


def extract_existing_target(content):
    targets = re.findall(PROXY_PATTERN, content)
    duplicates = [target for target, count in collections.Counter(targets).items() if count == 2]
    if len(duplicates) != 1:
        raise ValueError('Could not identify exactly one repeated DSH upstream.')
    target = duplicates[0]
    parsed = urlsplit('http://' + target)
    if parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password or parsed.hostname is None or parsed.port is None:
        raise ValueError('The existing DSH upstream is not a plain IP and port.')
    ip = ipaddress.ip_address(parsed.hostname)
    port = parsed.port
    if port < 1 or port > 65535:
        raise ValueError('The existing DSH upstream port is invalid.')
    address = '[{}]'.format(ip) if ip.version == 6 else str(ip)
    return '{}:{}'.format(address, port)


def render_changes(content, snippet_path):
    if SNIPPET_MARKER in content:
        raise ValueError('The registration location is already installed.')
    target = extract_existing_target(content)
    old = 'proxy_pass http://{};'.format(target)
    if content.count(old) != 2:
        raise ValueError('The DSH upstream changed during installation.')
    updated = content.replace(old, 'proxy_pass http://{};'.format(UPSTREAM_NAME))
    marker = '    location / {'
    if updated.count(marker) != 1:
        raise ValueError('Could not identify the DSH root location.')
    updated = updated.replace(marker, '    include {};\n\n{}'.format(snippet_path, marker), 1)
    upstream = 'upstream {} {{\n    server {};\n}}\n'.format(UPSTREAM_NAME, target)
    return updated, upstream, target


def atomic_write(path, content, owner, group, mode):
    descriptor, temporary = tempfile.mkstemp(prefix='.dsh-registry-', dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chown(temporary, owner, group)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def patch_files(server_path, upstream_path, snippet_path):
    with open(server_path, 'r', encoding='utf-8') as source:
        content = source.read()
    updated, upstream, target = render_changes(content, snippet_path)
    server_info = os.stat(server_path)
    atomic_write(upstream_path, upstream, 0, 0, 0o644)
    atomic_write(
        server_path,
        updated,
        server_info.st_uid,
        server_info.st_gid,
        stat.S_IMODE(server_info.st_mode),
    )
    return target


def main(argv):
    if len(argv) == 3 and argv[1] == 'port':
        with open(argv[2], 'r', encoding='utf-8') as source:
            target = extract_existing_target(source.read())
        print(target.rsplit(':', 1)[1])
        return 0
    if len(argv) == 5 and argv[1] == 'patch':
        patch_files(argv[2], argv[3], argv[4])
        return 0
    sys.stderr.write('invalid configure_nginx.py invocation\n')
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except (OSError, ValueError):
        sys.stderr.write('Nginx DSH upstream configuration could not be prepared.\n')
        sys.exit(1)
