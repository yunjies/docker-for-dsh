import assert from 'node:assert/strict'
import test from 'node:test'
import { createProxyRegistrationPublisher } from '../proxy-token-registration.mjs'

const secret = 's'.repeat(64)
const token = 't'.repeat(48)
const env = {
  DSH_PROXY_REGISTRATION_URL: 'https://proxy.example.invalid:13832/_internal/dsh/register',
  DSH_PROXY_REGISTRATION_SECRET_FILE: '/run/secrets/proxy_registry_secret',
  DSH_PROXY_UPSTREAM_IP: '192.0.2.217',
  DSH_WEB_HOST_PORT: '13082',
}

function createPublisher(fetchImpl = async () => ({ ok: true })) {
  return createProxyRegistrationPublisher(env, fetchImpl, path => {
    assert.equal(path, env.DSH_PROXY_REGISTRATION_SECRET_FILE)
    return secret
  })
}

test('registers IP, host web port, and token as authenticated JSON', async () => {
  let request
  const publisher = createPublisher(async (url, options) => {
    request = { url, options }
    return { ok: true }
  })
  const controller = new AbortController()
  await publisher(token, controller.signal)

  assert.equal(request.url.href, env.DSH_PROXY_REGISTRATION_URL)
  assert.equal(request.options.method, 'POST')
  assert.equal(request.options.headers.authorization, `Bearer ${secret}`)
  assert.equal(request.options.headers['content-type'], 'application/json')
  assert.deepEqual(JSON.parse(request.options.body), {
    ip: '192.0.2.217',
    web_port: 13082,
    token,
  })
  assert.equal(request.options.signal, controller.signal)
  assert.equal(request.options.body.includes(secret), false)
})

test('rejects invalid tokens before sending a request', async () => {
  let fetchCount = 0
  const publisher = createPublisher(async () => {
    fetchCount += 1
    return { ok: true }
  })
  await assert.rejects(publisher('bad token'), /Invalid DSH launch token/)
  assert.equal(fetchCount, 0)
})

test('rejects registrar HTTP URLs, invalid addresses, and invalid ports', () => {
  assert.throws(
    () => createProxyRegistrationPublisher({ ...env, DSH_PROXY_REGISTRATION_URL: 'http://proxy.invalid/register' }, async () => ({}), () => secret),
    /HTTPS URL/,
  )
  assert.throws(
    () => createProxyRegistrationPublisher({ ...env, DSH_PROXY_UPSTREAM_IP: 'proxy.internal' }, async () => ({}), () => secret),
    /must be an IP address/,
  )
  assert.throws(
    () => createProxyRegistrationPublisher({ ...env, DSH_WEB_HOST_PORT: '013082' }, async () => ({}), () => secret),
    /DSH_WEB_HOST_PORT/,
  )
})

test('does not disclose the bearer secret when the registrar rejects a request', async () => {
  const publisher = createPublisher(async () => ({ ok: false }))
  await assert.rejects(publisher(token), error => {
    assert.match(error.message, /rejected the token/)
    assert.equal(error.message.includes(secret), false)
    assert.equal(error.message.includes(token), false)
    return true
  })
})
