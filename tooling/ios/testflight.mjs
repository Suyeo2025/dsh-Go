// After `altool --upload-app`: wait for processing, make the build testable internally, read back.
//   node tooling/ios/testflight.mjs <buildNumber>          # e.g. 202611041030
//   node tooling/ios/testflight.mjs --status [buildNumber] # read-only: latest builds / one build
// Internal TestFlight only: no external groups, no beta review submission.
import { api, need, raw } from './asc.mjs';

const BUNDLE = process.env.DG_BUNDLE_ID || 'com.colex.dshgo';
const GROUP = process.env.DG_TF_GROUP || '内部测试';
const TESTERS = need('DG_TF_TESTERS').split(',').map((s) => s.trim().toLowerCase());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const args = process.argv.slice(2);
const statusOnly = args[0] === '--status';
const BN = statusOnly ? args[1] : args[0];
if (!statusOnly && !BN) { console.error('usage: testflight.mjs <buildNumber> | --status [buildNumber]'); process.exit(2); }

const app = (await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE}&fields[apps]=name,bundleId,sku`)).data.find((a) => a.attributes.bundleId === BUNDLE);
if (!app) throw new Error(`no App Store Connect app record for ${BUNDLE} (create it in the web UI first)`);
console.log('app', app.id, JSON.stringify(app.attributes));

const BF = 'fields[builds]=version,processingState,uploadedDate,expired,usesNonExemptEncryption';
async function findBuild(v) {
  return (await api('GET', `/v1/builds?filter[app]=${app.id}&filter[version]=${v}&${BF}&limit=5`)).data[0];
}
if (statusOnly) {
  const list = BN ? [await findBuild(BN)].filter(Boolean)
    : (await api('GET', `/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=5&${BF}`)).data;
  for (const b of list) console.log(b.id, JSON.stringify(b.attributes));
  process.exit(0);
}

// 1. Wait until the build shows up and finishes processing (typically 5-30 min).
let build;
const deadline = Date.now() + 90 * 60e3;
for (;;) {
  build = await findBuild(BN);
  const st = build?.attributes.processingState ?? 'NOT_FOUND';
  console.log(new Date().toISOString(), 'build', BN, st);
  if (st === 'VALID') break;
  if (st === 'FAILED' || st === 'INVALID') throw new Error(`build ${BN} processing ${st}`);
  if (Date.now() > deadline) throw new Error(`build ${BN} not processed after 90 min (last: ${st})`);
  await sleep(60e3);
}

// 2. Export compliance. Info.plist declares ITSAppUsesNonExemptEncryption=false; this is the
//    idempotent fallback for a build that still has no answer.
if (build.attributes.usesNonExemptEncryption == null) {
  await api('PATCH', `/v1/builds/${build.id}`, { data: { type: 'builds', id: build.id, attributes: { usesNonExemptEncryption: false } } });
  console.log('set usesNonExemptEncryption=false');
}

// 3. Internal group for this app (created once), testers, build.
let group = (await api('GET', `/v1/apps/${app.id}/betaGroups?fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds&limit=50`)).data
  .find((g) => g.attributes.name === GROUP && g.attributes.isInternalGroup);
if (!group) {
  group = (await api('POST', '/v1/betaGroups', {
    data: { type: 'betaGroups', attributes: { name: GROUP, isInternalGroup: true, hasAccessToAllBuilds: false }, relationships: { app: { data: { type: 'apps', id: app.id } } } },
  })).data;
  console.log('created internal group', GROUP, group.id);
}
// Internal testers must be App Store Connect users who can see this app. Linking an existing
// betaTester record (from another app) to the group answers 409; creating the tester with the
// group relationship works. A user with allAppsVisible=false needs this app in Users and Access.
const inGroup = new Set((await api('GET', `/v1/betaGroups/${group.id}/betaTesters?fields[betaTesters]=email&limit=200`)).data.map((t) => t.attributes.email.toLowerCase()));
const users = (await api('GET', '/v1/users?limit=200&fields[users]=username,allAppsVisible')).data;
const problems = [];
for (const email of TESTERS.filter((e) => !inGroup.has(e))) {
  const user = users.find((u) => u.attributes.username.toLowerCase() === email);
  if (!user) { problems.push(`${email}: not an App Store Connect user (internal testers must be)`); continue; }
  if (!user.attributes.allAppsVisible) {
    const apps = (await api('GET', `/v1/users/${user.id}/visibleApps?fields[apps]=bundleId&limit=200`)).data;
    if (!apps.some((a) => a.id === app.id)) { problems.push(`${email}: user cannot see app ${app.id} (Users and Access -> Apps: add "${app.attributes.name}")`); continue; }
  }
  const r = await raw('POST', '/v1/betaTesters', {
    data: { type: 'betaTesters', attributes: { email }, relationships: { betaGroups: { data: [{ type: 'betaGroups', id: group.id }] } } },
  });
  if (r.ok) console.log('added tester', email);
  else problems.push(`${email}: HTTP ${r.status} ${r.text.replace(/\s+/g, ' ').slice(0, 300)}`);
}
for (const p of problems) console.log('TESTER_PROBLEM', p);
if (!group.attributes.hasAccessToAllBuilds) {
  const has = (await api('GET', `/v1/betaGroups/${group.id}/builds?fields[builds]=version&limit=200`)).data.some((b) => b.id === build.id);
  if (!has) {
    await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, { data: [{ type: 'builds', id: build.id }] });
    console.log('added build to group');
  }
}

// 4. Read back.
await sleep(5e3);
const b2 = (await api('GET', `/v1/builds/${build.id}?${BF}`)).data.attributes;
const detail = (await api('GET', `/v1/builds/${build.id}/buildBetaDetail`)).data.attributes;
// builds/{id}/betaGroups is write-only; read the group's builds instead.
const inGroupBuild = group.attributes.hasAccessToAllBuilds
  || (await api('GET', `/v1/betaGroups/${group.id}/builds?fields[builds]=version&limit=200`)).data.some((x) => x.id === build.id);
const testers = (await api('GET', `/v1/betaGroups/${group.id}/betaTesters?fields[betaTesters]=email,state&limit=200`)).data.map((t) => `${t.attributes.email}:${t.attributes.state}`);
console.log('build', JSON.stringify(b2));
console.log('betaDetail', JSON.stringify(detail));
console.log(`group "${GROUP}" ${group.id} hasBuild=${inGroupBuild} | testers`, testers.join(','));
const ok = b2.processingState === 'VALID' && b2.usesNonExemptEncryption === false && inGroupBuild && problems.length === 0
  && TESTERS.every((e) => testers.some((t) => t.toLowerCase().startsWith(e + ':')));
console.log(ok ? 'TESTFLIGHT_OK' : 'TESTFLIGHT_CHECK_FAILED');
process.exit(ok ? 0 : 1);
