'use strict';
/**
 * source_root — a deterministic fingerprint of the source tree a node is running.
 *
 * Two nodes holding identical source MUST compute an identical root, on any OS.
 * That property is the whole point: agreeing on *what source is legitimate* is
 * cheap and portable, whereas agreeing on byte-identical binaries is not. Windows
 * and macOS nodes cannot build a snap, but they can compute this — so they can
 * still verify and attest.
 *
 * Determinism rules (each one exists because breaking it desynchronises nodes):
 *   - paths are recorded with forward slashes, so Windows and Linux agree;
 *   - the file list is sorted by that normalised path, so directory-read order
 *     (which differs per filesystem) cannot matter;
 *   - only file CONTENT and PATH are hashed — never mtime, mode, uid or inode,
 *     all of which differ between two correct copies of the same source;
 *   - the tree walk skips anything generated, machine-local or mutable.
 *
 * Root = sha256 over the newline-joined "sha256(content)  path" lines. A flat
 * canonical list is used rather than a binary Merkle tree because the leaf list is
 * small, the result is trivially reproducible by hand (`sha256sum` + `sort`), and
 * an operator can audit it without our code.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/** Never part of the fingerprint: generated, machine-local, or per-install state. */
const EXCLUDED_DIRS = new Set([
  '.git', 'node_modules', 'parts', 'prime', 'stage', 'coverage',
  '.sov-node', 'logs', 'keys', 'genesis_keys', '__pycache__', '.pytest_cache',
]);

/** Backups and build spoil — present on one node, absent on another, same source. */
//
// 2026-08-06: this list previously covered `.bak` only, so a rescue copy named
// `db.js.broken_revert_...` — exactly the kind of file a careful operator leaves
// behind — WAS hashed. Two such files on VPS1 alone made its root differ from an
// otherwise byte-identical tree. Under `release_enforce_mode=refuse` that is not a
// cosmetic problem: a node would be refused for holding a backup it never executes.
// The rule has to be "junk a node happens to keep on disk cannot change what source
// it is running", so the patterns below cover the usual rescue/merge/editor spoil.
// This is safe for the same reason the `.bak` exclusion always was: a hidden file is
// only reachable if some hashed file requires it, and that requirer IS hashed.
function isExcludedFile(name) {
  return (
    name.startsWith('.bak') ||
    name.includes('.bak_') ||
    name.includes('.broken') ||   // rescue copies (db.js.broken_revert_…)
    name.includes('.orig') ||     // merge spoil
    name.includes('.rej') ||      // failed-patch spoil
    name.endsWith('~') ||         // editor backup
    name.endsWith('.tmp') ||
    name.endsWith('.log') ||
    name.endsWith('.db') ||
    name.endsWith('.db-wal') ||
    name.endsWith('.db-shm') ||
    name.endsWith('.pyc') ||
    name.endsWith('.snap') ||
    name === '.DS_Store'
  );
}

/**
 * Walk `root` and return [{ path, sha256 }] sorted by path.
 * Paths are relative to `root` and always forward-slashed.
 */
function fileDigests(root, { include = ['src'] } = {}) {
  const out = [];

  function walk(abs) {
    let entries;
    try {
      entries = fs.readdirSync(abs, { withFileTypes: true });
    } catch (_) {
      return;                       // unreadable dir: skip rather than crash a boot
    }
    for (const e of entries) {
      const full = path.join(abs, e.name);
      if (e.isDirectory()) {
        if (EXCLUDED_DIRS.has(e.name)) continue;
        walk(full);
      } else if (e.isFile()) {
        if (isExcludedFile(e.name)) continue;
        let buf;
        try {
          buf = fs.readFileSync(full);
        } catch (_) {
          continue;
        }
        out.push({
          path: path.relative(root, full).split(path.sep).join('/'),
          sha256: crypto.createHash('sha256').update(buf).digest('hex'),
        });
      }
      // symlinks and specials are deliberately ignored — they are not content
    }
  }

  for (const dir of include) {
    const abs = path.join(root, dir);
    if (fs.existsSync(abs)) walk(abs);
  }

  out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return out;
}

/** The canonical text an operator can reproduce with `sha256sum` + `sort`. */
function canonicalList(digests) {
  return digests.map(d => `${d.sha256}  ${d.path}`).join('\n');
}

/**
 * @returns {{ root:string, fileCount:number, bytes:number }}
 */
function sourceRoot(root, opts = {}) {
  const digests = fileDigests(root, opts);
  const text = canonicalList(digests);
  return {
    root: crypto.createHash('sha256').update(text, 'utf8').digest('hex'),
    fileCount: digests.length,
    bytes: Buffer.byteLength(text, 'utf8'),
  };
}

module.exports = { sourceRoot, fileDigests, canonicalList, EXCLUDED_DIRS, isExcludedFile };
