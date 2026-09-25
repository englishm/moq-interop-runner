// moq-dev-js test client
// MoQT interop test client using @moq/net with the @moq/web-transport polyfill

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import * as Moq from "@moq/net";
import { install } from "@moq/web-transport";

// Redirect all console output to stderr so library debug output
// doesn't corrupt TAP on stdout.
console.log = console.error;
console.debug = console.error;
console.info = console.error;
console.warn = console.error;

// Write TAP output directly to stdout
function tap(line: string) {
	process.stdout.write(`${line}\n`);
}

// Suppress unhandled rejections from async cleanup (e.g. WebTransport polyfill)
process.on("unhandledRejection", (err) => {
	console.error("unhandled rejection:", err);
});

// Install the @moq/web-transport polyfill (QUIC/HTTP3 via a NAPI addon).
// @moq/net's connect() reads globalThis.WebTransport at call time.
install();

const TESTS = [
	"setup-only",
	"announce-only",
	"publish-namespace-done",
	"subscribe-error",
	"announce-subscribe",
	"subscribe-before-announce",
] as const;

type TestName = (typeof TESTS)[number];

const TEST_NAMESPACE = "moq-test/interop";
const TEST_TRACK = "test-track";

interface Args {
	relay: string;
	test?: string;
	list: boolean;
	tlsDisableVerify: boolean;
	verbose: boolean;
}

function parseArgs(): Args {
	const args: Args = {
		relay: "https://localhost:4443",
		list: false,
		tlsDisableVerify: false,
		verbose: false,
	};

	const argv = process.argv.slice(2);
	for (let i = 0; i < argv.length; i++) {
		switch (argv[i]) {
			case "--relay":
			case "-r":
				args.relay = argv[++i];
				break;
			case "--test":
			case "-t":
				args.test = argv[++i];
				break;
			case "--list":
			case "-l":
				args.list = true;
				break;
			case "--tls-disable-verify":
				args.tlsDisableVerify = true;
				break;
			case "--verbose":
			case "-v":
				args.verbose = true;
				break;
		}
	}

	return args;
}

interface Diagnostics {
	connection_id?: string;
	publisher_connection_id?: string;
	subscriber_connection_id?: string;
}

function printDiagnostics(durationMs: number, diag: Diagnostics) {
	tap("  ---");
	tap(`  duration_ms: ${durationMs}`);
	if (diag.connection_id) {
		tap(`  connection_id: ${diag.connection_id}`);
	}
	if (diag.publisher_connection_id) {
		tap(`  publisher_connection_id: ${diag.publisher_connection_id}`);
	}
	if (diag.subscriber_connection_id) {
		tap(`  subscriber_connection_id: ${diag.subscriber_connection_id}`);
	}
	tap("  ...");
}

function printFailureDiagnostics(durationMs: number, message: string) {
	tap("  ---");
	tap(`  duration_ms: ${durationMs}`);
	tap(`  message: "${message.replace(/"/g, '\\"')}"`);
	tap("  ...");
}

function withTimeout<T>(
	promise: Promise<T>,
	ms: number,
	label: string,
): Promise<T> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(
			() => reject(new Error(`timeout after ${ms}ms: ${label}`)),
			ms,
		);
		promise.then(
			(v) => {
				clearTimeout(timer);
				resolve(v);
			},
			(e) => {
				clearTimeout(timer);
				reject(e);
			},
		);
	});
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

// Path to the relay's TLS certificate, mounted by the interop runner following
// the QUIC interop convention (/certs/cert.pem). Override with CERT_PATH.
const CERT_PATH = process.env.CERT_PATH ?? "/certs/cert.pem";

// Compute the SHA-256 of the leaf certificate's DER encoding, suitable for
// WebTransport `serverCertificateHashes`. Returns undefined if no cert is found.
function certHash(): Uint8Array<ArrayBuffer> | undefined {
	let pem: string;
	try {
		pem = readFileSync(CERT_PATH, "utf8");
	} catch {
		return undefined;
	}

	// Use only the first (leaf) certificate block.
	const match = pem.match(
		/-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/,
	);
	if (!match) return undefined;

	const der = Buffer.from(match[1].replace(/\s+/g, ""), "base64");
	return new Uint8Array(createHash("sha256").update(der).digest());
}

type Established = Awaited<ReturnType<typeof Moq.Connection.connect>>;
type ConnectProps = Parameters<typeof Moq.Connection.connect>[0];

interface Ends {
	publish?: Moq.Origin.Consumer;
	consume?: Moq.Origin.Producer;
}

// Connect to the relay, returning an established connection.
async function connect(
	relayUrl: string,
	tlsDisableVerify: boolean,
	ends: Ends = {},
): Promise<Established> {
	const url = new URL(relayUrl);
	let webtransport: ConnectProps["webtransport"];

	if (tlsDisableVerify) {
		// Prefer pinning the mounted self-signed cert via serverCertificateHashes
		// over https://. This works against any relay using that cert, unlike the
		// http:// `/certificate.sha256` fingerprint fetch (a moq.dev-only, non-
		// standard convention). Fall back to that fetch if no cert is mounted.
		const hash = certHash();
		if (hash) {
			webtransport = {
				serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
			};
		} else {
			url.protocol = "http:";
		}
	}

	return await Moq.Connection.connect({
		url,
		webtransport,
		publish: ends.publish,
		consume: ends.consume,
	});
}

// Test implementations

async function closeConn(conn: Established) {
	conn.close();
	await Promise.race([conn.closed, sleep(200)]);
}

// Fail when the session ends during the grace window.
async function assertOpen(conn: Established, ms: number, what: string) {
	const wait = await Promise.race([
		sleep(ms).then(() => "open" as const),
		conn.closed.then((err: Error | null) => err),
	]);
	if (wait !== "open") {
		const message =
			wait instanceof Error ? wait.message : "session closed cleanly";
		throw new Error(`session closed after ${what}: ${message}`);
	}
}

async function waitBroadcast(
	requesting: Moq.Origin.Requesting,
	ms: number,
): Promise<Moq.Broadcast.Consumer> {
	const deadline = Date.now() + ms;
	for (;;) {
		const active = requesting.active.peek();
		if (active) return active;
		if (requesting.unroutable.peek()) {
			throw new Error("broadcast unroutable");
		}
		const remaining = deadline - Date.now();
		if (remaining <= 0) {
			throw new Error(`timeout after ${ms}ms waiting for broadcast`);
		}
		await Promise.race([
			requesting.active.changed(),
			requesting.unroutable.changed(),
			sleep(remaining),
		]);
	}
}

function publishNamespace(track?: string): {
	origin: Moq.Origin.Producer;
	broadcast: Moq.Broadcast.Producer;
} {
	const origin = new Moq.Origin.Producer();
	const broadcast = origin.createBroadcast(Moq.Path.from(TEST_NAMESPACE));
	if (track) {
		broadcast.createTrack(track);
	}
	broadcast.announce();
	return { origin, broadcast };
}

async function testSetupOnly(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const conn = await withTimeout(
		connect(relayUrl, tlsDisableVerify),
		2000,
		"connect",
	);
	await closeConn(conn);
	return {};
}

async function testAnnounceOnly(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const { origin } = publishNamespace();
	const conn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: origin.consume() }),
		2000,
		"connect",
	);

	await assertOpen(conn, 500, "announce");
	await closeConn(conn);
	origin.close();
	return {};
}

async function testPublishNamespaceDone(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const { origin, broadcast } = publishNamespace();
	const conn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: origin.consume() }),
		2000,
		"connect",
	);

	await assertOpen(conn, 500, "announce");

	// Close the broadcast (unpublish / PUBLISH_NAMESPACE_DONE)
	broadcast.close();
	await assertOpen(conn, 200, "unpublish");

	await closeConn(conn);
	origin.close();
	return {};
}

async function testSubscribeError(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const origin = new Moq.Origin.Producer();
	const conn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { consume: origin }),
		2000,
		"connect",
	);

	// Subscribe to a nonexistent namespace. A local refusal, a track reset, or a
	// subscription that closes without data all count. Receiving a group does not.
	const requesting = origin.request(Moq.Path.from("nonexistent/namespace"));
	try {
		const broadcast = await waitBroadcast(requesting, 1500);
		const track = broadcast.track(TEST_TRACK).subscribe().ordered();
		try {
			const group = await withTimeout(
				track.nextGroup(),
				1500,
				"subscribe response",
			);
			if (group) {
				throw new Error(
					"unexpected success: received data from nonexistent namespace",
				);
			}
		} catch (e: unknown) {
			if (e instanceof Error && e.message?.includes("unexpected success")) {
				throw e;
			}
		}
	} catch (e: unknown) {
		if (e instanceof Error && e.message?.includes("unexpected success")) {
			throw e;
		}
	}

	await assertOpen(conn, 300, "subscribe error");
	requesting.close();
	await closeConn(conn);
	origin.close();
	return {};
}

async function testAnnounceSubscribe(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const { origin: pubOrigin, broadcast } = publishNamespace(TEST_TRACK);
	const pubConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: pubOrigin.consume() }),
		2000,
		"publisher connect",
	);

	// Give the relay time to process the announce
	await sleep(300);

	const subOrigin = new Moq.Origin.Producer();
	const subConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { consume: subOrigin }),
		2000,
		"subscriber connect",
	);

	const requesting = subOrigin.request(Moq.Path.from(TEST_NAMESPACE), {
		announced: true,
	});
	const subBroadcast = await waitBroadcast(requesting, 1500);
	const track = subBroadcast.track(TEST_TRACK).subscribe();
	await withTimeout(track.info(), 1500, "subscribe response");

	broadcast.close();
	requesting.close();
	await closeConn(pubConn);
	await closeConn(subConn);
	pubOrigin.close();
	subOrigin.close();

	return {};
}

async function testSubscribeBeforeAnnounce(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	// Subscriber connects first
	const subOrigin = new Moq.Origin.Producer();
	const subConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { consume: subOrigin }),
		2000,
		"subscriber connect",
	);

	const requesting = subOrigin.request(Moq.Path.from(TEST_NAMESPACE), {
		announced: true,
	});

	// Publisher connects 500ms later
	await sleep(500);

	const { origin: pubOrigin, broadcast } = publishNamespace(TEST_TRACK);
	const pubConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: pubOrigin.consume() }),
		2000,
		"publisher connect",
	);

	// Either a late success or a clean error is valid for this ordering.
	try {
		const subBroadcast = await waitBroadcast(requesting, 2000);
		const track = subBroadcast.track(TEST_TRACK).subscribe();
		await Promise.race([track.info(), track.closed, sleep(2000)]);
	} catch {
		// Either outcome is valid
	}

	broadcast.close();
	requesting.close();
	await closeConn(pubConn);
	await closeConn(subConn);
	pubOrigin.close();
	subOrigin.close();

	return {};
}

// Main

const args = parseArgs();

if (args.list) {
	for (const t of TESTS) {
		tap(t);
	}
	process.exit(0);
}

const tests: TestName[] = args.test
	? (() => {
			if (!TESTS.includes(args.test as TestName)) {
				console.error(`Unknown test: ${args.test}`);
				process.exit(127);
			}
			return [args.test as TestName];
		})()
	: [...TESTS];

tap("TAP version 14");
tap("# moq-dev-js-client v0.1.0 (@moq/net 0.4.0)");
tap(`# Relay: ${args.relay}`);
tap(`1..${tests.length}`);

let allPassed = true;

for (let i = 0; i < tests.length; i++) {
	const testName = tests[i];
	const num = i + 1;
	const start = Date.now();

	const timeouts: Record<TestName, number> = {
		"setup-only": 2000,
		"announce-only": 2000,
		"publish-namespace-done": 2000,
		"subscribe-error": 2000,
		"announce-subscribe": 3000,
		"subscribe-before-announce": 3500,
	};

	try {
		const testFn = {
			"setup-only": testSetupOnly,
			"announce-only": testAnnounceOnly,
			"publish-namespace-done": testPublishNamespaceDone,
			"subscribe-error": testSubscribeError,
			"announce-subscribe": testAnnounceSubscribe,
			"subscribe-before-announce": testSubscribeBeforeAnnounce,
		}[testName];

		const diag = await withTimeout(
			testFn(args.relay, args.tlsDisableVerify),
			timeouts[testName],
			testName,
		);

		const durationMs = Date.now() - start;
		tap(`ok ${num} - ${testName}`);
		printDiagnostics(durationMs, diag);
	} catch (e: unknown) {
		allPassed = false;
		const durationMs = Date.now() - start;
		tap(`not ok ${num} - ${testName}`);
		printFailureDiagnostics(
			durationMs,
			e instanceof Error ? e.message : String(e),
		);
	}
}

// Small delay before exit to let native addon cleanup (avoids Bun segfault)
await new Promise((resolve) => setTimeout(resolve, 50));
process.exit(allPassed ? 0 : 1);
