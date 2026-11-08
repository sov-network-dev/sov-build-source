#!/bin/bash
# registry_dump.sh <node-number> — the operator registry a mesh node holds: node, status, certificate size.
# Reads a COPY of the node's data dir, never the live DB.
set -u
B=/root/sov-mesh; N=$1; C=$(mktemp -d); cp -r $B/n$N/data/. $C/
SOV_DATA_DIR=$C SNAP_COMMON=$C NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
let rows=[]; try { rows=d._db.prepare("SELECT node_id, status, admission_cert FROM sov_operator_registry").all(); } catch(e) {}
const out=rows.map(r=>{let n="none"; try{const c=JSON.parse(r.admission_cert||"null"); n=Array.isArray(c)?c.length:(r.admission_cert||"none");}catch(_){n=r.admission_cert||"none"} return r.node_id.slice(0,8)+":"+r.status+":cert="+n;});
console.log(JSON.stringify({ node: '$N', rows: rows.length, detail: out.sort() })); process.exit(0);' 2>/dev/null
chattr -i $C/db-encryption-key 2>/dev/null; rm -rf $C
