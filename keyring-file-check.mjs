import fs from 'node:fs'
import { pathToFileURL } from 'node:url'

function decodeMountField(value) {
  return value.replace(/\\([0-7]{3})/g, (_, code) => String.fromCharCode(Number.parseInt(code, 8)))
}

export function validateKeyringSecretFile(filePath, mountInfoPath = '/proc/self/mountinfo', expectedUid = 0) {
  let stat
  try {
    stat = fs.lstatSync(filePath)
  } catch (error) {
    return error.code === 'ENOENT' ? 'absent' : 'invalid'
  }
  if (stat.isSymbolicLink()) return 'invalid'
  if (stat.isDirectory()) return 'absent'
  if (!stat.isFile() || stat.uid !== expectedUid || ![0o400, 0o600].includes(stat.mode & 0o777)) return 'invalid'

  let secret
  try {
    secret = fs.readFileSync(filePath)
  } catch {
    return 'invalid'
  }
  if (secret.length === 0 || secret.length > 4096 || secret.includes(0)) return 'invalid'
  if (secret[secret.length - 1] === 10) {
    secret = secret.subarray(0, secret.length - 1)
    if (secret[secret.length - 1] === 13) secret = secret.subarray(0, secret.length - 1)
  }
  if (secret.length === 0 || secret.includes(10) || secret.includes(13)) return 'invalid'

  let mountInfo
  try {
    mountInfo = fs.readFileSync(mountInfoPath, 'utf8')
  } catch {
    return 'invalid'
  }
  for (const line of mountInfo.split('\n')) {
    const fields = line.split(' ')
    if (fields.length > 5 && decodeMountField(fields[4]) === filePath && fields[5].split(',').includes('ro')) return 'valid'
  }
  return 'invalid'
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , filePath, mountInfoPath = '/proc/self/mountinfo'] = process.argv
  if (!filePath) process.exitCode = 2
  else {
    const result = validateKeyringSecretFile(filePath, mountInfoPath)
    process.exitCode = result === 'valid' ? 0 : result === 'absent' ? 1 : 2
  }
}
