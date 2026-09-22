'use strict';
/**
 * test_builder_registry.js — tier 2 (builder registry + content agreement).
 *
 * Run:  node test_builder_registry.js
 *
 * The cases worth writing down are the ones where a WRONG implementation still looks
 * like it works:
 *   - quorum reached by one party running several builders (sybil)
 *   - a signing gate that lets a content disagreement through
 *   - a refusal whose stated reason reads like an approval
 * The last one was a real bug this file caught: `{ok:false, reason:'…'} ` had the
 * spread after the override, so agreeDigest's 'QUORUM' overwrote the refusal reason.
 * The gate held; the explanation didn't.
 */
const path = require('path');

function loadSqlite() {
  const candidates = [
    'better-sqlite3-multiple-ciphers',
    path.join(__dirname, 'node_modules', 'better-sqlite3-multiple-ciphers'),
    '/snap/sov-relay/current/node_modules/better-sqlite3-multiple-ciphers',
  ];
  for (const c of candidates) {
    try { return require(c); } catch (_) { /* try next */ }
  }
  console.log('SKIP: better-sqlite3-multiple-ciphers not resolvable from here.');
  process.exit(0);
}
const Database = loadSqlite();

global.sovLog = { info: () => {}, warn: () => {}, error: () => {}, debug: () => {} };
const { BuilderRegistry } = require('./src/protocol/builder_registry');

const raw = new Database(':memory:');
raw.exec(`CREATE TABLE sov_operator_registry (
  node_id TEXT PRIMARY KEY, operator_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active');`);
for (const [n, o] of [['n1', 'OP-A'], ['n2', 'OP-B'], ['n3', 'OP-C']]) {
  raw.prepare('INSERT INTO sov_operator_registry (node_id, operator_id, status) VALUES (?,?,?)').run(n, o, 'active');
}

const reg = new BuilderRegistry({ nodeId: 'testnode' }, { _db: raw },
                                { on: () => {}, broadcast: () => {} }, null);
let pass = 0, fail = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}` +
    (ok ? '' : `\n          got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  ok ? pass++ : fail++;
};
const id = (r) => BuilderRegistry.builderId(r);

console.log('=== registration: only EARNED operators may vouch ===');
check('malformed repo rejected', reg.registerBuilder({ githubRepo: 'nope', operatorId: 'OP-A' }).reason, 'BAD_REPO');
check('unearned operator rejected', reg.registerBuilder({ githubRepo: 'x/y', operatorId: 'OP-NOBODY' }).reason, 'OPERATOR_NOT_EARNED');
check('earned operator accepted', reg.registerBuilder({ githubRepo: 'alice/sov-build', operatorId: 'OP-A' }).ok, true);
reg.registerBuilder({ githubRepo: 'bob/sov-build', operatorId: 'OP-B' });
reg.registerBuilder({ githubRepo: 'carol/sov-build', operatorId: 'OP-C' });
check('three builders registered', reg.activeBuilders().length, 3);

const RID = BuilderRegistry.releaseId('1.2.0', 'd0ecc0f5072d87cb');
const base = { release_id: RID, source_root: 'd0ecc0f5072d87cb', toolchain_id: 'tc-pinned',
               config_hash: 'cfg1', build_path: '/sov-apkbuild/proj' };

console.log('\n=== agreement reports the REAL k, never a badge ===');
reg.recordAttestation({ ...base, builder_id: id('alice/sov-build'), content_digest: 'GOOD' });
let a = reg.agreeDigest(RID, 2);
check('one builder -> k=1', a.k, 1);
check('one builder does not reach quorum 2', a.agreed, false);
reg.recordAttestation({ ...base, builder_id: id('bob/sov-build'), content_digest: 'GOOD' });
a = reg.agreeDigest(RID, 2);
check('two distinct operators -> quorum', a.agreed, true);
check('signing gate opens', reg.readyToSign(RID, 2).ok, true);
check('on the agreed digest', reg.readyToSign(RID, 2).digest, 'GOOD');

console.log('\n=== SYBIL: one operator, several builders, still ONE voice ===');
reg.registerBuilder({ githubRepo: 'dave/sov-build', operatorId: 'OP-A' });   // OP-A already has alice
const RID2 = BuilderRegistry.releaseId('1.3.0', 'd0ecc0f5072d87cb');
reg.recordAttestation({ ...base, release_id: RID2, builder_id: id('alice/sov-build'), content_digest: 'D2' });
reg.recordAttestation({ ...base, release_id: RID2, builder_id: id('dave/sov-build'),  content_digest: 'D2' });
check('two builders one operator -> k=1', reg.agreeDigest(RID2, 2).k, 1);
check('signing gate stays shut', reg.readyToSign(RID2, 2).ok, false);

console.log('\n=== CONTENT disagreement refuses even WITH quorum ===');
const RID3 = BuilderRegistry.releaseId('1.4.0', 'd0ecc0f5072d87cb');
reg.recordAttestation({ ...base, release_id: RID3, builder_id: id('alice/sov-build'), content_digest: 'HONEST' });
reg.recordAttestation({ ...base, release_id: RID3, builder_id: id('bob/sov-build'),   content_digest: 'HONEST' });
reg.recordAttestation({ ...base, release_id: RID3, builder_id: id('carol/sov-build'), content_digest: 'HOSTILE' });
check('honest majority still k=2', reg.agreeDigest(RID3, 2).k, 2);
check('disagreement flagged', reg.agreeDigest(RID3, 2).contentDisagreement, true);
check('SIGNING REFUSED', reg.readyToSign(RID3, 2).ok, false);
check('and the reason survives the spread', reg.readyToSign(RID3, 2).reason, 'CONTENT_DISAGREEMENT_REFUSE_TO_SIGN');

console.log('\n=== VERSION disagreement is benign, not an attack ===');
const RID4 = BuilderRegistry.releaseId('1.5.0', 'd0ecc0f5072d87cb');
reg.recordAttestation({ ...base, release_id: RID4, builder_id: id('alice/sov-build'), content_digest: 'X' });
reg.recordAttestation({ ...base, release_id: RID4, builder_id: id('bob/sov-build'),   content_digest: 'X' });
reg.recordAttestation({ ...base, release_id: RID4, builder_id: id('carol/sov-build'),
                        toolchain_id: 'tc-OTHER', content_digest: 'Y' });   // different question
const v = reg.agreeDigest(RID4, 2);
check('matching cohort agrees', v.agreed, true);
check('flagged as VERSION difference', v.versionDisagreement, true);
check('not as a content attack', v.contentDisagreement, false);
check('signing proceeds', reg.readyToSign(RID4, 2).ok, true);

console.log(`\n  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
