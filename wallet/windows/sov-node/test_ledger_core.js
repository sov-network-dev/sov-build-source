// test_ledger_core.js — the 1.4.90 ledger rules, on a real (encrypted) NodeDB, no network.
// Run from the node root with the node runtime + vendored modules (see tools/test_mesh/run_unit.sh).
// Every rule is shown twice: the legal case passes AND a violation is refused (a test that only
// ever says yes proves nothing).
'use strict';
const os = require('os'), fs = require('fs'), path = require('path');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-ut-'));
process.env.SOV_DATA_DIR = dir; process.env.SNAP_COMMON = dir;
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const { NodeDB } = require('./src/storage/db.js');
const db = new NodeDB();

let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };
const bal = (id) => (db.readDisc(id) || {}).balance_seeds;
const nonce = (id) => (db.readDisc(id) || {}).nonce;
const pool = (p) => db.getPool(p).remaining_seeds;
let seq = 1;
const op = (o) => ({ origin_node: 'nodeA', seq: seq++, ...o });

// Fund two citizens from the enrolment pool (system ops).
const enr0 = pool('citizen_enrollment');
t('grant applies', db.ledgerApply(op({ op_id: 'g-alice', kind: 'enroll_grant', moves: [{ acct: 'ALICE', d: 1000 }], pools: [{ pool: 'citizen_enrollment', d: -1000 }] })) === 'applied');
db.ledgerApply(op({ op_id: 'g-bob', kind: 'enroll_grant', moves: [{ acct: 'BOB', d: 500 }], pools: [{ pool: 'citizen_enrollment', d: -500 }] }));
t('grant moved pool -> wallet exactly', bal('ALICE') === 1000 && pool('citizen_enrollment') === enr0 - 1500);

// Conservation
t('unbalanced op REFUSED (would mint)', db.ledgerApply(op({ op_id: 'mint', kind: 'x', moves: [{ acct: 'ALICE', d: 999 }] })) === 'error');
t('…and nothing changed', bal('ALICE') === 1000);

// Owner slot voting
t('first grant of (ALICE,#1) to op X', db.ledgerVote('ALICE', 1, 'X', 'nodeA').granted === true);
t('same op X again (another origin) granted', db.ledgerVote('ALICE', 1, 'X', 'nodeB').granted === true);
const y = db.ledgerVote('ALICE', 1, 'Y', 'nodeC');
t('different op Y for the same slot REFUSED', y.granted === false && y.reason === 'SLOT_GRANTED_TO_OTHER_OP', JSON.stringify(y));
t('future slot (#2 before #1) REFUSED', db.ledgerVote('ALICE', 2, 'Z', 'nodeA').reason === 'NONCE_BEHIND');

// Abort: only that origin's grants are released; an aborted op never commits
t('abort X at nodeA', db.ledgerAbort('ALICE', 1, 'X', 'nodeA') === true);
t('Y still refused: X is still granted to nodeB', db.ledgerVote('ALICE', 1, 'Y', 'nodeC').granted === false);
db.ledgerRelease('ALICE', 1, 'X', 'nodeB');
t('after nodeB also releases, Y may be granted', db.ledgerVote('ALICE', 1, 'Y', 'nodeC').granted === true);
t('aborted op X can never be granted again', db.ledgerVote('ALICE', 1, 'X', 'nodeD').reason === 'OP_ABORTED');

// Owner op apply: atomic, nonce-checked, no credit without debit
const pay = (id, n, amt, fee = 1) => op({ op_id: id, kind: 'transfer', owner: { acct: 'ALICE', nonce: n },
  moves: [{ acct: 'ALICE', d: -(amt + fee) }, { acct: 'BOB', d: amt }], pools: [{ pool: 'witness_operator', d: fee }] });
const wo0 = pool('witness_operator');
t('payment #1 applies', db.ledgerApply(pay('Y', 1, 300)) === 'applied');
t('…sender, recipient, fee pool and nonce all moved', bal('ALICE') === 699 && bal('BOB') === 800 && pool('witness_operator') === wo0 + 1 && nonce('ALICE') === 1);
t('a DIFFERENT op for slot #1 is a CONFLICT, not applied', db.ledgerApply(pay('Y2', 1, 300)) === 'conflict' && bal('BOB') === 800);
t('the same op again is a DUPLICATE, applied once', db.ledgerApply({ ...pay('Y', 1, 300), origin_node: 'nodeB', seq: 77 }) === 'duplicate' && bal('BOB') === 800);
t('…and the duplicate\'s (origin, seq) is remembered for the digest', db.ledgerDigest().nodeB === 77);
const over = pay('BIG', 2, 5000);
t('over-spend REFUSED as insufficient', db.ledgerApply(over) === 'insufficient');
t('…NO credit without the debit (recipient unchanged)', bal('BOB') === 800 && bal('ALICE') === 699);
t('slot #3 before #2 is a GAP (held, not applied)', db.ledgerApply(pay('P3', 3, 10)) === 'gap');
db.ledgerHold(pay('P3', 3, 10), 'gap');
t('#2 applies', db.ledgerApply(pay('P2', 2, 10)) === 'applied');
const held = db.ledgerHeld();
t('held #3 then applies in order', held.length === 1 && db.ledgerApply(held[0]) === 'applied' && nonce('ALICE') === 3 && db.ledgerHeld().length === 0);

// Holdings (escrow)
t('escrow list: wallet -> holding', db.ledgerApply(op({ op_id: 'L1', kind: 'escrow_list', owner: { acct: 'BOB', nonce: 1 }, moves: [{ acct: 'BOB', d: -100 }], holds: [{ id: 'escrow:o1', d: 100 }] })) === 'applied' && db.holdingBalance('escrow:o1') === 100);
const rel = (id) => op({ op_id: id, kind: 'escrow_confirm', holds: [{ id: 'escrow:o1', d: -100 }], moves: [{ acct: 'ALICE', d: 99 }], pools: [{ pool: 'witness_operator', d: 1 }] });
t('escrow released once', db.ledgerApply(rel('escrow-release:o1')) === 'applied' && db.holdingBalance('escrow:o1') === 0);
t('a second release of the same escrow is REFUSED (insufficient / duplicate id)', db.ledgerApply(rel('escrow-release:o1-again')) === 'insufficient' && db.ledgerApply(rel('escrow-release:o1')) === 'duplicate');
t('adopt only for an EMPTY holding', db.ledgerApply(op({ op_id: 'ad1', kind: 'escrow_adopt', holds: [{ id: 'escrow:o2', d: 40 }] })) === 'applied'
  && db.ledgerApply(op({ op_id: 'ad2', kind: 'escrow_adopt', holds: [{ id: 'escrow:o2', d: 40 }] })) === 'duplicate');
t('malformed adopt (with a wallet move) REFUSED', db.ledgerApply(op({ op_id: 'ad3', kind: 'escrow_adopt', holds: [{ id: 'escrow:o3', d: 40 }], moves: [{ acct: 'BOB', d: 5 }] })) === 'error');

// Baseline: recorded as applied where it already is; ADDED where it is not
const n0 = db.ledgerRecordBaseline('nodeA');
t('baseline recorded for existing accounts, balances unchanged', n0 >= 2 && bal('ALICE') === 776 && bal('BOB') === 720, `n0=${n0} alice=${bal('ALICE')} bob=${bal('BOB')}`);
t('baseline recorded once only', db.ledgerRecordBaseline('nodeA') === 0);
t('a baseline for a NEW account adds balance and sets the nonce',
  db.ledgerApply({ op_id: 'baseline:CAROL', kind: 'baseline', origin_node: 'nodeB', seq: 900, moves: [{ acct: 'CAROL', d: 250 }], baseline_nonce: 4 }) === 'applied'
  && bal('CAROL') === 250 && nonce('CAROL') === 4);

// Conservation over everything: wallets + holdings + pools = 50M
const w = db._db.prepare('SELECT COALESCE(SUM(balance_seeds),0) s FROM sov_disc').get().s;
const p = db.allPools().reduce((s, x) => s + x.remaining_seeds, 0);
t('wallets + holdings + pools = genesis + baseline-only additions', w + db.totalHoldings() + p === 50_000_000_000_000 + 40 + 250,
  `got ${w + db.totalHoldings() + p}`);

console.log(`\n${pass} passed, ${fail} failed`);
try { db._db.close(); } catch (_) {}
try { require('child_process').execSync(`chattr -i '${dir}'/* 2>/dev/null || true`); fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}   // the node makes its key immutable
process.exit(fail ? 1 : 0);
