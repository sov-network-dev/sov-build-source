// test_trust_gate_1497.js — node 1.4.97 (audit D85/D81): unsigned state, system money ops and validator
// standing are taken only from TRUSTED nodes, judged by the authenticated link id. No network, no DB:
// the real PeerMesh message path (encrypted frame -> verify -> gate -> handler) and the real Ledger
// trust check are driven directly. Every attack is also run against the 1.4.96 code (CONTROL: it must
// get through there, or the refusal proves nothing).
// Run: bash tools/test_mesh/run_unit.sh test_trust_gate_1497.js
'use strict';
const os = require('os'), fs = require('fs'), path = require('path');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
const OLD_MESH = require('path').join(process.env.SOV_BACKUPS || require('path').join(__dirname, '..', '..', '..', 'backups'), 'peer_mesh.js.bak_1497trust_20261014');
const OLD_LEDGER = require('path').join(process.env.SOV_BACKUPS || require('path').join(__dirname, '..', '..', '..', 'backups'), 'ledger.js.bak_1497trust_20261014');

let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };
const NID = (c) => c.repeat(64);
const SELF = NID('e'), TRUSTED = NID('a'), UNTRUSTED = NID('b');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'trust1497-'));
process.env.SOV_DATA_DIR = dir; process.env.SNAP_COMMON = dir;
delete process.env.SOV_TRUSTED_NODES;

const tn = require('./src/network/trusted_nodes.js');
console.log('=== trusted_nodes');
tn._reset();
t('built-in list = the three network servers', tn.list().source === 'default' && tn.list().ids.size === 3);
t('VPS1 trusted by default', tn.isTrusted('374aaebb13df31a7c3a49f05e90e8375d688df84cd73380159e42d69c662764b'));
t('an unknown node is not', !tn.isTrusted(UNTRUSTED));
fs.writeFileSync(path.join(dir, 'trusted_nodes.json'), JSON.stringify([TRUSTED, 'not-an-id']));
tn._reset();
t('trusted_nodes.json overrides the built-in list', tn.isTrusted(TRUSTED) && !tn.isTrusted('374aaebb13df31a7c3a49f05e90e8375d688df84cd73380159e42d69c662764b'));
t('malformed ids in the file are ignored', tn.list().ids.size === 1);
process.env.SOV_TRUSTED_NODES = TRUSTED; tn._reset();
t('SOV_TRUSTED_NODES wins over the file', tn.list().source === 'env' && tn.isTrusted(TRUSTED));
t('a missing id is never trusted', !tn.isTrusted('') && !tn.isTrusted(null));
tn.setSelf(SELF);
t('this node itself is trusted', tn.isTrusted(SELF));

// ── PeerMesh gate ───────────────────────────────────────────────────────────
function meshFrom(modPath) {
  delete require.cache[require.resolve(modPath)];
  const { PeerMesh } = require(modPath);
  const m = new PeerMesh({ nodeId: SELF, publicKey: new Uint8Array(32), sign: () => Buffer.alloc(64) }, {}, {}, null);
  const got = [];
  for (const ty of ['STATE_DELTA_RESPONSE', 'ENROLLMENT_BROADCAST', 'GUARDIAN_SET_BROADCAST', 'VAULT_BROADCAST',
                    'LEDGER_OP', 'POLL_VOTE_BROADCAST', 'MSG_FORWARD']) m.on(ty, (msg, ws) => got.push(ty + '@' + ws._nodeId.slice(0, 1)));
  return { m, got };
}
function frame(ws, obj) {
  const nonce = nacl.randomBytes(nacl.secretbox.nonceLength);
  const box = nacl.secretbox(new Uint8Array(Buffer.from(JSON.stringify({ ...obj, _sig: '00' }))), nonce, ws._linkShared);
  return JSON.stringify({ e: Buffer.concat([Buffer.from(nonce), Buffer.from(box)]).toString('base64') });
}
const link = (id) => ({ _verified: true, _nodeId: id, _peerRole: 'voting', _linkShared: nacl.randomBytes(32) });

function runMesh(modPath, label) {
  const { m, got } = meshFrom(modPath);
  const wT = link(TRUSTED), wU = link(UNTRUSTED);
  for (const ty of ['STATE_DELTA_RESPONSE', 'ENROLLMENT_BROADCAST', 'GUARDIAN_SET_BROADCAST', 'VAULT_BROADCAST']) {
    m._handleMessage(wU, frame(wU, { type: ty, node_id: UNTRUSTED }));
    m._handleMessage(wT, frame(wT, { type: ty, node_id: TRUSTED }));
  }
  // claiming to be the trusted node in the message itself must not help
  m._handleMessage(wU, frame(wU, { type: 'STATE_DELTA_RESPONSE', node_id: TRUSTED }));
  for (const ty of ['LEDGER_OP', 'POLL_VOTE_BROADCAST', 'MSG_FORWARD']) m._handleMessage(wU, frame(wU, { type: ty, node_id: UNTRUSTED }));
  return got;
}
console.log('=== peer mesh gate (1.4.97)');
const g = runMesh('./src/network/peer_mesh.js');
const fromU = (ty) => g.filter(x => x === ty + '@b').length;
t('STATE_DELTA_RESPONSE from an untrusted node dropped', fromU('STATE_DELTA_RESPONSE') === 0, g.join(','));
t('…even when the message claims a trusted node_id', fromU('STATE_DELTA_RESPONSE') === 0);
t('ENROLLMENT_BROADCAST (fake citizens) from an untrusted node dropped', fromU('ENROLLMENT_BROADCAST') === 0);
t('GUARDIAN_SET_BROADCAST from an untrusted node dropped', fromU('GUARDIAN_SET_BROADCAST') === 0);
t('VAULT_BROADCAST from an untrusted node dropped', fromU('VAULT_BROADCAST') === 0);
t('the same four from a trusted node delivered', ['STATE_DELTA_RESPONSE', 'ENROLLMENT_BROADCAST', 'GUARDIAN_SET_BROADCAST', 'VAULT_BROADCAST'].every(ty => g.includes(ty + '@a')));
t('signed traffic from an untrusted node still delivered (ledger op, signed vote, message transport)',
  fromU('LEDGER_OP') === 1 && fromU('POLL_VOTE_BROADCAST') === 1 && fromU('MSG_FORWARD') === 1, g.join(','));
console.log('=== CONTROL: 1.4.96 peer mesh');
const gOld = (() => {
  const copy = path.resolve('./src/network/_control_peer_mesh_1496.js');
  fs.copyFileSync(OLD_MESH, copy);
  try { return runMesh(copy); } finally { fs.unlinkSync(copy); }
})();
t('control: 1.4.96 delivered STATE_DELTA_RESPONSE from the untrusted node', gOld.includes('STATE_DELTA_RESPONSE@b'));
t('control: 1.4.96 delivered ENROLLMENT_BROADCAST from the untrusted node', gOld.includes('ENROLLMENT_BROADCAST@b'));

// ── Ledger ─────────────────────────────────────────────────────────────────
function ledgerFrom(modPath, peers) {
  delete require.cache[require.resolve(modPath)];
  const { Ledger } = require(modPath);
  const db = { validatorsActiveAt: () => [], validatorPub: () => null, operatorOfNode: () => '' };
  const mesh = { activePeers: () => peers.map(id => ({ ws: { _nodeId: id, _peerRole: 'voting' } })), peerPublicKey: () => null };
  return new Ledger(db, { nodeId: SELF, publicKey: new Uint8Array(32) }, mesh);
}
const sysOp = (origin) => ({ op_id: 'payout:x:' + origin.slice(0, 1), kind: 'operator_payout', origin_node: origin, committed_at: Date.now(), moves: [] });
console.log('=== ledger (1.4.97)');
const L = ledgerFrom('./src/protocol/ledger.js', [TRUSTED, UNTRUSTED]);
t('system op from a trusted origin over a trusted link: allowed', L._trustCheck(sysOp(TRUSTED), TRUSTED) === null, L._trustCheck(sysOp(TRUSTED), TRUSTED));
t('system op whose origin is untrusted: refused', L._trustCheck(sysOp(UNTRUSTED), UNTRUSTED) === 'SYSTEM_OP_FROM_UNTRUSTED_NODE');
t('system op CLAIMING a trusted origin, relayed by an untrusted node: refused', L._trustCheck(sysOp(TRUSTED), UNTRUSTED) === 'SYSTEM_OP_FROM_UNTRUSTED_NODE');
t('back-dating does not help', L._trustCheck(Object.assign(sysOp(UNTRUSTED), { committed_at: 1 }), UNTRUSTED) === 'SYSTEM_OP_FROM_UNTRUSTED_NODE');
const vset = L._currentVset();
t('an untrusted voting peer is not in the validator set', vset.includes(TRUSTED) && !vset.includes(UNTRUSTED), vset.map(v => v.slice(0, 1)).join(','));
console.log('=== CONTROL: 1.4.96 ledger');
const copyL = path.resolve('./src/protocol/_control_ledger_1496.js');
fs.copyFileSync(OLD_LEDGER, copyL);
try {
  const Lo = ledgerFrom(copyL, [TRUSTED, UNTRUSTED]);
  t('control: 1.4.96 accepted a system op from an untrusted origin', Lo._trustCheck(sysOp(UNTRUSTED), UNTRUSTED) === null);
  t('control: 1.4.96 counted the untrusted voting peer as a validator', Lo._currentVset().includes(UNTRUSTED));
} finally { fs.unlinkSync(copyL); }

console.log(`\n${pass} passed, ${fail} failed`);
console.log(fail ? 'SOME FAILED' : 'ALL PASS');
process.exit(fail ? 1 : 0);
