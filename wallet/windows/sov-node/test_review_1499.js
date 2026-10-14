// test_review_1499.js — node 1.4.99: the three real findings of the Gemini review of 1.4.97/1.4.98 (2026-10-14).
//   1. a node now verifies the citizen's signed request on votes/petitions/disputes/juror votes made ON IT
//      (before, only peers re-checked them);
//   2. a node that was away is caught up on open polls' votes and open petitions' signatures, each with proof
//      (before, state sync carried neither, so its counts stayed short for ever);
//   3. a verdict may not leave out a signed juror vote this node holds (before, an origin could drop the
//      dismissal votes and convict with the rest).
// Each is also run against the 1.4.98 engine (CONTROL: the old behaviour must show).
// Run: bash tools/test_mesh/run_unit.sh test_review_1499.js
'use strict';
const os = require('os'), fs = require('fs'), path = require('path'), crypto = require('crypto');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
const BK = process.env.SOV_BACKUPS || path.join(__dirname, '..', '..', '..', 'backups');
const OLD_GOV = path.join(BK, 'governance_engine.js.1498'), OLD_JUS = path.join(BK, 'justice_engine.js.1498');

let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };
const sha = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
let nonceSeq = 7000;
function walletSend(kp, sid, op, fields, ts = Date.now()) {
  const m = Object.assign({}, fields, { node_id: sid, timestamp: ts, op });
  const json = JSON.stringify(m);
  const nonce = ++nonceSeq;
  const sig = Buffer.from(nacl.sign.detached(Buffer.from(`${sid}|${nonce}|${ts}||${sha(json)}`, 'utf8'), kp.secretKey)).toString('hex');
  return json.slice(0, -1) + `,"nonce":${nonce},"signature":"${sig}"}`;
}
function asMsg(raw) { const m = JSON.parse(raw); Object.defineProperty(m, '_rawRequest', { value: raw, enumerable: false }); return m; }
const authOf = (raw) => JSON.stringify({ scheme: 'app', raw, signature: JSON.parse(raw).signature });

const K = {}, ID = {};
for (const n of ['A', 'B', 'M', 'P', 'D', 'J1', 'J2', 'J3', 'J4', 'J5']) { K[n] = nacl.sign.keyPair(); ID[n] = 'SOV-' + n.padEnd(16, 'Z'); }
const NID = (c) => c.repeat(64);
process.env.SOV_TRUSTED_NODES = [NID('a'), NID('b')].join(',');

function freshDb(label) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rev1499-' + label + '-'));
  process.env.SOV_DATA_DIR = dir; process.env.SNAP_COMMON = dir;
  for (const k of Object.keys(require.cache)) if (k.includes('storage') && k.endsWith('db.js')) delete require.cache[k];
  const { NodeDB } = require('./src/storage/db.js');
  const db = new NodeDB();
  const ins = db._db.prepare('INSERT OR IGNORE INTO sov_enrollments (sovereign_id, public_key_hex, mcc, enrolled_at) VALUES (?, ?, ?, ?)');
  for (const n of Object.keys(K)) ins.run(ID[n], Buffer.from(K[n].publicKey).toString('hex'), '234', Date.now());
  return db;
}
function gov(modPath, label) {
  const db = freshDb(label);
  db._db.prepare("INSERT OR REPLACE INTO sov_governance_params (param_key,param_value,activated_at) VALUES ('min_poll_duration','60',0)").run();
  const handlers = new Map(), sent = [];
  const wsA = { _nodeId: NID('a'), _peerRole: 'voting' }, wsB = { _nodeId: NID('b'), _peerRole: 'voting' };
  const mesh = { on: (ty, h) => handlers.set(ty, h), broadcast: (ty, m) => sent.push({ type: ty, m }), activePeers: () => [{ ws: wsA }, { ws: wsB }] };
  delete require.cache[require.resolve(modPath)];
  const { GovernanceEngine } = require(modPath);
  const eng = new GovernanceEngine({ nodeId: 'NODE-' + label }, db, mesh);
  const peer = (ty, m, ws = wsA) => handlers.get(ty)(Object.assign({ node_id: ws._nodeId }, m), ws);
  const cws = (sid) => ({ _sovereignId: sid, _verified: true, _legacyMode: false, readyState: 1, out: [], send(s) { this.out.push(JSON.parse(s)); } });
  return { db, eng, peer, sent, cws };
}
function copyBeside(src, name) {                 // an old engine must sit beside ./owner_auth to load
  const dst = path.resolve('./src/protocol/' + name); fs.copyFileSync(src, dst); return dst;
}

function govRun(modPath, label, isNew) {
  const want = (blocked) => (isNew ? blocked : !blocked);
  const tag = isNew ? '' : ' (control: 1.4.98)';
  console.log(`\n=== governance ${label}`);
  const e = gov(modPath, label);
  const a = e.cws(ID.A);
  e.eng.handlePollCreate(a, asMsg(walletSend(K.A, ID.A, 'PC', { poll_id: 'P-R', tag: 'quorum_threshold', title: 'q', options: ['0.05', '0.10'], duration_minutes: 60 })));
  t('honest poll created' + tag, (a.out[0] || {}).success === true, JSON.stringify(a.out[0]));
  // 1. a vote signed by someone else, on a session that is A's
  const forged = e.cws(ID.B);
  e.eng.handlePollVote(forged, asMsg(walletSend(K.M, ID.B, 'PV', { poll_id: 'P-R', option: '0.10' })));
  const fv = e.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-R' AND voter_id=?").get(ID.B);
  t('1. a local vote whose request the citizen did not sign is refused' + tag, want(!fv), JSON.stringify(forged.out[0]));
  if (!isNew) return;
  // honest votes + petition + signature on node 1
  const b = e.cws(ID.B);
  e.db._db.prepare("DELETE FROM sov_poll_votes WHERE poll_id='P-R' AND voter_id=?").run(ID.B);
  e.eng.handlePollVote(a, asMsg(walletSend(K.A, ID.A, 'PV', { poll_id: 'P-R', option: '0.05' })));
  e.eng.handlePollVote(b, asMsg(walletSend(K.B, ID.B, 'PV', { poll_id: 'P-R', option: '0.05' })));
  t('honest local votes counted', e.db._db.prepare("SELECT COUNT(*) c FROM sov_poll_votes WHERE poll_id='P-R'").get().c === 2);
  const a2 = e.cws(ID.A);
  e.eng.handlePetitionCreate(a2, asMsg(walletSend(K.A, ID.A, 'EC', { petition_id: 'PET-R', param_key: 'sov_enclave', direction: 'deactivate', title: 'g' })));
  t('honest petition created', (a2.out[0] || {}).success === true, JSON.stringify(a2.out[0]));
  e.eng.handlePetitionSign(b, asMsg(walletSend(K.B, ID.B, 'ES', { petition_id: 'PET-R' })));
  t('honest petition signature counted', e.db._db.prepare("SELECT COUNT(*) c FROM sov_petition_signatures WHERE petition_id='PET-R'").get().c === 1);
}

function syncRun(modPath, label, isNew) {
  const tag = isNew ? '' : ' (control: 1.4.98)';
  console.log(`\n=== state sync ${label}`);
  const e = gov(modPath, label + 'src');
  const a = e.cws(ID.A), b = e.cws(ID.B);
  e.eng.handlePollCreate(a, asMsg(walletSend(K.A, ID.A, 'PC', { poll_id: 'P-S', tag: 'quorum_threshold', title: 'q', options: ['0.05', '0.10'], duration_minutes: 60 })));
  e.eng.handlePollVote(a, asMsg(walletSend(K.A, ID.A, 'PV', { poll_id: 'P-S', option: '0.05' })));
  e.eng.handlePollVote(b, asMsg(walletSend(K.B, ID.B, 'PV', { poll_id: 'P-S', option: '0.05' })));
  e.eng.handlePetitionCreate(a, asMsg(walletSend(K.A, ID.A, 'EC', { petition_id: 'PET-S', param_key: 'sov_enclave', direction: 'deactivate', title: 'g' })));
  e.eng.handlePetitionSign(b, asMsg(walletSend(K.B, ID.B, 'ES', { petition_id: 'PET-S' })));
  e.sent.length = 0;
  e.eng._handleStateRequest({ node_id: 'OTHER' }, { _nodeId: NID('b') });
  const resp = (e.sent.find(s => s.type === 'GOVERNANCE_STATE_RESPONSE') || {}).m;
  t('state response produced' + tag, !!resp);
  const f = gov(modPath, label + 'dst');                      // a node that was away: knows nothing
  f.peer('GOVERNANCE_STATE_RESPONSE', resp);
  const votes = f.db._db.prepare("SELECT COUNT(*) c FROM sov_poll_votes WHERE poll_id='P-S'").get().c;
  const sigs = f.db._db.prepare("SELECT COUNT(*) c FROM sov_petition_signatures WHERE petition_id='PET-S'").get().c;
  t('2. the returning node gets the open poll' + tag, !!f.db._db.prepare("SELECT 1 FROM sov_polls WHERE poll_id='P-S'").get());
  t('2. … and both signed votes' + tag, isNew ? votes === 2 : votes === 0, 'votes=' + votes);
  t('2. … and the petition signature' + tag, isNew ? sigs === 1 : sigs === 0, 'sigs=' + sigs);
  if (!isNew) return;
  const bad = JSON.parse(JSON.stringify(resp));
  bad.open_votes = [{ poll_id: 'P-S', voter_id: ID.M, option_text: '0.10', voted_at: Date.now(), vote_auth: resp.open_votes[0].vote_auth }];
  const g = gov(modPath, label + 'bad');
  g.peer('GOVERNANCE_STATE_RESPONSE', bad);
  t('2. a synced vote whose signature is someone else\'s is refused', !g.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE voter_id=?").get(ID.M));
}

function jusRun(modPath, label, isNew) {
  const tag = isNew ? '' : ' (control: 1.4.98)';
  console.log(`\n=== justice ${label}`);
  const db = freshDb(label);
  const validators = new Map();
  db.ledger = { setValidator: (k, fn) => validators.set(k, fn), commitOwnerOp: async () => ({ ok: true }) };
  delete require.cache[require.resolve(modPath)];
  const { JusticeEngine } = require(modPath);
  const eng = new JusticeEngine({ nodeId: 'NODE-J' + label }, db, { on() {}, broadcast() {}, sendTo() {} });
  const v = validators.get('verdict');
  const CASE = 'C-R' + label, AMT = 50000000, FEE = 500000;
  const openAuth = authOf(walletSend(K.P, ID.P, 'DO', { case_id: CASE, defendant_id: ID.D, amount_seeds: AMT }));
  const vote = (n, choice) => ({ juror_id: ID[n], vote: choice, auth: authOf(walletSend(K[n], ID[n], 'DV', { case_id: CASE, vote: choice })) });
  const all = [vote('J1', 'conviction'), vote('J2', 'conviction'), vote('J3', 'conviction'), vote('J4', 'dismissal'), vote('J5', 'dismissal')];
  // this node holds every juror's signed vote (they were broadcast)
  db._db.prepare(`INSERT INTO sov_disputes (case_id, plaintiff_id, defendant_id, amount_seeds, created_at, status) VALUES (?, ?, ?, ?, ?, 'jury_selection')`).run(CASE, ID.P, ID.D, AMT, Date.now());
  for (const x of all) db._db.prepare("INSERT INTO sov_case_jurors (case_id, juror_id, status, invited_at, vote, vote_auth) VALUES (?, ?, 'voted', ?, ?, ?)").run(CASE, x.juror_id, Date.now(), x.vote, x.auth);
  const op = (votes, verdict) => ({ op_id: 'verdict:' + CASE, kind: 'verdict', ref: CASE, holds: [{ id: 'bond:' + CASE, d: -10000000 }],
    moves: verdict === 'convicted' ? [{ acct: ID.P, d: 10000000 }, { acct: ID.D, d: -AMT }, { acct: ID.P, d: AMT }] : [{ acct: ID.D, d: 10000000 }],
    proof: { case: { case_id: CASE, plaintiff_id: ID.P, defendant_id: ID.D, amount_seeds: AMT, open_auth: openAuth }, verdict, votes } });
  const dropped = v(op(all.slice(0, 3), 'convicted'));
  t('3. a "convicted" verdict that drops the two dismissal votes is refused' + tag, isNew ? dropped === 'VERDICT_OMITS_VOTES' : dropped === null, String(dropped));
  if (isNew) {
    const honest = v(op(all, 'dismissed'));
    t('3. the honest verdict with every vote (3 of 5 < 0.67 → dismissed) passes', honest === null, String(honest));
    // a late vote the origin had not seen that does NOT change the outcome must not split the nodes
    // (Gemini follow-up 2026-10-14): proof = J1..J3 conviction; this node also holds J4's conviction.
    const L = 'C-L' + label;
    const openL = authOf(walletSend(K.P, ID.P, 'DO', { case_id: L, defendant_id: ID.D, amount_seeds: AMT }));
    const voteL = (n, choice) => ({ juror_id: ID[n], vote: choice, auth: authOf(walletSend(K[n], ID[n], 'DV', { case_id: L, vote: choice })) });
    const lv = [voteL('J1', 'conviction'), voteL('J2', 'conviction'), voteL('J3', 'conviction'), voteL('J4', 'conviction')];
    for (const x of lv) db._db.prepare("INSERT INTO sov_case_jurors (case_id, juror_id, status, invited_at, vote, vote_auth) VALUES (?, ?, 'voted', ?, ?, ?)").run(L, x.juror_id, Date.now(), x.vote, x.auth);
    const lop = { op_id: 'verdict:' + L, kind: 'verdict', ref: L, holds: [{ id: 'bond:' + L, d: -10000000 }],
      moves: [{ acct: ID.P, d: 10000000 }, { acct: ID.D, d: -AMT }, { acct: ID.P, d: AMT }],
      proof: { case: { case_id: L, plaintiff_id: ID.P, defendant_id: ID.D, amount_seeds: AMT, open_auth: openL }, verdict: 'convicted', votes: lv.slice(0, 3) } };
    const late = v(lop);
    t('3. a verdict missing a late vote that does not change the outcome still passes', late === null, String(late));
    // a local juror vote whose request the juror did not sign
    db._db.prepare(`INSERT INTO sov_disputes (case_id, plaintiff_id, defendant_id, amount_seeds, created_at, status) VALUES ('C-V', ?, ?, 1, ?, 'jury_selection')`).run(ID.P, ID.D, Date.now());
    db._db.prepare("INSERT INTO sov_case_jurors (case_id, juror_id, status, invited_at) VALUES ('C-V', ?, 'accepted', ?)").run(ID.J1, Date.now());
    const ws = { _sovereignId: ID.J1, _verified: true, _legacyMode: false, readyState: 1, out: [], send(s) { this.out.push(JSON.parse(s)); } };
    eng.handleJusticeVote(ws, asMsg(walletSend(K.M, ID.J1, 'DV', { case_id: 'C-V', vote: 'conviction' })));
    const row = db._db.prepare("SELECT vote FROM sov_case_jurors WHERE case_id='C-V' AND juror_id=?").get(ID.J1);
    t('1. a local juror vote the juror did not sign is refused', row.vote === '' || row.vote === null, JSON.stringify(ws.out[0]));
  }
}

govRun('./src/protocol/governance_engine.js', 'new', true);
syncRun('./src/protocol/governance_engine.js', 'new', true);
jusRun('./src/protocol/justice_engine.js', 'new', true);
const og = copyBeside(OLD_GOV, '_control_gov_1498.js'), oj = copyBeside(OLD_JUS, '_control_jus_1498.js');
try {
  govRun(og, 'old', false);
  syncRun(og, 'old', false);
  jusRun(oj, 'old', false);
} finally { fs.unlinkSync(og); fs.unlinkSync(oj); }
console.log(`\n${pass} passed, ${fail} failed`);
console.log(fail ? 'SOME FAILED' : 'ALL PASS');
process.exit(fail ? 1 : 0);
