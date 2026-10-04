'use strict';
/**
 * build_release.js — assemble + threshold-sign a Distribution Manifest over the
 * built platform artifacts. This is what the autonomous release node runs each
 * cycle (after crossCompileAll + buildAndroidApk). Run standalone to produce a
 * real signed manifest from already-built binaries.
 *
 * Usage: node build_release.js <version> <artifactsDir> <outManifest> [signerSeedsCsv] [threshold]
 *   artifactsDir layout (any present are included):
 *     SovWallet-win.exe | sov-wallet-win.exe   -> windows
 *     SovWallet-macos   | sov-wallet-macos      -> macos
 *     SovWallet-linux   | sov-wallet-linux      -> linux
 *     SovWallet.apk                             -> android
 */
const fs = require('fs');
const path = require('path');
const { buildManifest, sha256File } = require('./autobuild');
const { addSignature, verifyManifest, _pubFromSeed } = require('./release_signer');

const PLATFORM_FILES = {
  windows: ['SovWallet-win.exe', 'sov-wallet-win.exe'],
  macos:   ['SovWallet-macos', 'sov-wallet-macos'],
  linux:   ['SovWallet-linux', 'sov-wallet-linux'],
  android: ['SovWallet.apk'],
};

function collectArtifacts(dir) {
  const out = [];
  for (const [platform, names] of Object.entries(PLATFORM_FILES)) {
    for (const n of names) {
      const p = path.join(dir, n);
      if (fs.existsSync(p)) {
        out.push({ platform, file: n, sha256: sha256File(p), size: fs.statSync(p).size });
        break;
      }
    }
  }
  return out;
}

function buildSigned({ version, artifactsDir, baseUrls, signerSeeds, threshold, builtAt, pool, govVersion }) {
  const artifacts = collectArtifacts(artifactsDir);
  if (!artifacts.length) throw new Error('no platform artifacts found in ' + artifactsDir);
  let manifest = buildManifest({ version, artifacts, baseUrls });
  manifest.built_at = builtAt;           // caller-supplied (no Date in some contexts)
  // The bootstrap relay pool baked into THESE artifacts (count + fingerprint). This is
  // what lets nodes detect a stale download pool and republish so new downloaders get
  // live relays (survive genesis death). Set by the scheduler from the current pool.
  if (pool) manifest.pool = pool;
  // Bake the governance version INTO the signed payload so a poll that flips a feature
  // default (a governance_version bump) forces a fresh release carrying it — new users
  // then get the current activated/deactivated feature state. (king, 2026-08-15)
  if (govVersion != null) manifest.gov_version = parseInt(govVersion, 10) || 0;
  manifest.signing = { model: 'witness-signer-threshold', alg: 'ed25519', threshold };
  for (const seed of signerSeeds) manifest = addSignature(manifest, seed);
  return manifest;
}

if (require.main === module) {
  const [, , version = '1.3.0', artifactsDir = '.', outManifest = 'sov-release-manifest.json',
         signerSeedsCsv = '', thresholdArg = '3'] = process.argv;
  const crypto = require('crypto');
  // Real runs pass the witness-signer FROST shares; for a standalone test, mint signers.
  const signerSeeds = signerSeedsCsv
    ? signerSeedsCsv.split(',')
    : Array.from({ length: 3 }, () => crypto.randomBytes(32).toString('hex'));
  const threshold = parseInt(thresholdArg, 10);
  const baseUrls = { windows: 'https://dl.sov.network/', macos: 'https://dl.sov.network/',
                     linux: 'https://dl.sov.network/', android: 'https://dl.sov.network/' };
  const manifest = buildSigned({ version, artifactsDir, baseUrls, signerSeeds, threshold, builtAt: Date.now() });
  fs.writeFileSync(outManifest, JSON.stringify(manifest, null, 2));
  const trusted = signerSeeds.map(_pubFromSeed);
  const v = verifyManifest(manifest, trusted, threshold);
  console.log('platforms:', manifest.sigs ? Object.keys(manifest.platforms).join(', ') : '');
  console.log('signers:', manifest.sigs.length, '| threshold:', threshold, '| verify:', JSON.stringify(v));
  console.log('wrote', outManifest);
}

module.exports = { buildSigned, collectArtifacts };
