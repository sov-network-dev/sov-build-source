// Deterministic harness for circuit_relay.js — drives the REAL module through an
// in-process mock mesh + fake N-gateway, validating: register→ack, session open,
// data both directions, and a full citizen round-trip bridged C→R→N→R→C.
global.sovLog = { info(){}, warn(){}, debug(){}, error(){} };
const assert = require('assert');
const { CircuitRelay } = require('./src/network/circuit_relay');

const bus = {}; // nodeId -> { mesh, cr }

function makeMesh(myId) {
  const handlers = new Map();
  return {
    _handlers: handlers,
    _network: { publicAddress: myId + '.local:9000' },
    on(type, fn) { handlers.set(type, fn); },
    sendTo(target, type, payload) {
      const t = bus[target];
      if (!t) return false;
      const fn = t.mesh._handlers.get(type);
      if (fn) setImmediate(() => { try { fn({ type, ...payload, node_id: myId }, null); } catch (e) { console.error('handler err', type, e.message); } });
      return true;
    },
    broadcast() {},
    peerCount() { return Object.keys(bus).length - 1; },
    verifiedPeers() { return Object.keys(bus).filter(id => id !== myId).map(id => ({ node_id: id, address: id + '.local:7771' })); },
  };
}

const R = 'Raaaaaaaaaaaa', N = 'Nbbbbbbbbbbbb';

// N-side fake gateway: emulates the citizen pipeline. Echoes a balance on BALANCE_QUERY.
let nGatewaySawHello = false;
const nGateway = {
  handleVirtualMessage(vws, frame) {
    const m = JSON.parse(frame);
    if (m.op === 'HL' || m.type === 'HELLO') { nGatewaySawHello = true; vws.send(JSON.stringify({ type: 'HELLO_ACK', op: 'HA', ok: true })); return; }
    if (m.op === 'BQ' || m.type === 'BALANCE_QUERY') { vws.send(JSON.stringify({ type: 'SOV_BALANCE_RESULT', op: 'BR', sovereign_id: m.sovereign_id, balance_seeds: 864843995 })); return; }
  },
};
const rGateway = { handleVirtualMessage() { throw new Error('R should never run N-side gateway'); } };

bus[R] = {}; bus[N] = {};
bus[R].mesh = makeMesh(R); bus[N].mesh = makeMesh(N);
bus[R].cr = new CircuitRelay({ peerMesh: bus[R].mesh, identity: { nodeId: R }, gateway: rGateway });
bus[N].cr = new CircuitRelay({ peerMesh: bus[N].mesh, identity: { nodeId: N }, gateway: nGateway });
bus[R].cr.registerHandlers();
bus[N].cr.registerHandlers();

const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  // 1) N registers with R
  const sent = bus[N].cr.registerWithRelays(3);
  assert.strictEqual(sent, 1, 'N should register with 1 relay (R)');
  await sleep(50);
  assert.ok(bus[R].cr._clients.has(N), 'R should now front N');
  assert.ok(bus[N].cr._myRelays.has(R), 'N should have R as a relay');
  console.log('PASS 1: register -> ack (R fronts N, N knows R)');

  // 2) R advertises N as a relayed node in RELAY_LIST
  const entries = bus[R].cr.relayedEntries();
  assert.strictEqual(entries.length, 1);
  assert.strictEqual(entries[0].target_node_id, N);
  assert.strictEqual(entries[0].relayed, true);
  console.log('PASS 2: RELAY_LIST advertises N via R  (target=' + entries[0].relay_id + ', relayed=true)');

  // 3) A citizen connects to R targeting N; bridge a HELLO then a BALANCE_QUERY.
  const citizenGot = [];
  const citizenWs = { readyState: 1, send(d) { citizenGot.push(d); }, on() {} };

  const hello = { op: 'HL', type: 'HELLO', target_node_id: N, sovereign_id: 'SOV-06D08DA3C6DFD90B' };
  assert.strictEqual(bus[R].cr.maybeBridge(citizenWs, hello), true, 'R should bridge HELLO to N');
  await sleep(60);
  assert.ok(nGatewaySawHello, 'N should have processed the bridged HELLO');

  const bq = { op: 'BQ', type: 'BALANCE_QUERY', target_node_id: N, sovereign_id: 'SOV-06D08DA3C6DFD90B' };
  assert.strictEqual(bus[R].cr.maybeBridge(citizenWs, bq), true, 'R should bridge BALANCE_QUERY to N');
  await sleep(60);

  // The citizen should have received HELLO_ACK then the balance — proxied N->R->C.
  const got = citizenGot.map(s => JSON.parse(s));
  assert.ok(got.some(m => m.type === 'HELLO_ACK'), 'citizen should receive HELLO_ACK from N via R');
  const bal = got.find(m => m.type === 'SOV_BALANCE_RESULT');
  assert.ok(bal, 'citizen should receive balance from N via R');
  assert.strictEqual(bal.balance_seeds, 864843995, 'balance value must match N');
  console.log('PASS 3: full round-trip C->R->N->R->C  (citizen got balance ' + (bal.balance_seeds/1e6).toFixed(2) + ' SOV from N, via R)');

  // 4) frames targeting R itself (or unknown) are NOT bridged (handled locally)
  assert.strictEqual(bus[R].cr.maybeBridge(citizenWs, { op: 'BQ', target_node_id: R }), false, 'frame for R itself -> not bridged');
  assert.strictEqual(bus[R].cr.maybeBridge(citizenWs, { op: 'BQ' }), false, 'frame with no target -> not bridged (local)');
  console.log('PASS 4: non-relayed frames pass through to local handling');

  // 5) citizen close tears down the session on both sides
  const session = citizenWs._relaySession;
  bus[R].cr._onClose({ session, node_id: N });
  assert.ok(!bus[R].cr._sessionsR.has(session), 'R session cleaned up on close');
  console.log('PASS 5: session teardown on close');

  console.log('\n✅ ALL CIRCUIT-RELAY TESTS PASSED — register, advertise, bridge, round-trip, isolation, teardown.');
  process.exit(0);
})().catch(e => { console.error('\n❌ TEST FAILED:', e.message); process.exit(1); });
