'use strict';
/**
 * dist_publish.js — the missing bridge between "a build exists" and "a citizen can
 * download it from this node".
 *
 * FOUND 2026-08-28. `relay_pool.js` serves `/download/android`, `/download/windows`,
 * `/download/linux`, `/sov-relay.snap` etc. straight off local disk
 * (`RelayPool._distDir(platform)` — `$SNAP_COMMON/dist/<platform>` on a snap,
 * `$SOV_DATA_DIR/dist/<platform>` otherwise). That code is real, live, and correctly
 * wired — but **nothing in the entire node source ever writes into that directory**.
 * Grepped the whole tree for it; the only references are relay_pool.js's own readers.
 *
 * Separately, `release_scheduler.js` DOES build artifacts (via `autobuild.js`) — into
 * `outDir` (default `~/.sov-releases/`, flat, one file per platform, no subfolders)
 * for upload to an EXTERNAL host (Storj/R2/B2). Two systems, two layouts, never
 * connected. Confirmed live: every node's RAM (~956 MB, measured 2026-08-26) is under
 * `DEFAULT_MIN_BUILD_RAM_MB` (4096), so `runTick()`'s local-build branch has in fact
 * never executed on any node in the fleet — the gap was invisible in the field for
 * the same reason `/download/*` was invisible: nothing ever exercised it.
 *
 * This module is that bridge. `publishArtifact()` takes a built file — from a local
 * build OR from anywhere else (a GitHub Actions download, a USB stick, tier-1/2/3
 * output) — and lands it at the exact path + filename the existing, unmodified
 * `/download/*` routes already expect, plus a `.sha256` sidecar so the existing
 * checksum routes (`/download/linux.sha256`, `/sov-relay.snap.sha256`) work too.
 *
 * Deliberately NOT a network call, NOT a build step, and NOT wired to any peer
 * broadcast — publishing to the mesh manifest is release_coordinator's job and
 * unrelated. This only makes a file this node ALREADY HAS servable to a citizen who
 * dials in and asks for it.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/**
 * Where an artifact for `platform` should be WRITTEN.
 *
 * NOT the same selection logic as RelayPool._distDir(), and that difference is
 * deliberate. relay_pool.js's version returns the first candidate that already
 * EXISTS, falling back to the repo-relative path if none do — correct for a READ
 * (nothing to serve is a safe 404 either way), but wrong for a WRITE: on a node
 * that has never published anything yet, NEITHER SNAP_COMMON's nor SOV_DATA_DIR's
 * dist/<platform> exists, so that logic falls through to the repo-relative
 * fallback regardless of which env vars are set. Verified against the real,
 * currently-shipped relay_pool.js 2026-08-28: with SOV_DATA_DIR pointed at a
 * directory that had never been created, _distDir('android') still returned the
 * repo-relative path. On an actual snap install that path sits inside the
 * read-only squashfs, so a first-ever publish attempt using that logic would fail
 * with EROFS outright, not merely land in the wrong place.
 *
 * This function exists to CREATE that directory for the first time, so it must
 * pick by env var PRESENCE, not by existence. Once it has created
 * SNAP_COMMON/SOV_DATA_DIR's dist/<platform>, relay_pool.js's own existence-based
 * loop will find and prefer it on every subsequent read — so this fix is
 * sufficient without touching relay_pool.js, which is live-serving code on
 * genesis nodes and out of scope for an unreviewed same-session change.
 */
function distDir(platform) {
  if (process.env.SNAP_COMMON) return path.join(process.env.SNAP_COMMON, 'dist', platform);
  if (process.env.SOV_DATA_DIR) return path.join(process.env.SOV_DATA_DIR, 'dist', platform);
  return path.join(__dirname, '..', '..', 'dist', platform);
}

/** The canonical filename each route matches on. Windows carries the version because
 *  the route builds it from package.json at request time — get this wrong and the
 *  route 404s even with a file sitting right next to where it looked. */
function canonicalName(platform, version) {
  switch (platform) {
    case 'android': return 'SovNode.apk';
    case 'windows': return `SOV-Node-Setup-${version}.exe`;
    case 'linux':   return 'sov-node.snap';        // also aliased as sov-relay.snap, see below
    default: throw new Error(`unknown platform: ${platform}`);
  }
}

function sha256File(p) {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

/**
 * Publish one already-built artifact so this node's own HTTP server can serve it.
 *
 * @param {object} o
 * @param {string} o.file      path to the built artifact (APK / .exe / .snap)
 * @param {string} o.platform  'android' | 'windows' | 'linux'
 * @param {string} [o.version] required for windows (filename embeds it); read from
 *                              package.json if omitted
 * @param {boolean} [o.alsoSnapAlias] for linux, also write the sov-relay.snap /
 *                              sov-relay.snap.sha256 pair that /sov-relay.snap serves —
 *                              same bytes, second name, because that route predates
 *                              /download/linux and citizens/operators may still hit it
 * @returns {{platform, distDir, files: string[]}}
 */
function publishArtifact(o) {
  const { file, platform } = o || {};
  if (!file || !fs.existsSync(file)) throw new Error(`publishArtifact: file not found: ${file}`);
  if (!['android', 'windows', 'linux'].includes(platform)) {
    throw new Error(`publishArtifact: unknown platform '${platform}'`);
  }
  let version = o.version;
  if (platform === 'windows' && !version) {
    try { version = require(path.join(__dirname, '..', '..', 'package.json')).version; }
    catch (_) { throw new Error('publishArtifact: windows needs a version and package.json was not readable'); }
  }

  // Validate the platform BEFORE touching disk. canonicalName() is what actually
  // rejects an unknown platform; calling it here, before mkdirSync, means a bad
  // platform argument fails cleanly with nothing created — not even an empty
  // directory left behind for the next run to trip over.
  const name = canonicalName(platform, version);
  const dir = distDir(platform);
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, name);
  fs.copyFileSync(file, dest);
  const written = [dest];

  const hash = sha256File(dest);
  if (platform === 'linux') {
    const shaPath = dest + '.sha256';
    fs.writeFileSync(shaPath, hash + '\n');
    written.push(shaPath);
    if (o.alsoSnapAlias) {
      const alias = path.join(dir, 'sov-relay.snap');
      fs.copyFileSync(file, alias);
      const aliasSha = alias + '.sha256';
      fs.writeFileSync(aliasSha, hash + '\n');
      written.push(alias, aliasSha);
    }
  }

  (global.sovLog || console).info(
    `[DistPublish] ${platform}: ${path.basename(file)} -> ${dest} (sha256 ${hash.slice(0, 16)}…)`
  );
  return { platform, distDir: dir, files: written, sha256: hash };
}

module.exports = { publishArtifact, distDir, canonicalName, sha256File };
