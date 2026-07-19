#!/usr/bin/env node

import { createHash, sign } from 'node:crypto'
import { writeFile } from 'node:fs/promises'

const API_ORIGIN = 'https://api.appstoreconnect.apple.com'
const BUNDLE_IDENTIFIER = 'com.drew.prompter'
const TEAM_IDENTIFIER = 'F3FXXB2HL6'
const PROFILE_NAME_PREFIX = 'Prompter Developer ID Associated Domains'

const outputFlagIndex = process.argv.indexOf('--output')
const outputPath = outputFlagIndex >= 0 ? process.argv[outputFlagIndex + 1] : ''
if (!outputPath || outputFlagIndex !== process.argv.length - 2) {
  fail('Usage: create-apple-developer-id-profile.mjs --output <path>')
}

const issuerId = requiredEnvironment('APPLE_API_ISSUER')
const keyId = requiredEnvironment('APPLE_API_KEY_ID')
const privateKey = requiredEnvironment('APPLE_API_KEY')
const signingCertificateSha256 = requiredEnvironment('SIGNING_CERT_SHA256').toLowerCase()
if (!/^[0-9a-f]{64}$/.test(signingCertificateSha256)) {
  fail('SIGNING_CERT_SHA256 must be a lowercase SHA-256 fingerprint')
}

const now = Math.floor(Date.now() / 1000)
const token = createJwt(
  { alg: 'ES256', kid: keyId, typ: 'JWT' },
  { iss: issuerId, iat: now - 30, exp: now + 600, aud: 'appstoreconnect-v1' },
  privateKey
)

let bundleId = await findBundleId()
if (!bundleId) bundleId = await createBundleId()
await ensureAssociatedDomainsCapability(bundleId.id)

const certificate = await findSigningCertificate()
let profile =
  (await findReusableProfile(bundleId.id, certificate.id)) ??
  (await createProfile(bundleId.id, certificate.id))

if (typeof profile.attributes?.profileContent !== 'string') {
  profile = (await request(apiUrl(`/v1/profiles/${encodeURIComponent(profile.id)}`))).data
}

const profileContent = profile.attributes?.profileContent
if (typeof profileContent !== 'string' || profileContent.length === 0) {
  fail('Apple returned a provisioning profile without profileContent')
}
const profileBytes = Buffer.from(profileContent, 'base64')
if (profileBytes.length < 256) fail('Apple returned an invalid provisioning profile')
await writeFile(outputPath, profileBytes, { mode: 0o600 })
console.log(`Provisioning profile ready for ${TEAM_IDENTIFIER}.${BUNDLE_IDENTIFIER}`)

async function findBundleId() {
  const url = apiUrl('/v1/bundleIds')
  url.searchParams.set('filter[identifier]', BUNDLE_IDENTIFIER)
  url.searchParams.set('limit', '2')
  const response = await request(url)
  const matches = response.data.filter(
    (item) => item.attributes?.identifier === BUNDLE_IDENTIFIER
  )
  if (matches.length > 1) fail('Apple returned duplicate Prompter bundle identifiers')
  return matches[0] ?? null
}

async function createBundleId() {
  const response = await request(apiUrl('/v1/bundleIds'), {
    method: 'POST',
    body: {
      data: {
        type: 'bundleIds',
        attributes: {
          identifier: BUNDLE_IDENTIFIER,
          name: 'Prompter',
          platform: 'MAC_OS',
        },
      },
    },
  })
  return response.data
}

async function ensureAssociatedDomainsCapability(bundleIdId) {
  const url = apiUrl(`/v1/bundleIds/${encodeURIComponent(bundleIdId)}/bundleIdCapabilities`)
  const response = await request(url)
  if (
    response.data.some(
      (capability) => capability.attributes?.capabilityType === 'ASSOCIATED_DOMAINS'
    )
  ) {
    return
  }

  await request(apiUrl('/v1/bundleIdCapabilities'), {
    method: 'POST',
    body: {
      data: {
        type: 'bundleIdCapabilities',
        attributes: { capabilityType: 'ASSOCIATED_DOMAINS' },
        relationships: {
          bundleId: { data: { type: 'bundleIds', id: bundleIdId } },
        },
      },
    },
  })
}

async function findSigningCertificate() {
  const url = apiUrl('/v1/certificates')
  url.searchParams.set('limit', '200')
  const response = await request(url)
  const matches = response.data.filter((certificate) => {
    if (!certificate.attributes?.certificateType?.startsWith('DEVELOPER_ID_APPLICATION')) {
      return false
    }
    const content = certificate.attributes?.certificateContent
    if (typeof content !== 'string') return false
    const fingerprint = createHash('sha256').update(Buffer.from(content, 'base64')).digest('hex')
    return fingerprint === signingCertificateSha256
  })
  if (matches.length !== 1) {
    fail('Could not uniquely match the imported Developer ID certificate in Apple Developer')
  }
  return matches[0]
}

async function findReusableProfile(bundleIdId, certificateId) {
  const url = apiUrl('/v1/profiles')
  url.searchParams.set('filter[profileState]', 'ACTIVE')
  url.searchParams.set('filter[profileType]', 'MAC_APP_DIRECT')
  url.searchParams.set('include', 'bundleId,certificates')
  url.searchParams.set('limit', '200')
  const response = await request(url)

  return (
    response.data.find((profile) => {
      const name = profile.attributes?.name
      const profileBundleId = profile.relationships?.bundleId?.data?.id
      const profileCertificates = profile.relationships?.certificates?.data ?? []
      return (
        typeof name === 'string' &&
        name.startsWith(PROFILE_NAME_PREFIX) &&
        profileBundleId === bundleIdId &&
        profileCertificates.some((item) => item.id === certificateId)
      )
    }) ?? null
  )
}

async function createProfile(bundleIdId, certificateId) {
  const profileName = `${PROFILE_NAME_PREFIX} ${signingCertificateSha256.slice(0, 12)}`
  const response = await request(apiUrl('/v1/profiles'), {
    method: 'POST',
    body: {
      data: {
        type: 'profiles',
        attributes: { name: profileName, profileType: 'MAC_APP_DIRECT' },
        relationships: {
          bundleId: { data: { type: 'bundleIds', id: bundleIdId } },
          certificates: { data: [{ type: 'certificates', id: certificateId }] },
        },
      },
    },
  })
  return response.data
}

async function request(url, { method = 'GET', body } = {}) {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!response.ok) {
    const payload = await response.json().catch(() => null)
    const descriptions = Array.isArray(payload?.errors)
      ? payload.errors
          .map((error) => [error.code, error.title, error.detail].filter(Boolean).join(': '))
          .join('; ')
      : ''
    fail(`Apple Developer API ${method} ${url.pathname} returned ${response.status}${descriptions ? ` (${descriptions})` : ''}`)
  }
  return response.status === 204 ? null : response.json()
}

function apiUrl(pathname) {
  return new URL(pathname, API_ORIGIN)
}

function createJwt(header, payload, key) {
  const signingInput = `${base64UrlJson(header)}.${base64UrlJson(payload)}`
  const signature = sign('sha256', Buffer.from(signingInput), {
    key,
    dsaEncoding: 'ieee-p1363',
  })
  return `${signingInput}.${signature.toString('base64url')}`
}

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url')
}

function requiredEnvironment(name) {
  const value = process.env[name]
  if (!value) fail(`Missing required environment variable: ${name}`)
  return value
}

function fail(message) {
  console.error(message)
  process.exit(1)
}
