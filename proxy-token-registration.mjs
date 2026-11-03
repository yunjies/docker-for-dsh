import { readFileSync } from 'node:fs'
import { isIP } from 'node:net'
import { isAbsolute } from 'node:path'

const tokenPattern = /^[A-Za-z0-9_-]{32,128}$/

function parsePort(value, name) {
  if (!/^[1-9][0-9]{0,4}$/.test(value) || Number(value) > 65535) {
    throw new Error(`Invalid ${name} passed to the proxy registrar.`)
  }
  return Number(value)
}

export function createProxyRegistrationPublisher(
  env = process.env,
  fetchImpl = globalThis.fetch,
  readSecret = readFileSync,
) {
  const urlText = env.DSH_PROXY_REGISTRATION_URL ?? ''
  if (!urlText) return null

  let registrationUrl
  try {
    registrationUrl = new URL(urlText)
  } catch {
    throw new Error('Invalid DSH_PROXY_REGISTRATION_URL.')
  }
  if (registrationUrl.protocol !== 'https:' || registrationUrl.username || registrationUrl.password || registrationUrl.search) {
    throw new Error('DSH_PROXY_REGISTRATION_URL must be an HTTPS URL without credentials or query parameters.')
  }

  const secretFile = env.DSH_PROXY_REGISTRATION_SECRET_FILE ?? ''
  if (!isAbsolute(secretFile)) {
    throw new Error('DSH_PROXY_REGISTRATION_SECRET_FILE must be an absolute path.')
  }
  let secret
  try {
    secret = String(readSecret(secretFile, 'utf8')).trim()
  } catch {
    throw new Error('Could not read the proxy registration secret file.')
  }
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(secret)) {
    throw new Error('The proxy registration secret file has an invalid format.')
  }

  const ip = env.DSH_PROXY_UPSTREAM_IP ?? ''
  if (isIP(ip) === 0) {
    throw new Error('DSH_PROXY_UPSTREAM_IP must be an IP address reachable by the proxy.')
  }
  const webPort = parsePort(env.DSH_WEB_HOST_PORT ?? '', 'DSH_WEB_HOST_PORT')

  return async (token, signal) => {
    if (!tokenPattern.test(token)) {
      throw new Error('Invalid DSH launch token.')
    }
    const response = await fetchImpl(registrationUrl, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${secret}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ ip, web_port: webPort, token }),
      signal,
    })
    if (!response.ok) {
      throw new Error('Proxy registration endpoint rejected the token.')
    }
  }
}
