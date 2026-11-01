import test from 'node:test'
import assert from 'node:assert/strict'
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { basename, delimiter, dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const bootstrap = readFileSync(resolve(root, 'bootstrap.sh'), 'utf8')
const runner = readFileSync(resolve(root, 'dsh-web-runner.mjs'), 'utf8')
const dockerfile = readFileSync(resolve(root, 'Dockerfile'), 'utf8')
const integration = readFileSync(resolve(root, 'tests/docker-integration.sh'), 'utf8')
const keyringSecretCheck = readFileSync(resolve(root, 'keyring-file-check.mjs'), 'utf8')
const keyringSession = readFileSync(resolve(root, 'dsh-keyring-session.sh'), 'utf8')
const keyringChild = readFileSync(resolve(root, 'dsh-keyring-child.sh'), 'utf8')
const unraidTemplate = readFileSync(resolve(root, 'unraid/dsh.xml'), 'utf8')

function currentSessionDirectory() {
  const id = process.env.DSH_SESSION_ID ?? ''
  assert.match(id, /^session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  const sessionDir = resolve(process.env.DSH_TEST_SESSION_DIR ?? resolve(root, '.sessions', id))
  const sessionsRoot = dirname(sessionDir)
  assert.equal(basename(sessionDir), id)
  assert.equal(basename(sessionsRoot), '.sessions')
  const projectRoot = realpathSync(root)
  const workspaceRoot = dirname(sessionsRoot)
  assert.equal(realpathSync(workspaceRoot), workspaceRoot)
  assert.ok(projectRoot === workspaceRoot || projectRoot.startsWith(`${workspaceRoot}/`))
  if (!existsSync(sessionsRoot)) mkdirSync(sessionsRoot, { mode: 0o700 })
  assert.equal(lstatSync(sessionsRoot).isSymbolicLink(), false)
  assert.equal(realpathSync(sessionsRoot), sessionsRoot)
  if (!existsSync(sessionDir)) mkdirSync(sessionDir, { mode: 0o700 })
  assert.equal(lstatSync(sessionDir).isSymbolicLink(), false)
  assert.equal(realpathSync(sessionDir), sessionDir)
  return sessionDir
}

function has(source, expression, message) {
  assert.match(source, expression, message)
}

// Each predicate is also exercised against a deliberately broken sample so a
// vacuous/pass-only assertion cannot silently become the test's sole evidence.
function rejectsMutation(predicate, healthy, broken, label) {
  assert.equal(predicate(healthy), true, `${label}: healthy fixture`)
  assert.equal(predicate(broken), false, `${label}: defective fixture`)
}

test('OpenSSH is installed at runtime, not baked into the image', () => {
  const runtimeInstall = source => {
    const check = source.indexOf('if ! command -v ssh')
    const needFlag = source.indexOf('need_openssh_packages=yes', check)
    const update = source.indexOf('apt-get update', needFlag)
    const packageList = source.indexOf('openssh-client openssh-server passwd', update)
    const install = source.indexOf('apt-get install -y --no-install-recommends $runtime_packages', packageList)
    const hostKeyGeneration = source.indexOf('ssh-keygen -A', install)
    return check >= 0 && needFlag > check && update > needFlag && packageList > update && install > packageList && hostKeyGeneration > install
  }
  assert.equal(runtimeInstall(bootstrap), true, 'missing SSH tools are installed before generating runtime host keys')
  rejectsMutation(runtimeInstall,
    'if ! command -v ssh; then need_openssh_packages=yes; fi\napt-get update\nruntime_packages="$runtime_packages openssh-client openssh-server passwd"\napt-get install -y --no-install-recommends $runtime_packages\nssh-keygen -A',
    'RUN apt-get install openssh-client openssh-server',
    'runtime-only SSH package install')
  assert.doesNotMatch(dockerfile, /openssh-client|openssh-server|ssh_host_/, 'image build must not install SSH or bake host keys')
  rejectsMutation(source => !/openssh-client|openssh-server/.test(source),
    'RUN apt-get install git', 'RUN apt-get install git openssh-server', 'no build-layer SSH packages')
  has(bootstrap, /if \[ ! -r \/data \] \|\| \[ ! -w \/data \][\s\S]*?\/data must be a readable and writable volume/, 'readable and writable volume gate')
  has(bootstrap, /ssh-keygen -A/, 'generate only missing host keys after runtime package install')
  rejectsMutation(s => /-w \/data/.test(s), 'test -w /data', 'test -d /data', 'writable gate')
})

test('SSH_PASSWORD and SSH_PORT are captured safely; SSH identity remains root', () => {
  has(bootstrap, /dsh_ssh_password_value=\$\{SSH_PASSWORD:-\}/)
  has(bootstrap, /dsh_ssh_port_value=\$\{SSH_PORT:-22\}/)
  has(bootstrap, /unset[^\n]*SSH_PASSWORD[^\n]*SSH_PORT/)
  assert.doesNotMatch(bootstrap, /dsh_ssh_username_value|useradd/)
  assert.doesNotMatch(bootstrap, /\$\{SSH_USERNAME/)
  has(runner, /AllowUsers=root/)
  assert.doesNotMatch(runner, /DSH_SSH_USERNAME|sshUsername/)
  has(bootstrap, /carriage_return=\$\(printf '\\r'\)/)
  has(bootstrap, /\*'\n'\*\|\*"\$carriage_return"\*/)
  has(bootstrap, /export SSH_PASSWORD_AUTH="\$ssh_password_auth"/)
  assert.doesNotMatch(bootstrap, /export\s+SSH_PASSWORD=/)
  const safePasswordFlow = source => {
    const copied = source.match(/^\s*dsh_ssh_password_value=\$\{SSH_PASSWORD:-\}\s*$/m)
    if (!copied) return false
    const unsetMatch = source.match(/^\s*unset[^\n]*SSH_PASSWORD[^\n]*$/m)
    if (!unsetMatch) return false
    const unsetAt = unsetMatch.index
    const aptAt = source.indexOf('apt-get update')
    const chpasswdAt = source.indexOf('| chpasswd')
    const stdinPattern = /printf 'root:%s\\n' "\$dsh_ssh_password_value" \| chpasswd/
    return unsetAt > copied.index && aptAt > unsetAt && chpasswdAt > unsetAt && stdinPattern.test(source)
  }
  assert.equal(safePasswordFlow(bootstrap), true, 'capture password, unset exported env before external commands, then send root password only on chpasswd stdin')
  rejectsMutation(s => safePasswordFlow(s),
    'dsh_ssh_password_value=${SSH_PASSWORD:-}\nunset SSH_PASSWORD SSH_PORT\napt-get update\nprintf \'root:%s\\n\' "$dsh_ssh_password_value" | chpasswd',
    'dsh_ssh_password_value=${SSH_PASSWORD:-}\napt-get update\nunset SSH_PASSWORD SSH_PORT\nprintf \'root:%s\\n\' "$dsh_ssh_password_value" | chpasswd',
    'unset before external children')
  rejectsMutation(s => /\*"\$carriage_return"\*/.test(s), 'case *"$carriage_return"*)', 'case *)', 'CR rejection')
  rejectsMutation(s => /printf 'root:%s\\n' "\$SSH_PASSWORD" \| chpasswd/.test(s),
    String.raw`printf 'root:%s\n' "$SSH_PASSWORD" | chpasswd`, 'chpasswd "$SSH_PASSWORD"', 'password not expanded from exported env')
})

test('sshd config is fixed to root and enforces safe auth policy', () => {
  has(runner, /spawnSync\('\/usr\/sbin\/sshd', \['-t', \.\.\.sshdOptions\]/)
  has(runner, /PasswordAuthentication=\$\{passwordAuth \? 'yes' : 'no'\}/)
  has(runner, /PermitRootLogin=\$\{passwordAuth \? 'yes' : 'prohibit-password'\}/)
  has(runner, /Port=\$\{sshPortText\}/)
  has(runner, /AllowUsers=root/)
  assert.doesNotMatch(runner, /DSH_SSH_USERNAME|sshUsername/)
  has(runner, /KbdInteractiveAuthentication=no/)
  has(runner, /AuthorizedKeysFile=\/run\/sshd\/authorized_keys/)
  const strictAuthorizedKeys = source => /install -d -m 0755 \/run\/sshd/.test(source)
    && /mkdir -p \/data\/\.ssh/.test(source)
    && /authorized_keys_source=\/data\/\.ssh\/authorized_keys/.test(source)
    && /install -o root -g root -m 0600 "\$authorized_keys_source" \/run\/sshd\/authorized_keys/.test(source)
  assert.equal(strictAuthorizedKeys(bootstrap), true)
  rejectsMutation(strictAuthorizedKeys,
    'install -d -m 0755 /run/sshd\nmkdir -p /data/.ssh\nauthorized_keys_source=/data/.ssh/authorized_keys\ninstall -o root -g root -m 0600 "$authorized_keys_source" /run/sshd/authorized_keys',
    'install -d -m 0755 /run/sshd\nmkdir -p /data/.ssh\nauthorized_keys_source=/data/.ssh/authorized_keys\ninstall -o root -g root -m 0644 "$authorized_keys_source" /run/sshd/authorized_keys',
    'StrictModes-compatible authorized_keys snapshot')
  has(dockerfile, /^USER root$/m)
  assert.doesNotMatch(bootstrap, /chmod\s+-R|chown\s+-R/)
  assert.doesNotMatch(bootstrap, /useradd|dsh_ssh_username_value/)
  has(runner, /UsePAM=yes/)
  has(runner, /PubkeyAuthentication=yes/)
  has(runner, /PermitEmptyPasswords=no/)
  has(runner, /sshd startup validation failed/)
  rejectsMutation(s => /PasswordAuthentication=\$\{passwordAuth \? 'yes' : 'no'\}/.test(s),
    "PasswordAuthentication=${passwordAuth ? 'yes' : 'no'}", "PasswordAuthentication=yes", 'password auth conditional')
  rejectsMutation(s => /PermitRootLogin=\$\{passwordAuth \? 'yes' : 'prohibit-password'\}/.test(s),
    "PermitRootLogin=${passwordAuth ? 'yes' : 'prohibit-password'}", 'PermitRootLogin=yes', 'root login policy')
  rejectsMutation(s => /AllowUsers=root/.test(s), 'AllowUsers=root', 'AllowUsers=${sshUsername}', 'root-only SSH account')
})

test('SSH_PORT is validated as canonical decimal and applied as the container listener port', () => {
  has(bootstrap, /dsh_ssh_port_value=\$\{SSH_PORT:-22\}/)
  has(bootstrap, /SSH_PORT must be a canonical decimal port without leading zeros from 1 to 65535/)
  assert.doesNotMatch(bootstrap, /useradd|dsh_ssh_username_value/)
  const rejectsLeadingZeros = source => /case "\$dsh_ssh_port_value" in[\s\S]*\|0\|0\*/.test(source)
  assert.equal(rejectsLeadingZeros(bootstrap), true, 'SSH_PORT rejects ambiguous leading-zero input')
  rejectsMutation(rejectsLeadingZeros,
    'case "$dsh_ssh_port_value" in\n  \'\'|*[!0-9]*|0|0*) exit 2;;\nesac',
    'case "$dsh_ssh_port_value" in\n  \'\'|*[!0-9]*|0) exit 2;;\nesac',
    'leading-zero port guard')
  const hasPortUpperBound = source => /\[ "\$dsh_ssh_port_value" -gt 65535 \]/.test(source)
  assert.equal(hasPortUpperBound(bootstrap), true)
  rejectsMutation(hasPortUpperBound,
    '[ "$dsh_ssh_port_value" -gt 65535 ]', '[ "$dsh_ssh_port_value" -gt 99999 ]', 'port upper bound')
  has(runner, /const sshPortText = process\.env\.DSH_SSH_PORT \?\? '22'/)
  has(runner, /Port=\$\{sshPortText\}/)
  const leadingZeroResult = spawnSync('/bin/sh', [resolve(root, 'bootstrap.sh')], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH ?? '', SSH_PORT: '022', SSH_PASSWORD: 'PORT_FIXTURE_SECRET' },
  })
  assert.equal(leadingZeroResult.error, undefined)
  assert.equal(leadingZeroResult.status, 2)
  assert.match(leadingZeroResult.stderr, /canonical decimal port without leading zeros/)
  assert.match(leadingZeroResult.stderr, /failed stage=bootstrap_init exit=2/)
  assert.doesNotMatch(`${leadingZeroResult.stdout}${leadingZeroResult.stderr}`, /PORT_FIXTURE_SECRET/)
})

test('E2E expects runtime SSH installation and keeps login fixed to root', () => {
  const preEntryPointAbsent = source => {
    const start = source.indexOf('docker run --rm --entrypoint /bin/sh "$DSH_TEST_IMAGE" -ec')
    const end = source.indexOf("\n'", start)
    const probe = source.slice(start, end < 0 ? source.length : end)
    const rejectsTool = tool => {
      const check = probe.indexOf(`if command -v ${tool} >/dev/null 2>&1; then`)
      const fail = probe.indexOf('exit 1', check)
      const close = probe.indexOf('fi', fail)
      return check >= 0 && fail > check && close > fail
    }
    const keyLoop = probe.indexOf('for host_key in /etc/ssh/ssh_host_*_key; do')
    const keyFail = probe.indexOf('exit 1', keyLoop)
    const keyLoopEnd = probe.indexOf('done', keyFail)
    return start >= 0 && rejectsTool('ssh') && rejectsTool('sshd')
      && keyLoop >= 0 && keyFail > keyLoop && keyLoopEnd > keyFail
  }
  assert.equal(preEntryPointAbsent(integration), true, 'pre-entrypoint image must contain no OpenSSH binary or host key')
  const healthyProbe = `docker run --rm --entrypoint /bin/sh "$DSH_TEST_IMAGE" -ec '\n  if command -v ssh >/dev/null 2>&1; then exit 1; fi\n  if command -v sshd >/dev/null 2>&1; then exit 1; fi\n  for host_key in /etc/ssh/ssh_host_*_key; do if [ -e "$host_key" ]; then exit 1; fi; done\n'\ncontainer_id=`
  const weakProbe = `docker run --rm --entrypoint /bin/sh "$DSH_TEST_IMAGE" -ec 'command -v ssh; command -v sshd'\ncontainer_id=`
  rejectsMutation(preEntryPointAbsent, healthyProbe, weakProbe, 'image pre-entrypoint absence probe')
  assert.ok(integration.includes('container_test_port=${DSH_TEST_CONTAINER_SSH_PORT:-2223}'))
  assert.ok(integration.includes('127.0.0.1:$host_port:$password_container_port'))
  assert.ok(integration.includes('set -- -e "SSH_PORT=$container_ssh_port" "$@"'))
  assert.ok(integration.includes('SSH_PASSWORD="$password" docker create'))
  assert.ok(integration.includes('-e SSH_PASSWORD'))
  assert.ok(integration.includes("grep -Eiq '^root@127\\.0\\.0\\.1: Permission denied"))
  assert.ok(integration.includes('docker exec "$container_id" id -u root'))
  assert.ok(integration.includes('create_and_start "$docker_name" no-password'))
  assert.ok(integration.includes('root@127.0.0.1'))
  rejectsMutation(s => !/DSH_BIND_HOST=0\.0\.0\.0/.test(s),
    'DSH_PUBLIC_URL=https://localhost -e DSH_TRUSTED_HOST=localhost',
    'DSH_BIND_HOST=0.0.0.0', 'avoid wildcard DSH listener')
  assert.doesNotMatch(integration, /SSH_USERNAME|password_username|useradd/)
  assert.doesNotMatch(integration, /-e SSH_PASSWORD="\$password"/)
})

test('optional keyring is secret-file gated and GH credentials prefer the container keyring', () => {
  assert.ok(bootstrap.includes('keyring_secret_file=/run/secrets/keyring-password'))
  assert.ok(bootstrap.includes('elif [ -d "$keyring_secret_file" ]; then'))
  assert.ok(bootstrap.includes('node /usr/local/bin/keyring-file-check.mjs "$keyring_secret_file"'))
  assert.ok(bootstrap.includes('export DSH_KEYRING_ENABLED="$dsh_keyring_enabled"'))
  assert.ok(bootstrap.includes('gh_cli_keyring_sha256=6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b'))
  assert.ok(bootstrap.includes('https://cli.github.com/packages stable main'))
  assert.ok(bootstrap.includes('Number(match[2]) >= 26'))
  assert.ok(keyringSecretCheck.includes('stat.uid !== expectedUid'))
  assert.ok(keyringSecretCheck.includes("fields[5].split(',').includes('ro')"))
  for (const tokenName of ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN']) {
    assert.ok(bootstrap.includes(tokenName))
    assert.ok(runner.includes(`delete childEnv.${tokenName}`))
  }
  assert.ok(dockerfile.includes('COPY keyring-file-check.mjs'))
  assert.ok(dockerfile.includes('COPY dsh-keyring-session.sh'))
  assert.ok(dockerfile.includes('COPY dsh-keyring-child.sh'))
  assert.ok(keyringSession.includes('dbus-run-session --'))
  assert.ok(runner.includes("const dshCommand = keyringEnabled ? '/usr/local/bin/dsh-keyring-session.sh' : 'dsh'"))
  assert.ok(runner.includes('const dshArgs = keyringEnabled ?'))
  assert.ok(keyringChild.includes('gnome-keyring-daemon --foreground --components=secrets --unlock'))
  assert.doesNotMatch(keyringChild, /awk[^\n]*\|[^\n]*gnome-keyring-daemon/)
  assert.ok(keyringChild.includes('wait_for_process_exit "$process_pid"'))
  assert.ok(keyringChild.includes('stop_managed_process "$keyring_pid"'))
  assert.ok(keyringChild.includes("trap 'handle_signal 143' TERM"))
  assert.match(keyringChild, /XDG_DATA_HOME=\$\{XDG_DATA_HOME:-\/data\/\.local\/share\}/)
  assert.ok(keyringChild.includes('secret-tool store'))
  assert.ok(keyringChild.includes('secret-tool lookup'))
  assert.ok(keyringChild.includes('secret-tool clear'))
  assert.ok(keyringChild.includes('keyring-secret-service-probe=passed'))
  assert.ok(keyringChild.includes('persist-store'))
  assert.ok(keyringChild.includes('persist-verify'))
  assert.ok(unraidTemplate.includes('Target="/run/secrets/keyring-password"'))
  assert.ok(unraidTemplate.includes('Default="/mnt/user/appdata/dsh-sec/keyring-password"'))
  assert.match(unraidTemplate, /Target="\/run\/secrets\/keyring-password"[^\n]*Mode="ro"/)
})

test('registration cancellation, spawn races, signal/timeout cleanup, and sibling stop are wired', () => {
  has(runner, /const registrationAbortController = new AbortController\(\)/)
  has(runner, /registrationAbortController\.abort\(\)/)
  has(runner, /signal: AbortSignal\.any\(\[\s*registrationAbortController\.signal/)
  has(runner, /state\.child\.once\('spawn'/)
  has(runner, /state\.child\.on\('error'/)
  has(runner, /state\.child\.once\('close'/)
  has(runner, /settleStarted\(false\)/)
  has(runner, /if \(stopping\) signalProcessTree\(state, shutdownSignal\)/)
  has(runner, /process\.on\('SIGTERM'/)
  has(runner, /process\.on\('SIGINT'/)
  has(runner, /process\.kill\(-state\.child\.pid, signal\)/)
  has(runner, /await waitForChildren\(active, 5000\)/)
  has(runner, /signalProcessTree\(state, 'SIGKILL'\)/)
  has(runner, /await waitForChildren\(active, 1500\)/)
  has(runner, /exited \(\$\{result\}\); stopping the other service/)
  has(runner, /requestShutdown\(status\)/)
  rejectsMutation(s => /registrationAbortController\.abort\(\)/.test(s),
    'registrationAbortController.abort()', '/* no abort */', 'registration cancel')
  rejectsMutation(s => /process\.kill\(-state\.child\.pid, signal\)/.test(s),
    'process.kill(-state.child.pid, signal)', 'child.kill(signal)', 'process group signal')
  rejectsMutation(s => /signalProcessTree\(state, 'SIGKILL'\)/.test(s),
    "signalProcessTree(state, 'SIGKILL')", '/* no escalation */', 'SIGKILL escalation')
  rejectsMutation(s => /stopping the other service/.test(s),
    'exited; stopping the other service', 'exited', 'sibling shutdown')
})

function integrationPathGuard(source) {
  const idCheck = source.indexOf('case "$DSH_SESSION_ID" in')
  const invalidId = source.indexOf('Invalid DSH_SESSION_ID')
  const firstMkdir = source.indexOf('mkdir')
  const rootContainment = source.indexOf('Refusing a .sessions root outside the project workspace ancestry.')
  const sessionContainment = source.indexOf('Session directory escapes .sessions.')
  const workContainment = source.indexOf('Integration directory escapes the current session.')
  const testFiles = source.indexOf('mkdir -p "$work_dir/data/.ssh"')
  const prerequisiteCheck = source.indexOf('for command in docker')
  return idCheck >= 0 && invalidId > idCheck && firstMkdir > invalidId
    && rootContainment > invalidId && rootContainment < firstMkdir
    && sessionContainment > invalidId && sessionContainment < testFiles
    && workContainment > invalidId && workContainment < testFiles
    && testFiles > workContainment && prerequisiteCheck > invalidId
    && /session-\?{8}-\?{4}-\?{4}-\?{4}-\?{12}/.test(source)
    && /sessions_real[\s\S]*?sessions_parent/.test(source)
    && /session_real[\s\S]*?sessions_real/.test(source)
    && /work_real[\s\S]*?session_real/.test(source)
}

test('integration paths require a UUID and physical containment before tools or writes', () => {
  assert.equal(integrationPathGuard(integration), true)
  const validPathFixture = 'case "$DSH_SESSION_ID" in\nsession-????????-????-????-????-????????????) ;;\n*) Invalid DSH_SESSION_ID;;\nesac\nsessions_parent=$(pwd -P)\nsessions_real=$(cd -P .sessions && pwd -P)\ncase "$repo_dir/" in "$sessions_parent/"*) ;;\n*) Refusing a .sessions root outside the project workspace ancestry.;;\nesac\nmkdir -m 700 "$sessions_root"\nsession_real=$(cd -P .sessions/id && pwd -P)\n[ "$session_real" = "$sessions_real/$DSH_SESSION_ID" ]\nSession directory escapes .sessions.\nwork_real=$(cd -P .sessions/id/docker-integration && pwd -P)\n[ "$work_real" = "$session_real/docker-integration" ]\nIntegration directory escapes the current session.\nmkdir -p "$work_dir/data/.ssh"\nfor command in docker ssh; do'
  const latePathFixture = 'mkdir -m 700 "$sessions_root"\ncase "$DSH_SESSION_ID" in\nsession-????????-????-????-????-????????????) ;;\n*) Invalid DSH_SESSION_ID;;\nesac\nsessions_parent=$(pwd -P)\nsessions_real=$(cd -P .sessions && pwd -P)\ncase "$repo_dir/" in "$sessions_parent/"*) ;;\n*) Refusing a .sessions root outside the project workspace ancestry.;;\nesac\nsession_real=$(cd -P .sessions/id && pwd -P)\n[ "$session_real" = "$sessions_real/$DSH_SESSION_ID" ]\nSession directory escapes .sessions.\nwork_real=$(cd -P .sessions/id/docker-integration && pwd -P)\n[ "$work_real" = "$session_real/docker-integration" ]\nIntegration directory escapes the current session.\nmkdir -p "$work_dir/data/.ssh"\nfor command in docker ssh; do'
  rejectsMutation(integrationPathGuard, validPathFixture, latePathFixture, 'path validation before writes')
  has(integration, /if \[ -L "\$sessions_root" \]/)
  has(integration, /if \[ -L "\$session_dir" \]/)
  has(integration, /if \[ -L "\$work_dir" \]/)
  has(integration, /SSH_ASKPASS_REQUIRE=force/)
  has(integration, /-e SSH_PASSWORD(?:\s|\\\\)/)
  has(integration, /StrictHostKeyChecking=yes/)
  has(integration, /report_sanitized_logs/)
  assert.doesNotMatch(integration, /sshpass|StrictHostKeyChecking=no/)
  assert.doesNotMatch(integration, /-e SSH_PASSWORD="\$password"/)
})

test('malformed session ID fails before prerequisites or any file-writing command', () => {
  const sessionDir = currentSessionDirectory()
  const scratch = mkdtempSync(resolve(sessionDir, 'integration-path-guard-'))
  const physicalScratch = realpathSync(scratch)
  assert.ok(physicalScratch.startsWith(`${sessionDir}/`))
  const fakeBin = resolve(scratch, 'bin')
  mkdirSync(fakeBin, { mode: 0o700 })
  const marker = resolve(scratch, 'unexpected-command')
  for (const command of ['mkdir', 'docker', 'ssh', 'ssh-keygen', 'cp', 'chmod', 'touch', 'install', 'rm', 'cat', 'sleep', 'sshpass']) {
    const shim = resolve(fakeBin, command)
    writeFileSync(shim, '#!/bin/sh\nprintf \'invoked\\n\' >> "$PATH_PROBE"\nexit 97\n')
    chmodSync(shim, 0o700)
  }
  const invalidId = `../../ssh-path-escape-${process.pid}`
  const result = spawnSync('/bin/sh', [resolve(root, 'tests/docker-integration.sh')], {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      DSH_SESSION_ID: invalidId,
      DSH_TEST_SESSION_DIR: `${dirname(sessionDir)}/${invalidId}`,
      PATH_PROBE: marker,
      PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ''}`,
    },
  })
  try {
    assert.equal(result.error, undefined)
    assert.equal(result.status, 2)
    assert.match(result.stderr, /Invalid DSH_SESSION_ID/)
    assert.doesNotMatch(result.stderr, /Required command missing/)
    assert.equal(existsSync(marker), false, 'no prerequisite or write command ran')

    const escapedWorkspace = resolve(scratch, 'escaped-workspace')
    mkdirSync(escapedWorkspace, { mode: 0o700 })
    const escapedSessionDir = resolve(escapedWorkspace, '.sessions', process.env.DSH_SESSION_ID)
    const escapedRootResult = spawnSync('/bin/sh', [resolve(root, 'tests/docker-integration.sh')], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env,
        DSH_SESSION_ID: process.env.DSH_SESSION_ID,
        DSH_TEST_SESSION_DIR: escapedSessionDir,
        PATH_PROBE: marker,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ''}`,
      },
    })
    assert.equal(escapedRootResult.error, undefined)
    assert.equal(escapedRootResult.status, 2)
    assert.match(escapedRootResult.stderr, /outside the project workspace ancestry/)
    assert.equal(existsSync(marker), false, 'rejected external .sessions root is not created')
  } finally {
    assert.equal(realpathSync(scratch), physicalScratch)
    assert.ok(physicalScratch.startsWith(`${sessionDir}/`))
    rmSync(scratch, { recursive: true, force: true })
  }
})
