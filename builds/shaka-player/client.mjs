#!/usr/bin/env node
// TAP client: moqxr publishes the fixture, Shaka Player plays it in a browser.
import { spawn } from 'node:child_process';
import { randomUUID, X509Certificate } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';
import { parseArgs } from 'node:util';

const TESTS = ['publish-subscribe-media'];
const DRAFTS = new Set(['18', '22']);
const APP = process.env.SHAKA_APP_DIR || '/app';
const SHAKA_DIST = join(APP, 'node_modules/shaka-player/dist');
const CERT = '/certs/cert.pem';
const PUBLISHER_WAIT_MS = 10000;
const PLAY_WINDOW_MS = 8000;
const MIN_FRAMES = 2;

// Playwright browser type and launch options per BROWSER (set by the image). Chrome's
// sandbox cannot start as a non-root user under Docker's default seccomp
// profile, so chromiumSandbox stays off (Playwright then passes --no-sandbox).
const CHROMIUM_ARGS = ['--autoplay-policy=no-user-gesture-required', '--disable-dev-shm-usage'];
const BROWSERS = {
  chrome: { type: 'chromium', channel: 'chrome', chromiumSandbox: false, args: CHROMIUM_ARGS },
  chromium: { type: 'chromium', chromiumSandbox: false, args: CHROMIUM_ARGS },
  firefox: { type: 'firefox', firefoxUserPrefs: { 'media.autoplay.default': 0 } },
};

const { values: opts } = parseArgs({
  options: {
    relay: { type: 'string', default: process.env.RELAY_URL || '' },
    test: { type: 'string', default: process.env.TESTCASE || '' },
    list: { type: 'boolean', default: false },
    'tls-disable-verify': { type: 'boolean', default: false },
    verbose: { type: 'boolean', default: false },
  },
});

const truthy = (v) => ['1', 'true', 'yes'].includes(String(v || '').toLowerCase());
const insecure = opts['tls-disable-verify'] || truthy(process.env.TLS_DISABLE_VERIFY);
const verbose = opts.verbose || process.env.VERBOSE === '1';
const log = (line) => { if (verbose) process.stderr.write(`[shaka-client] ${line}\n`); };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// As PID 1 node ignores SIGTERM unless handled; the browser exits with its pipe.
const children = new Set();
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    for (const child of children) child.kill('SIGKILL');
    process.exit(signal === 'SIGTERM' ? 143 : 130);
  });
}

// YAML scalars: JSON strings are valid double-quoted YAML.
function yaml(fields, indent = '  ') {
  const lines = [`${indent}---`];
  const emit = (obj, pad) => {
    for (const [key, value] of Object.entries(obj)) {
      if (value === undefined || value === null || value === '') continue;
      if (typeof value === 'object') {
        lines.push(`${pad}${key}:`);
        emit(value, `${pad}  `);
      } else if (typeof value === 'string' && value.includes('\n')) {
        lines.push(`${pad}${key}: |`);
        for (const l of value.replace(/\n+$/, '').split('\n')) lines.push(`${pad}  ${l}`);
      } else {
        lines.push(`${pad}${key}: ${typeof value === 'string' ? JSON.stringify(value) : value}`);
      }
    }
  };
  emit(fields, indent);
  lines.push(`${indent}...`);
  return lines.join('\n');
}

const tail = (text, n = verbose ? 80 : 25) => text.trim().split('\n').slice(-n).join('\n');

function certFingerprint() {
  if (!insecure || !existsSync(CERT)) return null;
  // fingerprint256 is the SHA-256 of the DER certificate, as "AB:CD:...".
  return new X509Certificate(readFileSync(CERT)).fingerprint256.replaceAll(':', '').toLowerCase();
}

// Serves the adapter page, Shaka's dist files and the pinned cert hash from
// localhost, which browsers treat as a secure context.
function startServer(fingerprint) {
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.map': 'application/json' };
  const server = createServer((req, res) => {
    const path = normalize(new URL(req.url, 'http://localhost').pathname);
    let file = null;
    if (path === '/' || path === '/index.html') file = join(APP, 'page/index.html');
    else if (path.startsWith('/shaka/')) file = join(SHAKA_DIST, path.slice('/shaka/'.length));
    if (path === '/cert.hex' && fingerprint) {
      res.writeHead(200, { 'content-type': 'text/plain' }).end(fingerprint);
    } else if (file && file.startsWith(APP) && existsSync(file)) {
      res.writeHead(200, { 'content-type': types[extname(file)] || 'application/octet-stream' })
        .end(readFileSync(file));
    } else {
      res.writeHead(404).end();
    }
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// moqxr wants https://host:port/path; browsers accept the URL without either.
function publisherEndpoint(relay) {
  if (!relay.startsWith('https://')) return relay;
  const url = new URL(relay);
  return `https://${url.hostname}:${url.port || 443}${url.pathname}${url.search}`;
}

function startPublisher(relay, draft, namespace) {
  const args = [
    '--input', process.env.MOQXR_FIXTURE || join(APP, 'fixture.mp4'),
    '--endpoint', publisherEndpoint(relay), '--draft', draft, '--namespace', namespace,
    '--publish-catalog', '--catalog-republish-interval', '1',
    '--paced', '--loop', '--forward', '1',
    '--timeout', '15',
  ];
  // moqxr defaults to "cmaf" packaging; MOQXR_PACKAGING=locmaf selects LOCMAF 0.3.
  if (process.env.MOQXR_PACKAGING) args.push('--packaging', process.env.MOQXR_PACKAGING);
  if (relay.startsWith('https://')) args.push('--transport', 'webtransport');
  if (insecure) args.push('--insecure');
  const bin = process.env.MOQXR_BIN || join(APP, 'openmoq-publisher');
  log(`${bin} ${args.join(' ')}`);
  const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  children.add(child);
  child.on('exit', () => children.delete(child));
  const publisher = { child, output: '', exited: null };
  const collect = (chunk) => { publisher.output += chunk; };
  child.stdout.setEncoding('utf8').on('data', collect);
  child.stderr.setEncoding('utf8').on('data', collect);
  child.on('exit', (code, signal) => { publisher.exited = signal || code; });
  child.on('error', (error) => { publisher.output += `\n${error}`; publisher.exited ??= 'spawn error'; });
  return publisher;
}

async function stopPublisher(publisher) {
  if (!publisher || publisher.exited !== null) return;
  const done = new Promise((resolve) => publisher.child.once('exit', resolve));
  publisher.child.kill('SIGTERM');
  if (await Promise.race([done.then(() => true), sleep(3000)])) return;
  publisher.child.kill('SIGKILL');
  await done;
}

async function launchBrowser(name) {
  const entry = BROWSERS[name];
  if (!entry) throw new Error(`unknown BROWSER "${name}" (expected ${Object.keys(BROWSERS).join(', ')})`);
  const playwright = await import('playwright-core');
  const { type, ...launch } = entry;
  try {
    return await playwright[type].launch({ headless: true, ...launch });
  } catch (error) {
    throw new Error(`cannot launch BROWSER "${name}"; is it installed in this image? ${error.message.split('\n')[0]}`);
  }
}

async function runMedia(relay, draft) {
  const started = Date.now();
  const namespace = process.env.MOQ_MEDIA_NAMESPACE || `moq-test/interop/${randomUUID().replaceAll('-', '')}`;
  const browserName = (process.env.BROWSER || 'chromium').toLowerCase();
  const result = { passed: false, frames: 0, stats: {}, message: '', console: [] };
  let publisher = null;
  let server = null;
  let browser = null;
  try {
    const fingerprint = certFingerprint();
    server = await startServer(fingerprint);
    const origin = `http://127.0.0.1:${server.address().port}`;

    // Load the page first so browser startup does not eat into the publisher's run.
    browser = await launchBrowser(browserName);
    result.browserVersion = `${browserName} ${browser.version()}`;
    const page = await browser.newPage();
    page.on('console', (msg) => result.console.push(`${msg.type()}: ${msg.text()}`));
    page.on('pageerror', (error) => result.console.push(`pageerror: ${error.message}`));
    await page.goto(`${origin}/${verbose ? '?debug=1' : ''}`);

    publisher = startPublisher(relay, draft, namespace);
    const deadline = Date.now() + PUBLISHER_WAIT_MS;
    while (!publisher.output.includes(`namespace published namespace=${namespace}`)) {
      if (publisher.exited !== null) throw new Error(`publisher exited ${publisher.exited} before namespace acceptance`);
      if (Date.now() > deadline) throw new Error('publisher did not confirm namespace acceptance');
      await sleep(100);
    }
    log('publisher namespace accepted');

    page.evaluate((o) => window.moqPlayer.start(o).then(() => null, (e) => String(e)), {
      url: relay, namespace, draft, fingerprintUri: fingerprint ? `${origin}/cert.hex` : '',
    }).then((error) => { if (error) result.console.push(`start: ${error}`); }, () => {});

    const playDeadline = Date.now() + PLAY_WINDOW_MS;
    while (Date.now() < playDeadline) {
      await sleep(250);
      result.stats = await page.evaluate(() => window.moqPlayer.stats());
      result.frames = result.stats.framesDecoded || 0;
      if (result.frames >= MIN_FRAMES) break;
      if (publisher.exited !== null) break;
    }
    if (result.frames < MIN_FRAMES) {
      result.message = `decoded ${result.frames} video frames, need ${MIN_FRAMES}`;
    } else if (publisher.exited !== null && publisher.exited !== 0) {
      result.message = `publisher exited ${publisher.exited} during delivery`;
    } else {
      result.passed = true;
    }
  } catch (error) {
    result.message = error.message;
  } finally {
    if (browser) await browser.close().catch(() => {});
    await stopPublisher(publisher);
    if (server) server.close();
  }
  result.duration = Date.now() - started;
  result.publisherOutput = publisher ? publisher.output : '';
  return result;
}

function report(number, testcase, draft, r) {
  console.log(`${r.passed ? 'ok' : 'not ok'} ${number} - ${testcase}`);
  const protocol = r.stats.negotiatedProtocol;
  const failed = !r.passed;
  console.log(yaml({
    duration_ms: r.duration,
    implementation_version: r.stats.playerVersion ? `shaka-player ${r.stats.playerVersion}` : undefined,
    test_spec_revision: 2,
    sessions: protocol ? {
      subscriber: { moqt_version: protocol, transport: 'webtransport-h3', webtransport_protocol: protocol },
    } : undefined,
    requested_draft: `draft-${draft}`,
    frames_decoded: r.frames,
    browser: r.browserVersion,
    player_error: r.stats.error,
    media_state: failed || verbose ? r.stats.media : undefined,
    message: r.message,
    browser_console: (failed || verbose) && r.console.length ? tail(r.console.join('\n')) : undefined,
    publisher_tail: (failed || verbose) && r.publisherOutput ? tail(r.publisherOutput) : undefined,
  }));
}

async function main() {
  if (opts.list) {
    console.log(TESTS.join('\n'));
    return 0;
  }
  const selected = opts.test ? [opts.test] : TESTS;
  console.log('TAP version 14');
  console.log('# Shaka Player (browser) subscriber with moqxr publisher');
  console.log(`# Relay: ${opts.relay}`);
  console.log(`1..${selected.length}`);
  if (opts.test && !TESTS.includes(opts.test)) {
    console.log(`ok 1 - ${opts.test} # SKIP shaka-player client does not implement this test`);
    return 127;
  }
  if (opts.relay.startsWith('moqt://')) {
    selected.forEach((t, i) => console.log(`ok ${i + 1} - ${t} # SKIP browsers support WebTransport (https://) only`));
    return 127;
  }
  const version = process.env.MOQ_CLIENT_VERSION || 'draft-22';
  const draft = version.replace(/^draft-/, '');
  const fail = (reason) => {
    selected.forEach((t, i) => console.log(`not ok ${i + 1} - ${t}`));
    console.log(`# ${reason}`);
    return 1;
  };
  if (!DRAFTS.has(draft)) return fail(`Unsupported draft for shaka-player client: ${version}`);
  if (!opts.relay) return fail('RELAY_URL is required');

  let failures = 0;
  for (const [index, testcase] of selected.entries()) {
    const result = await runMedia(opts.relay, draft);
    report(index + 1, testcase, draft, result);
    failures += !result.passed;
  }
  return failures ? 1 : 0;
}

process.exit(await main());
