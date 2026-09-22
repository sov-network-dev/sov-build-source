// test_circuit_relay_integration.js — 2-node REAL WebSocket integration test.
//
// Topology: C (citizen, plain ws) → R (relay node, :18444) ← N (NAT'd node, :18445)
//           N registers with R via in-process mesh bus (simulates peer mesh signaling)
//           C connects to R and sends a HELLO; R bridges it to N; N responds; C sees it.
//
// This tests the REAL CircuitRelay module with REAL ws sockets — not mocks.
// The peer mesh is still in-process (no actual TCP between R and N) because we're
// testing circuit_relay.js logic, not the mesh transport.  A separate mesh integration
// test would be needed for the full stack.

'use strict';

global.sovLog = { info: () => {}, warn: () => {}, debug: () => {}, error: () => {} };

const assert = require('assert');
const http   = require('http');
const { WebSocketServer, WebSocket } = require('ws');
const { CircuitRelay } = require('./src/network/circuit_relay');

// ── In-process mesh bus ────────────────────────────────────────────────────────
const bus = {};
function makeMesh(myId) {
  const handlers = new Map();
  return {
    _myId: myId,
    on(type, fn)           { handlers.set(type, fn); },
    sendTo(target, type, payload) {
      const t = bus[target];
      if (!t) return false;
      const fn = t.mesh._handlers.get(type);
      if (fn) setImmediate(() => {
        try { fn({ type, ...payload, node_id: myId }, null); }
        catch (e) { console.error(`[mesh] handler err for ${type}:`, e.message); }
      });
      return true;
    },
    broadcast()   {},
    peerCount()   { return Object.keys(bus).filter(id => id !== myId).length; },
    verifiedPeers() {
      return Object.keys(bus)
        .filter(id => id !== myId)
        .map(id => ({ node_id: id, address: `127.0.0.1:18000` }));
    },
    _handlers: handlers,
  };
}

// ── Test state ─────────────────────────────────────────────────────────────────
const R_ID = 'Relay-RRRRRRRR';
const N_ID = 'NATd-NNNNNNNN';
const R_PORT = 18444;

let passCount = 0;
let testsDone = 0;
const TOTAL_TESTS = 5;

function pass(label) { passCount++; testsDone++; console.log(`  [PASS] ${label}`); }
function fail(label, reason) { testsDone++; console.error(`  [FAIL] ${label}: ${reason}`); process.exit(1); }

function timeout(ms, label) {
  return new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`Timeout after ${ms}ms: ${label}`)), ms)
  );
}

// ── Main ───────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n>>> SOV Circuit-Relay Integration Test (2-node real WebSocket)\n');

  // ── Set up R (relay node with WS server) ─────────────────────────────────
  const rMesh = makeMesh(R_ID);
  bus[R_ID] = { mesh: rMesh };

  // Gateway stub for R — R doesn't need to process citizen frames locally;
  // the circuit relay calls maybeBridge() first and returns true for bridged frames.
  const rGateway = {
    handleVirtualMessage() {},  // R never calls this for bridged traffic
    getGovParam(k, d) { return d; },
  };

  const rCR = new CircuitRelay({ peerMesh: rMesh, identity: { nodeId: R_ID }, gateway: rGateway });
  rCR.registerHandlers();

  // WS server for R — citizen clients connect here
  const rServer = http.createServer();
  const rWss = new WebSocketServer({ server: rServer });

  // Track received citizen messages for assertions
  const citizenMsgsAtR = [];

  rWss.on('connection', (ws) => {
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw.toString());
      // R-side: if this is a bridged message, maybeBridge handles it
      if (!rCR.maybeBridge(ws, msg)) {
        // R handles it locally (e.g. HELLO to R itself)
        citizenMsgsAtR.push(msg);
      }
    });
    ws.on('close', () => {});
  });

  await new Promise(resolve => rServer.listen(R_PORT, '127.0.0.1', resolve));
  console.log(`  R node listening on :${R_PORT}`);

  // ── Set up N (NAT'd node — no WS server, fronted by R) ───────────────────
  const nMesh = makeMesh(N_ID);
  bus[N_ID] = { mesh: nMesh };

  // N's gateway stub — receives virtual citizen messages and echoes them back
  const nReceived = [];
  const nGateway = {
    handleVirtualMessage(virtualWs, frameString) {
      const msg = JSON.parse(frameString);
      nReceived.push(msg);
      // Echo response back to citizen
      virtualWs.send(JSON.stringify({ type: 'ECHO', echo: msg.payload, from: 'N' }));
    },
    getGovParam(k, d) { return d; },
  };

  const nCR = new CircuitRelay({ peerMesh: nMesh, identity: { nodeId: N_ID }, gateway: nGateway });
  nCR.registerHandlers();

  // ── Test 1: N registers with R ────────────────────────────────────────────
  console.log('\n>>> Test 1: N registers with R via mesh');
  const regAckP = new Promise(resolve => {
    const orig = nCR._onRegisterAck.bind(nCR);
    nCR._onRegisterAck = (msg) => { orig(msg); resolve(msg); };
  });

  const sent = nCR.registerWithRelays(1);
  assert.strictEqual(sent, 1, 'Should have sent 1 RELAY_REGISTER');

  const ack = await Promise.race([regAckP, timeout(2000, 'RELAY_REGISTER_ACK')]);
  assert.strictEqual(ack.ok, true, 'ACK must have ok:true');
  assert.strictEqual(ack.relay_id, R_ID, 'ACK relay_id must be R');
  assert(nCR._myRelays.has(R_ID), 'N should track R in _myRelays');
  assert(rCR._clients.has(N_ID), 'R should have N in _clients');
  pass('N registered with R, both sides updated');

  // ── Test 2: R lists N as a relayed entry ─────────────────────────────────
  console.log('\n>>> Test 2: R.relayedEntries() includes N');
  const entries = rCR.relayedEntries();
  assert(Array.isArray(entries), 'relayedEntries must return array');
  const nEntry = entries.find(e => e.target_node_id === N_ID);
  assert(nEntry, 'N must appear in relayed entries');
  pass(`relayedEntries() includes N (${entries.length} entry/entries)`);

  // ── Test 3: Citizen connects to R and sends a HELLO directly to R ─────────
  console.log('\n>>> Test 3: Citizen sends non-bridged message to R');
  const cWs = new WebSocket(`ws://127.0.0.1:${R_PORT}`);
  await new Promise((resolve, reject) => {
    cWs.on('open', resolve);
    cWs.on('error', reject);
  });

  cWs.send(JSON.stringify({ type: 'HELLO', payload: 'direct-to-R' }));
  await new Promise(resolve => setTimeout(resolve, 100));
  const direct = citizenMsgsAtR.find(m => m.type === 'HELLO');
  assert(direct, 'R should have received direct HELLO');
  pass('Direct (non-bridged) message handled by R');

  // ── Test 4: Citizen sends message addressed to N — R bridges it ───────────
  console.log('\n>>> Test 4: Citizen message to N is bridged through R');
  const echoP = new Promise(resolve => {
    cWs.on('message', (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.type === 'ECHO') resolve(m);
    });
  });

  cWs.send(JSON.stringify({ type: 'PING', payload: 'hello-N', target_node_id: N_ID }));

  const echo = await Promise.race([echoP, timeout(2000, 'ECHO from N')]);
  assert.strictEqual(echo.from, 'N', 'Echo must come from N');
  assert.strictEqual(echo.echo, 'hello-N', 'Echo payload must match');
  assert(nReceived.some(m => m.payload === 'hello-N'), 'N must have received the bridged frame');
  pass('C→R→N→R→C round-trip bridged correctly');

  // ── Test 5: Session teardown on citizen close ─────────────────────────────
  console.log('\n>>> Test 5: Session teardown when citizen disconnects');
  const sessionsBefore = rCR._sessionsR.size;
  cWs.close();
  await new Promise(resolve => setTimeout(resolve, 200));
  // After close, R should have pruned the session
  assert(rCR._sessionsR.size < sessionsBefore || rCR._sessionsR.size === 0,
    'R should have removed the session after citizen close');
  pass('Session pruned from R after citizen close');

  // ── Cleanup ───────────────────────────────────────────────────────────────
  rServer.close();
  if (nCR._keepaliveT) clearInterval(nCR._keepaliveT);

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log(`\n  ${passCount}/${TOTAL_TESTS} tests passed`);
  if (passCount === TOTAL_TESTS) {
    console.log('\n  RESULT: PASS — circuit-relay 2-node integration verified\n');
  } else {
    console.log('\n  RESULT: FAIL\n');
    process.exit(1);
  }
}

main().catch(e => { console.error('\n  [FATAL]', e.message); process.exit(1); });
