// disk_guard.js — a node must look after its own disk, with nobody watching.
//
// WHY (king, 2026-10-02): the SOV node is meant to be run-and-forget, like a Bitcoin miner.
// An operator who has to watch disk space, prune files or call an engineer will not run one.
// Everything the node writes is already bounded on its own — the ledger prunes and
// auto-vacuums, the log rotates at 10 MB x 3, snapd keeps two revisions — but the DISK is
// shared with everything else on the machine, and nothing in the node noticed when it ran low.
// The capability tier (docs/SOV_CAPABILITY_TIERED_COMPUTE.md, Phase 1) measured pressure and
// only logged it.
//
// This closes that loop, without a human:
//   - measures free space on the data volume every few minutes;
//   - below a floor, RECLAIMS what the node itself owns: rotated log files, the WAL
//     (checkpoint + truncate) and free database pages (incremental vacuum);
//   - reports its state - in /node-info and in the heartbeat capability peers already read - so
//     the network can route around a starved node and its owner's app can say so plainly;
//   - logs each change of state once, at the right level, instead of every tick.
// It never deletes anything it did not create, and never touches the ledger's rows: what
// counts as history is governance's decision (tx_retention_days etc.), not the disk's.
//
// What it deliberately does NOT do: drop biometric templates or skip replication. That is
// Phase 2 of the tiered-compute design (delegated dedup with threshold-verified results), a
// consensus change that must be proven on an isolated mesh first. This module supplies the
// signal Phase 2 consumes.
'use strict';
const fs = require('fs');
const path = require('path');

const GIB = 1024 * 1024 * 1024;
const FLOOR_BYTES    = parseInt(process.env.SOV_DISK_FLOOR_BYTES || String(GIB), 10);          // "low" below 1 GiB ...
const FLOOR_FRACTION = parseFloat(process.env.SOV_DISK_FLOOR_FRACTION || '0.05');              // ... or below 5 % of the volume
const CRITICAL_BYTES = parseInt(process.env.SOV_DISK_CRITICAL_BYTES || String(256 * 1024 * 1024)); // "critical" below 256 MiB

let _state = { status: 'unknown', free_bytes: 0, total_bytes: 0, checked_at: 0, last_reclaimed_bytes: 0, reclaims: 0 };

function measure(dir) {
  try {
    const st = fs.statfsSync(dir);
    return { free: st.bavail * st.bsize, total: st.blocks * st.bsize };
  } catch (_) { return null; }
}

function classify(free, total) {
  if (free < CRITICAL_BYTES) return 'critical';
  if (free < Math.max(FLOOR_BYTES, total * FLOOR_FRACTION)) return 'low';
  return 'ok';
}

// Rotated logs only (sov-node1.log, sov-node2.log, ...). The live file belongs to the logger.
function _reclaimLogs(dataDir) {
  let freed = 0;
  const dir = path.join(dataDir, 'logs');
  let names = [];
  try { names = fs.readdirSync(dir); } catch (_) { return 0; }
  for (const n of names) {
    if (!/^sov-node\d+\.log$/.test(n)) continue;
    const p = path.join(dir, n);
    try { const sz = fs.statSync(p).size; fs.unlinkSync(p); freed += sz; } catch (_) {}
  }
  return freed;
}

function _reclaimDb(db, dbFile) {
  if (!db || !db._db) return 0;
  const size = () => { let s = 0; for (const f of [dbFile, dbFile + '-wal']) { try { s += fs.statSync(f).size; } catch (_) {} } return s; };
  const before = dbFile ? size() : 0;
  try { db._db.pragma('wal_checkpoint(TRUNCATE)'); } catch (_) {}
  try { db._db.pragma('incremental_vacuum'); } catch (_) {}
  return dbFile ? Math.max(0, before - size()) : 0;
}

/**
 * One pass. Safe to call often; does work only when the disk is short.
 * @param {{db?:object, dataDir:string, dbFile?:string, log?:object}} o
 */
function check(o) {
  const log = o.log || global.sovLog || { info() {}, warn() {}, error() {} };
  const m = measure(o.dataDir);
  if (!m) return _state;
  let status = classify(m.free, m.total);
  let reclaimed = 0;
  if (status !== 'ok') {
    reclaimed = _reclaimLogs(o.dataDir) + _reclaimDb(o.db, o.dbFile);
    const again = measure(o.dataDir) || m;
    m.free = again.free;
    status = classify(m.free, m.total);
    _state.reclaims += 1;
  }
  const prev = _state.status;
  _state = { ...(_state), status, free_bytes: m.free, total_bytes: m.total, checked_at: Date.now(),
             last_reclaimed_bytes: reclaimed };
  if (status !== prev) {
    const mb = (b) => (b / 1048576).toFixed(0) + ' MB';
    const msg = `[Disk] ${prev} -> ${status}: ${mb(m.free)} free of ${mb(m.total)}` +
                (reclaimed ? `, reclaimed ${mb(reclaimed)} the node owned` : '');
    if (status === 'critical') log.error(msg + ' — the machine is nearly full; free space outside the node');
    else if (status === 'low') log.warn(msg);
    else log.info(msg);
  }
  global.sovDiskStatus = status;
  return _state;
}

function state() { return { ..._state }; }

module.exports = { check, state, classify, FLOOR_BYTES, FLOOR_FRACTION, CRITICAL_BYTES };
