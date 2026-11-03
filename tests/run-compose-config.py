import subprocess
from pathlib import Path

project_root = Path.cwd().resolve()
result = subprocess.run(
    [
        'docker',
        'compose',
        '--env-file',
        'tests/fixtures/compose.env',
        '-f',
        'docker-compose.yml',
        'config',
        '--quiet',
    ],
    cwd=str(project_root),
)
raise SystemExit(result.returncode)
