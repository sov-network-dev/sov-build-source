// ─────────────────────────────────────────────────────────────────────────────
// FROZEN LEDGER HISTORY — node 1.4.94
// ─────────────────────────────────────────────────────────────────────────────
// Ops committed before 1.4.94 carry no certificate: three kinds ('baseline',
// 'escrow_adopt', 'holding_adopt') were allowed to break the zero-sum rule during the
// 1.4.90 upgrade, and every owner op (a transfer, a bond) was authorised by the old
// quorum-slot rule rather than by a signed validator certificate. A node joining later
// still has to replay that history — but a dishonest node must not be able to invent
// more of it (a made-up 'baseline' would create SOV on every other node, D60; a
// certless 'transfer' would otherwise be refused, D61/D62).
//
// So the pre-1.4.94 history that existed when 1.4.94 was built is pinned here by the
// CONTENT HASH of each such op (sha256 over its op id, kind, owner, moves, holds,
// pools and baseline nonce — see ledger_cert.opHash; the per-node origin and timestamp
// are excluded, so every honest node's copy of the same op hashes the same). A peer's
// legacy-kind op is accepted WITHOUT a certificate only if its hash is in this set;
// anything else is refused, always.
//
// Only HASHES are stored — never an account id or a balance. This file ships in public
// source (it is part of the node's source_root, so every node has the same list and a
// fork cannot change it), and a hash reveals none of the genesis ledger's contents while
// still being impossible to forge a different (account, amount) into.
//
// Rebuild with scripts/build_frozen_history.js (reads the live ledger, prints hashes).
// ─────────────────────────────────────────────────────────────────────────────
'use strict';

const { opHash } = require('./ledger_cert');

// Content hashes of every pre-1.4.94 op on the fleet that would otherwise fail the new
// trust rules (measured 2026-10-09 from all three live nodes, which held an identical ledger:
// one genesis baseline and two certless owner transfers; no escrow/holding adoptions). The two
// enrolment grants are system ops of a known kind and need no entry — they pass on their own.
const FROZEN = new Set([
  // genesis baseline
  'd82da394ba5e7919d55267277af5e3557d9214ddb69e9232f7a374efcb9037aa',
  // pre-1.4.94 owner transfers (authorised under the old quorum-slot rule, no certificate)
  '490554a4e1aab7886c4ff61f1d0ec9061d9e41732053d0909321ec14bd987b68',
  'c552ac0472ee73e13b810dce607bd78956583ac8015f548d24b41d6fe276bf5e',
]);

function isFrozenHistory(op) {
  return !!op && FROZEN.has(opHash(op));
}

module.exports = { isFrozenHistory, FROZEN_COUNT: FROZEN.size };
