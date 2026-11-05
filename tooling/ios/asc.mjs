// App Store Connect API helper (Node >= 18, runs on the Mac).
//   node asc.mjs METHOD PATH [bodyJsonFile]   -> raw response on stdout, exit 1 on HTTP error
//   import { api } from './asc.mjs'            -> await api('GET', '/v1/apps')
// Key: ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (never printed).
// Account values come from the environment (env.sh) or, when unset, tooling/ios/local.env.
import { existsSync, readFileSync } from 'node:fs';
import { createSign, createPrivateKey } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const LOCAL_ENV = fileURLToPath(new URL('./local.env', import.meta.url));
const local = {};
if (existsSync(LOCAL_ENV)) {
  for (const line of readFileSync(LOCAL_ENV, 'utf8').split('\n')) {
    const m = /^\s*([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line);
    if (!m) continue;
    local[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2').replace(/\$\{?HOME\}?/g, process.env.HOME);
  }
}

/** [name] from the environment or local.env; exits with a clear message when it is missing. */
export function need(name) {
  const v = process.env[name] || local[name];
  if (!v) {
    console.error(`${name} is not set: add it to ${LOCAL_ENV} (template: local.env.example)`);
    process.exit(2);
  }
  return v;
}

const kid = need('ASC_KEY_ID');
const iss = need('ASC_ISSUER');
const key = createPrivateKey(readFileSync(`${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${kid}.p8`));
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

function token() {
  const now = Math.floor(Date.now() / 1000);
  const h = b64({ alg: 'ES256', kid, typ: 'JWT' });
  const p = b64({ iss, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' });
  const s = createSign('SHA256').update(`${h}.${p}`).sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${h}.${p}.${s}`;
}

export async function raw(method, path, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + path, {
    method,
    headers: { authorization: 'Bearer ' + token(), 'content-type': 'application/json' },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  });
  return { status: r.status, ok: r.ok, text: await r.text() };
}

export async function api(method, path, body) {
  const r = await raw(method, path, body);
  if (!r.ok) throw new Error(`${method} ${path} -> HTTP ${r.status} ${r.text.slice(0, 800)}`);
  return r.text ? JSON.parse(r.text) : {};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [m, path, bf] = process.argv.slice(2);
  const r = await raw(m, path, bf ? readFileSync(bf, 'utf8') : undefined);
  process.stdout.write(r.text);
  if (!r.ok) { console.error('\nHTTP', r.status); process.exit(1); }
}
