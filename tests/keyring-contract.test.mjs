import test from 'node:test'
import assert from 'node:assert/strict'
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { delimiter, dirname, resolve } from 'node:path'
import { validateKeyringSecretFile } from '../keyring-file-check.mjs'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function currentSessionDirectory() {
  const id = process.env.DSH_SESSION_ID ?? ''
  assert.match(id, /^session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  const sessionDirectory = resolve(process.env.DSH_TEST_SESSION_DIR ?? resolve(projectRoot, '.sessions', id))
  const sessionsRoot = dirname(sessionDirectory)
  assert.equal(sessionsRoot.split('/').at(-1), '.sessions')
  assert.equal(sessionDirectory.split('/').at(-1), id)
  const workspaceRoot = dirname(sessionsRoot)
  assert.equal(realpathSync(workspaceRoot), workspaceRoot)
  assert.ok(projectRoot === workspaceRoot || projectRoot.startsWith(`${workspaceRoot}/`))
  if (!existsSync(sessionsRoot)) mkdirSync(sessionsRoot, { mode: 0o700 })
  assert.equal(lstatSync(sessionsRoot).isSymbolicLink(), false)
  assert.equal(realpathSync(sessionsRoot), sessionsRoot)
  if (!existsSync(sessionDirectory)) mkdirSync(sessionDirectory, { mode: 0o700 })
  assert.equal(lstatSync(sessionDirectory).isSymbolicLink(), false)
  assert.equal(realpathSync(sessionDirectory), sessionDirectory)
  return sessionDirectory
}

function withKeyringFixture(callback) {
  const sessionDirectory = currentSessionDirectory()
  const fixtureDirectory = mkdtempSync(resolve(sessionDirectory, 'keyring-fixtures-'))
  const physicalFixtureDirectory = realpathSync(fixtureDirectory)
  assert.ok(physicalFixtureDirectory.startsWith(`${sessionDirectory}/`))
  const cleanup = () => {
    assert.equal(realpathSync(fixtureDirectory), physicalFixtureDirectory)
    assert.ok(physicalFixtureDirectory.startsWith(`${sessionDirectory}/`))
    rmSync(physicalFixtureDirectory, { recursive: true, force: true })
  }
  try {
    const result = callback(fixtureDirectory)
    if (result && typeof result.then === 'function') return result.finally(cleanup)
    cleanup()
    return result
  } catch (error) {
    cleanup()
    throw error
  }
}

function writeMountInfo(path, options = 'ro,relatime') {
  const mountInfoPath = `${path}.mountinfo`
  writeFileSync(mountInfoPath, `31 23 0:28 / ${path} ${options} - tmpfs keyring rw\n`, { mode: 0o600 })
  return mountInfoPath
}

test('missing keyring file and Docker-created directory disable optional keyring', () => {
  withKeyringFixture(directory => {
    const missing = resolve(directory, 'missing-keyring-file')
    const hostDirectory = resolve(directory, 'auto-created-host-directory')
    mkdirSync(hostDirectory, { mode: 0o700 })
    const mountInfoPath = resolve(directory, 'mountinfo')
    writeFileSync(mountInfoPath, '', { mode: 0o600 })
    assert.equal(validateKeyringSecretFile(missing, mountInfoPath), 'absent')
    assert.equal(validateKeyringSecretFile(hostDirectory, mountInfoPath), 'absent')
  })
})

test('root-owned read-only one-line keyring file is accepted', () => {
  withKeyringFixture(directory => {
    const secretFile = resolve(directory, 'keyring-password')
    writeFileSync(secretFile, 'fixture-unlock-password\n', { mode: 0o600 })
    chmodSync(secretFile, 0o600)
    const mountInfoPath = writeMountInfo(secretFile)
    const expectedUid = process.getuid?.() ?? 0
    assert.equal(validateKeyringSecretFile(secretFile, mountInfoPath, expectedUid), 'valid')
    assert.equal(validateKeyringSecretFile(secretFile, mountInfoPath, 0), expectedUid === 0 ? 'valid' : 'invalid')
  })
})

test('keyring file rejects symlinks, unsafe modes, empty and multiline contents', () => {
  withKeyringFixture(directory => {
    const targetFile = resolve(directory, 'target')
    writeFileSync(targetFile, 'fixture-unlock-password', { mode: 0o600 })
    const symlinkFile = resolve(directory, 'symlink')
    symlinkSync(targetFile, symlinkFile)
    const noMountInfo = resolve(directory, 'no-mountinfo')
    writeFileSync(noMountInfo, '', { mode: 0o600 })
    assert.equal(validateKeyringSecretFile(symlinkFile, noMountInfo), 'invalid')

    const wideModeFile = resolve(directory, 'wide-mode')
    writeFileSync(wideModeFile, 'fixture-unlock-password', { mode: 0o644 })
    chmodSync(wideModeFile, 0o644)
    assert.equal(validateKeyringSecretFile(wideModeFile, writeMountInfo(wideModeFile)), 'invalid')

    const emptyFile = resolve(directory, 'empty')
    writeFileSync(emptyFile, '', { mode: 0o600 })
    assert.equal(validateKeyringSecretFile(emptyFile, writeMountInfo(emptyFile)), 'invalid')

    const multilineFile = resolve(directory, 'multiline')
    writeFileSync(multilineFile, 'first-line\nsecond-line', { mode: 0o600 })
    assert.equal(validateKeyringSecretFile(multilineFile, writeMountInfo(multilineFile)), 'invalid')
  })
})

test('keyring file requires a read-only mount and accepts one terminal newline', () => {
  withKeyringFixture(directory => {
    const secretFile = resolve(directory, 'keyring-password')
    writeFileSync(secretFile, 'fixture-unlock-password\n', { mode: 0o600 })
    chmodSync(secretFile, 0o600)
    assert.equal(validateKeyringSecretFile(secretFile, writeMountInfo(secretFile, 'rw,relatime')), 'invalid')
    assert.equal(validateKeyringSecretFile(secretFile, writeMountInfo(secretFile, 'ro,relatime'), process.getuid?.() ?? 0), 'valid')
  })
})

function writeKeyringRuntimeStubs(directory) {
  const bin = resolve(directory, 'bin')
  mkdirSync(bin, { mode: 0o700 })
  const secretFile = resolve(directory, 'keyring-password')
  const logFile = resolve(directory, 'keyring.log')
  const storeFile = resolve(directory, 'keyring-item')
  const runtimeDirectory = resolve(directory, 'runtime')
  const dataDirectory = resolve(directory, 'data')
  writeFileSync(secretFile, 'fixture-unlock-password\n', { mode: 0o600 })
  chmodSync(secretFile, 0o600)
  writeFileSync(resolve(bin, 'dbus-run-session'), '#!/bin/sh\n[ "$1" = "--" ] || exit 91\nshift\nDBUS_SESSION_BUS_ADDRESS=unix:path=/run/fake-dbus-session\nexport DBUS_SESSION_BUS_ADDRESS\nexec "$@"\n', { mode: 0o700 })
  writeFileSync(resolve(bin, 'gnome-keyring-daemon'), `#!/bin/sh
set -eu
[ "$1" = "--foreground" ] && [ "$2" = "--components=secrets" ] && [ "$3" = "--unlock" ] || exit 91
printf '%s\\n' "$*" >> "$KEYRING_FIXTURE_LOG"
exec node -e '
const fs = require("node:fs")
let password = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", chunk => { password += chunk })
process.stdin.on("end", () => {
  if (password.replace(/\\r?\\n$/, "") !== "fixture-unlock-password") process.exit(92)
  fs.appendFileSync(process.env.KEYRING_FIXTURE_LOG, "gnome-keyring-unlock=passed\\n")
  const stop = signal => {
    fs.appendFileSync(process.env.KEYRING_FIXTURE_LOG, "gnome-keyring-stopped=" + signal + "\\n")
    process.exit(0)
  }
  process.on("SIGTERM", () => stop("term"))
  process.on("SIGINT", () => stop("int"))
  setInterval(() => {}, 1000)
})
'
`, { mode: 0o700 })
  writeFileSync(resolve(bin, 'secret-tool'), '#!/bin/sh\nmode=$1\nshift\ncase "$mode" in\n  store) cat > "$KEYRING_FIXTURE_STORE"; chmod 0600 "$KEYRING_FIXTURE_STORE" ;;\n  lookup) [ -f "$KEYRING_FIXTURE_STORE" ] || exit 1; cat "$KEYRING_FIXTURE_STORE" ;;\n  clear) rm -f -- "$KEYRING_FIXTURE_STORE" ;;\n  *) exit 2 ;;\nesac\n', { mode: 0o700 })
  return { bin, secretFile, logFile, storeFile, runtimeDirectory, dataDirectory }
}

async function waitForLogMarker(logFile, marker) {
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (existsSync(logFile) && readFileSync(logFile, 'utf8').includes(marker)) return
    await new Promise(resolvePromise => setTimeout(resolvePromise, 20))
  }
  assert.fail(`Timed out waiting for keyring fixture marker: ${marker}`)
}

function keyringFixtureEnvironment(stub, probeMode = 'yes') {
  return {
    ...process.env,
    DSH_KEYRING_PROBE: probeMode,
    KEYRING_FIXTURE_LOG: stub.logFile,
    KEYRING_FIXTURE_STORE: stub.storeFile,
    PATH: `${stub.bin}${delimiter}${process.env.PATH ?? ''}`,
    XDG_RUNTIME_DIR: stub.runtimeDirectory,
    XDG_DATA_HOME: stub.dataDirectory,
  }
}

test('keyring session streams unlock input and waits for the foreground daemon after DSH exits', () => {
  withKeyringFixture(directory => {
    const stub = writeKeyringRuntimeStubs(directory)
    const result = spawnSync('/bin/sh', [resolve(projectRoot, 'dsh-keyring-session.sh'), stub.secretFile, '/bin/sh', '-c', 'printf "%s\\n" "dsh-child=started"'], {
      cwd: projectRoot,
      encoding: 'utf8',
      timeout: 5000,
      env: keyringFixtureEnvironment(stub),
    })
    assert.equal(result.error, undefined)
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, 'dsh-child=started\n')
    assert.equal(result.stderr, 'keyring-secret-service-probe=passed\n')
    assert.match(readFileSync(stub.logFile, 'utf8'), /^--foreground --components=secrets --unlock\ngnome-keyring-unlock=passed\ngnome-keyring-stopped=term\n$/)
    assert.equal(existsSync(stub.storeFile), false)
    assert.doesNotMatch(`${result.stdout}${result.stderr}${readFileSync(stub.logFile, 'utf8')}`, /fixture-unlock-password|keyring-probe|probe_value/)
  })
})

test('SIGTERM waits for and reaps the foreground keyring process', () => withKeyringFixture(async directory => {
  const stub = writeKeyringRuntimeStubs(directory)
  const child = spawn('/bin/sh', [resolve(projectRoot, 'dsh-keyring-session.sh'), stub.secretFile, '/bin/sh', '-c', 'sleep 30'], {
    cwd: projectRoot,
    detached: true,
    stdio: ['ignore', 'ignore', 'pipe'],
    env: keyringFixtureEnvironment(stub),
  })
  let stderr = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', chunk => { stderr += chunk })
  const closed = new Promise(resolveClose => child.once('close', (code, signal) => resolveClose({ code, signal })))
  try {
    await waitForLogMarker(stub.logFile, 'gnome-keyring-unlock=passed')
    process.kill(-child.pid, 'SIGTERM')
    const result = await closed
    assert.ok(result.code === 143 || result.signal === 'SIGTERM')
    assert.match(readFileSync(stub.logFile, 'utf8'), /gnome-keyring-stopped=term\n/)
    assert.doesNotMatch(stderr, /sent SIGKILL/)
    assert.doesNotMatch(stderr, /fixture-unlock-password/)
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, 'SIGKILL') } catch {}
      await closed
    }
  }
}))
