// Runs assets/web/dsh_web_phone.js against a page model (node, no DOM
// library) and prints what it told the app and did to the official sidebar,
// as JSON. Used by test/web/web_phone_layout_test.dart.
//
//   node phone_layout_harness.mjs <phone.js> <scenario JSON>
//
// Scenario:
//   official   the frame is DSH 0.2.1-rc.5's own narrow drawer
//              (frame[data-sidebar-drawer] with its mask)
//   officialAt ms after load when the frame says so (default 0)
//   frameAt    ms after load when the frame is drawn (default 0)
//   layout     html[data-dsh-app-layout] (default 'drawer')
//   run        virtual ms to run (default 15000)
import fs from 'node:fs';
import vm from 'node:vm';

const [scriptPath, scenarioJson] = process.argv.slice(2);
const s = JSON.parse(scenarioJson);
const out = { reports: [], clicks: [], focusBlurs: 0 };

let now = 1000;
let seq = 0;
const timers = new Map();
const setTimeoutV = (fn, ms) => { const id = ++seq; timers.set(id, { at: now + Math.max(0, +ms || 0), fn, id }); return id; };
const clearTimeoutV = (id) => { timers.delete(id); };
function runUntil(limit) {
  for (;;) {
    let next = null;
    for (const t of timers.values()) if (!next || t.at < next.at || (t.at === next.at && t.id < next.id)) next = t;
    if (!next || next.at > limit) break;
    now = Math.max(now, next.at);
    timers.delete(next.id);
    try { next.fn(); } catch (e) { out.thrown = String(e && e.stack || e); }
  }
  now = limit;
}

class El {
  constructor(name, attrs = {}) { this.name = name; this.attrs = { ...attrs }; this.style = {}; }
  getAttribute(n) { return n in this.attrs ? String(this.attrs[n]) : null; }
  hasAttribute(n) { return n in this.attrs; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  removeAttribute(n) { delete this.attrs[n]; }
  addEventListener() {}
}

const html = new El('html', { 'data-dsh-app-layout': s.layout ?? 'drawer' });
const body = new El('body');
const frame = new El('frame', { 'data-sidebar-collapsed': '', 'data-rightbar-collapsed': '' });
let frameShown = false;
const mask = new El('drawerMask');
const toggle = new El('toggle');
toggle.click = () => {
  out.clicks.push('toggle');
  if (frame.hasAttribute('data-sidebar-collapsed')) frame.removeAttribute('data-sidebar-collapsed');
  else frame.setAttribute('data-sidebar-collapsed', '');
};
frame.querySelector = (sel) => {
  if (sel === ':scope > [class*="_drawerMask"]') return frame.hasAttribute('data-sidebar-drawer') ? mask : null;
  if (sel === '[class*="_sidebarCol"]') return null;
  throw new Error('frame.querySelector: ' + sel);
};
setTimeoutV(() => { frameShown = true; }, s.frameAt || 0);
if (s.official) setTimeoutV(() => { frame.setAttribute('data-sidebar-drawer', ''); }, s.officialAt || 0);

const TOGGLE = '[data-slot="sidebar"] [class*="_logoRow"] button[class*="_iconButton"]';
const document = {
  documentElement: html,
  body,
  activeElement: body,
  addEventListener() {},
  querySelector(sel) {
    if (sel === '[data-slot="root"] > [class*="_frame"]') return frameShown ? frame : null;
    if (sel === TOGGLE) return frameShown ? toggle : null;
    throw new Error('document.querySelector: ' + sel);
  },
};
const window = {
  DshAppLayout: { postMessage: (m) => out.reports.push(m) },
  matchMedia: () => ({ addEventListener() {} }),
};
const context = vm.createContext({
  window,
  document,
  getComputedStyle: () => ({ backgroundColor: 'rgb(255, 255, 255)' }),
  MutationObserver: class { observe() {} },
  setTimeout: setTimeoutV,
  clearTimeout: clearTimeoutV,
  Date: { now: () => now },
});
vm.runInContext(fs.readFileSync(scriptPath, 'utf8'), context);
runUntil(now + (s.run || 15000));
out.officialExpanded = !frame.hasAttribute('data-sidebar-collapsed');
out.appDrawer = frame.hasAttribute('data-dsh-app-drawer');
out.layout = window.__dshApp && window.__dshApp.layout();
process.stdout.write(JSON.stringify(out));
