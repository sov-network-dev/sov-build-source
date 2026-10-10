// ─────────────────────────────────────────────────────────────────────────────
// OWNER AUTH — every node checks the CITIZEN'S OWN signed request (node 1.4.95)
// ─────────────────────────────────────────────────────────────────────────────
// A citizen's own money moves only by an owner op (ledger.js): a majority of nodes must grant the
// (account, nonce) slot. Until 1.4.95 the other nodes checked the citizen's signature only for a
// TRANSFER. For a vault lock, an exchange listing, a dispute or Academy bond and the platform fee they
// granted the slot on the connected node's word — so a dishonest node could lock or list a citizen's
// SOV that the citizen never asked to move (it could not mint or double-spend: the slot and the
// balance check stop that).
//
// Now the connected node carries the citizen's signed request INSIDE the op (op.auth) and every node,
// before it grants and again before it applies, checks for itself:
//   1. the signature verifies under the citizen's ENROLLED key;
//   2. the request was signed by the account the op debits;
//   3. the request is the operation this kind of op performs (e.g. 'VL' for vault_lock);
//   4. the debit is exactly what the citizen signed (or, for fees/bonds, the governance value);
//   5. the op's reference is the one the citizen named, where the request names one;
//   6. the request is fresh;
//   7. the op id is DERIVED from the signature, so one signed request can move money at most once —
//      a replay is the same op id, which the ledger refuses as a duplicate. The op id is inside every
//      node's signed grant, so the request cannot be swapped after the grants were given.
//
// Request formats verified:
//   'app'      — every request the wallet sends is signed by KeyManager.signMessage:
//                Ed25519( node_id | nonce | timestamp | type | sha256(JSON of the request without
//                nonce/signature) ). The app removes `type` before signing, so `type` is ''.
//                The request travels as the RAW text the node received, so the JSON hash is checked
//                on the exact bytes the wallet produced (a re-serialised object would turn 5.0 into 5).
//   'platform' — /sov-platform/register's own canonical string (relay_pool.js _doPlatformRegister).
//
// Not covered here: 'transfer' keeps its own validator (transfer_engine.js), and 'verdict' is not a
// citizen's request at all — a jury decides it; re-deriving it on every node is SOV_LEDGER_V2_DESIGN
// §5 (slow path), still open.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const { NodeIdentity } = require('../security/node_identity');

const FRESH_MS = 5 * 60 * 1000;
const SEEDS = 1_000_000;

const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const int = (v) => Math.trunc(Number(v) || 0);

// kind -> what the citizen must have signed. `debit(req, param)` = seeds leaving the citizen's wallet.
const RULES = {
  vault_lock:           { op: 'VL', type: 'VAULT_LOCK',        debit: (r) => int(r.amount_seeds),
                          ref: (r, op) => r.vault_id === op.ref },
  alloc_lock:           { op: 'OC', type: 'ALLOCATION_CREATE', debit: (r) => int(r.amount_seeds) },
  escrow_list:          { op: 'XL', type: 'EXCHANGE_LIST_ORDER', debit: (r) => Math.round(Number(r.sov_amount) || 0),
                          ref: (r, op) => !r.order_id || r.order_id === op.ref },
  dispute_bond:         { op: 'DO', type: 'DISPUTE_OPEN',      debit: (r, p) => parseInt(p('dispute_bond_amount', '10')) * SEEDS,
                          ref: (r, op) => r.case_id === op.ref },
  academy_article_bond: { op: 'AP', type: 'ACADEMY_PUBLISH',   debit: (r, p) => parseInt(p('academy_article_bond', '5')) * SEEDS,
                          ref: (r, op) => r.article_id === op.ref },
  academy_upvote_bond:  { op: 'AU', type: 'ACADEMY_UPVOTE',    debit: (r, p) => parseInt(p('academy_upvote_bond', '1')) * SEEDS,
                          ref: (r, op) => `${r.article_id}:${op.owner.acct}` === op.ref },
  platform_fee:         { scheme: 'platform', debit: (r, p) => Math.round(parseFloat(p('platform_register_fee', '10')) * SEEDS),
                          ref: (r, op) => platformIdOf(r.domain) === op.ref },
};

function platformDomain(domain) {
  return String(domain || '').toLowerCase().replace(/^https?:\/\//, '').split('/')[0];
}
function platformIdOf(domain) {
  return crypto.createHash('sha256').update(platformDomain(domain)).digest('hex').substring(0, 32);
}

/** The op id a signed request produces. One request, one op id — so it can move money once. */
function opIdFor(auth) {
  return 'req-' + sha256(String(auth && auth.signature || '')).slice(0, 40);
}

/** Build op.auth from a request a citizen sent over the gateway (msg carries its raw text). */
function fromAppRequest(msg) {
  const raw = msg && msg._rawRequest;
  if (typeof raw !== 'string' || !msg.signature) return null;
  return { scheme: 'app', raw, signature: String(msg.signature) };
}

/** Build op.auth from a platform registration (its own signed canonical fields). */
function fromPlatformRegister(input) {
  const { domain, return_url, registering_sovereign_id, x25519_pubkey_hex, timestamp, signature } = input || {};
  return { scheme: 'platform', domain, return_url, registering_sovereign_id, x25519_pubkey_hex, timestamp, signature: String(signature || '') };
}

function _verifyApp(auth, pubHex) {
  let req;
  try { req = JSON.parse(auth.raw); } catch (_) { return { reason: 'AUTH_UNREADABLE' }; }
  if (!req || typeof req !== 'object') return { reason: 'AUTH_UNREADABLE' };
  if (String(req.signature || '') !== auth.signature) return { reason: 'AUTH_SIGNATURE_MISMATCH' };
  if (req.nonce == null || !req.timestamp || !req.node_id) return { reason: 'AUTH_FIELDS_MISSING' };

  // The JSON the wallet hashed: the request before nonce + signature were added. Tried on the raw bytes
  // first (exact), then re-serialised (for a key order the regex does not cover).
  const payloads = [];
  const tail = /,"nonce":-?\d+,"signature":"[0-9a-fA-F]+"\}\s*$/;
  if (tail.test(auth.raw)) payloads.push(auth.raw.replace(tail, '}'));
  const obj = Object.assign({}, req); delete obj.nonce; delete obj.signature;
  payloads.push(JSON.stringify(obj));

  const pub = Buffer.from(String(pubHex), 'hex');
  const sig = Buffer.from(auth.signature, 'hex');
  for (const p of payloads) {
    const input = `${req.node_id}|${req.nonce}|${req.timestamp}|${req.type || ''}|${sha256(p)}`;
    let ok = false;
    try { ok = NodeIdentity.verify(Buffer.from(input, 'utf8'), sig, pub); } catch (_) { ok = false; }
    if (ok) return { req, signer: req.node_id, ts: Number(req.timestamp) };
  }
  return { reason: 'AUTH_SIGNATURE_INVALID' };
}

function _verifyPlatform(auth, pubHex) {
  const canonical = `sov-platform-register-v1|${platformDomain(auth.domain)}|${auth.return_url}|` +
                    `${auth.registering_sovereign_id}|${auth.x25519_pubkey_hex}|${auth.timestamp}`;
  let ok = false;
  try {
    ok = NodeIdentity.verify(Buffer.from(canonical, 'utf8'), Buffer.from(auth.signature, 'hex'), Buffer.from(String(pubHex), 'hex'));
  } catch (_) { ok = false; }
  return ok ? { req: auth, signer: auth.registering_sovereign_id, ts: Number(auth.timestamp) }
            : { reason: 'AUTH_SIGNATURE_INVALID' };
}

/**
 * Why this owner op must NOT be granted/applied (null = the citizen really asked for exactly this).
 * @param op      the ledger op (owner op)
 * @param ctx     { pubKeyOf(acct) -> hex|null, param(key, fallback) -> string, now }
 *                now = Date.now() when voting; op.committed_at when applying a committed op.
 *                atApply = true when applying a committed op (fee/bond amounts proven by its certificate).
 */
function check(op, ctx) {
  const rule = RULES[op.kind];
  if (!rule) return null;                                        // not a citizen-requested kind (see header)
  const auth = op.auth;
  if (!auth || !auth.signature) return 'AUTH_MISSING';
  if (op.op_id !== opIdFor(auth)) return 'AUTH_OP_ID_MISMATCH';
  if ((rule.scheme || 'app') !== auth.scheme) return 'AUTH_WRONG_SCHEME';

  const acct = op.owner && op.owner.acct;
  const pub = acct ? ctx.pubKeyOf(acct) : null;
  if (!pub) return 'AUTH_NOT_ENROLLED';
  const v = auth.scheme === 'platform' ? _verifyPlatform(auth, pub) : _verifyApp(auth, pub);
  if (v.reason) return v.reason;
  if (v.signer !== acct) return 'AUTH_WRONG_SIGNER';

  const req = v.req;
  if (rule.op && req.op !== rule.op && req.type !== rule.type) return 'AUTH_WRONG_OPERATION';

  if (ctx.now && Math.abs(ctx.now - v.ts) > FRESH_MS) return 'AUTH_STALE';

  const debits = (op.moves || []).filter(m => m.acct === acct);
  if (debits.length !== 1 || !(debits[0].d < 0)) return 'AUTH_AMOUNT_MISMATCH';
  // A fee/bond is the governance value at the moment the nodes GRANTED it. When a committed op is
  // replayed later (a joining node), that value may have been voted to something else since — the
  // majority certificate already proves it was right then, so only a signed amount is re-checked.
  const byParam = rule.debit.length > 1;
  if (!(ctx.atApply && byParam)) {
    const want = rule.debit(req, ctx.param);
    if (!(want > 0) || debits[0].d !== -want) return 'AUTH_AMOUNT_MISMATCH';
  }
  if ((op.moves || []).some(m => m.acct !== acct && m.d < 0)) return 'AUTH_DEBITS_SOMEONE_ELSE';
  if (rule.ref && !rule.ref(req, op)) return 'AUTH_REF_MISMATCH';
  return null;
}

module.exports = { check, opIdFor, fromAppRequest, fromPlatformRegister, RULES, FRESH_MS };
