// Read the running gateway's control plane without sending a model request.
// Use the same service identity and loopback auth as teamclaude-accounts.
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export async function control(path, configPath, method = 'GET') {
  const { proxy } = JSON.parse(await readFile(configPath, 'utf8'));
  if (!Number.isInteger(proxy?.port) || proxy.port < 1 || proxy.port > 65535 ||
      typeof proxy.apiKey !== 'string' || !proxy.apiKey) throw new Error('missing loopback control settings');
  return fetch(`http://127.0.0.1:${proxy.port}/teamclaude/${path}`, {
    method, headers: { 'x-api-key': proxy.apiKey }, redirect: 'error', signal: AbortSignal.timeout(5000),
  });
}

export async function readStatus(configPath) {
  const res = await control('status', configPath);
  if (!res.ok) throw new Error('status request failed');
  const status = await res.json();
  if (!Array.isArray(status?.accounts) || status.accounts.some(a =>
    !validName(a?.name) || typeof a.type !== 'string' || typeof a.provider !== 'string' ||
    typeof a.disabled !== 'boolean' || typeof a.status !== 'string')) {
    throw new Error('unexpected status schema');
  }
  return status;
}

const validName = name => typeof name === 'string' && name.length > 0 && name.length <= 320 && !/[\x00-\x1f\x7f]/.test(name);
export const subscriptionOAuth = a => a.type === 'oauth' && a.provider === 'anthropic' && a.longLived !== true;
export const authRejection = a => a.status === 'error' && ['refresh_rejected', 'credential_rejected'].includes(a.errorReason?.code);
export const epochMs = value => Number.isSafeInteger(value) && value >= 1e12 && value <= 8.64e15;
const esc = name => name.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

export function oauthMetrics(status, now = Date.now()) {
  const counts = new Map();
  for (const { name } of status.accounts) counts.set(name, (counts.get(name) ?? 0) + 1);
  const expiry = [], rejected = [];
  for (const a of status.accounts) {
    if (a.disabled || !subscriptionOAuth(a) || counts.get(a.name) !== 1) continue;
    const label = `{account="${esc(a.name)}"}`;
    if (epochMs(a.refreshTokenExpiresAt)) {
      expiry.push(`teamclaude_account_oauth_refresh_expiry_timestamp_seconds${label} ${Math.floor(a.refreshTokenExpiresAt / 1000)}`);
    }
    // A failed quota poll by itself is not an auth verdict. The manager
    // keeps the explicit rejection until recovery; even if the prober skips
    // this account and its timestamp ages, a fresh status is still evidence.
    rejected.push(`teamclaude_account_oauth_relogin_required${label} ${Number(authRejection(a))}`);
  }
  return [
    '# HELP teamclaude_oauth_status_collected_timestamp_seconds Unix time of the last successful OAuth status collection.',
    '# TYPE teamclaude_oauth_status_collected_timestamp_seconds gauge',
    `teamclaude_oauth_status_collected_timestamp_seconds ${Math.floor(now / 1000)}`,
    '# HELP teamclaude_account_oauth_refresh_expiry_timestamp_seconds Recorded refresh-token deadline as Unix time, if known.',
    '# TYPE teamclaude_account_oauth_refresh_expiry_timestamp_seconds gauge',
    ...expiry,
    '# HELP teamclaude_account_oauth_relogin_required Whether TeamClaude confirmed a credential rejection.',
    '# TYPE teamclaude_account_oauth_relogin_required gauge',
    ...rejected, '',
  ].join('\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.stdout.write(oauthMetrics(await readStatus(process.argv[2])));
  } catch {
    // Never log the config, request headers, response, or parser exception.
    console.error('teamclaude-metrics: could not collect authenticated OAuth status');
    process.exitCode = 1;
  }
}
