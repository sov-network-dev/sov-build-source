'use strict';
/**
 * release_scheduler.js — drives the autonomous release pipeline on a timer
 * (king's launch-and-forget). On each tick it checks whether the bundled
 * client/node source version has advanced past the last published manifest; if so
 * it runs the full cycle: crossCompileAll (desktop via pkg) + buildAndroidApk
 * (Android via Flutter) → threshold-sign the Distribution Manifest → publish.
 *
 * No human in the loop. Signing is the witness-signer FROST threshold (PI-37):
 * the signer SEEDS/shares are supplied via env (SOV_RELEASE_SIGNER_SEEDS) — on a
 * real node these are that node's FROST share, and >= threshold nodes co-sign the
 * same manifest across the mesh. `publish` uploads artifacts to a third-party host
 * and posts the signed manifest to peers (never exposes the node endpoint).
 *
 * REQUIRES the build toolchains present (pkg + flutter/Android SDK). In the snap
 * these are bundled (owner-gated packaging step); on a toolchain host they are on
 * PATH. If a toolchain is missing the tick logs + skips (never crashes the node).
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

// RAM floor for attempting a LOCAL heavy (Flutter/Gradle) build. A 1 GB node
// swap-thrashes for hours on `gradle assembleRelease` (verified on VPS4, e2-micro,
// 2026-08-16) — worse than useless, it ties the node up. Below this floor the node
// SKIPS the local build and defers to the GitHub runner (one of several build
// channels; no single point of failure). Android release AOT + R8 needs real memory,
// so the default is generous; tune via SOV_RELEASE_MIN_RAM_MB or the release opts.
const DEFAULT_MIN_BUILD_RAM_MB = 4096;

function nodeRamMb() { return Math.round(os.totalmem() / (1024 * 1024)); }

function readVersion(pkgJsonPath) {
  try { return JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8')).version; } catch (_) { return null; }
}

// The artifact filenames to upload = the basename of each platform URL in the manifest.
function collectArtifactFiles(manifest, outDir) {
  return Object.values(manifest.platforms || {})
    .map((p) => (p.url || '').split('/').pop())
    .filter((f) => f && fs.existsSync(path.join(outDir, f)));
}

/**
 * @param o.nodeClientDir   the Node wallet project dir (pkg compiles this -> desktop binaries)
 * @param o.flutterDir      the Flutter project root (-> apk)
 * @param o.outDir          where artifacts + manifest are written
 * @param o.lastManifestPath path of the last published manifest (version compare)
 * @param o.signerSeeds     array of FROST/release signer seed-hex (env in prod)
 * @param o.threshold       min signatures
 * @param o.baseUrls        per-platform host base URLs
 * @param o.publish         async ({artifacts,outDir,manifest}) => void
 * @param o.now             timestamp (ms) — passed in (no Date dependency)
 * @param o.log             logger
 */
async function runTick(o) {
  const log = o.log || console;
  const curVersion = readVersion(path.join(o.nodeClientDir, 'package.json'));
  if (!curVersion) { log.warn && log.warn('[Release] no node-client version — skip'); return { ran: false, reason: 'no-version' }; }

  // Version consensus (king's no-SPOF model): ANY node may publish, but only when its
  // bundled version is newer than the latest threshold-signed manifest the MESH knows.
  // The coordinator tracks that via RELEASE_MANIFEST_BROADCAST gossip. Falls back to a
  // local last-manifest file when no coordinator is wired (dev).
  // Current live relay pool — the bootstrap set we want baked into new downloads.
  const { poolFingerprint } = require('./release_coordinator');
  const livePoolNodes = o.getPool ? (o.getPool() || []) : [];
  const livePool = poolFingerprint(livePoolNodes);

  if (o.coordinator) {
    if (!o.coordinator.shouldPublish(curVersion, livePool)) {
      return { ran: false, reason: 'mesh-up-to-date', version: curVersion, pool: livePool.count, meshLatest: o.coordinator.latestPublished() && o.coordinator.latestPublished().version };
    }
    log.info && log.info(`[Release] publishing — ${o.coordinator.publishReason(curVersion, livePool)} (pool=${livePool.count})`);
    // The final apps live on the governance-set external host (never a node IP).
    o.baseUrls = o.coordinator.baseUrls();
    if (!o.baseUrls.windows) { log.warn && log.warn('[Release] app_download_host not set by governance — skip publish'); return { ran: false, reason: 'no-download-host' }; }
  } else {
    let lastVersion = null;
    try { lastVersion = JSON.parse(fs.readFileSync(o.lastManifestPath, 'utf8')).version; } catch (_) {}
    if (lastVersion === curVersion) return { ran: false, reason: 'up-to-date', version: curVersion };
  }

  const ab = require('./autobuild');
  const { buildSigned } = require('./build_release');
  log.info && log.info(`[Release] building all platforms (version ${curVersion}, pool ${livePool.count})…`);

  // EMBED the current live pool into the artifacts so new downloads bootstrap against
  // live relays (the whole point — survive genesis death). Write relay_pool.json into
  // the node-client (pkg bundles it) before compiling; the apk/snap read the same file.
  if (livePoolNodes.length) {
    try {
      const poolJson = JSON.stringify({ nodes: livePoolNodes.map((n) => n.endpoint || n.address || n).filter(Boolean) });
      fs.writeFileSync(path.join(o.nodeClientDir, 'relay_pool.json'), poolJson);
      if (o.flutterDir) { try { fs.writeFileSync(path.join(o.flutterDir, 'assets', 'relay_pool.json'), poolJson); } catch (_) {} }
      log.info && log.info(`[Release] embedded ${livePoolNodes.length}-node bootstrap pool into artifacts`);
    } catch (e) { log.warn && log.warn('[Release] pool embed failed: ' + e.message); }
  }

  // RAM GATE (king 2026-08-16): a low-RAM node must NOT attempt the heavy build — on
  // 1 GB it swap-thrashes for hours (verified VPS4). Such a node SKIPS its local build
  // and defers to the GitHub runner (dispatched here if wired). This is not a downgrade:
  // the runner is one of several build channels, and the threshold-signed manifest it
  // produces is verified the same way a node-built one is — so no SPOF is introduced.
  const minRamMb = parseInt(o.minBuildRamMb || process.env.SOV_RELEASE_MIN_RAM_MB || String(DEFAULT_MIN_BUILD_RAM_MB), 10);
  const ramMb = nodeRamMb();
  if (ramMb < minRamMb) {
    log.info && log.info(`[Release] node RAM ${ramMb}MB < ${minRamMb}MB build floor — skipping local build, deferring to remote (GitHub) runner`);
    let dispatched = false;
    if (o.dispatchRemoteBuild) {
      try { const r = await o.dispatchRemoteBuild({ version: curVersion, pool: livePool, govVersion: o.coordinator ? o.coordinator.getGovParam('governance_version', '0') : '0' }); dispatched = !!(r && r.ok !== false); log.info && log.info('[Release] remote build dispatched: ' + JSON.stringify(r)); }
      catch (e) { log.warn && log.warn('[Release] remote build dispatch failed: ' + e.message); }
    }
    return { ran: false, reason: 'insufficient-ram', ramMb, minRamMb, remoteDispatched: dispatched, version: curVersion };
  }

  // Desktop (pkg compiles the node-client PROJECT, not a single file).
  const { publishArtifact } = require('./dist_publish');
  try {
    await ab.crossCompileAll({ entry: o.nodeClientDir, outDir: o.outDir, pkgBin: o.pkgBin });
    // NOT bridged to dist_publish here, on purpose. crossCompileAll's windows/linux
    // output (SovWallet-win.exe / SovWallet-linux) is a raw pkg-compiled CLIENT
    // binary -- a different artifact than what /download/windows and /download/linux
    // actually serve. Windows: release.yml's separate windows job produces
    // dist\SovNode.exe via tools/portable_packer (Flutter build + embedded node.exe +
    // sov-node source) -- not this. Linux: the route is explicitly "the Linux snap"
    // (sov-node.snap / sov-relay.snap, verified against a signature), built by
    // snapcraft, not by pkg. Auto-publishing either under the trusted route's
    // filename would ship the wrong file under the right name -- worse than the
    // 404 it replaces, because it looks like success. Use
    // `node scripts/publish_dist_artifact.js` to publish the CORRECT artifact for
    // these platforms once you have it; that is a deliberate human action, matching
    // the "operator drops an artifact" model the routes were built for
    // (relay_pool.js:149-155).
  } catch (e) { log.warn && log.warn('[Release] desktop build skipped: ' + e.message); }
  // Android (headless Flutter) -- SAFE to auto-publish. buildAndroidApk produces
  // exactly the release-signed citizen APK /download/android exists to serve; this
  // is the one artifact type where "what was built" and "what the route serves"
  // are proven identical (same code path verified repeatedly this session: signer
  // 7c783a95..., content-digest tested against tier-1/tier-3 builds).
  if (o.flutterDir) {
    try {
      const apkArtifact = await ab.buildAndroidApk({ flutterDir: o.flutterDir, outDir: o.outDir, flutterBin: o.flutterBin });
      try { publishArtifact({ file: path.join(o.outDir, apkArtifact.file), platform: 'android' }); }
      catch (e) { log.warn && log.warn('[Release] local dist publish (android) failed: ' + e.message); }
    }
    catch (e) { log.warn && log.warn('[Release] apk build skipped: ' + e.message); }
  }

  // Governance version baked into this release (king, 2026-08-15) — a poll that flips a
  // feature default bumps it, and shouldPublish() republishes so new downloads carry it.
  const govVersion = o.coordinator
    ? (parseInt(o.coordinator.getGovParam('governance_version', '0'), 10) || 0)
    : (o.getGovParam ? (parseInt(o.getGovParam('governance_version', '0'), 10) || 0) : 0);
  const manifest = buildSigned({
    version: curVersion, artifactsDir: o.outDir, baseUrls: o.baseUrls,
    signerSeeds: o.signerSeeds, threshold: o.threshold, builtAt: o.now,
    pool: livePool,   // record the bootstrap pool baked into these artifacts
    govVersion,       // record the governance state baked into these artifacts
  });
  const manifestPath = o.lastManifestPath;
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  // Upload artifacts + manifest to the external host (overwrites the latest version).
  let publishResult = null;
  if (o.publish) {
    try { publishResult = await o.publish({ artifacts: collectArtifactFiles(manifest, o.outDir), outDir: o.outDir, manifest }); }
    catch (e) { log.warn && log.warn('[Release] external publish failed (manifest still signed/gossiped): ' + e.message); }
  }
  // Record locally + GOSSIP the signed manifest so every node converges on the new
  // version/pool (RELEASE_MANIFEST_BROADCAST). Threshold sig means peers trust it.
  if (o.coordinator) o.coordinator.ingest(manifest);
  if (o.broadcastManifest) { try { o.broadcastManifest(manifest); } catch (_) {} }
  log.info && log.info(`[Release] published v${curVersion} (pool ${livePool.count}): ${Object.keys(manifest.platforms).join(', ')}, ${manifest.sigs.length} sig(s).`);
  return { ran: true, version: curVersion, pool: livePool.count, platforms: Object.keys(manifest.platforms), signatures: manifest.sigs.length, published: !!publishResult };
}

/**
 * Arm the scheduler on the node. Call once at startup. Returns a stop() fn.
 * Wire into index.js after engines init:  require('./release/release_scheduler').start({...})
 */
function start(o) {
  const intervalMs = o.intervalMs || 24 * 60 * 60 * 1000; // daily default
  const tickOpts = { ...o, now: undefined };
  let timer = null;
  const tick = () => runTick({ ...tickOpts, now: Date.now() }).catch((e) => (o.log || console).warn('[Release] tick error: ' + e.message));
  timer = setInterval(tick, intervalMs);
  if (o.runImmediately) tick();
  return () => clearInterval(timer);
}

module.exports = { runTick, start, readVersion, nodeRamMb, DEFAULT_MIN_BUILD_RAM_MB };
