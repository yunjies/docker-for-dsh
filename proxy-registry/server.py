import hmac
import ipaddress
import json
import os
import re
import stat
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN_PATTERN = re.compile(r'^[A-Za-z0-9_-]{32,128}$')
MAX_BODY_BYTES = 4096


def validate_registration(value, source_ip, allowed_source_ip, allowed_web_port):
    if source_ip != allowed_source_ip:
        raise ValueError('source')
    if not isinstance(value, dict) or set(value) != {'ip', 'web_port', 'token'}:
        raise ValueError('shape')
    try:
        registration_ip = str(ipaddress.ip_address(value['ip']))
    except (TypeError, ValueError):
        raise ValueError('ip')
    if registration_ip != allowed_source_ip:
        raise ValueError('target')
    port = value['web_port']
    if isinstance(port, bool) or not isinstance(port, int) or port < 1 or port > 65535 or port != allowed_web_port:
        raise ValueError('port')
    token = value['token']
    if not isinstance(token, str) or not TOKEN_PATTERN.fullmatch(token):
        raise ValueError('token')
    return {'ip': registration_ip, 'web_port': port, 'token': token}


def response_body(status, message):
    return status, json.dumps({'ok': status == 200, 'message': message}).encode('utf-8')


def process_registration(body, source_ip, authorization, secret, allowed_source_ip, allowed_web_port, apply_registration):
    if source_ip != allowed_source_ip:
        return response_body(403, 'source_not_allowed')
    expected = 'Bearer ' + secret
    if not isinstance(authorization, str) or not hmac.compare_digest(authorization, expected):
        return response_body(401, 'unauthorized')
    try:
        value = json.loads(body.decode('utf-8'))
        registration = validate_registration(value, source_ip, allowed_source_ip, allowed_web_port)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return response_body(400, 'invalid_registration')
    if not apply_registration(registration):
        return response_body(502, 'registration_failed')
    return response_body(200, 'registered')


def load_secret(path):
    info = os.lstat(path)
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or mode & 0o027 or not mode & 0o400 or not mode & 0o040:
        raise RuntimeError('registration secret file permissions are invalid')
    with open(path, 'r', encoding='ascii') as secret_file:
        secret = secret_file.read().strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', secret):
        raise RuntimeError('registration secret file contents are invalid')
    return secret


def apply_with_privilege(registration, command):
    try:
        result = subprocess.run(
            ['/usr/bin/sudo', '-n', command],
            input=json.dumps(registration),
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


class RegistrationHandler(BaseHTTPRequestHandler):
    server_version = 'DshProxyRegistry/1'
    sys_version = ''

    def log_message(self, _format, *_args):
        return

    def send_json(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != '/register':
            self.send_json(*response_body(404, 'not_found'))
            return
        if self.headers.get('Transfer-Encoding') is not None:
            self.send_json(*response_body(400, 'invalid_request'))
            return
        if self.headers.get_content_type() != 'application/json':
            self.send_json(*response_body(415, 'unsupported_media_type'))
            return
        try:
            body_length = int(self.headers.get('Content-Length', ''))
        except ValueError:
            body_length = -1
        if body_length < 0 or body_length > MAX_BODY_BYTES:
            self.send_json(*response_body(413, 'invalid_request_size'))
            return
        body = self.rfile.read(body_length)
        if len(body) != body_length:
            self.send_json(*response_body(400, 'invalid_request'))
            return
        source_ip = self.headers.get('X-Real-IP', '')
        status, response = process_registration(
            body,
            source_ip,
            self.headers.get('Authorization'),
            self.server.registration_secret,
            self.server.allowed_source_ip,
            self.server.allowed_web_port,
            self.server.apply_registration,
        )
        self.send_json(status, response)


def main():
    secret_file = os.environ.get('DSH_REGISTRY_SECRET_FILE', '/etc/dsh-token-registry/bearer-token')
    allowed_ip = str(ipaddress.ip_address(os.environ['DSH_REGISTRY_ALLOWED_SOURCE_IP']))
    allowed_web_port = int(os.environ['DSH_REGISTRY_ALLOWED_WEB_PORT'])
    if allowed_web_port < 1 or allowed_web_port > 65535:
        raise RuntimeError('allowed web port is invalid')
    listen_port = int(os.environ.get('DSH_REGISTRY_LISTEN_PORT', '13833'))
    apply_command = os.environ.get('DSH_REGISTRY_APPLY_COMMAND', '/usr/local/sbin/dsh-apply-registration')
    secret = load_secret(secret_file)
    server = HTTPServer(('127.0.0.1', listen_port), RegistrationHandler)
    server.registration_secret = secret
    server.allowed_source_ip = allowed_ip
    server.allowed_web_port = allowed_web_port
    server.apply_registration = lambda registration: apply_with_privilege(registration, apply_command)
    server.serve_forever()


if __name__ == '__main__':
    main()
