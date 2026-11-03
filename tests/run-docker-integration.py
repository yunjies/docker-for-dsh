import os
import re
import secrets
import subprocess
import uuid
from pathlib import Path

session_id = os.environ.get('DSH_SESSION_ID') or 'session-{}'.format(uuid.uuid4())
if not re.fullmatch(r'session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', session_id):
    raise SystemExit('DSH_SESSION_ID must be a session UUID.')

project_root = Path.cwd().resolve()
workspace_root = (project_root / '../../..').resolve()
env = os.environ.copy()
env['DSH_SESSION_ID'] = session_id
env.setdefault('DSH_TEST_SESSION_DIR', str(workspace_root / '.sessions' / session_id))
env.setdefault('DSH_TEST_IMAGE', 'docker-for-dsh-test:{}-{}'.format(session_id, secrets.token_hex(4)))
env.setdefault('DSH_TEST_SSH_PORT', '2222')
env.setdefault('DSH_TEST_CONTAINER_SSH_PORT', '2223')

result = subprocess.run(['/bin/sh', 'tests/docker-integration.sh'], cwd=str(project_root), env=env)
raise SystemExit(result.returncode)
