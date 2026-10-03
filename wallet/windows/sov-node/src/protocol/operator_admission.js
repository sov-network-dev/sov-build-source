'use strict';
// operator_admission.js — what it takes for a node to EXIST in sov_operator_registry.
//
// docs/OPERATOR_QUORUM_GAP_2026-10-03.md. The signup quorum (`operator_signup_quorum`, CLAUDE.md 4b:
// "replaces first-approval-wins, under which one dishonest peer could admit any node") was never the
// admission gate: every approver wrote an ACTIVE row on its own approval and broadcast it, and any
// admitted peer could broadcast a brand-new row with no proof at all.
//
// The rule now: a registry row is accepted from the network only with an ADMISSION CERTIFICATE —
// a set of signed approvals, one per distinct approving node, that together meet the quorum. An
// approval is signed by the approver over exactly what was approved (node, operator, source,
// signup time), and the approver's id must be the hash of the key that signed it — node ids are
// sha256(public key), so nobody can sign as a node whose key they do not hold. The receiver also
// requires every approver to be a node it already knows (an active registry row or a verified
// peer), so a pile of freshly generated keys cannot vouch for anything.
//
// Pure functions only — operator_engine.js does the I/O. Tested by scripts/test_operator_admission.js.
const crypto = require('crypto');
const nacl = require('tweetnacl');

const HEX64 = /^[0-9a-f]{64}$/;
const SIG_HEX = /^[0-9a-f]{128}$/;

function sha256hex(buf) { return crypto.createHash('sha256').update(buf).digest('hex'); }
function upper(s) { return String(s || '').trim().toUpperCase(); }

// The exact bytes a joining node signs in its signup.
function signupBody(s) {
  return Buffer.from(['SOV-OPSIGNUP-v1', s.node_id, upper(s.operator_sovereign_id),
    String(s.source_root || ''), String(s.timestamp)].join('|'));
}

// The exact bytes an approver signs.
function approvalBody(a) {
  return Buffer.from(['SOV-OPAPPROVAL-v1', a.node_id, upper(a.operator_id), String(a.source_root || ''),
    String(a.signup_ts), a.approver, String(a.ts)].join('|'));
}

function verifySig(body, sigHex, pubHex) {
  if (!SIG_HEX.test(String(sigHex || '')) || !HEX64.test(String(pubHex || ''))) return false;
  try {
    return nacl.sign.detached.verify(new Uint8Array(body), new Uint8Array(Buffer.from(sigHex, 'hex')),
      new Uint8Array(Buffer.from(pubHex, 'hex')));
  } catch (_) { return false; }
}

// Is this signup really from the node it names? node_id must be the hash of public_key, and the
// signature must verify under that key over this exact signup.
function verifySignup(s) {
  if (!s || typeof s !== 'object') return false;
  const pub = String(s.public_key || '');
  if (!HEX64.test(pub) || !HEX64.test(String(s.node_id || ''))) return false;
  if (sha256hex(Buffer.from(pub, 'hex')) !== s.node_id) return false;
  if (!Number.isFinite(Number(s.timestamp))) return false;
  return verifySig(signupBody(s), s.signature, pub);
}

// Does `a` validly approve exactly `subject` ({node_id, operator_id, source_root, signup_ts})?
function verifyApproval(a, subject) {
  if (!a || typeof a !== 'object' || !subject) return false;
  if (a.node_id !== subject.node_id) return false;
  if (upper(a.operator_id) !== upper(subject.operator_id)) return false;
  if (String(a.source_root || '') !== String(subject.source_root || '')) return false;
  if (String(a.signup_ts) !== String(subject.signup_ts)) return false;
  if (!HEX64.test(String(a.approver || '')) || a.approver === a.node_id) return false;
  if (sha256hex(Buffer.from(String(a.approver_pub || ''), 'hex')) !== a.approver) return false;
  return verifySig(approvalBody(a), a.sig, a.approver_pub);
}

function makeApproval(identity, pubHex, subject) {
  const a = { node_id: subject.node_id, operator_id: upper(subject.operator_id),
    source_root: String(subject.source_root || ''), signup_ts: subject.signup_ts,
    approver: identity.nodeId, approver_pub: pubHex, ts: Date.now() };
  a.sig = identity.signMessage(approvalBody(a)).toString('hex');
  return a;
}

// Certificate check for a row received from the network.
//   cert      — array of approvals
//   row       — {node_id, operator_id, source_root}
//   known     — function(nodeId) -> true if THIS node already knows that node (active row / verified peer)
//   need      — approvals required (the caller computes it from the quorum and what it can see)
// Returns { ok, valid, reason }.
function verifyCertificate(cert, row, known, need) {
  if (cert === 'genesis') return { ok: false, valid: 0, reason: 'GENESIS_NOT_RELAYABLE' };
  if (!Array.isArray(cert) || !cert.length) return { ok: false, valid: 0, reason: 'NO_CERTIFICATE' };
  if (cert.length > 64) return { ok: false, valid: 0, reason: 'CERTIFICATE_TOO_LARGE' };
  const first = cert[0] || {};
  const subject = { node_id: row.node_id, operator_id: row.operator_id, source_root: first.source_root,
    signup_ts: first.signup_ts };
  const seen = new Set();
  for (const a of cert) {
    if (!a || seen.has(a.approver)) continue;
    if (!verifyApproval(a, subject)) continue;
    if (!known(a.approver)) continue;
    seen.add(a.approver);
  }
  const ok = seen.size >= Math.max(1, need);
  return { ok, valid: seen.size, reason: ok ? 'OK' : 'NOT_ENOUGH_VALID_APPROVALS' };
}

module.exports = { signupBody, approvalBody, verifySignup, verifyApproval, makeApproval, verifyCertificate, sha256hex };
