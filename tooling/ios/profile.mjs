// Ensure the bundle IDs, their capabilities and the provisioning profiles exist; install them locally.
//   node tooling/ios/profile.mjs            # reuse ACTIVE profiles that match, else (re)create
//   node tooling/ios/profile.mjs --renew    # delete and recreate every profile
//   node tooling/ios/profile.mjs --store    # only the App Store profiles (what tf-release.sh needs)
// Bundle IDs and profiles:
//   com.colex.dshgo        the app            push + App Groups
//     "dg com.colex.dshgo"            IOS_APP_STORE        Apple Distribution DG_CERT_ID
//     "dg dev com.colex.dshgo"        IOS_APP_DEVELOPMENT  Apple Development DG_DEV_CERT_ID + enabled devices
//   com.colex.dshgo.share  the share extension (app/ios/ShareExtension)   App Groups
//     "dg com.colex.dshgo.share"      IOS_APP_STORE
//     "dg dev com.colex.dshgo.share"  IOS_APP_DEVELOPMENT
// (certificate ids from tooling/ios/local.env)
// Missing capabilities are added; a capability change invalidates existing profiles, which are then
// recreated here. The API can enable the App Groups capability but cannot register an App Group nor
// assign one to an App ID (developer portal only): each profile's application-groups are printed as
// `APP_GROUPS <profile> <groups|none>` so tf-release.sh can tell whether the share extension can ship.
// Time Sensitive Notifications has no App ID capability in the API either.
import { writeFileSync, mkdirSync, existsSync, rmSync } from 'node:fs';
import { api, need, raw } from './asc.mjs';

const MAIN = process.env.DG_BUNDLE_ID || 'com.colex.dshgo';
const BUNDLES = [
  { id: MAIN, name: 'DSH Go', caps: ['PUSH_NOTIFICATIONS', 'APP_GROUPS'] },
  { id: `${MAIN}.share`, name: 'DSH Go Share', caps: ['APP_GROUPS'] },
];
const renew = process.argv.includes('--renew');
const storeOnly = process.argv.includes('--store');
const HOME = process.env.HOME;
const dirs = [`${HOME}/Library/MobileDevice/Provisioning Profiles`, `${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles`];
dirs.forEach((d) => mkdirSync(d, { recursive: true }));

const devices = (await api('GET', '/v1/devices?limit=200&filter[platform]=IOS&filter[status]=ENABLED&fields[devices]=name')).data;

for (const bundle of BUNDLES) {
  const profiles = [
    { name: bundle.id === MAIN && process.env.DG_PROFILE_NAME ? process.env.DG_PROFILE_NAME : `dg ${bundle.id}`, type: 'IOS_APP_STORE', certs: [need('DG_CERT_ID')], devices: false },
    ...(storeOnly ? [] : [{ name: `dg dev ${bundle.id}`, type: 'IOS_APP_DEVELOPMENT', certs: [need('DG_DEV_CERT_ID')], devices: true }]),
  ];

  // 1. Bundle ID (filter[identifier] is a prefix match, so compare exactly).
  let bid = (await api('GET', `/v1/bundleIds?limit=200&filter[identifier]=${bundle.id}`)).data.find((d) => d.attributes.identifier === bundle.id);
  if (!bid) {
    bid = (await api('POST', '/v1/bundleIds', { data: { type: 'bundleIds', attributes: { identifier: bundle.id, name: bundle.name, platform: 'IOS' } } })).data;
    console.log('registered bundleId', bundle.id, bid.id);
  } else console.log('bundleId', bundle.id, bid.id, bid.attributes.platform);

  // 2. Capabilities.
  const have = new Set((await api('GET', `/v1/bundleIds/${bid.id}/bundleIdCapabilities`)).data.map((c) => c.attributes.capabilityType));
  for (const cap of bundle.caps.filter((c) => !have.has(c))) {
    const r = await raw('POST', '/v1/bundleIdCapabilities', {
      data: { type: 'bundleIdCapabilities', attributes: { capabilityType: cap }, relationships: { bundleId: { data: { type: 'bundleIds', id: bid.id } } } },
    });
    if (!r.ok) throw new Error(`${bundle.id}: enable ${cap}: HTTP ${r.status} ${r.text.replace(/\s+/g, ' ').slice(0, 400)}`);
    console.log('enabled capability', bundle.id, cap);
  }
  console.log('capabilities', bundle.id, [...new Set([...have, ...bundle.caps])].join(','));

  // 3. Profiles.
  const existing = (await api('GET', `/v1/bundleIds/${bid.id}/profiles?limit=50&fields[profiles]=name,uuid,profileState,profileType,expirationDate`)).data;
  for (const want of profiles) {
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
    const groupsBlock = /application-groups<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(s)?.[1];
    const groups = groupsBlock ? [...groupsBlock.matchAll(/<string>([^<]*)<\/string>/g)].map((m) => m[1]) : [];
    console.log(`profile "${a.name}" ${a.uuid} ${a.profileState} expires ${a.expirationDate} aps-environment=${aps}${want.devices ? ` devices=${devices.length}` : ''} -> installed`);
    console.log(`APP_GROUPS ${a.name} ${groups.length ? groups.join(',') : 'none'}`);
  }
}
