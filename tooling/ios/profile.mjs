// Ensure the bundle ID, its capabilities and the provisioning profiles exist; install them locally.
//   node tooling/ios/profile.mjs            # reuse ACTIVE profiles that match, else (re)create
//   node tooling/ios/profile.mjs --renew    # delete and recreate both profiles
//   node tooling/ios/profile.mjs --store    # only the App Store profile (what tf-release.sh needs)
// Profiles:
//   "dg com.colex.dshgo"      IOS_APP_STORE        Apple Distribution DG_CERT_ID  (TestFlight / App Store)
//   "dg dev com.colex.dshgo"  IOS_APP_DEVELOPMENT  Apple Development DG_DEV_CERT_ID + every enabled iOS device
// (certificate ids from tooling/ios/local.env)
// The push capability (aps-environment) is added when missing. A
// capability change invalidates existing profiles, which are then recreated here.
import { writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { api, need, raw } from './asc.mjs';

const BUNDLE = process.env.DG_BUNDLE_ID || 'com.colex.dshgo';
// Time Sensitive Notifications has no App ID capability in the API (its entitlement is checked against
// the profile below and reported).
const CAPABILITIES = ['PUSH_NOTIFICATIONS'];
const renew = process.argv.includes('--renew');
const storeOnly = process.argv.includes('--store');
const HOME = process.env.HOME;
const dirs = [`${HOME}/Library/MobileDevice/Provisioning Profiles`, `${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles`];
dirs.forEach((d) => mkdirSync(d, { recursive: true }));

const PROFILES = [
  { name: process.env.DG_PROFILE_NAME || `dg ${BUNDLE}`, type: 'IOS_APP_STORE', certs: [need('DG_CERT_ID')], devices: false },
  ...(storeOnly ? [] : [{ name: `dg dev ${BUNDLE}`, type: 'IOS_APP_DEVELOPMENT', certs: [need('DG_DEV_CERT_ID')], devices: true }]),
];

// 1. Bundle ID (filter[identifier] is a prefix match, so compare exactly).
let bid = (await api('GET', `/v1/bundleIds?limit=200&filter[identifier]=${BUNDLE}`)).data.find((d) => d.attributes.identifier === BUNDLE);
if (!bid) {
  bid = (await api('POST', '/v1/bundleIds', { data: { type: 'bundleIds', attributes: { identifier: BUNDLE, name: 'DSH Go', platform: 'IOS' } } })).data;
  console.log('registered bundleId', BUNDLE, bid.id);
} else console.log('bundleId', BUNDLE, bid.id, bid.attributes.platform);

// 2. Capabilities.
const have = new Set((await api('GET', `/v1/bundleIds/${bid.id}/bundleIdCapabilities`)).data.map((c) => c.attributes.capabilityType));
for (const cap of CAPABILITIES.filter((c) => !have.has(c))) {
  const r = await raw('POST', '/v1/bundleIdCapabilities', {
    data: { type: 'bundleIdCapabilities', attributes: { capabilityType: cap }, relationships: { bundleId: { data: { type: 'bundleIds', id: bid.id } } } },
  });
  if (!r.ok) throw new Error(`enable ${cap}: HTTP ${r.status} ${r.text.replace(/\s+/g, ' ').slice(0, 400)}`);
  console.log('enabled capability', cap);
}
console.log('capabilities', [...new Set([...have, ...CAPABILITIES])].join(','));

const devices = (await api('GET', '/v1/devices?limit=200&filter[platform]=IOS&filter[status]=ENABLED&fields[devices]=name')).data;

// 3. Profiles.
const existing = (await api('GET', `/v1/bundleIds/${bid.id}/profiles?limit=50&fields[profiles]=name,uuid,profileState,profileType,expirationDate`)).data;
for (const want of PROFILES) {
  let keep = null;
  for (const p of existing.filter((p) => p.attributes.name === want.name)) {
    const a = p.attributes;
    let ok = !renew && a.profileState === 'ACTIVE' && a.profileType === want.type && Date.parse(a.expirationDate) > Date.now() + 7 * 864e5;
    if (ok) {
      const certs = (await api('GET', `/v1/profiles/${p.id}/certificates?fields[certificates]=name`)).data.map((c) => c.id);
      ok = want.certs.every((c) => certs.includes(c));
    }
    if (ok && want.devices) {
      const ids = new Set((await api('GET', `/v1/profiles/${p.id}/devices?limit=200&fields[devices]=name`)).data.map((d) => d.id));
      ok = devices.every((d) => ids.has(d.id));
    }
    if (ok && !keep) { keep = p; continue; }
    await api('DELETE', `/v1/profiles/${p.id}`);
    dirs.forEach((d) => { const f = `${d}/${a.uuid}.mobileprovision`; if (existsSync(f)) rmSync(f); });
    console.log('deleted profile', want.name, a.uuid, a.profileState);
  }
  let full;
  if (keep) {
    full = (await api('GET', `/v1/profiles/${keep.id}?fields[profiles]=name,uuid,profileState,profileContent,expirationDate`)).data;
  } else {
    const relationships = {
      bundleId: { data: { type: 'bundleIds', id: bid.id } },
      certificates: { data: want.certs.map((id) => ({ type: 'certificates', id })) },
      ...(want.devices ? { devices: { data: devices.map((d) => ({ type: 'devices', id: d.id })) } } : {}),
    };
    full = (await api('POST', '/v1/profiles', { data: { type: 'profiles', attributes: { name: want.name, profileType: want.type }, relationships } })).data;
    console.log('created profile', want.name);
  }
  const a = full.attributes;
  const buf = Buffer.from(a.profileContent, 'base64');
  dirs.forEach((d) => writeFileSync(`${d}/${a.uuid}.mobileprovision`, buf));
  const s = buf.toString('latin1');
  const aps = /aps-environment<\/key>\s*<string>([^<]*)/.exec(s)?.[1] ?? '(none)';
  const ts = /time-sensitive<\/key>\s*<(true|false)/.exec(s)?.[1] ?? '(none)';
  console.log(`profile "${a.name}" ${a.uuid} ${a.profileState} expires ${a.expirationDate} aps-environment=${aps} time-sensitive=${ts}${want.devices ? ` devices=${devices.length}` : ''} -> installed`);
}
