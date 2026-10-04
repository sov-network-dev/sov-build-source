// ─────────────────────────────────────────────────────────────────────────────
// NODE IDENTITY — Cryptographic identity for a SOV Node
// ─────────────────────────────────────────────────────────────────────────────
// Every SOV Node has a permanent Ed25519 identity keypair.
// Node ID = SHA-256(public key) — permanent even if IP changes.
//
// Key storage priority:
//   1. TPM (Trusted Platform Module) — hardware-bound, never leaves chip
//   2. Encrypted file — AES-256-GCM protected by machine-derived key
//
// The node's public key is broadcast to the peer network.
// All node-to-node messages are signed with this key.
// Citizens' apps verify this signature — no third-party certificate needed.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const nacl    = require('tweetnacl');
const forge   = require('node-forge');
const crypto  = require('crypto');
const fs      = require('fs');
const path    = require('path');
const os      = require('os');

const DATA_DIR   = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
const KEY_FILE   = path.join(DATA_DIR, 'node_identity.enc');
const PUB_FILE   = path.join(DATA_DIR, 'node_public.pem');

class NodeIdentity {

  constructor({ nodeId, publicKey, sign, storageMethod }) {
    this.nodeId        = nodeId;        // SHA-256(pubKey) — permanent node identifier
    this.publicKey     = publicKey;     // Ed25519 public key bytes (32 bytes)
    this.sign          = sign;          // fn(data: Buffer) => signature: Buffer
    this.storageMethod = storageMethod; // 'TPM' | 'encrypted-file'

    // The Sovereign ID of the citizen who operates this node.
    // Set OPERATOR_SOVEREIGN_ID=SOV-XX999-XXXXXXXX in snap.env after your first enrollment.
    // Used by the operator engine to link proof-of-service earnings to your wallet.
    // Empty string until the operator fills it in — the node works fine without it.
    this.operatorSovereignId =
      NodeIdentity.normaliseOperatorId(process.env.OPERATOR_SOVEREIGN_ID);
  }

  /** Canonical Sovereign ID shape used across the protocol: SOV- + 16 hex. */
  static get OPERATOR_ID_RE() { return /^SOV-[0-9A-F]{16}$/; }

  /** Trim + uppercase an operator ID. Returns '' when unset. */
  static normaliseOperatorId(raw) {
    return String(raw || '').trim().toUpperCase();
  }

  /**
   * Validate the operator ID at startup.
   *
   * A malformed value is always fatal: it is a typo, and letting it through would
   * register this node under an ID nobody owns — the payouts would simply vanish.
   *
   * A blank value is fatal only on FIRST RUN (no node key on disk yet). That is a
   * brand-new operator who would otherwise serve citizens for free without ever
   * being told. Established nodes keep running regardless, so upgrading can never
   * take the live fleet down over a config field.
   */
  static assertOperatorId({ firstRun, genesis }) {
    const id = NodeIdentity.normaliseOperatorId(process.env.OPERATOR_SOVEREIGN_ID);

    if (id && NodeIdentity.OPERATOR_ID_RE.test(id)) return { ok: true, id };

    // A malformed ID is ALWAYS fatal (typo), even at genesis — better to stop than
    // to register under an ID nobody owns and vanish the payouts.
    if (id) {
      return { ok: false, id, reason: [
        'OPERATOR_SOVEREIGN_ID is "' + id + '", which is not a Sovereign ID.',
        'Expected SOV- followed by 16 hex characters, e.g. SOV-1A2B3C4D5E6F7A8B.',
        'Copy it exactly from your wallet: Profile -> your Sovereign ID.',
      ] };
    }

    // GENESIS EXCEPTION. A first run with NO bootstrap is the operator STARTING the
    // network, not joining one — and they cannot yet have a Sovereign ID, because the
    // app needs a LIVE node to enrol a palm against. The very first node must come up
    // BEFORE any ID can exist. So a blank ID is fatal only for a JOINING first run;
    // at genesis it is expected. The node serves; the founder enrols as citizen #1;
    // then they set OPERATOR_SOVEREIGN_ID and restart to claim proof-of-service.
    if (firstRun && !genesis) {
      return { ok: false, id: '', reason: [
        'OPERATOR_SOVEREIGN_ID is not set.',
        'This node is JOINING an existing network, so it needs the Sovereign ID of an',
        'enrolled citizen — the network will check it against the enrollment ledger.',
        'Enrol on the SOV phone app, copy your Sovereign ID from Profile, set it in',
        'your .env, then start the node again.',
      ] };
    }

    return { ok: true, id: '', warn: true, genesis: !!(firstRun && genesis) };
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  static async load() {
    fs.mkdirSync(DATA_DIR, { recursive: true });

    // Try TPM first
    try {
      const tpm = await NodeIdentity._loadFromTPM();
      if (tpm) {
        global.sovLog.info('      Node key loaded from TPM hardware');
        return tpm;
      }
    } catch (_) { /* TPM not available on this machine */ }

    // Fall back to encrypted key file
    if (fs.existsSync(KEY_FILE)) {
      global.sovLog.info('      Node key loaded from encrypted file');
      return NodeIdentity._loadFromFile();
    }

    // GUARD (identity-churn / operator over-count): a data dir that already holds
    // a node.db has PRIOR state — an operator, a reputation, citizens on disc. If
    // its key file is gone we must NOT silently generate a brand-new identity over
    // it: that orphans the existing node and spawns a duplicate operator (exactly
    // the "a node ran for an hour with an identity it never persisted" incident).
    // A missing key beside real state is an error to surface, not to paper over.
    const dbPath = path.join(DATA_DIR, 'node.db');
    if (fs.existsSync(dbPath)) {
      throw new Error(
        'IDENTITY_MISSING_OVER_EXISTING_STATE — ' + KEY_FILE + ' is gone but a ' +
        'node.db exists in ' + DATA_DIR + '. Refusing to mint a NEW identity over ' +
        'existing state (it would orphan this node and duplicate the operator). ' +
        'Restore node_identity.enc from backup, or point SOV_DATA_DIR at the ' +
        'correct data directory.');
    }

    // First run — generate new identity
    global.sovLog.info('      First run — generating node identity...');
    return NodeIdentity._generateAndStore();
  }

  // Sign arbitrary data — used for NODE_ANNOUNCE, NODE_HEARTBEAT, etc.
  signMessage(data) {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(JSON.stringify(data));
    return this.sign(buf);
  }

  // Verify a message signed by another node
  static verify(data, signature, senderPublicKey) {
    const dataBuf = Buffer.isBuffer(data) ? data : Buffer.from(JSON.stringify(data));
    return nacl.sign.detached.verify(
      new Uint8Array(dataBuf),
      new Uint8Array(signature),
      new Uint8Array(senderPublicKey)
    );
  }

  // Export public identity for peer announcements
  toAnnouncement() {
    return {
      node_id:    this.nodeId,
      public_key: Buffer.from(this.publicKey).toString('hex'),
      version:    require('../../package.json').version,
    };
  }

  // ── Private: Generate and store ────────────────────────────────────────────

  static async _generateAndStore() {
    const keypair    = nacl.sign.keyPair();
    const publicKey  = keypair.publicKey;
    const privateKey = keypair.secretKey;
    const nodeId     = crypto.createHash('sha256').update(publicKey).digest('hex');

    // Derive machine-specific encryption key for private key storage
    const machineKey = NodeIdentity._deriveMachineKey();

    // Encrypt private key with AES-256-GCM
    const salt  = crypto.randomBytes(16);
    const nonce = crypto.randomBytes(12);
    const aesKey = crypto.scryptSync(machineKey, salt, 32);
    const cipher = crypto.createCipheriv('aes-256-gcm', aesKey, nonce);
    const ct     = Buffer.concat([cipher.update(privateKey), cipher.final()]);
    const tag    = cipher.getAuthTag();

    // Store: magic(4) + salt(16) + nonce(12) + tag(16) + ciphertext
    const stored = Buffer.concat([
      Buffer.from('SOVK'),
      salt, nonce, tag, ct
    ]);
    fs.writeFileSync(KEY_FILE, stored, { mode: 0o600 }); // owner-read only

    // Store public key separately (not secret)
    fs.writeFileSync(PUB_FILE, Buffer.from(publicKey).toString('hex'));

    global.sovLog.info(`      Generated Node ID: ${nodeId}`);
    global.sovLog.info('      Private key stored in encrypted file (AES-256-GCM)');

    return new NodeIdentity({
      nodeId,
      publicKey,
      sign: (data) => Buffer.from(
        nacl.sign.detached(new Uint8Array(data), new Uint8Array(privateKey))
      ),
      storageMethod: 'encrypted-file',
    });
  }

  static _loadFromFile() {
    const stored     = fs.readFileSync(KEY_FILE);
    const magic      = stored.subarray(0, 4).toString();
    if (magic !== 'SOVK') throw new Error('Corrupted key file');

    const salt       = stored.subarray(4,  20);
    const nonce      = stored.subarray(20, 32);
    const tag        = stored.subarray(32, 48);
    const ct         = stored.subarray(48);

    const machineKey = NodeIdentity._deriveMachineKey();
    const aesKey     = crypto.scryptSync(machineKey, salt, 32);
    const decipher   = crypto.createDecipheriv('aes-256-gcm', aesKey, nonce);
    decipher.setAuthTag(tag);

    let privateKey;
    try {
      privateKey = Buffer.concat([decipher.update(ct), decipher.final()]);
    } catch (_) {
      throw new Error('KEY_DECRYPT_FAILED — wrong machine or corrupted file');
    }

    // The identity is derived from the PRIVATE key we just decrypted — the single
    // source of truth. Reading the public key from a SEPARATE node_public.pem let
    // the reported node id silently drift whenever that file was stale, swapped,
    // or restored from a different backup than the key — one root of the identity
    // churn / operator over-count. The tweetnacl secret key is seed(32)+pub(32);
    // fromSecretKey recovers the matching public key with certainty.
    const publicKey = Buffer.from(
      nacl.sign.keyPair.fromSecretKey(new Uint8Array(privateKey)).publicKey);
    const nodeId    = crypto.createHash('sha256').update(publicKey).digest('hex');

    // Keep node_public.pem in step with the key (best-effort self-heal): if it had
    // drifted, rewrite it so external readers match what we actually sign with.
    try {
      const pubHex = publicKey.toString('hex');
      if (fs.readFileSync(PUB_FILE, 'utf8').trim() !== pubHex) {
        fs.writeFileSync(PUB_FILE, pubHex);
        global.sovLog.warn('      node_public.pem was stale — rewritten to match the private key');
      }
    } catch (_) { try { fs.writeFileSync(PUB_FILE, publicKey.toString('hex')); } catch (__) {} }

    return new NodeIdentity({
      nodeId,
      publicKey,
      sign: (data) => Buffer.from(
        nacl.sign.detached(new Uint8Array(data), new Uint8Array(privateKey))
      ),
      storageMethod: 'encrypted-file',
    });
  }

  static async _loadFromTPM() {
    // TPM integration via Windows CNG API (tpm2-tools on Linux)
    // If neither is available, returns null and falls back to encrypted file.
    // Full TPM implementation goes here in platform-specific builds.
    // For now, return null to use encrypted-file path on all platforms.
    return null;
  }

  // ── Machine-binding key ────────────────────────────────────────────────────
  // Derives a machine-specific secret from hardware identifiers.
  // The private key encrypted with this secret is bound to THIS machine.
  // Copying the key file to another machine will not decrypt it.

  static _deriveMachineKey() {
    const components = [
      os.hostname(),
      os.platform(),
      os.arch(),
      // Machine ID from OS (stable across reboots)
      NodeIdentity._getMachineId(),
    ].join('|');
    return crypto.createHash('sha256').update(components).digest('hex');
  }

  static _getMachineId() {
    // Linux: /etc/machine-id
    // Windows: registry MachineGuid
    // macOS: IOPlatformSerialNumber
    try {
      if (process.platform === 'linux') {
        return fs.readFileSync('/etc/machine-id', 'utf8').trim();
      } else if (process.platform === 'win32') {
        const { execSync } = require('child_process');
        return execSync(
          'powershell -command "(Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Cryptography MachineGuid).MachineGuid"',
          { encoding: 'utf8' }
        ).trim();
      } else if (process.platform === 'darwin') {
        const { execSync } = require('child_process');
        return execSync(
          'ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformSerialNumber',
          { encoding: 'utf8' }
        ).trim();
      }
    } catch (_) {}
    return 'fallback-machine-id';
  }
}

module.exports = { NodeIdentity };
