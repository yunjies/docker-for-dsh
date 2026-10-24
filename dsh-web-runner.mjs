import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'

const args = process.argv.slice(2)
const registerUrl = process.env.DSH_TOKEN_REGISTER_URL ?? ''
const childEnv = { ...process.env }
delete childEnv.DSH_TOKEN_REGISTER_URL

const child = spawn('dsh', args, {
  env: childEnv,
  stdio: ['inherit', 'pipe', 'pipe'],
})

const pendingRegistrations = new Set()
let lastToken = ''

function registerToken(token) {
  if (!registerUrl) return Promise.resolve()
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    process.stderr.write('DSH token registration skipped because token format was invalid.\n')
    return Promise.resolve()
  }

  let retryDelayMs = 500
  const task = (async () => {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        const response = await fetch(registerUrl, {
          method: 'POST',
          headers: { 'content-type': 'text/plain' },
          body: token,
          signal: AbortSignal.timeout(8000),
        })
        if (response.ok) {
          process.stderr.write('DSH launch token registered with the proxy.\n')
          return
        }
      } catch {}
      if (attempt < 4) {
        await new Promise(resolve => setTimeout(resolve, retryDelayMs))
        retryDelayMs = Math.min(retryDelayMs * 2, 4000)
      }
    }
    process.stderr.write('DSH launch-token registration failed; the proxy needs a retry.\n')
  })().finally(() => pendingRegistrations.delete(task))
  pendingRegistrations.add(task)
  return task
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

forwardLines(child.stdout, process.stdout)
forwardLines(child.stderr, process.stderr)

process.on('SIGTERM', () => child.kill('SIGTERM'))
process.on('SIGINT', () => child.kill('SIGINT'))
child.on('error', error => {
  process.stderr.write(`Unable to start DSH Web process: ${error.name}\n`)
  process.exitCode = 1
})
child.on('close', async (code, signal) => {
  await Promise.allSettled([...pendingRegistrations])
  process.exitCode = code ?? (signal ? 1 : 0)
})
