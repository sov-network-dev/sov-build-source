#!/bin/bash
# ledger_ops_dump.sh <node-number> — the citizen money ops a mesh node holds (1.4.95 owner_auth check):
# one line per op of a citizen-requested kind: kind, op id prefix, whether the signed request rides with it.
# Reads a COPY of the node's data dir, never the live DB.
set -u
B=/root/sov-mesh; N=$1; C=$(mktemp -d); cp -r $B/n$N/data/. $C/
SOV_DATA_DIR=$C SNAP_COMMON=$C NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
const kinds = ["vault_lock","alloc_lock","escrow_list","dispute_bond","academy_article_bond","academy_upvote_bond","platform_fee"];
let rows = []; try { rows = d._db.prepare("SELECT op_id, kind, op_json FROM sov_ledger_ops").all(); } catch (e) {}
for (const r of rows.filter(r => kinds.includes(r.kind))) {
  let a = null; try { a = JSON.parse(r.op_json).auth || null; } catch (_) {}
  console.log([r.kind, r.op_id.slice(0, 4), a ? "auth:" + a.scheme : "auth:none"].join(" "));
}
process.exit(0);' 2>/dev/null
chattr -i $C/db-encryption-key 2>/dev/null; rm -rf $C
