// test_gov_trust_1497.js — node 1.4.97 governance trust model (audit D76, D79, D82, D85), on a real
// encrypted NodeDB with no network. A dishonest PEER is played directly: its messages are handed to
// the same peer handlers the mesh calls, with an authenticated socket ({_nodeId, _peerRole}).
// Every attack is run twice: against the NEW engine (must be refused) and against the 1.4.96 engine
// (CONTROL: must succeed) — a refusal the old code would also have made proves nothing.
// Requests are signed exactly as the wallet signs them (KeyManager.signMessage).
// Run: bash tools/test_mesh/run_unit.sh test_gov_trust_1497.js
'use strict';
const os = require('os'), fs = require('fs'), path = require('path'), crypto = require('crypto');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
// 1.4.97: peers are trusted by their authenticated node id (network/trusted_nodes.js). A, B and S are
// trusted; U1 and U2 are admitted VOTING peers that are not.
const NID = (c) => c.repeat(64);
process.env.SOV_TRUSTED_NODES = [NID('a'), NID('b'), NID('5')].join(',');
const OLD_ENGINE = process.env.OLD_GOV || require('path').join(process.env.SOV_BACKUPS || require('path').join(__dirname, '..', '..', '..', 'backups'), 'governance_engine.js.bak_1497_20261014');

let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };
const sha = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

const alice = nacl.sign.keyPair(), bob = nacl.sign.keyPair(), mallory = nacl.sign.keyPair();
const A = 'SOV-AAAAAAAAAAAAAAAA', B = 'SOV-BBBBBBBBBBBBBBBB', X = 'SOV-XXXXXXXXXXXXXXXX'; // X = never enrolled
const hex = (k) => Buffer.from(k.publicKey).toString('hex');
let nonceSeq = 500;
function walletSend(kp, sid, op, fields, ts = Date.now()) {          // the wallet's send(): returns the raw text
  const m = Object.assign({}, fields, { node_id: sid, timestamp: ts, op });
  const json = JSON.stringify(m);
  const nonce = ++nonceSeq;
  const sig = Buffer.from(nacl.sign.detached(Buffer.from(`${sid}|${nonce}|${ts}||${sha(json)}`, 'utf8'), kp.secretKey)).toString('hex');
  return json.slice(0, -1) + `,"nonce":${nonce},"signature":"${sig}"}`;
}
function asMsg(raw) { const m = JSON.parse(raw); Object.defineProperty(m, '_rawRequest', { value: raw, enumerable: false }); return m; }
const authOf = (raw) => ({ scheme: 'app', raw, signature: JSON.parse(raw).signature });

function freshEngine(modPath, label) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gov1497-' + label + '-'));
  process.env.SOV_DATA_DIR = dir; process.env.SNAP_COMMON = dir;
  for (const k of Object.keys(require.cache)) if (k.includes('storage') && k.endsWith('db.js')) delete require.cache[k];
  const { NodeDB } = require('./src/storage/db.js');
  const db = new NodeDB();
  const handlers = new Map(), sent = [];
  const wsA = { _nodeId: NID('a'), _peerRole: 'voting' }, wsB = { _nodeId: NID('b'), _peerRole: 'voting' };
  const wsS = { _nodeId: NID('5'), _peerRole: 'serving' };
  const wsU1 = { _nodeId: NID('1'), _peerRole: 'voting' }, wsU2 = { _nodeId: NID('2'), _peerRole: 'voting' };
  const mesh = {
    on: (type, h) => handlers.set(type, h), broadcast: (type, m) => sent.push({ type, m }),
    activePeers: () => [{ ws: wsA }, { ws: wsB }, { ws: wsS }, { ws: wsU1 }, { ws: wsU2 }],
  };
  delete require.cache[require.resolve(modPath)];
  const { GovernanceEngine } = require(modPath);
  const eng = new GovernanceEngine({ nodeId: 'NODE-' + label }, db, mesh);   // each simulated node its own identity
  const ins = db._db.prepare('INSERT OR IGNORE INTO sov_enrollments (sovereign_id, public_key_hex, mcc, enrolled_at) VALUES (?, ?, ?, ?)');
  ins.run(A, hex(alice), '234', Date.now()); ins.run(B, hex(bob), '234', Date.now());
  const peer = (type, m, ws = wsA) => handlers.get(type)(Object.assign({ node_id: ws._nodeId }, m), ws);
  const param = (k) => (db._db.prepare('SELECT param_value FROM sov_governance_params WHERE param_key = ?').get(k) || {}).param_value;
  const citizenWs = (sid) => ({ _sovereignId: sid, _verified: true, _legacyMode: false, readyState: 1, out: [], send(s) { this.out.push(JSON.parse(s)); } });
  return { db, eng, peer, param, wsA, wsB, wsS, wsU1, wsU2, sent, citizenWs };
}

function pollRow(over = {}) {
  const now = Date.now();
  return Object.assign({ poll_id: 'P-EVIL', tag: 'quorum_threshold', title: 't', description: '', options: JSON.stringify(['0.01', '0.10']),
    created_by: A, created_at: now, closes_at: now + 60000, closed_at: 0, status: 'open', direction: 'activate', tally: '{}', quorum_required: 0 }, over);
}

function run(label, modPath, isNew) {
  console.log(`\n=== ${label}`);
  const want = (attackBlocked) => (isNew ? attackBlocked : !attackBlocked);   // control: the attack must WORK on old code
  const tag = isNew ? '' : ' (control: 1.4.96 accepts)';

  // D79 — direct activation broadcast of a SECURITY switch by one peer
  let e = freshEngine(modPath, label + '1');
  e.db._db.prepare("INSERT OR REPLACE INTO sov_governance_params (param_key,param_value,activated_at) VALUES ('tx_signature_enforce','reject',0)").run();
  e.peer('GOVERNANCE_PARAM_ACTIVATED', { param_key: 'tx_signature_enforce', param_value: 'log', activated_at: Date.now() });
  t('D79 peer activation of tx_signature_enforce=log refused' + tag, want(e.param('tx_signature_enforce') === 'reject'), e.param('tx_signature_enforce'));
  e.peer('GOVERNANCE_PARAM_ACTIVATED', { param_key: 'tx_fee_rate', param_value: '0.05', activated_at: Date.now() });
  t('D79 peer activation of a votable fee refused' + tag, want(e.param('tx_fee_rate') !== '0.05'), e.param('tx_fee_rate'));

  // D79 — state sync: one peer, security key, far-future stamp
  e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'tx_signature_enforce', param_value: 'log', activated_at: Date.now() + 1e12 }], open_polls: [] });
  t('D79 state sync of a non-votable security key refused' + tag, want(e.param('tx_signature_enforce') === 'reject'), e.param('tx_signature_enforce'));
  // votable key from ONE voting peer
  e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '0.01', activated_at: Date.now() - 1000 }], open_polls: [] });
  t('D79 votable value reported by ONE peer not adopted' + tag, want(e.param('quorum_threshold') !== '0.01'), e.param('quorum_threshold'));
  if (isNew) {
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '0.01', activated_at: Date.now() - 1000 }], open_polls: [] }, e.wsS);
    t('serving node does not make a majority', e.param('quorum_threshold') !== '0.01', e.param('quorum_threshold'));
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '0.05', activated_at: Date.now() - 1000 }], open_polls: [] }, e.wsU1);
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '0.05', activated_at: Date.now() - 1000 }], open_polls: [] }, e.wsU2);
    t('1.4.97: two UNTRUSTED voting peers agreeing do not make a majority', e.param('quorum_threshold') !== '0.05', e.param('quorum_threshold'));
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '0.01', activated_at: Date.now() - 1000 }], open_polls: [] }, e.wsB);
    t('catch-up: the same value from TWO voting peers IS adopted', e.param('quorum_threshold') === '0.01', e.param('quorum_threshold'));
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '99', activated_at: Date.now() }], open_polls: [] }, e.wsA);
    e.peer('GOVERNANCE_STATE_RESPONSE', { params: [{ param_key: 'quorum_threshold', param_value: '99', activated_at: Date.now() }], open_polls: [] }, e.wsB);
    t('out-of-range value never adopted even by a majority', e.param('quorum_threshold') === '0.01', e.param('quorum_threshold'));
  }

  // D85/D79 — forged poll: quorum 0, 1-minute life, no citizen signature
  e = freshEngine(modPath, label + '2');
  e.peer('POLL_CREATE_BROADCAST', { poll: pollRow() });
  const evil = e.db._db.prepare("SELECT * FROM sov_polls WHERE poll_id='P-EVIL'").get();
  t('forged poll (no signature, quorum 0, 1 min) refused' + tag, want(!evil), evil ? 'stored, quorum ' + evil.quorum_required : 'absent');

  // D82 — forged vote relay (no signature) for an ENROLLED citizen
  e.db._db.prepare(`INSERT INTO sov_polls (poll_id,tag,title,description,options,created_by,created_at,closes_at,status,direction,tally,quorum_required)
    VALUES ('P-1','quorum_threshold','t','',?,?,?,?, 'open','activate','{}',1)`).run(JSON.stringify(['0.01', '0.10']), A, Date.now(), Date.now() + 86400000);
  e.peer('POLL_VOTE_BROADCAST', { poll_id: 'P-1', voter_id: B, option: '0.01', voted_at: Date.now() });
  const fv = e.db._db.prepare("SELECT * FROM sov_poll_votes WHERE poll_id='P-1' AND voter_id=?").get(B);
  t('D82 unsigned relayed vote for an enrolled citizen refused' + tag, want(!fv));

  if (isNew) {
    // signed by the wrong key / for another option / genuine
    const rawM = walletSend(mallory, B, 'PV', { poll_id: 'P-1', option: '0.01' });
    e.peer('POLL_VOTE_BROADCAST', { poll_id: 'P-1', voter_id: B, option: '0.01', auth: authOf(rawM) });
    t('vote signed by another key refused', !e.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-1' AND voter_id=?").get(B));
    const rawB = walletSend(bob, B, 'PV', { poll_id: 'P-1', option: '0.10' });
    e.peer('POLL_VOTE_BROADCAST', { poll_id: 'P-1', voter_id: B, option: '0.01', auth: authOf(rawB) });
    t('vote signed for 0.10 but relayed as 0.01 refused', !e.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-1' AND voter_id=?").get(B));
    e.peer('POLL_VOTE_BROADCAST', { poll_id: 'P-1', voter_id: B, option: '0.10', auth: authOf(rawB) });
    t('GENUINE signed relayed vote accepted', !!e.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-1' AND voter_id=? AND option_text='0.10'").get(B));
  }

  // early close by a peer
  e.peer('POLL_CLOSE_BROADCAST', { poll_id: 'P-1', tally: { '0.01': 99 }, winner: '0.01', closed_at: Date.now() });
  const p1 = e.db._db.prepare("SELECT status FROM sov_polls WHERE poll_id='P-1'").get();
  t('peer cannot close a poll before its time' + tag, want(p1.status === 'open'), p1.status);

  // D76 — a vote on THIS node by a session whose key never enrolled
  e = freshEngine(modPath, label + '3');
  e.db._db.prepare(`INSERT INTO sov_polls (poll_id,tag,title,description,options,created_by,created_at,closes_at,status,direction,tally,quorum_required)
    VALUES ('P-2','quorum_threshold','t','',?,?,?,?, 'open','activate','{}',1)`).run(JSON.stringify(['0.01', '0.10']), A, Date.now(), Date.now() + 86400000);
  const xkp = nacl.sign.keyPair();
  const wsX = e.citizenWs(X);
  e.eng.handlePollVote(wsX, asMsg(walletSend(xkp, X, 'PV', { poll_id: 'P-2', option: '0.01' })));
  const xv = e.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-2' AND voter_id=?").get(X);
  t('D76 vote by a never-enrolled key on this node refused' + tag, want(!xv), JSON.stringify(wsX.out[0] || {}));

  // petition signature relayed without the signer's signature
  e.db._db.prepare(`INSERT INTO sov_petitions (petition_id,param_key,direction,title,description,created_by,created_at,expires_at,status,signature_count)
    VALUES ('PET-1','sov_enclave','deactivate','t','',?,?,?, 'open',0)`).run(A, Date.now(), Date.now() + 86400000);
  e.peer('PETITION_SIG_BROADCAST', { petition_id: 'PET-1', signer_id: B, signed_at: Date.now() });
  const ps = e.db._db.prepare("SELECT 1 FROM sov_petition_signatures WHERE petition_id='PET-1' AND signer_id=?").get(B);
  t('unsigned relayed petition signature refused' + tag, want(!ps));

  if (isNew) {
    // HONEST end-to-end on this node: a citizen proposes, two citizens vote, the poll closes, the value applies.
    e = freshEngine(modPath, label + '4');
    e.db._db.prepare("INSERT OR REPLACE INTO sov_governance_params (param_key,param_value,activated_at) VALUES ('min_poll_duration','60',0)").run();
    const wsA = e.citizenWs(A), wsB = e.citizenWs(B);
    e.eng.handlePollCreate(wsA, asMsg(walletSend(alice, A, 'PC', { poll_id: 'P-H', tag: 'quorum_threshold', title: 'q', options: ['0.05', '0.10'], duration_minutes: 60 })));
    t('honest: enrolled citizen creates a poll', (wsA.out[0] || {}).success === true, JSON.stringify(wsA.out[0]));
    const created = e.sent.find(s => s.type === 'POLL_CREATE_BROADCAST');
    t('honest: the poll broadcast carries the creator\'s signed request', !!(created && created.m.poll && created.m.poll.create_auth));
    e.eng.handlePollVote(wsA, asMsg(walletSend(alice, A, 'PV', { poll_id: 'P-H', option: '0.05' })));
    e.eng.handlePollVote(wsB, asMsg(walletSend(bob, B, 'PV', { poll_id: 'P-H', option: '0.05' })));
    const vb = e.sent.filter(s => s.type === 'POLL_VOTE_BROADCAST');
    t('honest: both votes recorded and each broadcast carries its signed request', vb.length === 2 && vb.every(v => v.m.auth && v.m.auth.raw));
    const poll = e.db._db.prepare("SELECT * FROM sov_polls WHERE poll_id='P-H'").get();
    e.eng._closePoll(poll);
    t('honest: this node closes the poll from its own tally and applies 0.05', e.param('quorum_threshold') === '0.05', e.param('quorum_threshold'));

    // the same poll + votes replicated into a SECOND node via the peer handlers are accepted there
    const f = freshEngine(modPath, label + '5');
    f.db._db.prepare("INSERT OR REPLACE INTO sov_governance_params (param_key,param_value,activated_at) VALUES ('min_poll_duration','60',0)").run();
    f.peer('POLL_CREATE_BROADCAST', created.m);
    if (!f.db._db.prepare("SELECT 1 FROM sov_polls WHERE poll_id='P-H'").get()) console.log('    reason: ' + f.eng._acceptPeerPoll(created.m.poll, f.wsA) + ' | create_auth type ' + typeof created.m.poll.create_auth);
    t('replica: a signed poll from a peer is accepted', !!f.db._db.prepare("SELECT 1 FROM sov_polls WHERE poll_id='P-H'").get());
    for (const v of vb) f.peer('POLL_VOTE_BROADCAST', v.m);
    t('replica: both signed votes are accepted', f.db._db.prepare("SELECT COUNT(*) c FROM sov_poll_votes WHERE poll_id='P-H'").get().c === 2);
    const fp = f.db._db.prepare("SELECT * FROM sov_polls WHERE poll_id='P-H'").get();
    if (fp) f.eng._closePoll(fp);
    t('replica: closes from its own tally to the same value', f.param('quorum_threshold') === '0.05', f.param('quorum_threshold'));

    // D85 — raw consensus rows for governance tables are no longer applied; peer column names are not trusted
    const g = freshEngine(modPath, label + '6');
    g.db._db.prepare(`INSERT INTO sov_polls (poll_id,tag,title,description,options,created_by,created_at,closes_at,status,direction,tally,quorum_required)
      VALUES ('P-3','quorum_threshold','t','',?,?,?,?, 'open','activate','{}',1)`).run(JSON.stringify(['0.01', '0.10']), A, Date.now(), Date.now() + 86400000);
    g.db.applyConsensus({ sov_poll_votes: [{ poll_id: 'P-3', voter_id: B, option_text: '0.01', voted_at: Date.now() }] });
    t('D85 raw sov_poll_votes rows from a peer are not applied', !g.db._db.prepare("SELECT 1 FROM sov_poll_votes WHERE poll_id='P-3'").get());
    let threw = false;
    try { g.db.applyConsensus({ sov_profiles: [{ 'x) VALUES (1); --': 1, 'sovereign_id': A }] }); } catch (_) { threw = true; }
    t('D85 a peer-supplied column name is ignored, not built into SQL', !threw);
  }
}

run('NEW engine (repo tree)', path.resolve('./src/protocol/governance_engine.js'), true);
if (fs.existsSync(OLD_ENGINE)) run('CONTROL: 1.4.96 engine', OLD_ENGINE, false);
else { console.log('CONTROL SKIPPED: old engine not found at ' + OLD_ENGINE); fail++; }

console.log(`\n${pass} passed, ${fail} failed`);
console.log(fail ? 'SOME FAILED' : 'ALL PASS');
process.exit(fail ? 1 : 0);
