// moq-dev-js test client
// MoQT interop test client using @moq/net with the @moq/web-transport polyfill

import { createHash, randomBytes } from "node:crypto";
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
	"subscribe-namespace-lifecycle",
	"subscribe-error",
	"announce-subscribe",
	"subscribe-before-announce",
	"data-subgroup-basic",
] as const;

type TestName = (typeof TESTS)[number];

const TEST_NAMESPACE = "moq-test/interop";
const TEST_TRACK = "test-track";

// The revision of each prose specification this client implements, for tests that declare one.
const SPEC_REVISIONS: Partial<Record<TestName, number>> = {
	"subscribe-namespace-lifecycle": 1,
	"data-subgroup-basic": 2,
};

// A run identifier with 128 bits of entropy, as lowercase hex.
function runId(): string {
	return randomBytes(16).toString("hex");
}

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

function printDiagnostics(
	durationMs: number,
	revision: number | undefined,
	diag: Diagnostics,
) {
	tap("  ---");
	tap(`  duration_ms: ${durationMs}`);
	if (revision !== undefined) {
		tap(`  test_spec_revision: ${revision}`);
	}
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

function printFailureDiagnostics(
	durationMs: number,
	revision: number | undefined,
	message: string,
) {
	tap("  ---");
	tap(`  duration_ms: ${durationMs}`);
	if (revision !== undefined) {
		tap(`  test_spec_revision: ${revision}`);
	}
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
		// Prefer pinning the mounted self-signed cert via serverCertificateHashes.
		// A remote relay mounts none, so skip verification in the polyfill rather
		// than fetch `/certificate.sha256` over http://, which only moq.dev serves.
		const hash = certHash();
		webtransport = hash
			? { serverCertificateHashes: [{ algorithm: "sha-256", value: hash }] }
			: ({
					serverCertificateDisableVerify: true,
				} as ConnectProps["webtransport"]);
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

// Wait for the next announcement of exactly `prefix`, returning whether it is active.
async function nextNamespaceState(
	announced: Moq.Announce.Consumer,
	prefix: Moq.Path.Valid,
	ms: number,
	label: string,
): Promise<boolean> {
	const deadline = Date.now() + ms;
	for (;;) {
		const update = await withTimeout<Moq.Announce.Update | undefined>(
			announced.next(),
			Math.max(deadline - Date.now(), 0),
			label,
		);
		if (!update) throw new Error("namespace subscription closed");
		if (update.prefix === prefix) return update.kind !== "retracted";
	}
}

// Observe NAMESPACE followed by NAMESPACE_DONE for one unique namespace.
async function testSubscribeNamespaceLifecycle(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const namespace = Moq.Path.from(
		`${TEST_NAMESPACE}/subscribe-namespace-lifecycle/${runId()}`,
	);

	// Scoping to the namespace keeps SUBSCRIBE_NAMESPACE off the empty prefix, which drafts
	// before 16 forbid.
	const subConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify),
		2000,
		"subscriber connect",
	);
	const announced = subConn.announced(Moq.Path.Pattern.subtree(namespace));

	const pubOrigin = new Moq.Origin.Producer();
	const broadcast = pubOrigin.createBroadcast(namespace);
	broadcast.announce();
	const pubConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: pubOrigin.consume() }),
		2000,
		"publisher connect",
	);

	if (!(await nextNamespaceState(announced, namespace, 3000, "NAMESPACE"))) {
		throw new Error("received NAMESPACE_DONE before NAMESPACE");
	}
	broadcast.close();
	if (await nextNamespaceState(announced, namespace, 3000, "NAMESPACE_DONE")) {
		throw new Error("received duplicate NAMESPACE before NAMESPACE_DONE");
	}

	announced.close();
	await closeConn(pubConn);
	await closeConn(subConn);
	pubOrigin.close();
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

// The canonical data-subgroup-basic MoQT Test tuple: groups 0-2, objects 0-4 on subgroup 0,
// a 64-byte object 0 then 32-byte objects, 2 ms apart, with no end-of-group markers,
// extensions, or delivery timeout.
const SUBGROUP_BASIC_TUPLE = "moq-test-00/0/0/0/2/4/5/64/32/2/1/1/0/-1/-1/0";
const SUBGROUP_BASIC_GROUPS = 3;
const SUBGROUP_BASIC_OBJECTS = 5;
const SUBGROUP_BASIC_TRACK = "track";

// The payload of one canonical object: MoQT Test fills it with `t`.
function subgroupBasicPayload(object: number): Uint8Array {
	return new Uint8Array(object === 0 ? 64 : 32).fill(0x74);
}

// Wait until a getter reads true, failing after `ms`.
async function waitTrue(
	getter: Moq.Signals.Getter<boolean>,
	ms: number,
	label: string,
): Promise<void> {
	const deadline = Date.now() + ms;
	while (!getter.peek()) {
		const remaining = deadline - Date.now();
		if (remaining <= 0) throw new Error(`timeout after ${ms}ms: ${label}`);
		await Promise.race([getter.changed(), sleep(remaining)]);
	}
}

// Answer the relay's request for the tuple's namespace, then publish the canonical objects
// once both subscriptions are established. Returns the broadcast, which must outlive the
// subscriber's reads.
async function serveSubgroupBasic(
	dynamic: Moq.Origin.Dynamic,
	path: Moq.Path.Valid,
	subscribed: Promise<void>,
): Promise<Moq.Broadcast.Producer> {
	const requests = dynamic.requested();
	const next = await withTimeout<IteratorResult<Moq.Origin.Request>>(
		requests.next(),
		5000,
		"relay requesting the tuple's namespace",
	);
	if (next.done) throw new Error("routing prefix closed");
	const request = next.value;
	if (request.path !== path) {
		request.reject(new Error("not found"));
		throw new Error(`relay requested ${request.path}, expected ${path}`);
	}

	const broadcast = new Moq.Broadcast.Producer();
	const track = broadcast.createTrack(SUBGROUP_BASIC_TRACK);
	request.accept(broadcast);

	// Objects start once both subscriptions are established, as the normal publication flow
	// orders. The relay answers downstream only after the upstream SUBSCRIBE_OK, so waiting
	// for the subscriber's answer keeps object 0 out of that SUBSCRIBE_OK's Largest Location,
	// which would leave the relay to recover it with a joining FETCH.
	await waitTrue(track.used, 5000, "relay subscribing");
	await subscribed;

	for (let sequence = 0; sequence < SUBGROUP_BASIC_GROUPS; sequence++) {
		const group = track.appendGroup();
		for (let object = 0; object < SUBGROUP_BASIC_OBJECTS; object++) {
			if (sequence > 0 || object > 0) await sleep(2);
			group.writeFrame({
				payload: subgroupBasicPayload(object),
				timestamp: Moq.Time.Timestamp.now(),
			});
		}
		group.close();
	}
	track.close();
	return broadcast;
}

// Subscribe to the canonical track through the relay and verify every object it delivers,
// returning how many arrived once the track ends.
async function receiveSubgroupBasic(
	origin: Moq.Origin.Producer,
	path: Moq.Path.Valid,
	established: () => void,
): Promise<number> {
	const requesting = origin.request(path, { announced: true });
	try {
		const broadcast = await waitBroadcast(requesting, 5000);
		// Verified against the expected set, so keep every group however late it lands.
		const subscriber = broadcast
			.track(SUBGROUP_BASIC_TRACK)
			.subscribe({ maxAge: Moq.Time.Milli(10_000) });
		await withTimeout(subscriber.info(), 5000, "SUBSCRIBE_OK");
		established();

		const seen = new Set<string>();
		const failures: string[] = [];
		const delivered = (async () => {
			for (;;) {
				const group = await subscriber.recvGroup();
				if (!group) return;
				for (;;) {
					const frame = await group.readFrameSequence();
					if (!frame) break;
					const at = `(${group.sequence}, ${frame.sequence})`;
					const expected = subgroupBasicPayload(frame.sequence);
					if (
						group.sequence >= SUBGROUP_BASIC_GROUPS ||
						frame.sequence >= SUBGROUP_BASIC_OBJECTS
					) {
						failures.push(`unexpected object ${at}`);
					} else if (seen.has(at)) {
						failures.push(`duplicate object ${at}`);
					} else {
						seen.add(at);
						if (
							frame.payload.length !== expected.length ||
							!frame.payload.every((byte: number) => byte === 0x74)
						) {
							failures.push(
								`object ${at} carried ${frame.payload.length} unexpected bytes`,
							);
						}
					}
				}
			}
		})();
		try {
			await withTimeout(delivered, 10_000, "the track to end");
		} catch (e: unknown) {
			failures.push(e instanceof Error ? e.message : String(e));
		}

		const missing: string[] = [];
		for (let group = 0; group < SUBGROUP_BASIC_GROUPS; group++) {
			for (let object = 0; object < SUBGROUP_BASIC_OBJECTS; object++) {
				if (!seen.has(`(${group}, ${object})`))
					missing.push(`(${group}, ${object})`);
			}
		}
		if (missing.length > 0)
			failures.push(`missing objects ${missing.join(", ")}`);
		if (failures.length > 0) throw new Error(failures.join("; "));

		subscriber.close();
		return seen.size;
	} finally {
		requesting.close();
	}
}

// Publish the routing prefix, serve the canonical tuple beneath it on demand, and verify
// that a second session subscribing through the relay receives exactly that object set.
//
// @moq/net does not surface subgroup IDs, publisher priority, or PUBLISH_DONE, so the
// subscriber checks only what the track exposes: every object, and a clean end. A
// downstream PUBLISH_DONE with an error status aborts the track, which fails the test.
async function testDataSubgroupBasic(
	relayUrl: string,
	tlsDisableVerify: boolean,
): Promise<Diagnostics> {
	const prefix = Moq.Path.from(`moq-test/data-subgroup-basic/${runId()}`);
	const path = Moq.Path.join(prefix, Moq.Path.from(SUBGROUP_BASIC_TUPLE));

	const pubOrigin = new Moq.Origin.Producer();
	const dynamic = pubOrigin.dynamic(prefix);
	const pubConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { publish: pubOrigin.consume() }),
		5000,
		"publisher connect",
	);

	// Asking only for the routing prefix keeps SUBSCRIBE_NAMESPACE off the empty prefix,
	// which drafts before 16 forbid.
	const subRoot = new Moq.Origin.Producer();
	const subOrigin = subRoot.scope(
		Moq.Path.empty(),
		new Moq.Path.Patterns([Moq.Path.Pattern.subtree(prefix)]),
	);
	const subConn = await withTimeout(
		connect(relayUrl, tlsDisableVerify, { consume: subOrigin }),
		5000,
		"subscriber connect",
	);

	let established!: () => void;
	const subscribed = new Promise<void>((resolve) => {
		established = resolve;
	});
	const serving = serveSubgroupBasic(dynamic, path, subscribed);
	// A failed publisher otherwise surfaces only as missing objects.
	await Promise.race([
		receiveSubgroupBasic(subOrigin, path, established),
		serving.then(() => new Promise<never>(() => {})),
	]);

	(await serving).close();
	dynamic.close();
	await closeConn(pubConn);
	await closeConn(subConn);
	pubOrigin.close();
	subRoot.close();
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
tap("# moq-dev-js-client v0.1.0 (@moq/net 0.4.7)");
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
		"subscribe-namespace-lifecycle": 12000,
		"subscribe-error": 2000,
		"announce-subscribe": 3000,
		"subscribe-before-announce": 3500,
		// Two 5 s setup and subscription phases, then 10 s to deliver and drain.
		"data-subgroup-basic": 20000,
	};

	try {
		const testFn = {
			"setup-only": testSetupOnly,
			"announce-only": testAnnounceOnly,
			"publish-namespace-done": testPublishNamespaceDone,
			"subscribe-namespace-lifecycle": testSubscribeNamespaceLifecycle,
			"subscribe-error": testSubscribeError,
			"announce-subscribe": testAnnounceSubscribe,
			"subscribe-before-announce": testSubscribeBeforeAnnounce,
			"data-subgroup-basic": testDataSubgroupBasic,
		}[testName];

		const diag = await withTimeout(
			testFn(args.relay, args.tlsDisableVerify),
			timeouts[testName],
			testName,
		);

		const durationMs = Date.now() - start;
		tap(`ok ${num} - ${testName}`);
		printDiagnostics(durationMs, SPEC_REVISIONS[testName], diag);
	} catch (e: unknown) {
		allPassed = false;
		const durationMs = Date.now() - start;
		tap(`not ok ${num} - ${testName}`);
		printFailureDiagnostics(
			durationMs,
			SPEC_REVISIONS[testName],
			e instanceof Error ? e.message : String(e),
		);
	}
}

// Small delay before exit to let native addon cleanup (avoids Bun segfault)
await new Promise((resolve) => setTimeout(resolve, 50));
process.exit(allPassed ? 0 : 1);
