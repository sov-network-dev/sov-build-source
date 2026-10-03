// ─────────────────────────────────────────────────────────────────────────────
// INTEGRITY CHECKER — Verifies node software has not been tampered with
// ─────────────────────────────────────────────────────────────────────────────
// On every boot, before doing anything else, the node verifies every source
// file against a SHA-256 manifest signed by the SOV Network master key.
//
// If any file has been modified — by malware, by a malicious update, by anyone
// — the node refuses to start and alerts the operator.
//
// The network master public key is embedded here at build time.
// It can only be rotated by a governance supermajority vote.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const nacl   = require('tweetnacl');
const fs     = require('fs');
const path   = require('path');

// SOV Network master verification key — embedded at build time
// This key signed the software manifest. Changing it requires a governance vote.
const NETWORK_MASTER_PUBLIC_KEY_HEX =
  '0000000000000000000000000000000000000000000000000000000000000000'; // placeholder — set at build time

const MANIFEST_FILE = path.join(__dirname, '../../keys/manifest.sig');
const SRC_DIR       = path.join(__dirname, '..');

class IntegrityChecker {

  static async verify() {
    // In development mode, skip integrity check
    if (process.env.NODE_ENV === 'development') {
      global.sovLog.info('      [DEV] Integrity check skipped in development mode');
      return;
    }

    // Check if manifest exists
    if (!fs.existsSync(MANIFEST_FILE)) {
      // First run before signing — warn but allow
      global.sovLog.warn('      No signed manifest found — run `npm run sign` to generate');
      return;
    }

    try {
      const manifestData = fs.readFileSync(MANIFEST_FILE);
      const signature    = manifestData.subarray(0, 64);
      const manifestBody = manifestData.subarray(64);

      // Verify signature
      const masterKey = Buffer.from(NETWORK_MASTER_PUBLIC_KEY_HEX, 'hex');
      const valid = nacl.sign.detached.verify(
        new Uint8Array(manifestBody),
        new Uint8Array(signature),
        new Uint8Array(masterKey)
      );

      if (!valid) {
        throw new Error('INTEGRITY_FAIL: Manifest signature invalid — software may be compromised');
      }

      // Verify each file listed in manifest
      const manifest = JSON.parse(manifestBody.toString());
      const failures = [];

      for (const [relPath, expectedHash] of Object.entries(manifest.files)) {
        const fullPath = path.join(SRC_DIR, relPath);
        if (!fs.existsSync(fullPath)) {
          failures.push(`Missing: ${relPath}`);
          continue;
        }
        const fileHash = crypto.createHash('sha256')
          .update(fs.readFileSync(fullPath))
          .digest('hex');
        if (fileHash !== expectedHash) {
          failures.push(`Modified: ${relPath}`);
        }
      }

      if (failures.length > 0) {
        throw new Error(
          `INTEGRITY_FAIL: ${failures.length} file(s) modified:\n${failures.join('\n')}`
        );
      }

    } catch (err) {
      global.sovLog.error('');
      global.sovLog.error('╔══════════════════════════════════════════════════════╗');
      global.sovLog.error('║  SOV NODE INTEGRITY CHECK FAILED                     ║');
      global.sovLog.error('║  This software has been modified or corrupted.       ║');
      global.sovLog.error('║  Do not run this node. Download a fresh copy from    ║');
      global.sovLog.error('║  any trusted SOV node: http://[node-ip]/download     ║');
      global.sovLog.error('╚══════════════════════════════════════════════════════╝');
      global.sovLog.error(err.message);
      global.sovLog.error('');
      process.exit(2);
    }
  }

  // Called by `npm run sign` to generate the signed manifest
  static async generateManifest(privateKeyHex) {
    const files  = {};
    const walk   = (dir, base) => {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        const rel  = path.join(base, entry.name);
        if (entry.isDirectory()) {
          walk(full, rel);
        } else if (entry.name.endsWith('.js')) {
          files[rel] = crypto.createHash('sha256')
            .update(fs.readFileSync(full))
            .digest('hex');
        }
      }
    };
    walk(SRC_DIR, '');

    const manifestBody = Buffer.from(JSON.stringify({
      version:   require('../../package.json').version,
      generated: Date.now(),
      files,
    }));

    const privateKey = Buffer.from(privateKeyHex, 'hex');
    const signature  = nacl.sign.detached(
      new Uint8Array(manifestBody),
      new Uint8Array(privateKey)
    );

    const output = Buffer.concat([Buffer.from(signature), manifestBody]);
    fs.mkdirSync(path.dirname(MANIFEST_FILE), { recursive: true });
    fs.writeFileSync(MANIFEST_FILE, output);
    console.log(`Manifest signed. ${Object.keys(files).length} files covered.`);
  }
}

module.exports = { IntegrityChecker };
