// Voice in a real browser: exports examples/web_voice_probe.tscn for the web (no threads,
// the template the client shell uses), serves it, starts examples/web_voice_server.gd, and
// drives Chromium with a fake microphone (its built-in beep) through Playwright.
//
//   node tools/web_voice_check.mjs [--keep] [--cdp=http://127.0.0.1:9222]
//
// What it asserts:
//   1. the page does not call getUserMedia before the talk key is pressed;
//   2. pressing V calls it, and the browser's frames reach a native client through the server;
//   3. the native client's frames reach the page and play.
// Exit 0 all held, 1 one did not, 2 no Playwright or no web template.
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PLAYWRIGHT = process.env.PLAYWRIGHT_CORE ?? '/home/christian/stack/website-city/node_modules/playwright-core/index.js';
const OUT = join(ROOT, 'build', 'web-voice');
const WS_PORT = 47380;
const HTTP_PORT = 47381;

if (!existsSync(PLAYWRIGHT)) { console.log('no playwright-core at ' + PLAYWRIGHT); process.exit(2); }
const pw = (await import(PLAYWRIGHT)).default;

// An export preset of our own, written each run (export_presets.cfg is gitignored here).
const preset = `[preset.0]
name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="build/*"
export_path="build/web-voice/index.html"

[preset.0.options]
variant/extensions_support=false
variant/thread_support=false
vram_texture_compression/for_desktop=true
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
`;
writeFileSync(join(ROOT, 'export_presets.cfg'), preset);
mkdirSync(OUT, { recursive: true });
// The probe is the main scene for this export only.
const projectFile = join(ROOT, 'project.godot');
const project = readFileSync(projectFile, 'utf8');
writeFileSync(projectFile, project.replace(/run\/main_scene="[^"]*"/, 'run/main_scene="res://examples/web_voice_probe.tscn"'));
const exported = spawnSync('timeout', ['300', 'godot', '--headless', '--path', ROOT, '--export-debug', 'Web', join(OUT, 'index.html')], { encoding: 'utf8' });
writeFileSync(projectFile, project);
if (exported.status !== 0 || !existsSync(join(OUT, 'index.wasm'))) {
  console.log(exported.stdout.slice(-2000), exported.stderr.slice(-2000));
  console.log('export failed');
  process.exit(2);
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.png': 'image/png' };
const http = createServer((req, res) => {
  const path = join(OUT, decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html');
  if (!existsSync(path)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': types[extname(path)] ?? 'application/octet-stream' });
  res.end(readFileSync(path));
});
await new Promise(r => http.listen(HTTP_PORT, '127.0.0.1', r));

const server = spawn('timeout', ['90', 'godot', '--headless', '--path', ROOT, '--script', 'examples/web_voice_server.gd', '--', '--port', String(WS_PORT), '--seconds', '60']);
let serverLast = {};
server.stdout.on('data', d => {
  for (const line of String(d).split('\n')) {
    if (line.startsWith('SERVER ')) { try { serverLast = JSON.parse(line.slice(7)); } catch {} }
  }
});

// --cdp=URL drives an already running Chrome (the GPU box's real one) instead of launching Chromium.
const cdp = (process.argv.find(a => a.startsWith('--cdp=')) ?? '').slice(6);
const browser = cdp ? await pw.chromium.connectOverCDP(cdp) : await pw.chromium.launch({
  headless: true,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--use-gl=swiftshader', '--enable-unsafe-swiftshader'],
});
const context = cdp ? browser.contexts()[0] : await browser.newContext({ viewport: { width: 640, height: 360 } });
await context.grantPermissions(['microphone'], { origin: `http://127.0.0.1:${HTTP_PORT}` });
const page = await context.newPage();
await page.addInitScript(() => {
  window.__gum = 0;
  const md = navigator.mediaDevices;
  if (md && md.getUserMedia) {
    const real = md.getUserMedia.bind(md);
    md.getUserMedia = (c) => { window.__gum += 1; return real(c); };
  }
});
let probeLast = {};
const errors = [];
page.on('console', m => {
  const t = m.text();
  if (t.startsWith('VOICEPROBE ')) { try { probeLast = JSON.parse(t.slice(11)); } catch {} }
  else if (m.type() === 'error') errors.push(t);
});
page.on('pageerror', e => errors.push(String(e)));

const sleep = ms => new Promise(r => setTimeout(r, ms));
await page.goto(`http://127.0.0.1:${HTTP_PORT}/index.html?ws=ws://127.0.0.1:${WS_PORT}`);
for (let i = 0; i < 60 && probeLast.socket !== 1; i++) await sleep(500);

const results = [];
const check = (ok, what) => { results.push(ok); console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${what}`); };

check(probeLast.socket === 1, `the page connected to the voice server over WebSocket (state ${probeLast.socket})`);
// A click first: the page's first user gesture, which is not a press of the talk key.
await page.mouse.click(320, 180);
await sleep(3000);
const before = await page.evaluate(() => window.__gum);
check(before === 0, `no getUserMedia before the talk key (${before} calls)`);
check(probeLast.received > 20 && probeLast.heard_rms > 0.05, `the page plays what the native client says (${probeLast.received} frames, ${(probeLast.heard_rms ?? 0).toFixed(3)} rms, speakers ${JSON.stringify(probeLast.speakers)})`);

await page.keyboard.down('v');
await sleep(4000);
const after = await page.evaluate(() => window.__gum);
const held = { ...probeLast };
await page.keyboard.up('v');
await sleep(1500);
check(after >= 1, `holding V asked for the microphone (${after} calls)`);
check(held.capturing === true && held.captured > 50, `the browser captured its microphone (${held.captured} frames, driver ${held.driver}, mix ${held.mix_rate}${held.press_error ? ', ' + held.press_error : ''})`);
check(held.sent > 50, `and sent it (${held.sent} frames)`);
check(serverLast.bot_received > 50 && serverLast.bot_heard_rms > 0.01, `a native client heard the browser through the server (${serverLast.bot_received} frames, ${(serverLast.bot_heard_rms ?? 0).toFixed(3)} rms)`);
const sentAtRelease = probeLast.sent;
await sleep(1500);
check(probeLast.sent === sentAtRelease, `released, the browser stops sending (${probeLast.sent - sentAtRelease} more)`);

if (errors.length) console.log('page errors:\n  ' + errors.slice(0, 10).join('\n  '));
await browser.close();
server.kill();
http.close();
const failed = results.filter(r => !r).length;
console.log(failed ? `${failed} failed` : 'voice works in the browser');
process.exit(failed ? 1 : 0);
