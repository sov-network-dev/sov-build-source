// ─────────────────────────────────────────────────────────────────────────────
// LEDGER CERTIFICATES — node 1.4.94 (docs/ledger/SOV_LEDGER_V2_DESIGN.md §3, §6)
// ─────────────────────────────────────────────────────────────────────────────
// Until 1.4.94 a committed op carried no record of who voted for it, so a node
// receiving it could not tell a majority-granted op from one a single node made up.
// Now every owner op carries a CERTIFICATE:
//
//   cert = { vset: [node ids the origin counted], grants: [{ voter, pub, sig }] }
//
// Each grant is the voter's Ed25519 signature (its node identity key — node id is
// sha256(pub)) over the op's exact content. Any node can re-check the certificate
// without trusting the origin:
//   * every counted voter is a node THIS node already knows as an admitted validator,
//     with that same public key — a fresh key made up by the sender counts for nothing;
//   * the set it was counted against is not smaller than the validators this node knows
//     were active when the op was committed (an origin cannot leave honest nodes out);
//   * a majority of NODES granted (so two certificates for one slot always share a node,
//     and every node grants a slot once — the 1.4.90 double-spend guarantee), AND
//   * a majority of OPERATORS granted (one human, one weight — many nodes run by one
//     person do not outvote everyone else). With one operator this is the same as today.
// ─────────────────────────────────────────────────────────────────────────────
'use strict';

const crypto = require('crypto');
const nacl   = require('tweetnacl');

const NETWORK = 'SOV-MAINNET';
const MAX_VSET = 500;

/** Canonical content of an op: everything that decides what money moves where. */
function opContent(op) {
  const mv = (a) => (a || []).map(m => [m.acct ?? m.id ?? m.pool, Math.trunc(m.d || 0)]);
  return JSON.stringify([
    op.op_id, op.kind, op.ref || null,
    op.owner ? [op.owner.acct, op.owner.nonce] : null,
    mv(op.moves), (op.holds || []).map(h => [h.id, Math.trunc(h.d || 0)]),
    (op.pools || []).map(p => [p.pool, Math.trunc(p.d || 0)]),
    op.baseline_nonce ?? null,
  ]);
}

function opHash(op) {
  return crypto.createHash('sha256').update(opContent(op)).digest('hex');
}

/** The exact text a voter signs when it grants an op. */
function grantString(op, voter) {
  const o = op.owner || {};
  return `${NETWORK}|LEDGER-GRANT-v1|${op.op_id}|${o.acct || ''}|${o.nonce ?? ''}|${opHash(op)}|${voter}`;
}

function signGrant(identity, op) {
  const sig = identity.sign(Buffer.from(grantString(op, identity.nodeId), 'utf8'));
  return { voter: identity.nodeId, pub: Buffer.from(identity.publicKey).toString('hex'), sig: Buffer.from(sig).toString('hex') };
}

/** Is this one grant a valid signature by the node it names? (Key-to-id check included.) */
function grantValid(op, g) {
  if (!g || !/^[0-9a-f]{64}$/i.test(g.pub || '') || !/^[0-9a-f]{128}$/i.test(g.sig || '')) return false;
  const pub = Buffer.from(g.pub, 'hex');
  if (crypto.createHash('sha256').update(pub).digest('hex') !== String(g.voter).toLowerCase()) return false;
  try {
    return nacl.sign.detached.verify(Buffer.from(grantString(op, g.voter), 'utf8'), Buffer.from(g.sig, 'hex'), pub);
  } catch (_) { return false; }
}

/**
 * Check an op's certificate from the point of view of the node receiving it.
 * ctx = {
 *   selfId,                          this node's id
 *   knownPub(nodeId) -> hex|null     the public key of an admitted validator this node knows
 *   activeAt(ts) -> [nodeIds]        validators this node knows were active at time ts
 *   selfActiveSince -> ms|0          when this node itself first became a validator (0 = not yet)
 *   operatorOf(nodeId) -> id|''      the operator (enrolled human) behind a node
 *   isVoting(nodeId) -> bool         1.4.96: a voting validator (servers); serving nodes never count
 * }
 * @returns null if valid, otherwise a reason string.
 */
function verifyCertificate(op, ctx) {
  const c = op.cert;
  if (!c || !Array.isArray(c.vset) || !Array.isArray(c.grants)) return 'NO_CERTIFICATE';
  if (c.vset.length === 0 || c.vset.length > MAX_VSET) return 'BAD_VALIDATOR_SET';
  const vset = new Set(c.vset.map(v => String(v).toLowerCase()));
  if (vset.size !== c.vset.length) return 'BAD_VALIDATOR_SET';
  if (!vset.has(String(op.origin_node).toLowerCase())) return 'ORIGIN_NOT_IN_SET';

  // The origin cannot shrink the set: every validator this node knew was active then must be in it,
  // and so must this node itself if it was already a validator.
  const ts = Number(op.committed_at) || 0;
  if (ts > Date.now() + 5 * 60 * 1000) return 'COMMITTED_IN_FUTURE';
  for (const v of ctx.activeAt(ts)) if (!vset.has(v)) return 'VALIDATOR_LEFT_OUT';
  if (ctx.selfActiveSince && ts >= ctx.selfActiveSince + 60 * 1000 && !vset.has(ctx.selfId)) return 'VALIDATOR_LEFT_OUT';

  // 1.4.96: the majority is over the VOTING validators in the set. A serving origin (the desktop app's
  // node) is in the set because it is the origin, but neither its grant nor its seat counts; ids this
  // node does not know as voting validators count for nothing, as before.
  const isVoting = ctx.isVoting || (() => true);
  const counted = new Set([...vset].filter(v => isVoting(v)));
  if (counted.size === 0) return 'NO_VOTING_VALIDATORS';

  // Count only real, known validators' signatures over THIS content.
  const voters = new Set();
  for (const g of c.grants) {
    const v = String(g && g.voter || '').toLowerCase();
    if (!counted.has(v) || voters.has(v)) continue;
    const known = v === ctx.selfId ? ctx.selfPub : ctx.knownPub(v);
    if (!known || known.toLowerCase() !== String(g.pub).toLowerCase()) continue;   // unknown key: counts for nothing
    if (!grantValid(op, g)) continue;
    voters.add(v);
  }
  const needNodes = Math.floor(counted.size / 2) + 1;
  if (voters.size < needNodes) return `NOT_ENOUGH_GRANTS:${voters.size}/${needNodes}`;

  // Operator majority (one human, one weight) — but only over operators the receiver has actually
  // resolved; a 'node:' placeholder (a peer whose operator row has not propagated here) does not count,
  // and with fewer than 2 resolved operators there is no operator constraint (bootstrap; see
  // SOV_LEDGER_V2_DESIGN §5). This matches the origin's own gather rule so a valid cert is not rejected.
  const resolvedOp = (n) => { const o = (ctx.operatorOf(n) || ('node:' + n)).toUpperCase(); return o.startsWith('NODE:') ? null : o; };
  const vsetOps = new Set([...counted].map(resolvedOp).filter(Boolean));
  if (vsetOps.size >= 2) {
    const grantedOps = new Set([...voters].map(resolvedOp).filter(Boolean));
    const needOps = Math.floor(vsetOps.size / 2) + 1;
    if (grantedOps.size < needOps) return `NOT_ENOUGH_OPERATORS:${grantedOps.size}/${needOps}`;
  }
  return null;
}

module.exports = { NETWORK, opContent, opHash, grantString, signGrant, grantValid, verifyCertificate };
