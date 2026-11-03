import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { resolve } from 'node:path'

const sessionId = process.env.DSH_SESSION_ID ?? `session-${randomUUID()}`
assert.match(sessionId, /^session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
const workspaceRoot = realpathSync(resolve(process.cwd(), '../../..'))
const sessionDir = resolve(process.env.DSH_TEST_SESSION_DIR ?? resolve(workspaceRoot, '.sessions', sessionId))
const env = {
  ...process.env,
  DSH_SESSION_ID: sessionId,
  DSH_TEST_SESSION_DIR: sessionDir,
  PYTHONDONTWRITEBYTECODE: '1',
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: process.cwd(), env, stdio: 'inherit' })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
}

run('sh', ['-n', 'bootstrap.sh'])
run('sh', ['-n', 'tests/docker-integration.sh'])
run('sh', ['-n', 'proxy-registry/install-proxy.sh'])
run('node', ['--check', 'dsh-web-runner.mjs'])
run('node', ['--check', 'proxy-token-registration.mjs'])
run('node', ['--test', 'tests/ssh-contract.test.mjs', 'tests/proxy-token-registration.test.mjs'])
run('python3', ['-c', 'import ast, pathlib; [ast.parse(path.read_text()) for path in map(pathlib.Path, ["proxy-registry/server.py", "proxy-registry/apply_registration.py", "proxy-registry/configure_nginx.py", "proxy-registry/tests/test_proxy_registry.py", "tests/run-docker-integration.py", "tests/run-compose-config.py"])]'])
run('python3', ['-c', 'import xml.etree.ElementTree as ET; ET.parse("unraid/dsh.xml")'])
