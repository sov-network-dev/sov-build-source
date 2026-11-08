#!/bin/bash
# gov_dump.sh <node-number> [param...] — what a mesh node holds for governance (1.4.97 trust model):
# one line per poll: poll_id status votes=<n> signed=<has create_auth>; then the value of each named param.
# Reads a COPY of the node's data dir, never the live DB.
set -u
B=/root/sov-mesh; N=$1; shift; C=$(mktemp -d); cp -r $B/n$N/data/. $C/
SOV_DATA_DIR=$C SNAP_COMMON=$C NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
let polls = []; try { polls = d._db.prepare("SELECT * FROM sov_polls").all(); } catch (e) {}
for (const p of polls) {
  const n = d._db.prepare("SELECT COUNT(*) c FROM sov_poll_votes WHERE poll_id = ?").get(p.poll_id).c;
  console.log(["poll", p.poll_id, p.status, "votes=" + n, "signed=" + !!(p.create_auth && p.create_auth.length > 10)].join(" "));
}
let pets = []; try { pets = d._db.prepare("SELECT * FROM sov_petitions").all(); } catch (e) {}
for (const p of pets) console.log(["petition", p.petition_id, p.status, "sigs=" + p.signature_count].join(" "));
for (const k of process.argv.slice(1)) { const r = d._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = ?").get(k); console.log("param " + k + " " + (r ? r.param_value : "?")); }
process.exit(0);' "$@" 2>/dev/null
chattr -i $C/db-encryption-key 2>/dev/null; rm -rf $C
