import { spawn, spawnSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { createProxyRegistrationPublisher } from './proxy-token-registration.mjs'

const args = process.argv.slice(2)
const registerUrl = process.env.DSH_TOKEN_REGISTER_URL ?? ''
const proxyRegistrationPublisher = createProxyRegistrationPublisher(process.env)
if (registerUrl && proxyRegistrationPublisher) {
  throw new Error('Configure either DSH_TOKEN_REGISTER_URL or DSH_PROXY_REGISTRATION_URL, not both.')
}
const passwordAuth = process.env.SSH_PASSWORD_AUTH === 'yes'
const sshPortText = process.env.DSH_SSH_PORT ?? '22'
if (!/^[1-9][0-9]{0,4}$/.test(sshPortText) || Number(sshPortText) > 65535) {
  throw new Error('Invalid SSH_PORT passed to the web runner.')
}
const childEnv = { ...process.env }
delete childEnv.DSH_TOKEN_REGISTER_URL
delete childEnv.DSH_PROXY_REGISTRATION_URL
delete childEnv.DSH_PROXY_REGISTRATION_SECRET_FILE
delete childEnv.DSH_PROXY_UPSTREAM_IP
delete childEnv.DSH_WEB_HOST_PORT
delete childEnv.SSH_PASSWORD
delete childEnv.SSH_PASSWORD_AUTH
delete childEnv.SSH_USERNAME
delete childEnv.SSH_PORT
delete childEnv.DSH_SSH_PORT
delete childEnv.DSH_RUN_UID

const dshRunUid = Number.parseInt(process.env.DSH_RUN_UID ?? '', 10)
if (process.env.DSH_RUN_UID !== undefined && (!/^[0-9]+$/.test(process.env.DSH_RUN_UID) || dshRunUid > 4294967294)) {
  throw new Error('Invalid DSH_RUN_UID passed to the web runner.')
}
const dshRunOptions = dshRunUid > 0 ? { uid: dshRunUid } : {}

const sshdOptions = [
  '-o', 'AuthorizedKeysFile=/run/sshd/authorized_keys',
  '-o', `Port=${sshPortText}`,
  '-o', 'AllowUsers=root',
  '-o', `PasswordAuthentication=${passwordAuth ? 'yes' : 'no'}`,
  '-o', `PermitRootLogin=${passwordAuth ? 'yes' : 'prohibit-password'}`,
  '-o', 'KbdInteractiveAuthentication=no',
  '-o', 'PermitEmptyPasswords=no',
  '-o', 'PubkeyAuthentication=yes',
  '-o', 'UsePAM=yes',
]
const children = []
const registrationAbortController = new AbortController()
let lastToken = ''
let stopping = false
let shutdownSignal = 'SIGTERM'
let runnerExitCode = 0
let shutdownPromise
let resolveShutdownRequested
const shutdownRequested = new Promise(resolve => {
  resolveShutdownRequested = resolve
})

function writeDiagnostic(message) {
  process.stderr.write(`${message}\n`)
}

function signalProcessTree(state, signal) {
  if (state.closed || !state.child?.pid) return
  let sent = false
  try {
    process.kill(-state.child.pid, signal)
    sent = true
  } catch (error) {
    if (error.code !== 'ESRCH') {
      writeDiagnostic(`Unable to signal ${state.name} process group: ${error.message}`)
    }
  }
  if (!sent && !state.closed) {
    try {
      state.child.kill(signal)
    } catch (error) {
      if (error.code !== 'ESRCH') {
        writeDiagnostic(`Unable to signal ${state.name} process: ${error.message}`)
      }
    }
  }
}

async function waitForChildren(states, timeoutMs) {
  if (states.every(state => state.closed)) return true
  let timer
  const timeout = new Promise(resolve => {
    timer = setTimeout(() => resolve(false), timeoutMs)
    timer.unref()
  })
  const closed = Promise.all(states.map(state => state.closedPromise)).then(() => true)
  const result = await Promise.race([closed, timeout])
  clearTimeout(timer)
  return result
}

async function stopManagedChildren(signal) {
  let active = children.filter(state => !state.closed)
  for (const state of active) signalProcessTree(state, signal)
  if (await waitForChildren(active, 5000)) return

  active = children.filter(state => !state.closed)
  if (active.length === 0) return
  writeDiagnostic('Graceful shutdown timed out; sending SIGKILL to remaining SSH/DSH process groups.')
  for (const state of active) signalProcessTree(state, 'SIGKILL')
  if (await waitForChildren(active, 1500)) return

  runnerExitCode ||= 1
  process.stderr.write('Child processes remained after SIGKILL; exiting the container init process.\n', () => {
    process.exit(runnerExitCode)
  })
}

function requestShutdown(code, signal = 'SIGTERM') {
  if (code !== 0 && runnerExitCode === 0) runnerExitCode = code ?? 1
  if (stopping) return shutdownPromise

  stopping = true
  shutdownSignal = signal
  registrationAbortController.abort()
  shutdownPromise = stopManagedChildren(signal).finally(() => {
    process.exitCode = runnerExitCode
  })
  resolveShutdownRequested()
  return shutdownPromise
}

function spawnManaged(name, command, childArgs, stdio, spawnOptions = {}) {
  let resolveStarted
  let resolveClosed
  let startSettled = false
  const state = {
    name,
    child: null,
    closed: false,
    started: new Promise(resolve => {
      resolveStarted = resolve
    }),
    closedPromise: new Promise(resolve => {
      resolveClosed = resolve
    }),
  }
  const settleStarted = result => {
    if (startSettled) return
    startSettled = true
    resolveStarted(result)
  }

  try {
    state.child = spawn(command, childArgs, {
      env: childEnv,
      stdio,
      detached: true,
      ...spawnOptions,
    })
  } catch (error) {
    state.closed = true
    settleStarted(false)
    resolveClosed()
    children.push(state)
    writeDiagnostic(`Unable to start ${name}: ${error.message}`)
    requestShutdown(1)
    return state
  }

  children.push(state)
  state.child.once('spawn', () => {
    settleStarted(true)
    if (stopping) signalProcessTree(state, shutdownSignal)
  })
  state.child.on('error', error => {
    writeDiagnostic(`Unable to start or control ${name}: ${error.message}`)
    settleStarted(false)
    requestShutdown(1)
  })
  state.child.once('close', (code, signal) => {
    state.closed = true
    settleStarted(false)
    resolveClosed()
    if (!stopping) {
      const status = name === 'DSH Web' ? (code ?? 1) : 1
      const result = signal ? `signal ${signal}` : `exit code ${code}`
      writeDiagnostic(`${name} exited (${result}); stopping the other service.`)
      requestShutdown(status)
    }
  })
  return state
}

function validateSshdConfig() {
  const result = spawnSync('/usr/sbin/sshd', ['-t', ...sshdOptions], {
    env: childEnv,
    encoding: 'utf8',
    timeout: 5000,
  })
  if (result.error) {
    throw new Error(`sshd configuration validation could not run: ${result.error.message}`)
  }
  if (result.status !== 0) {
    const detail = String(result.stderr ?? '').trim()
    throw new Error(`sshd -t exited with status ${result.status ?? 'unknown'}${detail ? `: ${detail}` : ''}`)
  }
}

function waitForRegistrationRetry(delayMs) {
  const signal = registrationAbortController.signal
  if (signal.aborted) return Promise.resolve(false)
  return new Promise(resolve => {
    let settled = false
    const finish = result => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal.removeEventListener('abort', onAbort)
      resolve(result)
    }
    const timer = setTimeout(() => finish(true), delayMs)
    timer.unref()
    const onAbort = () => finish(false)
    signal.addEventListener('abort', onAbort, { once: true })
    if (signal.aborted) onAbort()
  })
}

function registerToken(token) {
  if ((!registerUrl && !proxyRegistrationPublisher) || stopping) return Promise.resolve()
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    writeDiagnostic('DSH token registration skipped because token format was invalid.')
    return Promise.resolve()
  }

  let retryDelayMs = 500
  return (async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        const signal = AbortSignal.any([
          registrationAbortController.signal,
          AbortSignal.timeout(8000),
        ])
        if (proxyRegistrationPublisher) {
          await proxyRegistrationPublisher(token, signal)
        } else {
          const response = await fetch(registerUrl, {
            method: 'POST',
            headers: { 'content-type': 'text/plain' },
            body: token,
            signal,
          })
          if (!response.ok) throw new Error('Proxy registration endpoint rejected the token.')
        }
        writeDiagnostic('DSH launch token registered with the proxy.')
        return
      } catch {
        if (registrationAbortController.signal.aborted) return
      }
      if (attempt < 4) {
        const shouldRetry = await waitForRegistrationRetry(retryDelayMs)
        if (!shouldRetry) return
        retryDelayMs = Math.min(retryDelayMs * 2, 4000)
      }
    }
    if (!stopping) writeDiagnostic('DSH launch-token registration failed; the proxy needs a retry.')
  })()
}

function forwardLines(stream, destination) {
  const lines = createInterface({ input: stream, crlfDelay: Infinity })
  lines.on('line', line => {
    let output = line
    const match = line.match(/\bdsh web:\s+(https?:\/\/\S+)/)
    if (match) {
      try {
        const launchUrl = new URL(match[1])
        const token = launchUrl.searchParams.get('token')
        if (token && token !== lastToken) {
          lastToken = token
          void registerToken(token)
        }
        launchUrl.searchParams.delete('token')
        output = line.replace(match[1], launchUrl.toString())
      } catch {}
    }
    destination.write(`${output}\n`)
  })
}

async function run() {
  process.on('SIGTERM', () => {
    writeDiagnostic('dsh-web-runner: graceful shutdown requested by SIGTERM')
    requestShutdown(0, 'SIGTERM')
  })
  process.on('SIGINT', () => {
    writeDiagnostic('dsh-web-runner: graceful shutdown requested by SIGINT')
    requestShutdown(0, 'SIGINT')
  })

  try {
    validateSshdConfig()
  } catch (error) {
    writeDiagnostic(`sshd startup validation failed: ${error.message}`)
    requestShutdown(1)
  }

  if (!stopping) {
    // sshd only accepts root: it reads root-owned system configuration and host
    // keys, and refuses to start as the DSH run user. Pin it to uid 0 so DSH can
    // drop to another account while the SSH service keeps working.
    const sshd = spawnManaged('sshd', '/usr/sbin/sshd', ['-D', '-e', ...sshdOptions], ['ignore', 'pipe', 'pipe'], dshRunUid === 0 ? {} : { uid: 0, gid: 0 })
    if (sshd.child) {
      forwardLines(sshd.child.stdout, process.stderr)
      forwardLines(sshd.child.stderr, process.stderr)
    }
    const sshdStarted = await sshd.started
    if (!sshdStarted || stopping || sshd.closed) {
      if (!stopping) requestShutdown(1)
    } else {
      const dsh = spawnManaged('DSH Web', 'dsh', args, ['inherit', 'pipe', 'pipe'], dshRunOptions)
      if (dsh.child) {
        forwardLines(dsh.child.stdout, process.stdout)
        forwardLines(dsh.child.stderr, process.stderr)
      }
      const dshStarted = await dsh.started
      if (!dshStarted && !stopping) requestShutdown(1)
    }
  }

  await shutdownRequested
  await shutdownPromise
}

void run().catch(error => {
  writeDiagnostic(`Runner failed: ${error.message}`)
  requestShutdown(1)
})
