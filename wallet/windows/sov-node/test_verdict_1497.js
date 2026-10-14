// test_verdict_1497.js — node 1.4.97 (audit D80): a verdict moves a defendant's money, so every node
// re-checks it from a self-contained proof (the plaintiff's signed filing + each juror's signed vote)
// before granting or applying it. Real NodeDB, no network; requests signed exactly as the wallet signs.
// CONTROL: the 1.4.96 engine registers NO verdict validator at all (peers applied any verdict).
// Run: bash tools/test_mesh/run_unit.sh test_verdict_1497.js
'use strict';
const os = require('os'), fs = require('fs'), path = require('path'), crypto = require('crypto');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
const OLD_JUSTICE = require('path').join(process.env.SOV_BACKUPS || require('path').join(__dirname, '..', '..', '..', 'backups'), 'justice_engine.js.bak_1497_20261014');

let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };
const sha = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
let nonceSeq = 900;
function walletSend(kp, sid, op, fields, ts = Date.now()) {
  const m = Object.assign({}, fields, { node_id: sid, timestamp: ts, op });
  const json = JSON.stringify(m);
  const nonce = ++nonceSeq;
  const sig = Buffer.from(nacl.sign.detached(Buffer.from(`${sid}|${nonce}|${ts}||${sha(json)}`, 'utf8'), kp.secretKey)).toString('hex');
  return json.slice(0, -1) + `,"nonce":${nonce},"signature":"${sig}"}`;
}
const authOf = (raw) => JSON.stringify({ scheme: 'app', raw, signature: JSON.parse(raw).signature });

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'verdict1497-'));
process.env.SOV_DATA_DIR = dir; process.env.SNAP_COMMON = dir;
const { NodeDB } = require('./src/storage/db.js');
const db = new NodeDB();
const validators = new Map();
db.ledger = { setValidator: (k, fn) => validators.set(k, fn) };     // capture what the engine registers
const mesh = { on() {}, broadcast() {}, sendTo() {} };
const { JusticeEngine } = require('./src/protocol/justice_engine.js');
const eng = new JusticeEngine({ nodeId: 'NODE-J' }, db, mesh);

const kp = {}; const ids = {};
for (const n of ['P', 'D', 'J1', 'J2', 'J3', 'EVE']) { kp[n] = nacl.sign.keyPair(); ids[n] = 'SOV-' + n.padEnd(16, 'X'); }
const ins = db._db.prepare('INSERT OR IGNORE INTO sov_enrollments (sovereign_id, public_key_hex, mcc, enrolled_at) VALUES (?, ?, ?, ?)');
for (const n of ['P', 'D', 'J1', 'J2', 'J3', 'EVE']) ins.run(ids[n], Buffer.from(kp[n].publicKey).toString('hex'), '234', Date.now());

const CASE = 'C-1497', AMT = 50000000, BOND = 10000000, FEE = 500000;
const openAuth = authOf(walletSend(kp.P, ids.P, 'DO', { case_id: CASE, defendant_id: ids.D, amount_seeds: AMT }));
const vote = (n, v, caseId = CASE, signer = n) => ({ juror_id: ids[n], vote: v, auth: authOf(walletSend(kp[signer], ids[n], 'DV', { case_id: caseId, vote: v })) });
function verdictOp(over = {}, proofOver = {}) {
  const op = Object.assign({
    op_id: 'verdict:' + CASE, kind: 'verdict', ref: CASE,
    holds: [{ id: 'bond:' + CASE, d: -BOND }],
    moves: [{ acct: ids.P, d: BOND }, { acct: ids.D, d: -AMT }, { acct: ids.P, d: AMT },
            { acct: ids.D, d: -FEE }, { acct: ids.J1, d: FEE }, { acct: ids.D, d: -FEE }, { acct: ids.J2, d: FEE }, { acct: ids.D, d: -FEE }, { acct: ids.J3, d: FEE }],
  }, over);
  op.proof = Object.assign({
    case: { case_id: CASE, plaintiff_id: ids.P, defendant_id: ids.D, amount_seeds: AMT, open_auth: openAuth },
    verdict: 'convicted',
    votes: [vote('J1', 'conviction'), vote('J2', 'conviction'), vote('J3', 'conviction')],
  }, proofOver);
  return op;
}

console.log('=== 1.4.97 verdict validator');
const v = validators.get('verdict');
t('the engine registers a verdict validator with the ledger', typeof v === 'function');
t('GENUINE conviction (signed filing + 3 signed juror votes) passes', v(verdictOp()) === null, v(verdictOp()));
t('no proof at all refused', v(Object.assign(verdictOp(), { proof: undefined })) === 'VERDICT_NO_PROOF');
const forgedVote = verdictOp({}, { votes: [vote('J1', 'conviction'), vote('J2', 'conviction', CASE, 'EVE'), vote('J3', 'conviction')] });
t('a juror vote signed by someone else refused', /^VERDICT_VOTE_/.test(v(forgedVote) || ''), v(forgedVote));
const otherCase = verdictOp({}, { votes: [vote('J1', 'conviction'), vote('J2', 'conviction', 'C-OTHER'), vote('J3', 'conviction')] });
t('a juror vote from another case refused', /^VERDICT_VOTE_/.test(v(otherCase) || ''), v(otherCase));
t('too few jurors refused', v(verdictOp({}, { votes: [vote('J1', 'conviction'), vote('J2', 'conviction')] })) === 'VERDICT_TOO_FEW_JURORS');
const notFollow = verdictOp({}, { votes: [vote('J1', 'conviction'), vote('J2', 'dismissal'), vote('J3', 'dismissal')] });
t('a "convicted" that the votes do not support refused', v(notFollow) === 'VERDICT_DOES_NOT_FOLLOW', v(notFollow));
t('a party sitting as juror refused', v(verdictOp({}, { votes: [vote('J1', 'conviction'), vote('J2', 'conviction'), { ...vote('J3', 'conviction'), juror_id: ids.D }] })) === 'VERDICT_PARTY_AS_JUROR');
const stranger = verdictOp({ moves: [{ acct: ids.D, d: -AMT }, { acct: ids.EVE, d: AMT }] });
t('money sent to someone outside the case refused', v(stranger) === 'VERDICT_PAYS_A_STRANGER', v(stranger));
const tooMuch = verdictOp({ moves: [{ acct: ids.D, d: -(AMT * 10) }, { acct: ids.P, d: AMT * 10 }] });
t('taking more than the disputed sum + juror fees refused', v(tooMuch) === 'VERDICT_TAKES_TOO_MUCH', v(tooMuch));
const forgedFiling = verdictOp({}, { case: { case_id: CASE, plaintiff_id: ids.P, defendant_id: ids.D, amount_seeds: AMT * 100, open_auth: openAuth } });
t('a filing whose amount differs from what the plaintiff signed refused', /^VERDICT_FILING_/.test(v(forgedFiling) || ''), v(forgedFiling));
const dismissedPays = verdictOp({ moves: [{ acct: ids.D, d: -AMT }, { acct: ids.P, d: AMT }] },
  { verdict: 'dismissed', votes: [vote('J1', 'dismissal'), vote('J2', 'dismissal'), vote('J3', 'dismissal')] });
t('a dismissal that takes the defendant\'s money refused', v(dismissedPays) === 'VERDICT_DISMISSED_BUT_DEFENDANT_PAYS', v(dismissedPays));
const genuineDismissal = verdictOp({ moves: [{ acct: ids.J1, d: FEE }, { acct: ids.J2, d: FEE }, { acct: ids.J3, d: FEE }, { acct: ids.D, d: BOND - 3 * FEE }] },
  { verdict: 'dismissed', votes: [vote('J1', 'dismissal'), vote('J2', 'dismissal'), vote('J3', 'dismissal')] });
t('GENUINE dismissal (bond paid to jurors + defendant) passes', v(genuineDismissal) === null, v(genuineDismissal));

console.log('=== peer handlers');
eng._handleCaseBroadcast({ dispute: { case_id: 'C-FAKE', plaintiff_id: ids.P, defendant_id: ids.D, amount_seeds: 1, created_at: Date.now() }, node_id: 'PEER' });
t('a replicated case without the plaintiff\'s signed filing refused', !db._db.prepare("SELECT 1 FROM sov_disputes WHERE case_id='C-FAKE'").get());
eng._handleCaseBroadcast({ dispute: { case_id: CASE, plaintiff_id: ids.P, defendant_id: ids.D, amount_seeds: AMT, created_at: Date.now(), status: 'convicted', open_auth: openAuth }, node_id: 'PEER' });
const row = db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(CASE);
t('a genuinely filed case replicates', !!row);
t('…and its status starts fresh (a peer cannot hand over a decided case)', row && row.status === 'jury_selection', row && row.status);
db._db.prepare("INSERT INTO sov_case_jurors (case_id, juror_id, status, invited_at) VALUES (?, ?, 'accepted', ?)").run(CASE, ids.J1, Date.now());
eng._handleVoteBroadcast({ case_id: CASE, juror_id: ids.J1, vote: 'conviction', node_id: 'PEER' });
t('an unsigned relayed juror vote refused', db._db.prepare('SELECT vote FROM sov_case_jurors WHERE case_id=? AND juror_id=?').get(CASE, ids.J1).vote === '');
const jv = vote('J1', 'conviction');
eng._handleVoteBroadcast({ case_id: CASE, juror_id: ids.J1, vote: 'conviction', auth: jv.auth, node_id: 'PEER' });
t('a signed relayed juror vote is recorded', db._db.prepare('SELECT vote FROM sov_case_jurors WHERE case_id=? AND juror_id=?').get(CASE, ids.J1).vote === 'conviction');

console.log('=== CONTROL: 1.4.96 justice engine');
if (fs.existsSync(OLD_JUSTICE)) {
  const vOld = new Map();
  const db2 = { _db: db._db, ledger: { setValidator: (k, fn) => vOld.set(k, fn) }, getEnrollment: db.getEnrollment.bind(db) };
  const oldCopy = path.resolve('./src/protocol/_control_justice_1496.js');      // beside ./owner_auth, as it was shipped
  fs.copyFileSync(OLD_JUSTICE, oldCopy);
  const { JusticeEngine: Old } = require(oldCopy);
  fs.unlinkSync(oldCopy);
  new Old({ nodeId: 'NODE-OLD' }, db2, mesh);
  t('control: 1.4.96 registered NO verdict validator (peers applied any verdict)', !vOld.has('verdict'));
} else { fail++; console.log('  FAIL control: old engine missing'); }

console.log(`\n${pass} passed, ${fail} failed`);
console.log(fail ? 'SOME FAILED' : 'ALL PASS');
process.exit(fail ? 1 : 0);
