import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from apply_registration import render_record, render_upstream, validate_registration
from configure_nginx import extract_existing_target, render_changes
from server import process_registration


class ProxyRegistryTests(unittest.TestCase):
    def setUp(self):
        self.secret = 's' * 64
        self.registration = {
            'ip': '192.0.2.217',
            'web_port': 13082,
            'token': 't' * 48,
        }

    def test_valid_registration_is_applied_and_response_does_not_echo_token(self):
        applied = []
        status, body = process_registration(
            json.dumps(self.registration).encode('utf-8'),
            '192.0.2.217',
            'Bearer ' + self.secret,
            self.secret,
            '192.0.2.217',
            13082,
            lambda value: applied.append(value) or True,
        )
        self.assertEqual(status, 200)
        self.assertEqual(applied, [self.registration])
        self.assertNotIn(self.registration['token'], body.decode('utf-8'))

    def test_invalid_secret_or_source_never_invokes_updater(self):
        calls = []
        arguments = (
            json.dumps(self.registration).encode('utf-8'),
            '192.0.2.217',
            'Bearer wrong',
            self.secret,
            '192.0.2.217',
            13082,
            lambda value: calls.append(value) or True,
        )
        self.assertEqual(process_registration(*arguments)[0], 401)
        wrong_source = list(arguments)
        wrong_source[1] = '192.0.2.99'
        self.assertEqual(process_registration(*wrong_source)[0], 403)
        self.assertEqual(calls, [])

    def test_payload_must_match_source_schema_and_configured_port(self):
        mismatched = dict(self.registration, ip='192.0.2.99')
        status, _ = process_registration(
            json.dumps(mismatched).encode('utf-8'),
            '192.0.2.217',
            'Bearer ' + self.secret,
            self.secret,
            '192.0.2.217',
            13082,
            lambda _value: True,
        )
        self.assertEqual(status, 400)
        for bad in (
            dict(self.registration, web_port=True),
            dict(self.registration, web_port=70000),
            dict(self.registration, web_port=13083),
            dict(self.registration, token='not-a-token'),
            dict(self.registration, extra='value'),
        ):
            self.assertEqual(
                process_registration(
                    json.dumps(bad).encode('utf-8'),
                    '192.0.2.217',
                    'Bearer ' + self.secret,
                    self.secret,
                    '192.0.2.217',
                    13082,
                    lambda _value: True,
                )[0],
                400,
            )

    def test_nginx_rewrite_preserves_existing_backend_as_initial_upstream(self):
        source = '''server {
    location ^~ /plugins/ {
        proxy_pass http://192.0.2.217:13082;
    }
    location /internal {
        proxy_pass http://127.0.0.1:9091;
    }
    location / {
        proxy_pass http://192.0.2.217:13082;
    }
}
'''
        self.assertEqual(extract_existing_target(source), '192.0.2.217:13082')
        updated, upstream, target = render_changes(source, '/etc/nginx/snippets/dsh-token-registry.location.conf')
        self.assertEqual(target, '192.0.2.217:13082')
        self.assertEqual(updated.count('proxy_pass http://dsh_container_backend;'), 2)
        self.assertIn('include /etc/nginx/snippets/dsh-token-registry.location.conf;', updated)
        self.assertIn('server 192.0.2.217:13082;', upstream)

    def test_apply_failure_returns_generic_error(self):
        status, body = process_registration(
            json.dumps(self.registration).encode('utf-8'),
            '192.0.2.217',
            'Bearer ' + self.secret,
            self.secret,
            '192.0.2.217',
            13082,
            lambda _value: False,
        )
        self.assertEqual(status, 502)
        self.assertNotIn(self.registration['token'], body.decode('utf-8'))

    def test_upstream_and_record_rendering(self):
        valid = validate_registration(self.registration, '192.0.2.217', 13082)
        self.assertEqual(
            render_upstream(valid),
            'upstream dsh_container_backend {\n    server 192.0.2.217:13082;\n}\n',
        )
        ipv6 = validate_registration({
            'ip': '2001:db8::217',
            'web_port': 3080,
            'token': 't' * 48,
        })
        self.assertIn('server [2001:db8::217]:3080;', render_upstream(ipv6))
        with self.assertRaises(ValueError):
            validate_registration(self.registration, '192.0.2.217', 13083)
        record = json.loads(render_record(valid, '2026-01-01T00:00:00+00:00'))
        self.assertEqual(record['ip'], '192.0.2.217')
        self.assertEqual(record['web_port'], 13082)
        self.assertEqual(record['token'], self.registration['token'])


if __name__ == '__main__':
    unittest.main()
