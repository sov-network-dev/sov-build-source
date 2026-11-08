#!/bin/bash
# count_templates.sh <node-number> — how many palm/face templates and enrolments a mesh node holds.
# Reads a COPY of the node's data dir (the encryption key travels with it), never the live DB.
set -u
B=/root/sov-mesh; N=$1; C=$(mktemp -d); cp -r $B/n$N/data/. $C/   # -r, not -a: -a copies the key's immutable flag and the copy can then never be deleted
SOV_DATA_DIR=$C SNAP_COMMON=$C NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
const q = (t) => d._db.prepare("SELECT COUNT(*) c FROM " + t).get().c;
console.log(JSON.stringify({ node: '$N', enrolments: q("sov_enrollments"), palm: q("palm_embeddings"), face: q("face_embeddings") }));
process.exit(0);' 2>/dev/null
chattr -i $C/db-encryption-key 2>/dev/null; rm -rf $C
