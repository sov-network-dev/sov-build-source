// ─────────────────────────────────────────────────────────────────────────────
// SOV NODE DATABASE — SQLite storage for node state
// ─────────────────────────────────────────────────────────────────────────────
// Uses better-sqlite3-multiple-ciphers for AES-256 encrypted SQLite storage.
// All database operations are synchronous — no async/await complexity.
//
// ENCRYPTION: Every page of node.db is AES-256 encrypted at rest.
//   - The encryption key is derived from the node's Ed25519 identity private key
//     using HKDF-SHA256 — it is never written to disk in any file.
//   - An operator who copies node.db sees only random bytes without the key.
//   - If no identity keypair exists yet (first run), falls back to a machine-
//     derived key (hostname + DATA_DIR). The DB is re-encrypted with the proper
//     identity key the next time NodeIdentity initialises.
//
// Tables:
//   sov_disc              — The Sovereign Disc: every citizen's balance record
//   sov_enrollments       — Enrolled citizens: biometric public keys
//   sov_transactions      — Recent transaction audit log (NOT permanent history)
//   sov_presence          — Current citizen→node mapping
//   sov_watch_list        — Who is watching whom for online notifications
//   sov_message_records   — Message metadata (NOT content — content is E2E encrypted)
//   sov_pending_messages  — Messages queued for offline citizens
//   sov_pending_tx        — Transactions queued across relay boundaries
//   sov_node_registry     — Known peer nodes
//   sov_governance_params — Network-wide governance parameter store
//   sov_messaging_keys    — Citizen X25519 public keys for E2E encryption
// ─────────────────────────────────────────────────────────────────────────────

'use strict';


// ─── Canonical economic invariants (Protocol Book Chapter 10) ──────────────
// Cannot be exceeded by any minting code path. If a credit would push total
// supply above this, the credit is rejected. Cannot be changed without a
// governance-voted protocol upgrade per sealed-launch §905.
const MAX_TOTAL_SUPPLY_SEEDS = 50_000_000_000_000;  // 50,000,000 SOV
const SOV_PER_SEED            = 1_000_000;
// ───────────────────────────────────────────────────────────────────────────

const Database = require('better-sqlite3-multiple-ciphers');
const path     = require('path');
const fs       = require('fs');
const os       = require('os');
const crypto   = require('crypto');

// ── Explicit cipher pin ──────────────────────────────────────────────────────
// The code used to apply only `pragma key` and ride the library's DEFAULT
// cipher. That default is version-specific: better-sqlite3-multiple-ciphers v12
// defaults to chacha20/kdf_iter=64007, and v11's chacha20 default is a DIFFERENT
// on-disk format — a v11 node literally cannot open a v12-default DB (verified
// 2026-08-03: "file is not a database"). Riding an implicit default means a
// future dependency bump could silently change the format and lock every node
// out of its own ledger.
//
// So pin it. These exact values ARE v12's current default, so this is a NO-OP
// for the existing v12 nodes (they keep opening their DBs unchanged — verified),
// and it lets a Node-18 / v11 build (the Catalina home node, which cannot run
// v12 because that needs Node 20+) use the SAME explicit scheme instead of v11's
// diverging default. Set BEFORE `pragma key`, at every key-application site.
function _pinCipher(db) {
  db.pragma("cipher='chacha20'");
  db.pragma('kdf_iter=64007');
}

// ── DB encryption key derivation (v2 — persistent, survives snap upgrades) ───
// Key lives in $SNAP_COMMON which Snap guarantees to preserve across every
// revision upgrade. On first install a random 256-bit key is generated and
// written there mode 600. Every subsequent boot reads it back. Snap can
// install v2 → v3 → v100 and the same key keeps working forever.
//
// Non-snap environments (dev, test) fall back to a machine-id stable key.
// Pre-v1.2.3 DBs encrypted under the old dataDir-based derivation are
// auto-migrated by the NodeDB constructor on first boot of v1.2.3+.
function _persistentKeyPath() {
  const snapCommon = process.env.SNAP_COMMON;
  if (snapCommon && snapCommon.length > 0) {
    return path.join(snapCommon, 'db-encryption-key');
  }
  // Non-snap: persist alongside data dir
  const dataDir = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
  return path.join(dataDir, 'db-encryption-key');
}

// ── Cross-platform key-at-rest protection ────────────────────────────────────
// Windows: wrap the raw DB key with DPAPI (CryptProtectData, CurrentUser scope)
//   so a COPIED key file is cryptographically useless on any other machine or
//   Windows user account — the OS binds the ciphertext to this user's login.
// Linux (VPS/snap): DPAPI does not exist. Protection is owner-only (chmod 600)
//   + the immutable flag (chattr +i). The key content is NOT changed on Linux,
//   so this path can never lock a node out of its own DB (TPM/keyring is a
//   separate, larger hardening tracked for later).
const _DPAPI_PREFIX = 'DPAPIv1:';

function _psEncoded(script) { return Buffer.from(script, 'utf16le').toString('base64'); }

// op:'protect' → input=rawHex, returns base64 blob. op:'unprotect' → input=blob, returns rawHex.
// The key never appears on the command line — it is piped over STDIN. Throws on failure.
function _winDpapi(op, input) {
  const script = (op === 'protect')
    ? "Add-Type -AssemblyName System.Security;$i=[Console]::In.ReadToEnd().Trim();"
      + "$b=[Text.Encoding]::UTF8.GetBytes($i);"
      + "$p=[Security.Cryptography.ProtectedData]::Protect($b,$null,'CurrentUser');"
      + "[Convert]::ToBase64String($p)"
    : "Add-Type -AssemblyName System.Security;$i=[Console]::In.ReadToEnd().Trim();"
      + "$d=[Convert]::FromBase64String($i);"
      + "$u=[Security.Cryptography.ProtectedData]::Unprotect($d,$null,'CurrentUser');"
      + "[Text.Encoding]::UTF8.GetString($u)";
  return require('child_process').execSync(
    'powershell -NoProfile -NonInteractive -EncodedCommand ' + _psEncoded(script),
    { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }
  ).trim();
}

// Lock a Windows key file's ACL to the current user only (drop inherited groups).
function _winLockAcl(keyFile) {
  try {
    require('child_process').execSync(
      'icacls "' + keyFile + '" /inheritance:r /grant:r "%USERNAME%:F"',
      { stdio: 'ignore', shell: 'cmd.exe' });
  } catch (_) {}
}

// Persist a freshly-generated key, protected for the platform. Never throws.
function _persistKeyProtected(keyFile, keyHex) {
  let content = keyHex;
  if (process.platform === 'win32') {
    try {
      const blob = _winDpapi('protect', keyHex);
      if (_winDpapi('unprotect', blob) === keyHex) content = _DPAPI_PREFIX + blob; // verify round-trip
    } catch (_) { /* DPAPI unavailable — store plaintext, still 600 + ACL-locked */ }
  }
  fs.writeFileSync(keyFile, content, { mode: 0o600 });
  try { fs.chmodSync(keyFile, 0o600); } catch (_) {}
  if (process.platform === 'win32') {
    _winLockAcl(keyFile);
  } else if (process.platform === 'darwin') {
    // macOS has no chattr; chflags uchg is the equivalent immutable flag. Gives
    // the Catalina home node the same delete/overwrite protection a Linux node
    // gets from chattr +i (owner-only 0600 above, plus immutability here).
    try { require('child_process').execSync('chflags uchg "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
  } else {
    try { require('child_process').execSync('chattr +i "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
  }
}

// Upgrade an existing LEGACY PLAINTEXT key file to the protected form. Best-effort,
// verify-before-replace, atomic (temp+rename) — a failure leaves the plaintext key
// intact so a node can never be locked out of its own DB.
function _upgradeKeyAtRest(keyFile, plainHex) {
  try {
    if (process.platform === 'win32') {
      let blob;
      try { blob = _winDpapi('protect', plainHex); } catch (_) { return; }
      if (_winDpapi('unprotect', blob) !== plainHex) return; // round-trip failed — keep plaintext
      const tmp = keyFile + '.tmp';
      fs.writeFileSync(tmp, _DPAPI_PREFIX + blob, { mode: 0o600 });
      // The constructor holds a read FD on the key file; on Windows that handle
      // blocks renaming over it (EPERM). Release it for the atomic swap, then
      // re-hold it on the new (DPAPI) file so deletion-protection is preserved.
      try { if (NodeDB._KEY_FD_HELD != null) { fs.closeSync(NodeDB._KEY_FD_HELD); NodeDB._KEY_FD_HELD = null; } } catch (_) {}
      fs.renameSync(tmp, keyFile);
      try { NodeDB._KEY_FD_HELD = fs.openSync(keyFile, 'r'); } catch (_) {}
      _winLockAcl(keyFile);
      if (global.sovLog) global.sovLog.info('      [DB-KEY] Upgraded DB key to DPAPI (bound to this Windows user)');
    } else if (process.platform === 'darwin') {
      // macOS: clear immutability, re-assert 0600, re-apply immutability. Same
      // no-content-change hardening as the Linux path, using chflags.
      try { require('child_process').execSync('chflags nouchg "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
      try { fs.chmodSync(keyFile, 0o600); } catch (_) {}
      try { require('child_process').execSync('chflags uchg "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
    } else {
      // Linux/snap: re-assert owner-only + immutable. No content change → zero risk.
      try { require('child_process').execSync('chattr -i "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
      try { fs.chmodSync(keyFile, 0o600); } catch (_) {}
      try { require('child_process').execSync('chattr +i "' + keyFile + '"', { stdio: 'ignore' }); } catch (_) {}
    }
  } catch (_) { /* never let key hardening break boot */ }
}

function _deriveDbKey() {
  const keyFile = _persistentKeyPath();
  try {
    if (fs.existsSync(keyFile)) {
      const raw = fs.readFileSync(keyFile, 'utf8').trim();
      // DPAPI-protected form (Windows) — decrypt it back to the raw key.
      if (raw.startsWith(_DPAPI_PREFIX)) {
        try {
          const k = _winDpapi('unprotect', raw.slice(_DPAPI_PREFIX.length));
          if (k.length === 64 && /^[0-9a-f]+$/i.test(k)) return k;
        } catch (e) {
          if (global.sovLog) global.sovLog.error('[DB-KEY] DPAPI unprotect failed (wrong user/machine?): ' + e.message);
          // cannot recover a DPAPI key without the same Windows user — fall through
        }
      }
      // Legacy plaintext hex — use it, and opportunistically harden at rest.
      if (raw.length === 64 && /^[0-9a-f]+$/i.test(raw)) {
        _upgradeKeyAtRest(keyFile, raw);
        return raw;
      }
    }
  } catch (_) {}
  // First boot — generate a cryptographic random key and persist it protected.
  try {
    fs.mkdirSync(path.dirname(keyFile), { recursive: true });
    const newKey = crypto.randomBytes(32).toString('hex');
    _persistKeyProtected(keyFile, newKey);
    if (global.sovLog) global.sovLog.info('      [DB-KEY] Generated DB key ('
      + (process.platform === 'win32' ? 'DPAPI-protected + ACL-locked' : 'owner-only 600 + immutable') + ')');
    return newKey;
  } catch (e) {
    // Filesystem write failed — last-resort deterministic key (logs alert)
    if (global.sovLog) global.sovLog.error(`[DB-KEY] Could not persist key: ${e.message} — using fallback`);
    let machineId = '';
    try { machineId = fs.readFileSync('/etc/machine-id', 'utf8').trim(); } catch (_) {}
    return crypto.createHash('sha256')
      .update('sov-db-fallback-v2:' + os.hostname() + ':' + machineId)
      .digest('hex');
  }
}

// V1 legacy fallback — kept ONLY for migrating pre-v2 DBs on first boot
function _deriveLegacyDbKey(dataDir) {
  return crypto.createHash('sha256')
    .update('sov-db-fallback:' + os.hostname() + ':' + dataDir)
    .digest('hex');
}

const DATA_DIR = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
const DB_FILE  = path.join(DATA_DIR, 'node.db');

// Append-only shared-consensus tables reconciled network-wide (every node holds all,
// so a citizen on ANY node sees the same guardians/justice/groups/platforms/etc).
// Excludes monetary/pool tables (balance-Merkle owns those), ephemeral/node-local tables
// (presence, proof-of-service log, sessions, pending queues) and already-reconciled tables
// (disc/enrollments/embeddings/exchange/governance_params). Carry-all + INSERT-OR-IGNORE.
const CONSENSUS_TABLES = [
  'sov_guardians','sov_recovery_requests','sov_payment_requests',
  'sov_disputes','sov_case_jurors','sov_justice_councils','sov_council_votes',
  'sov_groups','sov_group_members','sov_group_messages',
  'sov_academy_articles','sov_academy_upvotes','sov_enclave_posts','sov_enclave_replies',
  'sov_message_reactions','sov_platforms','sov_messaging_keys',
  'sov_reputation','sov_polls','sov_poll_votes','sov_petitions','sov_petition_signatures',
  'sov_value_proposals','sov_vaults','sov_vault_claims','sov_inheritance_escrow',
  'sov_profiles'
  // sov_pioneer_questions intentionally NOT in consensus: it is code-shipped
  // content (the certification quiz), reseeded deterministically by every node
  // at boot — syncing it caused per-node autoincrement ids to re-add each
  // other's copies in a perpetual add/heal flap.
];

class NodeDB {

  // Class-level held FD on the key file (protection: cannot be deleted
  // while the sov-node process is running)
  static _KEY_FD_HELD = null;

  constructor() {
    fs.mkdirSync(DATA_DIR, { recursive: true });

    // Hold an open FD on the key file for the process lifetime. While this
    // FD is open, the kernel keeps the inode alive even if a (privileged)
    // operator runs `rm` — the file disappears from the directory but the
    // node continues using it. Combined with chattr +i, this makes the key
    // effectively undeletable while the node is running.
    if (!NodeDB._KEY_FD_HELD) {
      try {
        const keyFile = _persistentKeyPath();
        if (fs.existsSync(keyFile)) {
          NodeDB._KEY_FD_HELD = fs.openSync(keyFile, 'r');
        }
      } catch (_) { /* file may not yet exist on first boot — generated below */ }
    }

    this._db = new Database(DB_FILE);

    this._nodeId      = null;   // set by PoolDeltaSync.start()

    this._onPoolDelta = null;   // broadcast sink installed by PoolDeltaSync

    // ── Encryption — MUST be set before any other pragma or query ─────────────
    // SQLCipher requires the key to be the very first operation on the connection.
    // We use the raw-key format (x'hex...') to bypass PBKDF2 stretching, since
    // our key material is already cryptographically strong (HKDF output).
    // Re-open held FD after key created on first boot (line above)
    if (!NodeDB._KEY_FD_HELD) {
      try {
        const keyFile = _persistentKeyPath();
        if (fs.existsSync(keyFile)) NodeDB._KEY_FD_HELD = fs.openSync(keyFile, 'r');
      } catch (_) {}
    }
    const dbKey = _deriveDbKey();
    _pinCipher(this._db);
    this._db.pragma(`key="x'${dbKey}'"`);

    // First-boot migration: legacy v1 DBs were encrypted with a key derived
    // from the dataDir path string. That changes when snap upgrades, which
    // is why we are migrating. If the new key fails to decrypt the existing
    // DB, try every known legacy candidate, then re-key to the persistent
    // key. Runs only once — once the DB is re-keyed, this path is dead.
    let _verified = false;
    try {
      this._db.prepare('SELECT count(*) FROM sqlite_master').get();
      _verified = true;
    } catch (_) {
      const legacyCandidates = [
        DATA_DIR,
        process.env.SNAP_DATA || '',
        '/var/snap/sov-relay/current',
        '/var/snap/sov-relay/x1',
        '/var/snap/sov-relay/x2',
        '/var/snap/sov-relay/x3',
        '/var/snap/sov-relay/x4',
        '/var/snap/sov-relay/x5',
        os.homedir() + '/.sov-node',
      ].filter(p => p && p.length > 0);
      for (const candidate of legacyCandidates) {
        try {
          this._db.close();
          this._db = new Database(DB_FILE);
          _pinCipher(this._db);
          this._db.pragma(`key="x'${_deriveLegacyDbKey(candidate)}'"`);
          this._db.prepare('SELECT count(*) FROM sqlite_master').get();
          // Worked — re-key to the new persistent key
          this._db.pragma(`rekey="x'${dbKey}'"`);
          if (global.sovLog) global.sovLog.info(
            `      [DB-MIGRATE] Re-keyed legacy DB (was: ${candidate}) → persistent key`
          );
          _verified = true;
          break;
        } catch (_) { /* try next */ }
      }
      if (!_verified) {
        // No legacy candidate worked — re-open clean with the persistent key
        // (treats DB as fresh; works for genuinely empty / first-install case)
        try { this._db.close(); } catch (_) {}
        this._db = new Database(DB_FILE);
        _pinCipher(this._db);
        this._db.pragma(`key="x'${dbKey}'"`);
      }
    }

    this._db.pragma('journal_mode = WAL');    // Write-Ahead Logging — better concurrent reads
    // launch-and-forget disk hygiene: INCREMENTAL auto_vacuum so node.db self-compacts.
    // Setting the pragma is a no-op on an existing NONE db until one VACUUM runs; do that
    // once here (guarded — after conversion auto_vacuum reads 2 and we skip it forever).
    try {
      this._db.pragma('auto_vacuum = INCREMENTAL');
      const _av = this._db.pragma('auto_vacuum', { simple: true });
      if (_av !== 2) { this._db.exec('VACUUM'); }
    } catch (_) {}
    this._db.pragma('synchronous = NORMAL');  // Safe + fast (not paranoid)
    this._db.pragma('foreign_keys = ON');
    this._db.pragma('cache_size = -32000');   // 32MB cache
    this._initSchema();
    this._initSupplyPools();
    global.sovLog.info(`      Node database: ${DB_FILE} (AES-256 encrypted)`);
  }

  // ── Schema initialisation ──────────────────────────────────────────────────

  _initSchema() {
    this._db.exec(`

      -- ── The Sovereign Disc ────────────────────────────────────────────────
      -- Every citizen's balance. This is the permanent financial record.
      -- A citizen's Sovereign ID is derived from their biometric public key.
      -- balance_seeds: 1 SOV = 1,000,000 seeds (micro-denomination)
      CREATE TABLE IF NOT EXISTS sov_operator_payouts (
        operator_id  TEXT NOT NULL,
        period_id    INTEGER NOT NULL,
        node_count   INTEGER NOT NULL,
        amount_seeds INTEGER NOT NULL,
        fired_at     INTEGER NOT NULL,
        PRIMARY KEY (operator_id, period_id)
      );

      CREATE TABLE IF NOT EXISTS sov_pool_deltas (
        delta_id          TEXT PRIMARY KEY,
        origin_node       TEXT    NOT NULL,
        seq               INTEGER NOT NULL,
        pool_id           TEXT    NOT NULL,
        remaining_delta   INTEGER NOT NULL,
        distributed_delta INTEGER NOT NULL,
        reason            TEXT,
        created_at        INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_pool_deltas_origin_seq
        ON sov_pool_deltas (origin_node, seq);

      CREATE TABLE IF NOT EXISTS sov_supply_pools (
        pool_id            TEXT PRIMARY KEY,
        allocated_seeds    INTEGER NOT NULL,
        remaining_seeds    INTEGER NOT NULL,
        distributed_seeds  INTEGER NOT NULL DEFAULT 0,
        updated_at         INTEGER NOT NULL DEFAULT 0
      );

      -- ── Pool fee inflow, per 30-day period (SOV_OPERATOR_ECONOMY_SPEC §3) ──
      -- Records fees COLLECTED into a pool (transfer fees, platform registration)
      -- so operator payouts can spend inflow first and only then draw, capped, on
      -- the reserve. Without this the reserve is the only funding source and it
      -- drains. Written by addToPool(); read by the monthly payout.
      CREATE TABLE IF NOT EXISTS sov_pool_inflow (
        pool_id    TEXT    NOT NULL,
        period_id  INTEGER NOT NULL,
        seeds      INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (pool_id, period_id)
      );

      -- Fees that could NOT be credited to their pool. Previously these were
      -- swallowed with a log line and the seeds simply vanished, which made
      -- "collected fees == pool credits" unauditable. Recording the obligation
      -- here means a failure is recoverable instead of silent.
      CREATE TABLE IF NOT EXISTS sov_fee_unrouted (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        pool_id    TEXT    NOT NULL,
        seeds      INTEGER NOT NULL,
        source     TEXT    NOT NULL,      -- 'transfer' | 'exchange' | ...
        ref        TEXT,                  -- tx id / order id for reconciliation
        reason     TEXT,
        created_at INTEGER NOT NULL,
        resolved_at INTEGER
      );

      CREATE TABLE IF NOT EXISTS sov_disc (
        slot_id         INTEGER PRIMARY KEY,
        sovereign_id    TEXT NOT NULL UNIQUE,
        balance_seeds   INTEGER NOT NULL DEFAULT 0,
        spendable_seeds INTEGER NOT NULL DEFAULT 0,
        version         INTEGER NOT NULL DEFAULT 0,
        last_tx_hash    TEXT    NOT NULL DEFAULT '',
        nonce           INTEGER NOT NULL DEFAULT 0,
        updated_at      INTEGER NOT NULL DEFAULT 0,
        pioneer_badges  TEXT DEFAULT '',
        liveness_ts     INTEGER NOT NULL DEFAULT 0   -- last proof-of-life / login (epoch SECONDS); 0 = never
      );

      -- ── Enrollments ───────────────────────────────────────────────────────
      -- Citizens enrolled on this node. Stores their biometric Ed25519 public key.
      -- The node verifies HELLO signatures against this key.
      CREATE TABLE IF NOT EXISTS sov_enrollments (
        sovereign_id    TEXT PRIMARY KEY,
        public_key_hex  TEXT NOT NULL,               -- Ed25519 signing key (64-hex chars)
        mcc             TEXT NOT NULL DEFAULT '',    -- Mobile Country Code (country of enrollment)
        enrolled_at     INTEGER NOT NULL,
        referrer_id     TEXT NOT NULL DEFAULT '',
        palm_name       TEXT NOT NULL DEFAULT ''     -- Citizen name derived from palm biometric
      );

      -- ── Transaction log ───────────────────────────────────────────────────
      -- Short-term audit records. NOT a permanent ledger — pruned by governance.
      -- Citizens own their full history on their devices.
      -- The node only holds records within tx_retention_days.
      CREATE TABLE IF NOT EXISTS sov_transactions (
        tx_id           TEXT PRIMARY KEY,
        tx_hash         TEXT NOT NULL UNIQUE,
        from_id         TEXT NOT NULL,
        to_id           TEXT NOT NULL,
        amount_seeds    INTEGER NOT NULL,
        memo            TEXT NOT NULL DEFAULT '',
        status          TEXT NOT NULL DEFAULT 'pending',  -- pending|confirmed|failed
        confirmed_at    INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_tx_from ON sov_transactions(from_id, confirmed_at);
      CREATE INDEX IF NOT EXISTS idx_tx_to   ON sov_transactions(to_id,   confirmed_at);

      -- ── Presence ──────────────────────────────────────────────────────────
      -- Tracks which node each citizen is currently connected to.
      -- Updated on HELLO (online) and disconnect (offline).
      CREATE TABLE IF NOT EXISTS sov_presence (
        sovereign_id    TEXT PRIMARY KEY,
        node_id         TEXT NOT NULL DEFAULT '',
        node_address    TEXT NOT NULL DEFAULT '',
        status          TEXT NOT NULL DEFAULT 'offline',  -- online|offline
        last_seen       INTEGER NOT NULL DEFAULT 0
      );

      -- ── Watch list ────────────────────────────────────────────────────────
      -- Watchers receive CITIZEN_ONLINE when a citizen reconnects.
      -- Used by the outbox system to retry messages when recipient comes back.
      CREATE TABLE IF NOT EXISTS sov_watch_list (
        watcher_id      TEXT NOT NULL,
        watching_id     TEXT NOT NULL,
        added_at        INTEGER NOT NULL,
        PRIMARY KEY (watcher_id, watching_id)
      );
      CREATE INDEX IF NOT EXISTS idx_watch_target ON sov_watch_list(watching_id);

      -- ── Message records ───────────────────────────────────────────────────
      -- Metadata only. Content is E2E encrypted and the node never decrypts it.
      -- Used for read receipt forwarding and dedup.
      CREATE TABLE IF NOT EXISTS sov_message_records (
        msg_id          TEXT PRIMARY KEY,
        from_id         TEXT NOT NULL,
        to_id           TEXT NOT NULL,
        media_type      TEXT NOT NULL DEFAULT 'text',
        created_at      INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_msg_rec_to ON sov_message_records(to_id);

      -- ── Pending messages ──────────────────────────────────────────────────
      -- Messages queued for offline citizens. Delivered on reconnect.
      -- Also survives node restart (in-memory queue rebuilt from this table).
      CREATE TABLE IF NOT EXISTS sov_pending_messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        sovereign_id    TEXT NOT NULL,
        op              TEXT NOT NULL,
        payload_json    TEXT NOT NULL,
        queued_at       INTEGER NOT NULL,
        expires_at      INTEGER NOT NULL   -- messages expire after 7 days
      );
      CREATE INDEX IF NOT EXISTS idx_pending_cid ON sov_pending_messages(sovereign_id);

      -- ── Pending transactions ───────────────────────────────────────────────
      -- Transactions in-flight across node boundaries.
      CREATE TABLE IF NOT EXISTS sov_pending_tx (
        tx_id           TEXT PRIMARY KEY,
        from_id         TEXT NOT NULL,
        to_id           TEXT NOT NULL,
        amount_seeds    INTEGER NOT NULL,
        memo            TEXT NOT NULL DEFAULT '',
        created_at      INTEGER NOT NULL,
        expires_at      INTEGER NOT NULL,
        payload_json    TEXT NOT NULL
      );

      -- ── Node registry ─────────────────────────────────────────────────────
      -- All known peer nodes. Persisted between restarts.
      -- Built up from NODE_ANNOUNCE gossip.
      CREATE TABLE IF NOT EXISTS sov_node_registry (
        node_id         TEXT PRIMARY KEY,
        address         TEXT NOT NULL,
        public_key_hex  TEXT NOT NULL DEFAULT '',
        last_seen       INTEGER NOT NULL DEFAULT 0,
        reputation      INTEGER NOT NULL DEFAULT 100
      );

      -- ── Governance parameters ─────────────────────────────────────────────
      -- Network-wide config values set by citizen vote.
      -- Same governance engine as the relay, just running on citizen hardware.
      CREATE TABLE IF NOT EXISTS sov_governance_params (
        param_key       TEXT PRIMARY KEY,
        param_value     TEXT NOT NULL,
        activated_at    INTEGER NOT NULL DEFAULT 0
      );

      -- ── Messaging public keys ─────────────────────────────────────────────
      -- X25519 public keys for end-to-end encrypted SOV Speak messages.
      -- Only the public key is stored. Private key never leaves the phone.
      CREATE TABLE IF NOT EXISTS sov_messaging_keys (
        sovereign_id    TEXT PRIMARY KEY,
        x25519_pub_hex  TEXT NOT NULL,
        updated_at      INTEGER NOT NULL
      );

      -- ── Spend locks ───────────────────────────────────────────────────────
      -- Double-spend prevention: optimistic lock during transaction quorum.
      CREATE TABLE IF NOT EXISTS sov_spend_locks (
        lock_key        TEXT PRIMARY KEY,  -- from_id:nonce
        tx_id           TEXT NOT NULL,
        locked_at       INTEGER NOT NULL,
        expires_at      INTEGER NOT NULL
      );

      -- ── Automated-wallet spend policy (network-enforced caps + allowlist) ──
      -- Bounds an AUTOMATED wallet so a compromised PC cannot drain funds:
      -- the NODES reject any transfer over the per-tx / daily cap or to a
      -- destination not on the allowlist, regardless of who holds the key.
      -- RELAXING the policy (raise caps / add allowlist / disable) is delayed
      -- by automation_relax_cooldown_hours and can be cancelled from any of the
      -- citizen's devices, so a thief with the key still cannot widen the limits
      -- without the owner being alerted. TIGHTENING applies immediately.
      CREATE TABLE IF NOT EXISTS sov_automation_policy (
        sovereign_id    TEXT PRIMARY KEY,
        enabled         INTEGER NOT NULL DEFAULT 0,
        per_tx_cap      INTEGER NOT NULL DEFAULT 0,  -- seeds; 0 = no per-tx limit
        daily_cap       INTEGER NOT NULL DEFAULT 0,  -- seeds, rolling 24h; 0 = no daily limit
        allowlist_json  TEXT NOT NULL DEFAULT '[]',  -- JSON array of sovereign_id strings; [] = any dest
        pending_json    TEXT,                         -- JSON of a pending RELAXATION, or NULL
        pending_at      INTEGER,                      -- epoch ms the pending relaxation becomes effective
        updated_at      INTEGER NOT NULL DEFAULT 0
      );

      -- Rolling ledger of automated spends, for the 24h daily-cap window.
      CREATE TABLE IF NOT EXISTS sov_automation_spend (
        sovereign_id    TEXT NOT NULL,
        spent_at        INTEGER NOT NULL,
        amount_seeds    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_autospend
        ON sov_automation_spend (sovereign_id, spent_at);

      -- ── Palm embeddings ───────────────────────────────────────────────────
      -- Stores the 128-dim palm embedding for each enrolled citizen.
      -- Used to enforce the one-human-one-wallet policy via cosine similarity.
      -- NOTE: This stores the mathematical representation, NOT palm images.
      -- Privacy: embeddings cannot be used to reconstruct the original palm image.
      CREATE TABLE IF NOT EXISTS palm_embeddings (
        sovereign_id    TEXT PRIMARY KEY,
        embedding_json  TEXT NOT NULL,     -- JSON array of 128 float values (4 decimal places)
        hand_type       TEXT NOT NULL DEFAULT 'LEFT',
        enrolled_at     INTEGER NOT NULL
      );

      -- ── Face embeddings (FACE-LOCK, 2026-07-19) ───────────────────────────
      -- One HUMAN = one identity, enforced across BOTH hands: the palm dedup
      -- cannot link a person's left palm to their right palm, so the face
      -- (already captured by the liveness step) is the cross-hand anchor.
      -- Stores the cancelable-transformed (R_face·v) 192-dim MobileFaceNet
      -- embedding — NEVER a face image, NEVER the raw vector.
      CREATE TABLE IF NOT EXISTS face_embeddings (
        sovereign_id    TEXT PRIMARY KEY,
        embedding_json  TEXT NOT NULL,     -- JSON array: protected 192-dim unit vector
        enrolled_at     INTEGER NOT NULL
      );

      -- ── Pioneer Program ───────────────────────────────────────────────────
      -- Citizens who join the pioneer program get a referral code.
      -- They earn SOV when others enroll with their pioneer code.
      -- Certified pioneers have completed specialisation assessments.
      CREATE TABLE IF NOT EXISTS sov_pioneers (
        sovereign_id           TEXT PRIMARY KEY,
        pioneer_code           TEXT NOT NULL UNIQUE,
        referral_count         INTEGER NOT NULL DEFAULT 0,
        total_earned           INTEGER NOT NULL DEFAULT 0,
        registered_at          INTEGER NOT NULL,
        cert_relay_engineer    INTEGER DEFAULT 0,
        cert_enrollment_agent  INTEGER DEFAULT 0,
        cert_protocol_specialist INTEGER DEFAULT 0,
        relay_engineer_at      INTEGER,
        enrollment_agent_at    INTEGER,
        protocol_specialist_at INTEGER,
        total_earned_seeds     INTEGER DEFAULT 0,
        rank                   TEXT DEFAULT 'apprentice'
      );
      CREATE INDEX IF NOT EXISTS idx_pioneer_code ON sov_pioneers (pioneer_code);

      -- ── Pioneer Assessment Questions ──────────────────────────────────────
      -- Bank of questions for relay_engineer / enrollment_agent / protocol_specialist
      CREATE TABLE IF NOT EXISTS sov_pioneer_questions (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        specialisation TEXT NOT NULL,
        question       TEXT NOT NULL,
        option_a       TEXT NOT NULL,
        option_b       TEXT NOT NULL,
        option_c       TEXT NOT NULL,
        option_d       TEXT NOT NULL,
        correct_answer TEXT NOT NULL,
        active         INTEGER DEFAULT 1
      );

      -- ── Pioneer Assessment Attempts ───────────────────────────────────────
      -- One row per attempt. Questions frozen at start time.
      CREATE TABLE IF NOT EXISTS sov_pioneer_assessments (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        sovereign_id   TEXT NOT NULL,
        specialisation TEXT NOT NULL,
        questions_json TEXT NOT NULL,
        started_at     INTEGER NOT NULL,
        completed_at   INTEGER,
        score          INTEGER,
        passed         INTEGER DEFAULT 0,
        attempt_number INTEGER DEFAULT 1
      );

    `);

    // --- MCC-Indexed Disc Migration ---
    try {
      const discInfo = this._db.prepare("PRAGMA table_info(sov_disc)").all();
      if (discInfo.length > 0 && !discInfo.some(c => c.name === 'slot_id')) {
        global.sovLog && global.sovLog.info('[DB] Schema drift detected. Migrating sov_disc to MCC-indexed slot_id...');
        this._db.exec(`
          CREATE TABLE sov_disc_v2 (
            slot_id         INTEGER PRIMARY KEY,
            sovereign_id    TEXT NOT NULL UNIQUE,
            balance_seeds   INTEGER NOT NULL DEFAULT 0,
            spendable_seeds INTEGER NOT NULL DEFAULT 0,
            version         INTEGER NOT NULL DEFAULT 0,
            last_tx_hash    TEXT    NOT NULL DEFAULT '',
            nonce           INTEGER NOT NULL DEFAULT 0,
            updated_at      INTEGER NOT NULL DEFAULT 0,
            pioneer_badges  TEXT DEFAULT ''
          );
        `);
        const rows = this._db.prepare('SELECT * FROM sov_disc').all();
        const insertV2 = this._db.prepare(`
          INSERT INTO sov_disc_v2 (slot_id, sovereign_id, balance_seeds, spendable_seeds, version, last_tx_hash, nonce, updated_at, pioneer_badges)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        `);
        
        let migrated = 0;
        this._db.transaction(() => {
          const mccOffsets = {};
          for (const row of rows) {
            const hexStr = row.sovereign_id.replace('SOV-', '');
            let mccStr = '001';
            if (hexStr.length >= 5) mccStr = hexStr.substring(2, 5);
            let mcc = parseInt(mccStr, 10);
            if (isNaN(mcc)) mcc = 1;

            if (mccOffsets[mcc] === undefined) {
               const maxSlotRow = this._db.prepare('SELECT MAX(slot_id) as m FROM sov_disc_v2 WHERE slot_id >= ? AND slot_id < ?').get(mcc * 100000000, (mcc + 1) * 100000000);
               mccOffsets[mcc] = (maxSlotRow && maxSlotRow.m != null) ? maxSlotRow.m : (mcc * 100000000) - 1;
            }
            mccOffsets[mcc]++;
            const slotId = mccOffsets[mcc];

            insertV2.run(
              slotId, row.sovereign_id, row.balance_seeds, row.spendable_seeds || row.balance_seeds,
              row.version || 0, row.last_tx_hash || '', row.nonce || 0, row.updated_at || 0, row.pioneer_badges || ''
            );
            migrated++;
          }
          this._db.exec('DROP TABLE sov_disc');
          this._db.exec('ALTER TABLE sov_disc_v2 RENAME TO sov_disc');
        })();
        global.sovLog && global.sovLog.info(`[DB] Migration complete: ${migrated} records moved to new sov_disc schema.`);
      }
    } catch(e) {
      global.sovLog && global.sovLog.error(`[DB] sov_disc migration failed: ${e.message}`);
    }
    // ----------------------------------


    // Migrate sov_disc to add pioneer_badges column (safe re-run)
    try { this._db.prepare("ALTER TABLE sov_disc ADD COLUMN pioneer_badges TEXT DEFAULT ''").run(); } catch (_) {}
    // Liveness wiring (king 2026-06-04 greenlight): proof-of-life / login timestamp.
    // Read by allocation_engine council-member selection (d.liveness_ts) — previously
    // referenced a column that did not exist. Written by HELLO (passive login) + LIVENESS_CHECK.
    try { this._db.prepare("ALTER TABLE sov_disc ADD COLUMN liveness_ts INTEGER NOT NULL DEFAULT 0").run(); } catch (_) {}

    // ── Dead-node prune wiring (king 2026-07-23) ──────────────────────────────
    // last_verified = last time WE had REAL contact with this node (verified peer
    // handshake / signed heartbeat). It is deliberately NOT bumped by gossip — that
    // was the bug that kept terminated nodes "fresh" forever (peers kept gossiping
    // dead entries, refreshing last_seen every cycle). The dead-node prune keys off
    // last_verified so a node unreachable for node_registry_ttl_days ages out.
    try { this._db.prepare("ALTER TABLE sov_node_registry ADD COLUMN last_verified INTEGER NOT NULL DEFAULT 0").run(); } catch (_) {}
    // One-time backfill: seed last_verified from last_seen for existing rows so the
    // TTL clock starts now rather than nuking the whole registry on first boot.
    try { this._db.prepare("UPDATE sov_node_registry SET last_verified = last_seen WHERE last_verified = 0").run(); } catch (_) {}
    // What source each registered node declared at signup. Peers count how many
    // EARNED nodes run a given root to decide whether a joining node's software is
    // recognised — this is the integrity anchor that replaced the founder key.
    try { this._db.prepare("ALTER TABLE sov_operator_registry ADD COLUMN source_root TEXT NOT NULL DEFAULT ''").run(); } catch (_) {}

    // Seed default governance parameters
    this._seedGovernanceDefaults();

    // Seed pioneer questions (no-op if already present)
    this._seedPioneerQuestions();

    // Heal the supply invariant on boot + keep it healed (pools are local, wallets
    // replicate globally — see reconcileSupplyPools). Self-contained, no wiring.
    try { this.startSupplyReconciler(); } catch (_) {}

    // Start hourly maintenance
    this._startMaintenance();
  }

  // ── Governance defaults ────────────────────────────────────────────────────

  _seedGovernanceDefaults() {
    const DEFAULTS = [
      ['tx_retention_days',            '90'],
      ['message_retention_days',       '90'],
      ['quorum_threshold',             '0.10'],
      ['min_poll_duration',            '1440'],
      ['max_poll_duration',            '10080'],
      ['tx_fee_rate',                  '0.001'],   // 0.1% — cheap-launch (king 2026-07-19); votable
      ['tx_fee_max_sov',               '1'],       // hard cap: no transfer ever costs more than 1 SOV (0 = uncapped)
      ['sov_issuance_rate',            '0'],
      ['issuance_epoch_hours',         '24'],
      ['issuance_max_backlog_epochs',  '7'],
      ['guardian_approval_threshold',  '2'],
      ['guardian_max_count',           '5'],
      ['guardian_recovery_window_hours','72'],
      ['node_registry_ttl_days',       '60'],  // prune relay nodes unreachable this many days (30–365; king 2026-07-23)
      ['academy_article_bond',         '5'],
      ['sov_enclave',                  '1'],
      ['enrollment_reward_seeds',      '1000000000'],
      ['pioneer_rewards_active',         '1'],  // 1=active, 0=sunset (citizens vote to deactivate when pioneers can charge at service level)
      // ── Operator economy (SOV_OPERATOR_ECONOMY_SPEC, king-approved 2026-07-19) ──
      // RETIRED: operator_monthly_payout_pct. It paid 1% of the WHOLE remaining
      // reserve every period (= 200,000 SOV on a 20M pool), appears in no blueprint,
      // and was never approved. Replaced by the flat, work-metered rates below.
      // The old DB row is left in place for audit but nothing reads it.
      ['operator_uptime_reward',       '20000000'],     // 20 SOV per qualifying relay per 30-day period
      ['operator_tx_reward',           '0'],            // seeds per confirmed tx witnessed (launches at 0; governance raises it)
      ['operator_reserve_draw_cap',    '50000000000'],  // 50,000 SOV/month max draw on the reserve (safety valve)
      ['platform_register_fee',        '10'],           // SOV paid by a PLATFORM OWNER to integrate SOV Login (citizens never pay)
      ['platform_fee_period_days',     '365'],          // registration is ANNUAL (king directive 2026-07-19) — renew via /sov-platform/register
      ['referral_reward_seeds',        '100000000'],   // 100 SOV for referrer (10% of enrollment reward)
      ['proof_of_service_reward_seeds','0'],            // seeds per proof score unit (0 = disabled until governance vote)
      ['max_nodes_per_operator',       '3'],            // max nodes one citizen may operate
      ['operator_signup_sample',       '5'],
      ['tx_signature_enforce',         'log'],  // 'log' -> 'reject' once verified against live traffic            // peers asked to interrogate a joining node
      ['operator_signup_quorum',       '3'],            // approvals required before a node counts as joined
      ['relay_join_min_stake',         '0'],            // MUST match governance_engine PARAM_DEFAULTS.
                                                        // Was '100' here vs '0' there; both arrays INSERT OR
                                                        // IGNORE, so the join stake was decided by whichever
                                                        // initialised first. King's design is no join stake.
      ['relay_max_citizens',           '100000'],       // max citizens this node can serve
      ['automation_relax_cooldown_hours','48'],  // delay before an automated-wallet policy RELAXATION takes effect (0–720; tightening is instant)
      // ── Phase 2 / witness signers (PI-37 Failsafe Bootstrap) ─────────────
      // The protocol signs its own releases. These govern when the network stops
      // relying on the genesis anchor and elects its own signers, and how it
      // recovers if those signers ever go silent. Documented in
      // SOV_PROTOCOL_DICTIONARY.md #### PI-37; seeded here so the triggers and
      // the election have something to read from day one.
      ['phase2_min_citizens',            '1000'],  // Trigger 1: enrolled citizens before the normal transition fires
      ['phase2_min_operators',           '5'],     // Trigger 1: operator nodes required alongside the citizen count
      ['phase2_emergency_inactivity_days','180'],  // Trigger 2: days with no signed release before emergency election opens
      ['phase2_emergency_min_citizens',  '100'],   // Trigger 2: floor below which the network accepts freezing instead
      ['phase2_emergency_quorum_pct',    '0.05'],  // Trigger 2: quorum for the emergency election (5%)
      ['witness_signer_count',           '5'],     // signers elected
      ['witness_signer_threshold',       '3'],     // signatures required to ship a release (no single key can)
      ['witness_signer_term_days',       '365'],   // term length before re-election
      // ── Self-validating releases (docs/SELF_VALIDATING_RELEASE_DESIGN.md Part A) ──
      // Signing qualification is DELIBERATELY separate from the payout rule
      // (operator_min_uptime_days): testing restarts reset uptime streaks, and that
      // must never quietly change who gets paid.
      ['release_signer_min_uptime_days','1'],     // raise to 21 at launch
      ['release_dispute_threshold',     '2'],     // dissenting earned nodes -> version disputed
      ['release_enforce_mode',          'warn'],  // 'warn' pre-launch, 'refuse' after
    ];

    const insert = this._db.prepare(
      `INSERT OR IGNORE INTO sov_governance_params (param_key, param_value, activated_at)
       VALUES (?, ?, 0)`
    );
    for (const [key, val] of DEFAULTS) {
      insert.run(key, val);
    }
  }

  // ── Pioneer questions seed ─────────────────────────────────────────────────
  // Seeds all 48 certification questions (16 per track). SELF-HEALING: if the table
  // does not hold EXACTLY the canonical 48 (empty, a stale/old set, or accumulated
  // duplicates — the table has no UNIQUE key, so a plain INSERT OR IGNORE cannot dedup),
  // it is atomically reset to the canonical 48 in a single transaction. A healthy node
  // (cnt === 48) returns immediately.
  // Content reflects the certification-institution model: citizens learn the protocol,
  // qualify, and offer paid services (the network never pays for referrals). No node
  // identities, no internal engineering terms — plain civic language only.

  _seedPioneerQuestions() {
    const check = this._db.prepare('SELECT COUNT(*) as cnt FROM sov_pioneer_questions').get();
    if (check && check.cnt === 48) return; // already correctly seeded — nothing to do

    const insert = this._db.prepare(`
      INSERT OR IGNORE INTO sov_pioneer_questions
        (id, specialisation, question, option_a, option_b, option_c, option_d, correct_answer, active)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
    `);

    const questions = [
      // relay_engineer  →  Node Operator track
      ['relay_engineer','What is a SOV node?','A phone app for sending messages','Software any citizen can run on a PC or server that helps carry the network\'s transactions and messages','A bank server owned by the network','A government registry of citizens','B'],
      ['relay_engineer','How do independent nodes stay in agreement with each other?','A head office pushes the correct data to them','They automatically reconcile: any node that falls behind catches up from its peers, so all nodes end up holding the same records','Operators phone each other to compare figures','Only one node is ever trusted at a time','B'],
      ['relay_engineer','Your node is switched off for a few hours. What happens when it returns?','Its citizens lose their balances','It must be re-installed from scratch','It automatically catches up from the other nodes and carries on — nothing is lost','It is permanently removed from the network','C'],
      ['relay_engineer','Can a citizen connect to any node on the network?','No, each citizen is locked to one node','Yes — every node can serve any citizen, and they all hold the same truth','Only if the operator approves them first','Only nodes in the same country','B'],
      ['relay_engineer','What can running a node earn an operator?','A share of every citizen\'s balance','Nothing, it is purely voluntary forever','The network can reward operators for the service their node provides, as decided by governance','A fee taken from every message sent','C'],
      ['relay_engineer','Does running a node let the operator read citizens\' messages or take their SOV?','Yes, operators can see everything','No — messages are end-to-end encrypted and SOV can only move with the owner\'s signature','Operators can read messages but not move SOV','Operators can move SOV but not read messages','B'],
      ['relay_engineer','An old computer or a nearly-full node can no longer hold all the data. What can it still do?','Nothing, it must shut down','Delete other citizens to make room','Keep taking part by delegating heavy work to more capable nodes and using their verified results','Force citizens to move to another node','C'],
      ['relay_engineer','What is the easiest way to install node software?','Compile it by hand from source','A one-command package on Linux, or a portable app on Windows and Mac','Order a pre-built server in the post','It can only be installed by the founder','B'],
      ['relay_engineer','How does a brand-new node find the others when it first starts?','The operator types in every address by hand','It starts from a built-in list of known nodes and asks them for more peers','A central directory server assigns it','It waits for other nodes to call it','B'],
      ['relay_engineer','Is there a central server that controls the whole network?','Yes, one master server runs everything','No — nodes are equal peers, none is in charge, and any node can be replaced','Yes, but only during business hours','Only the founder\'s node can approve transactions','B'],
      ['relay_engineer','What is a full node on Windows or Mac?','A separate paid product','The same node software bundled with the wallet, running on your own PC, able to auto-start when your connection can be reached','A backup of the phone app','A tool only developers can use','B'],
      ['relay_engineer','Does a Windows or Mac operator need to scan their palm again to run a node?','Yes, every time they start it','No — they restore their existing wallet; they already passed verification','Yes, once per week','Only if they move house','B'],
      ['relay_engineer','How is a node\'s stored data protected on the machine?','It is left as plain readable files','The node database is encrypted and its keys are locked to that specific machine','It is uploaded to a public website','It has no protection, so nodes hold no secrets','B'],
      ['relay_engineer','What keeps the network healthy without an administrator watching it?','A paid support team fixes it each night','Nodes constantly check each other and self-heal — stale links are dropped and re-formed automatically','Citizens must restart their nodes daily','Nothing; problems must be reported by email','B'],
      ['relay_engineer','Why is the SOV network described as lightweight compared with older cryptocurrencies?','It stores fewer citizens','Nodes hold compact current records rather than an ever-growing chain of every transaction in history','It only runs a few hours a day','It deletes citizens who do not transact','B'],
      ['relay_engineer','When can a home full node start serving the network automatically?','Never — nodes must be started by hand each time','When it can be reached from the outside — for example through a working forwarded connection or a reachability service — the node can auto-start and join','Only between certain hours','Only if it is the fastest node','B'],
      // enrollment_agent  →  Enrollment Helper track
      ['enrollment_agent','What does palm enrollment actually create?','A photo of the palm stored on a server','A unique network identity from a mathematical commitment to the palm — the palm image itself is never stored','A username and password','A printed membership card','B'],
      ['enrollment_agent','What is a Sovereign ID?','An email address','A username the citizen picks','A unique network identity created at enrollment that reveals nothing about who the person is','A government reference number','C'],
      ['enrollment_agent','How many wallets can one human have?','As many as they like','Exactly one — the palm check blocks the same person enrolling twice','One per device','One per country','B'],
      ['enrollment_agent','What is the very first thing a new citizen should do after enrolling?','Share their Sovereign ID publicly','Save their encrypted wallet backup and write down their recovery phrase, kept offline','Send their reward to an exchange','Delete the app to stay safe','B'],
      ['enrollment_agent','Who receives the one-time enrollment reward?','The person who introduced them','The newly enrolled citizen themselves','The node operator','It is split between operators','B'],
      ['enrollment_agent','Is anyone paid by the network for referring or recruiting new citizens?','Yes, a fixed SOV amount per referral','No — the network never pays for referrals; the reward belongs to the enrolled citizen','Yes, but only certified helpers','Yes, a share of the new citizen\'s future transfers','B'],
      ['enrollment_agent','A citizen has lost their phone AND their recovery phrase. What can still save their wallet?','Nothing, it is gone forever','Guardian recovery: enough of their nominated guardians approve to restore the wallet','A support team resets it for them','They prove ownership with a passport','B'],
      ['enrollment_agent','What is a guardian?','A node operator','A trusted person the citizen nominates who can help approve wallet recovery','An automatic cloud backup','A network moderator','B'],
      ['enrollment_agent','What does the wallet backup contain and how is it protected?','The palm photo, protected by a PIN','The identity and recovery secret, encrypted with a password the citizen chooses (AES-256)','The full transaction history in plain text','Nothing sensitive, so it needs no protection','B'],
      ['enrollment_agent','Why does the app lock itself the moment you leave it?','To save battery','So no one who picks up the phone can reach the wallet','To download updates','To log the citizen out of the network','B'],
      ['enrollment_agent','Does the network keep a picture of a citizen\'s palm?','Yes, encrypted on a server','No — only a mathematical commitment that cannot be turned back into an image','Yes, but only for a week','Only for citizens who opt in','B'],
      ['enrollment_agent','What advice about the PIN or password should a helper give a new citizen?','Use their birthday so it is easy','Choose one only they know — it protects the wallet on the device and there is no "reset by support"','Share it with a guardian for safekeeping','Write it on the back of the phone','B'],
      ['enrollment_agent','Roughly how long before a transfer is visible to the other nodes?','Up to 24 hours','Within a few seconds','One week','It is never shared with other nodes','B'],
      ['enrollment_agent','Can an enrollment helper see or hold a citizen\'s SOV?','Yes, helpers manage balances','No — only the citizen\'s own signed action can move their SOV','Only during the first day','Only if they are certified','B'],
      ['enrollment_agent','What should a citizen NEVER share publicly?','Their Sovereign ID','Their recovery phrase, backup file and PIN','The fact that they are enrolled','Which country they are in','B'],
      ['enrollment_agent','What does one-human-one-wallet mean for fairness at enrollment?','Rich citizens get extra wallets','Every person counts once, so rewards and votes cannot be gamed by making fake accounts','Only the first citizen in a family can enroll','Wallets are shared between family members','B'],
      // protocol_specialist  →  Protocol Expert track
      ['protocol_specialist','How is the SOV supply controlled?','It grows without limit','There is a fixed cap; a community reserve can only be activated by a citizen vote','The founder mints more when needed','Each node creates its own supply','B'],
      ['protocol_specialist','How does governance voting work?','Votes are weighted by SOV balance','One enrolled human, one vote, regardless of balance — enforced by the one-person-one-identity check','Only node operators may vote','The founder has the final say','B'],
      ['protocol_specialist','How is double-spending prevented?','The fastest node wins a race to confirm','Every transfer is signed by the owner and ordered so the same balance cannot be spent twice, and nodes reconcile to the same result','Citizens must wait 24 hours between transfers','A central ledger checks each payment','B'],
      ['protocol_specialist','What is SOV Login?','Citizens hand their password to each website','Citizens sign in to outside websites by signing a challenge with their key — no password is shared and no separate account is made','A paid membership for premium sites','A way for websites to read a citizen\'s balance','B'],
      ['protocol_specialist','Do citizens ever pay to use SOV Login?','Yes, a fee after a number of sign-ins','Never — the platform pays a small yearly connection fee to the operator pool; citizens are always free','Only for banking sites','Yes, a small charge each time','B'],
      ['protocol_specialist','How does the SOV Exchange work?','A company sets the price and holds the funds','Peer-to-peer: citizens list and fill offers directly, funds held in escrow and released when the seller confirms — no middleman holds the money','Only the founder can approve trades','It only trades SOV for other coins','B'],
      ['protocol_specialist','What are certifications for in the current model?','They are network jobs that pay a salary','They are professional qualifications: a certified citizen can offer services and set their own price — the network does not pay them for it','They unlock extra voting power','They are required to hold a wallet','B'],
      ['protocol_specialist','What replaced any idea of "earning for referrals"?','A bigger referral bonus','Nothing pays for referrals — you learn the protocol, get certified, and charge clients for the services you provide','A monthly recruiter salary','A share of new citizens\' rewards','B'],
      ['protocol_specialist','What happens to balances left completely inactive for many years?','They transfer to the founder','After a long period with no liveness and no allocation, they can be reclaimed or burned under protocol rules','They are given to node operators','They double in value automatically','B'],
      ['protocol_specialist','What is the role of the justice council?','A team of operators who approve big transfers','Randomly selected active citizens who review certain disputes and inheritance claims and vote to approve or reject','The founder and advisors','A committee of senior recruiters','B'],
      ['protocol_specialist','How does the network stop any single node becoming a gatekeeper?','A backup node is kept in reserve','The app can use any available node and all nodes hold the same records, so no node can block a citizen','Government approval of each node','Citizens pay the node they trust most','B'],
      ['protocol_specialist','Can a node operator censor or reverse a citizen\'s transfer?','Yes, operators have that power','No — transfers need the owner\'s signature and any node can carry them','Only within the first minute','Only for large amounts','B'],
      ['protocol_specialist','What is proof of service?','Proof a citizen paid their fees','The idea that nodes can be rewarded for the useful work they do for the network, as set by governance','A certificate of enrollment','A record of a citizen\'s messages','B'],
      ['protocol_specialist','How are protocol rules and values changed after launch?','The founder edits them','Citizens vote — a governed value changes only when a vote passes; nothing important is hard-coded','Node operators change them freely','They can never change','B'],
      ['protocol_specialist','Why is SOV described as a sovereign mesh rather than a blockchain?','It uses a single giant server','Compact current state is held across equal, self-healing nodes instead of an ever-growing chain every node must keep forever','It has no records at all','It runs only on phones','B'],
      ['protocol_specialist','How does a certified citizen turn their qualification into income?','The network pays them a monthly wage','They offer their service to others, set their own price, and get paid directly in SOV — advertising, for example, on the Exchange','They collect a fee from every node','They are paid for each person they certify','B'],
    ];

    // Atomic reset: clear whatever is there (empty, stale, or duplicated) and lay down
    // exactly the canonical set in one transaction so the table can never end up holding
    // a partial or mixed old/new set.
    const reseed = this._db.transaction(() => {
      this._db.prepare('DELETE FROM sov_pioneer_questions').run();
      // Deterministic ids (1..N) so every node holds IDENTICAL rows — assessments
      // reference stable question ids and no cross-node drift is possible.
      let qid = 0;
      for (const [spec, q, a, b, c, d, ans] of questions) {
        insert.run(++qid, spec, q, a, b, c, d, ans);
      }
    });
    reseed();
    global.sovLog && global.sovLog.info(`[DB] Pioneer questions reset to canonical set (${questions.length} questions)`);
  }

  // ── Pioneer pool helpers ────────────────────────────────────────────────────

  // Returns how many SOV remain in the 5M pioneer referral pool.
  // Computed from SUM(total_earned) across all pioneer records — no separate counter needed.
  getPioneerPoolRemaining() {
    try {
      const row = this._db.prepare('SELECT COALESCE(SUM(total_earned), 0) as issued FROM sov_pioneers').get();
      const issued = row ? (row.issued || 0) : 0;
      return Math.max(0, 5000000 - issued);
    } catch (e) {
      global.sovLog && global.sovLog.error('[DB] getPioneerPoolRemaining error:', e.message);
      return 5000000;
    }
  }

  // ── SOV Disc operations ────────────────────────────────────────────────────

  readDisc(sovereignId) {
    return this._db.prepare('SELECT * FROM sov_disc WHERE sovereign_id = ?').get(sovereignId);
  }

  // Write balance with optimistic concurrency — returns false if version mismatch
  writeDiscGuarded(sovereignId, balanceSeeds, spendableSeeds, expectedVersion) {
    const result = this._db.prepare(`
      UPDATE sov_disc
      SET balance_seeds = ?, spendable_seeds = ?, version = version + 1, updated_at = ?
      WHERE sovereign_id = ? AND version = ?
    `).run(balanceSeeds, spendableSeeds, Date.now(), sovereignId, expectedVersion);
    return result.changes === 1;
  }

  // Atomically add seeds to an existing disc entry.
  // Uses optimistic concurrency — retries up to 3 times on version collision.
  // Returns true on success, false if citizen not found or retries exhausted.
  creditBalance(sovereignId, additionalSeeds) {
    // ── Supply cap invariant (Protocol Book Ch.10) ───────────────────────
    // Every mint path goes through here. If this credit would push total
    // network supply above MAX_TOTAL_SUPPLY_SEEDS (50M SOV), refuse.
    if (additionalSeeds > 0) {
      const totalRow = this._db.prepare('SELECT COALESCE(SUM(balance_seeds), 0) AS t FROM sov_disc').get();
      const projected = (totalRow.t || 0) + additionalSeeds;
      if (projected > MAX_TOTAL_SUPPLY_SEEDS) {
        global.sovLog && global.sovLog.error(
          `[ECON-CAP] REFUSED credit of ${additionalSeeds} seeds to ${sovereignId} — would push supply to ${projected} (cap ${MAX_TOTAL_SUPPLY_SEEDS})`
        );
        return false;
      }
    }
    for (let attempt = 0; attempt < 3; attempt++) {
      const disc = this.readDisc(sovereignId);
      if (!disc) return false;
      const ok = this.writeDiscGuarded(
        sovereignId,
        disc.balance_seeds   + additionalSeeds,
        disc.spendable_seeds + additionalSeeds,
        disc.version
      );
      if (ok) return true;
    }
    global.sovLog && global.sovLog.warn(`[DB] creditBalance failed after retries for ${sovereignId}`);
    return false;
  }

  // Total seeds currently minted across all disc entries
  currentTotalSupply() {
    const r = this._db.prepare('SELECT COALESCE(SUM(balance_seeds), 0) AS t FROM sov_disc').get();
    return r.t || 0;
  }

  ensureDiscEntry(sovereignId) {
    // GHOST-ROW GUARD: never create a disc row for an empty id or a transient
    // enrolment-application id (AS-2026-XXXX, a legacy relay operator
    // scheme the current node never legitimately issues). Such ids leaked in via a
    // pre-enrolment app message and produced phantom 0-balance citizen rows. Reject
    // at the storage layer so NO client path (app/CLI/NFC/STATE_DELTA) can create it.
    if (!sovereignId || String(sovereignId).startsWith("AS-2026")) return;
    this._db.prepare(`
      INSERT OR IGNORE INTO sov_disc (sovereign_id, balance_seeds, spendable_seeds, version, updated_at)
      VALUES (?, 0, 0, 0, ?)
    `).run(sovereignId, Date.now());
  }

  /// Record proof-of-life / login (king 2026-06-04). Stores epoch SECONDS in
  /// sov_disc.liveness_ts (matches allocation_engine's thirtyDaysAgoSec compare).
  /// Called passively on authenticated HELLO + explicitly on LIVENESS_CHECK.
  /// Does NOT touch balance/version — pure liveness bookkeeping.
  touchLiveness(sovereignId) {
    if (!sovereignId) return 0;
    // GHOST-ROW ROOT FIX: liveness is only meaningful for an ENROLLED citizen (it
    // feeds allocation_engine's 30-day-active check). This runs on every
    // authenticated HELLO — so an app re-announcing a STALE cached identity to a
    // fresh genesis, or any node/wallet that never enrolled here, would otherwise
    // get ensureDiscEntry() to mint a 0-balance phantom wallet slot. Only touch
    // liveness for ids that actually hold an enrolment on THIS node; an unenrolled
    // HELLO is a no-op. (Legitimate money-to-unenrolled still mints a row via the
    // transfer path's own ensureDiscEntry — this only gates the bare-HELLO path.)
    const enrolled = this._db.prepare(
      'SELECT 1 FROM sov_enrollments WHERE sovereign_id = ? LIMIT 1'
    ).get(sovereignId);
    if (!enrolled) return 0;
    const tsSec = Math.floor(Date.now() / 1000);
    try {
      this.ensureDiscEntry(sovereignId);
      this._db.prepare('UPDATE sov_disc SET liveness_ts = ? WHERE sovereign_id = ?').run(tsSec, sovereignId);
    } catch (e) { global.sovLog && global.sovLog.warn('[DB] touchLiveness: ' + e.message); }
    return tsSec;
  }

  // ── Enrollment operations ──────────────────────────────────────────────────

  getEnrollment(sovereignId) {
    return this._db.prepare('SELECT * FROM sov_enrollments WHERE sovereign_id = ?').get(sovereignId);
  }

  // ── enrollNewCitizen — atomic enrollment + disc creation with reward ─────────
  // Used by EnrollmentEngine for brand-new citizens.
  // Wraps both the enrollment record and the disc entry in a single transaction
  // so they are always consistent — no half-enrolled citizens.

  enrollNewCitizen({ sovereignId, publicKeyHex, mcc, enrolledAt, referrerId, palmName, enrollmentRewardSeeds }) {
    const insertEnrollment = this._db.prepare(`
      INSERT OR REPLACE INTO sov_enrollments
        (sovereign_id, public_key_hex, mcc, enrolled_at, referrer_id, palm_name)
      VALUES (?, ?, ?, ?, ?, ?)
    `);

    // UPSERT (not INSERT OR IGNORE): a 0-balance disc row is often ALREADY created
    // for this sovereign_id before enrolment (a pre-enrolment HELLO / balance query
    // mints a wallet slot). With plain INSERT OR IGNORE the reward silently never
    // lands — the existing 0-balance row wins and the citizen is credited nothing.
    // On conflict, credit the reward INTO the existing row, but only when it is an
    // uncredited 0-balance ghost (WHERE balance_seeds = 0) so a re-run or an already
    // funded wallet is never double-credited or clobbered.
    const insertDisc = this._db.prepare(`
      INSERT INTO sov_disc
        (slot_id, sovereign_id, balance_seeds, spendable_seeds, version, updated_at)
      VALUES (?, ?, ?, ?, 0, ?)
      ON CONFLICT(sovereign_id) DO UPDATE SET
        balance_seeds   = excluded.balance_seeds,
        spendable_seeds = excluded.spendable_seeds,
        updated_at      = excluded.updated_at
      WHERE sov_disc.balance_seeds = 0
    `);

    const rewardSeeds = enrollmentRewardSeeds || 0;

    const doEnroll = this._db.transaction(() => {
      insertEnrollment.run(
        sovereignId, publicKeyHex, mcc || '',
        enrolledAt || Date.now(), referrerId || '', palmName || ''
      );
      
      const hexStr = sovereignId.replace('SOV-', '');
      let mccStr = mcc || '001';
      if (hexStr.length >= 5 && (!mcc || mcc.length === 0)) mccStr = hexStr.substring(2, 5);
      let mccNum = parseInt(mccStr, 10);
      if (isNaN(mccNum)) mccNum = 1;
      const baseSlot = mccNum * 100000000;
      
      const maxSlotRow = this._db.prepare('SELECT MAX(slot_id) as m FROM sov_disc WHERE slot_id >= ? AND slot_id < ?').get(baseSlot, baseSlot + 100000000);
      const nextSlot = (maxSlotRow && maxSlotRow.m != null) ? maxSlotRow.m + 1 : baseSlot;
      
      insertDisc.run(nextSlot, sovereignId, rewardSeeds, rewardSeeds, Date.now());
    });

    doEnroll();
  }

  // Alias used by EnrollmentEngine for messaging key storage
  upsertMessagingKey(sovereignId, x25519PubHex) {
    this.setMessagingPublicKey(sovereignId, x25519PubHex);
  }

  upsertEnrollment({ sovereignId, publicKeyHex, mcc, enrolledAt, referrerId, palmName }) {
    this._db.prepare(`
      INSERT OR REPLACE INTO sov_enrollments
        (sovereign_id, public_key_hex, mcc, enrolled_at, referrer_id, palm_name)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(sovereignId, publicKeyHex, mcc || '', enrolledAt || Date.now(), referrerId || '', palmName || '');
    this.ensureDiscEntry(sovereignId);
  }

  citizenCount() {
    return this._db.prepare('SELECT COUNT(*) as c FROM sov_enrollments').get().c;
  }

  // ── Genesis founder seeding (REMOVED — fair launch) ─────────────────────────
  //
  // Historically this pre-seeded a founder allocation at startup (a premine path
  // independent of enrollment_engine.js). It was removed for the fair launch: the
  // network mints ZERO premine — all SOV comes from the enrollment/operator/pioneer
  // pools. The method is kept as an inert no-op so existing snap.env/.env files that
  // still set FOUNDER_SOVEREIGN_ID / GENESIS_FOUNDER_SEEDS do not crash; it only logs
  // a one-time deprecation warning and never writes to sov_disc / sov_enrollments.
  //
  // Always returns false (no seeding ever happens).

  seedGenesisFounder() {
    // ── [FAIR-LAUNCH REFACTOR 2026-05-27 / completed 2026-05-29] GENESIS FOUNDER SEED REMOVED ──
    // The startup founder pre-seed (a second premine path independent of enrollment_engine.js)
    // was neutralized for the fair launch. FOUNDER_SOVEREIGN_ID / GENESIS_FOUNDER_SEEDS are now
    // no-ops here, mirroring the enrollment_engine.js deprecation pattern. The network launches
    // with ZERO premine — every SOV is minted through the enrollment/operator/pioneer pools.
    // See SOV_PROTOCOL_FAIRNESS_AUDIT.md + FOUNDER_REWARD_VERIFY.md + FOUNDER_REWARD_REMOVAL_DIFF.md.
    if (process.env.FOUNDER_SOVEREIGN_ID || process.env.GENESIS_FOUNDER_SEEDS) {
      if (!NodeDB._founderSeedWarnLogged) {
        global.sovLog.warn(
          `      [GENESIS] FOUNDER_SOVEREIGN_ID / GENESIS_FOUNDER_SEEDS are DEPRECATED ` +
          `(fair-launch refactor) and have no effect — no founder disc is seeded. ` +
          `Remove them from snap.env/.env to silence this warning.`
        );
        NodeDB._founderSeedWarnLogged = true;
      }
    }
    return false;
  }

  // ── Transaction operations ─────────────────────────────────────────────────

  hasTransaction(txHash) {
    const row = this._db.prepare(
      'SELECT 1 FROM sov_transactions WHERE tx_hash = ? LIMIT 1'
    ).get(txHash);
    return !!row;
  }

  insertTransaction(tx) {
    this._db.prepare(`
      INSERT OR IGNORE INTO sov_transactions
        (tx_id, tx_hash, from_id, to_id, amount_seeds, memo, status, confirmed_at, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      tx.tx_id, tx.tx_hash, tx.from_id, tx.to_id,
      tx.amount_seeds, tx.memo || '', tx.status || 'pending',
      tx.confirmed_at || 0, tx.created_at || Date.now()
    );
  }

  confirmTransaction(txId, confirmedAt) {
    this._db.prepare(
      `UPDATE sov_transactions SET status = 'confirmed', confirmed_at = ? WHERE tx_id = ?`
    ).run(confirmedAt || Date.now(), txId);
  }

  getTransactionHistory(sovereignId, { after_ts, limit } = {}) {
    return this._db.prepare(`
      SELECT * FROM sov_transactions
      WHERE (from_id = ? OR to_id = ?)
        AND confirmed_at > ?
        AND status = 'confirmed'
      ORDER BY confirmed_at DESC
      LIMIT ?
    `).all(sovereignId, sovereignId, after_ts || 0, limit || 50);
  }

  // ── Presence operations ────────────────────────────────────────────────────

  setPresenceOnline(sovereignId, nodeId, nodeAddress) {
    this._db.prepare(`
      INSERT OR REPLACE INTO sov_presence
        (sovereign_id, node_id, node_address, status, last_seen)
      VALUES (?, ?, ?, 'online', ?)
    `).run(sovereignId, nodeId, nodeAddress || '', Date.now());
  }

  setPresenceOffline(sovereignId) {
    this._db.prepare(`
      UPDATE sov_presence SET status = 'offline', last_seen = ? WHERE sovereign_id = ?
    `).run(Date.now(), sovereignId);
  }

  getCitizenPresence(sovereignId) {
    return this._db.prepare('SELECT * FROM sov_presence WHERE sovereign_id = ?').get(sovereignId);
  }

  // ── Watch list operations ──────────────────────────────────────────────────

  addWatch(watcherId, watchingId) {
    this._db.prepare(`
      INSERT OR IGNORE INTO sov_watch_list (watcher_id, watching_id, added_at)
      VALUES (?, ?, ?)
    `).run(watcherId, watchingId, Date.now());
  }

  removeWatch(watcherId, watchingId) {
    this._db.prepare(
      'DELETE FROM sov_watch_list WHERE watcher_id = ? AND watching_id = ?'
    ).run(watcherId, watchingId);
  }

  getWatchersFor(sovereignId) {
    return this._db.prepare(
      'SELECT watcher_id FROM sov_watch_list WHERE watching_id = ?'
    ).all(sovereignId).map(r => r.watcher_id);
  }

  // ── Message record operations ──────────────────────────────────────────────

  storeMessageRecord({ msg_id, from, to, media_type, created_at }) {
    this._db.prepare(`
      INSERT OR IGNORE INTO sov_message_records
        (msg_id, from_id, to_id, media_type, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(msg_id, from, to, media_type || 'text', created_at || Date.now());
  }

  getMessageRecord(msgId) {
    return this._db.prepare(
      'SELECT * FROM sov_message_records WHERE msg_id = ?'
    ).get(msgId);
  }

  // ── Pending message operations ─────────────────────────────────────────────

  queuePendingMessage(sovereignId, op, payload) {
    const expiresAt = Date.now() + (7 * 24 * 60 * 60 * 1000); // 7 days
    this._db.prepare(`
      INSERT INTO sov_pending_messages
        (sovereign_id, op, payload_json, queued_at, expires_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(sovereignId, op, JSON.stringify(payload), Date.now(), expiresAt);
  }

  getPendingMessages(sovereignId) {
    const rows = this._db.prepare(`
      SELECT op, payload_json FROM sov_pending_messages
      WHERE sovereign_id = ? AND expires_at > ?
      ORDER BY id ASC
    `).all(sovereignId, Date.now());
    return rows.map(r => ({ op: r.op, payload: JSON.parse(r.payload_json) }));
  }

  clearPendingMessages(sovereignId) {
    this._db.prepare(
      'DELETE FROM sov_pending_messages WHERE sovereign_id = ?'
    ).run(sovereignId);
  }

  // Keep certain ops (e.g. 'SV' transfer notifications) pending until the client
  // ACKs them via TX_HISTORY_CONFIRMED; clear the rest on delivery (king's design).
  clearPendingMessagesExcept(sovereignId, keepOps) {
    if (!keepOps || keepOps.length === 0) return this.clearPendingMessages(sovereignId);
    const ph = keepOps.map(() => '?').join(',');
    this._db.prepare(
      `DELETE FROM sov_pending_messages WHERE sovereign_id = ? AND op NOT IN (${ph})`
    ).run(sovereignId, ...keepOps);
  }

  // Delete pending records the client confirmed receiving, matched by tx_id/tx_hash.
  deletePendingByTxIds(sovereignId, txIds) {
    if (!txIds || txIds.length === 0) return 0;
    const set = new Set(txIds);
    const rows = this._db.prepare('SELECT id, payload_json FROM sov_pending_messages WHERE sovereign_id = ?').all(sovereignId);
    const del = this._db.prepare('DELETE FROM sov_pending_messages WHERE id = ?');
    let n = 0;
    for (const r of rows) {
      try { const p = JSON.parse(r.payload_json); const t = p.tx_id || p.tx_hash || '';
        if (t && set.has(t)) { del.run(r.id); n++; } } catch (_) {}
    }
    return n;
  }

  // ── Node registry operations ───────────────────────────────────────────────

  // verified=true only for REAL contact (verified peer handshake / signed heartbeat).
  // Gossip mentions call with verified=false and must NOT advance last_verified — that
  // is what lets a terminated node age out even while peers keep gossiping its address.
  upsertNodeRegistry(nodeId, address, publicKeyHex, verified = false) {
    const now = Date.now();
    const row = this._db.prepare(
      'SELECT last_verified, public_key_hex, reputation FROM sov_node_registry WHERE node_id = ?'
    ).get(nodeId);
    // New discovery gets a full grace window (last_verified = now) so it isn't pruned
    // before it has a fair chance to prove itself. Existing rows only advance on real contact.
    const lastVerified = row ? (verified ? now : row.last_verified) : now;
    const pk  = (publicKeyHex && publicKeyHex !== '') ? publicKeyHex : (row ? row.public_key_hex : '');
    const rep = row ? row.reputation : 100;
    this._db.prepare(`
      INSERT OR REPLACE INTO sov_node_registry
        (node_id, address, public_key_hex, last_seen, last_verified, reputation)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(nodeId, address, pk, now, lastVerified, rep);
  }

  getNodeRegistry() {
    return this._db.prepare(
      'SELECT * FROM sov_node_registry ORDER BY last_seen DESC LIMIT 200'
    ).all();
  }

  // Nodes to GOSSIP to peers: only those we (or the local mesh) verified within
  // freshMs, so dead entries stop propagating network-wide and can age out.
  getGossipableNodes(freshMs, limit = 50) {
    const cutoff = Date.now() - freshMs;
    return this._db.prepare(
      'SELECT * FROM sov_node_registry WHERE last_verified >= ? ORDER BY last_verified DESC LIMIT ?'
    ).all(cutoff, limit);
  }

  // Count of nodes verified-reachable within freshMs — the honest "live registered" number.
  countLiveNodes(freshMs) {
    const cutoff = Date.now() - freshMs;
    const r = this._db.prepare(
      'SELECT COUNT(*) AS n FROM sov_node_registry WHERE last_verified >= ?'
    ).get(cutoff);
    return r ? r.n : 0;
  }

  // Delete relay nodes not verified-reachable for > ttlMs (dead-node prune, king 2026-07-23).
  // Returns the number of rows removed. last_verified > 0 guard avoids nuking pre-migration rows.
  pruneDeadNodes(ttlMs) {
    const cutoff = Date.now() - ttlMs;
    const res = this._db.prepare(
      'DELETE FROM sov_node_registry WHERE last_verified > 0 AND last_verified < ?'
    ).run(cutoff);
    return res.changes;
  }

  // One-shot removal of explicitly-known-dead hosts (terminated VPS / test entries).
  // Used once at deploy to clear historical cruft that predates the TTL clock.
  purgeNodesByAddressPrefix(prefixes = []) {
    let n = 0;
    const del = this._db.prepare('DELETE FROM sov_node_registry WHERE address LIKE ?');
    for (const p of prefixes) { try { n += del.run(p + '%').changes; } catch (_) {} }
    return n;
  }

  // ── Governance operations ──────────────────────────────────────────────────

  getGovParam(key, defaultValue = null) {
    const row = this._db.prepare(
      'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
    ).get(key);
    return row ? row.param_value.toString() : defaultValue;
  }

  setGovParam(key, value) {
    this._db.prepare(`
      INSERT OR REPLACE INTO sov_governance_params (param_key, param_value, activated_at)
      VALUES (?, ?, ?)
    `).run(key, value.toString(), Date.now());
  }

  // ── Messaging keys ─────────────────────────────────────────────────────────

  setMessagingPublicKey(sovereignId, x25519PubHex) {
    this._db.prepare(`
      INSERT OR REPLACE INTO sov_messaging_keys (sovereign_id, x25519_pub_hex, updated_at)
      VALUES (?, ?, ?)
    `).run(sovereignId, x25519PubHex, Date.now());
  }

  getMessagingPublicKey(sovereignId) {
    const row = this._db.prepare(
      'SELECT x25519_pub_hex FROM sov_messaging_keys WHERE sovereign_id = ?'
    ).get(sovereignId);
    return row ? row.x25519_pub_hex : null;
  }

  // ── Spend lock operations (double-spend prevention) ────────────────────────

  acquireSpendLock(fromId, nonce, txId, ttlMs = 5000) {
    const lockKey  = `${fromId}:${nonce}`;
    const now      = Date.now();
    const expires  = now + ttlMs;

    // Clean expired locks first
    this._db.prepare('DELETE FROM sov_spend_locks WHERE expires_at < ?').run(now);

    try {
      this._db.prepare(`
        INSERT INTO sov_spend_locks (lock_key, tx_id, locked_at, expires_at)
        VALUES (?, ?, ?, ?)
      `).run(lockKey, txId, now, expires);
      return true;
    } catch (_) {
      return false; // Lock already held
    }
  }

  releaseSpendLock(fromId, nonce) {
    this._db.prepare(
      'DELETE FROM sov_spend_locks WHERE lock_key = ?'
    ).run(`${fromId}:${nonce}`);
  }

  // ── Automated-wallet spend policy ──────────────────────────────────────────

  /// Raw row → normalised object, or null if the citizen has no policy.
  getAutomationPolicyRaw(sovereignId) {
    const row = this._db.prepare(
      'SELECT * FROM sov_automation_policy WHERE sovereign_id = ?'
    ).get(sovereignId);
    if (!row) return null;
    let allowlist = [];
    let pending   = null;
    try { allowlist = JSON.parse(row.allowlist_json || '[]'); } catch (_) {}
    try { pending   = row.pending_json ? JSON.parse(row.pending_json) : null; } catch (_) {}
    return {
      sovereign_id: row.sovereign_id,
      enabled:      row.enabled === 1,
      per_tx_cap:   row.per_tx_cap || 0,
      daily_cap:    row.daily_cap  || 0,
      allowlist,
      pending,
      pending_at:   row.pending_at || null,
      updated_at:   row.updated_at || 0,
    };
  }

  /// Write the ACTIVE policy fields (used for both local set and peer sync).
  writeAutomationPolicy(sovereignId, p) {
    this._db.prepare(`
      INSERT INTO sov_automation_policy
        (sovereign_id, enabled, per_tx_cap, daily_cap, allowlist_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(sovereign_id) DO UPDATE SET
        enabled=excluded.enabled, per_tx_cap=excluded.per_tx_cap,
        daily_cap=excluded.daily_cap, allowlist_json=excluded.allowlist_json,
        updated_at=excluded.updated_at
    `).run(
      sovereignId,
      p.enabled ? 1 : 0,
      Math.max(0, Math.floor(p.per_tx_cap || 0)),
      Math.max(0, Math.floor(p.daily_cap  || 0)),
      JSON.stringify(Array.isArray(p.allowlist) ? p.allowlist : []),
      p.updated_at || Date.now()
    );
  }

  setAutomationPending(sovereignId, pending, pendingAt) {
    this._db.prepare(
      'UPDATE sov_automation_policy SET pending_json = ?, pending_at = ? WHERE sovereign_id = ?'
    ).run(pending ? JSON.stringify(pending) : null, pendingAt || null, sovereignId);
  }

  clearAutomationPending(sovereignId) {
    this._db.prepare(
      'UPDATE sov_automation_policy SET pending_json = NULL, pending_at = NULL WHERE sovereign_id = ?'
    ).run(sovereignId);
  }

  recordAutomationSpend(sovereignId, amountSeeds) {
    this._db.prepare(
      'INSERT INTO sov_automation_spend (sovereign_id, spent_at, amount_seeds) VALUES (?, ?, ?)'
    ).run(sovereignId, Date.now(), amountSeeds);
  }

  sumAutomationSpend24h(sovereignId) {
    const cutoff = Date.now() - 86400000;
    // Opportunistically prune rows older than the window.
    this._db.prepare('DELETE FROM sov_automation_spend WHERE spent_at < ?').run(cutoff);
    const row = this._db.prepare(
      'SELECT COALESCE(SUM(amount_seeds),0) AS s FROM sov_automation_spend WHERE sovereign_id = ? AND spent_at >= ?'
    ).get(sovereignId, cutoff);
    return row ? row.s : 0;
  }

  // ── Merkle root ───────────────────────────────────────────────────────────
  // Quick integrity check — SHA-256 over sorted balances.
  // Peer nodes compare Merkle roots to detect state divergence.

  computeMerkleRoot() {
    const rows = this._db.prepare(
      'SELECT sovereign_id, balance_seeds, version, nonce FROM sov_disc ORDER BY sovereign_id ASC'
    ).all();
    if (rows.length === 0) return '0'.repeat(64);

    // H4 (2026-08-06): the leaf now binds `nonce` too. Before this, a node that
    // converged balance+version via STATE_DELTA kept a STALE nonce — invisible to
    // consensus (nonce was not in the root) — which re-opened a replay window: a
    // validly-signed old transfer at the stale nonce would be accepted again. With
    // nonce in the leaf, a nonce divergence shows as a root mismatch and heals via
    // the (also nonce-carrying) state delta. NOTE: changing the leaf changes the
    // root for every node, so this MUST be deployed fleet-wide together.
    const leafHashes = rows.map(r =>
      require('crypto').createHash('sha256')
        .update(`${r.sovereign_id}:${r.balance_seeds}:${r.version}:${r.nonce}`)
        .digest('hex')
    );

    // Reduce to single root hash
    let level = leafHashes;
    while (level.length > 1) {
      const next = [];
      for (let i = 0; i < level.length; i += 2) {
        const left  = level[i];
        const right = level[i + 1] || level[i];
        next.push(
          require('crypto').createHash('sha256').update(left + right).digest('hex')
        );
      }
      level = next;
    }
    return level[0];
  }

  // Exchange-state root — a second anti-entropy digest (the balance Merkle only
  // covers sov_disc, so chat/orders that don't move a balance would never trigger
  // a delta). Hashed over the UNION of open+recent orders (local + replicas,
  // newest wins) and recent message ids, so two converged nodes produce the same
  // root regardless of which holds each order locally vs as a replica.
  computeExchangeRoot() {
    try {
      const cut = Date.now() - 7 * 24 * 60 * 60 * 1000;
      const m = new Map();
      const add = (r) => { const e = m.get(r.order_id); if (!e || r.updated_at > e.updated_at) m.set(r.order_id, r); };
      for (const r of this._db.prepare("SELECT order_id,status,filled_by,price_per_sov,updated_at FROM sov_exchange_orders WHERE status='open' OR updated_at > ?").all(cut)) add(r);
      try { for (const r of this._db.prepare("SELECT order_id,status,filled_by,price_per_sov,updated_at FROM sov_exchange_replicas WHERE status='open' OR updated_at > ?").all(cut)) add(r); } catch (_) {}
      const ids = [...m.keys()].sort();
      const msgs = this._db.prepare("SELECT msg_id FROM sov_exchange_messages WHERE created_at > ? ORDER BY msg_id ASC").all(cut);
      const h = require('crypto').createHash('sha256');
      for (const id of ids) { const o = m.get(id); h.update(id + ':' + o.status + ':' + (o.filled_by||'') + ':' + o.price_per_sov + ':' + o.updated_at + ';'); }
      for (const mm of msgs) h.update(mm.msg_id + ';');
      return h.digest('hex');
    } catch (_) { return ''; }
  }

  // ── Hourly maintenance ─────────────────────────────────────────────────────

  _startMaintenance() {
    // Run once at startup (delayed) then every hour
    setTimeout(() => this._runMaintenance(), 30000);
    setInterval(() => this._runMaintenance(), 60 * 60 * 1000);
  }

  // ── Generic consensus anti-entropy ────────────────────────────────────────
  // One digest over every registered consensus table (order-independent per table),
  // carried in NODE_HEARTBEAT so any divergence in any of them triggers a pull.
  //
  // Volatile per-node columns are EXCLUDED from the hash. A column like updated_at
  // is stamped with THIS node's Date.now() when the row is written locally, so the
  // same logical row (e.g. a citizen's messaging key) hashes differently on each
  // node — the consensus root then never converges and the mesh flaps forever
  // pulling deltas that change nothing. The hash must be over the STABLE identity +
  // content of each row, not the moment each node happened to store it.
  static get _CONSENSUS_VOLATILE_COLS() {
    // Per-node timestamps + DERIVED cached counters. member_count is recomputed
    // locally from sov_group_members (which IS consensus-synced), so it can drift
    // between nodes even when the authoritative membership rows are identical —
    // hashing it caused a perpetual sov_groups consensus flap.
    return ['updated_at', 'ts', 'last_seen', 'updated', 'last_message_at',
            'synced_at', 'member_count'];
  }

  _stableRow(r) {
    const vol = NodeDB._CONSENSUS_VOLATILE_COLS;
    const o = {};
    for (const k of Object.keys(r).sort()) { if (!vol.includes(k)) o[k] = r[k]; }
    return JSON.stringify(o);
  }

  computeConsensusRoot() {
    try {
      const crypto = require('crypto');
      const h = crypto.createHash('sha256');
      for (const t of CONSENSUS_TABLES) {
        try {
          const rows = this._db.prepare('SELECT * FROM ' + t).all();
          if (!rows.length) continue;
          const d = rows.map(r => this._stableRow(r)).sort().join('|');
          h.update(t + '=' + crypto.createHash('sha256').update(d).digest('hex') + ';');
        } catch (_) {}
      }
      return h.digest('hex');
    } catch (_) { return ''; }
  }

  exportConsensus() {
    const out = {};
    for (const t of CONSENSUS_TABLES) {
      try { const rows = this._db.prepare('SELECT * FROM ' + t + ' LIMIT 5000').all(); if (rows.length) out[t] = rows; } catch (_) {}
    }
    return out;
  }

  applyConsensus(data) {
    if (!data) return 0;
    let applied = 0;
    for (const t of CONSENSUS_TABLES) {
      const rows = data[t]; if (!rows || !rows.length) continue;
      try {
        const cols = Object.keys(rows[0]);
        // sov_messaging_keys is NOT append-only — a citizen can re-publish their
        // key. INSERT OR IGNORE would keep a stale key forever (nodes diverge),
        // so take the peer's row when its updated_at is newer (latest-wins).
        if (t === 'sov_messaging_keys' && cols.includes('updated_at')) {
          const up = this._db.prepare(
            'INSERT INTO sov_messaging_keys (sovereign_id, x25519_pub_hex, updated_at) VALUES (?, ?, ?) ' +
            'ON CONFLICT(sovereign_id) DO UPDATE SET x25519_pub_hex=excluded.x25519_pub_hex, updated_at=excluded.updated_at ' +
            'WHERE excluded.updated_at > sov_messaging_keys.updated_at');
          for (const r of rows) { try { applied += up.run(r.sovereign_id, r.x25519_pub_hex, r.updated_at || 0).changes; } catch (_) {} }
          continue;
        }
        const stmt = this._db.prepare('INSERT OR IGNORE INTO ' + t + ' (' + cols.join(',') + ') VALUES (' + cols.map(() => '?').join(',') + ')');
        for (const r of rows) { try { applied += stmt.run(...cols.map(c => r[c])).changes; } catch (_) {} }
      } catch (_) {}
    }
    // Wallet/pool-affecting rows may have arrived via replication — keep the
    // supply invariant true right away rather than waiting for the timer.
    if (applied > 0) { try { this.reconcileSupplyPools(); } catch (_) {} }
    return applied;
  }

  // ── Node capability / storage awareness ───────────────────────────────────
  // Each node measures how much of its available disk its state is consuming, so it
  // KNOWS whether it can keep holding the full replicated state (which grows with the
  // citizen population, dominated by biometric templates) or must shed heavy work.
  // pressure = state / (state + free). At/above the high-water mark the node reports
  // tier='light' — the signal that it should stop pulling the big embedding set and
  // DELEGATE heavy compute (enrollment dedup) to full/witness peers instead of trying
  // to hold ~TBs it has no room for. Old/small machines can then still participate.
  computeCapability() {
    try {
      const fs = require('fs');
      let stateBytes = 0;
      try { stateBytes += fs.statSync(DB_FILE).size; } catch (_) {}
      try { stateBytes += fs.statSync(DB_FILE + '-wal').size; } catch (_) {}
      let freeBytes = 0, totalBytes = 0;
      try { const st = fs.statfsSync(DATA_DIR); freeBytes = st.bavail * st.bsize; totalBytes = st.blocks * st.bsize; } catch (_) {}
      const usable = stateBytes + freeBytes;
      const pressure = usable > 0 ? Math.round((stateBytes / usable) * 10000) / 10000 : 0;
      const highWater = parseFloat(process.env.SOV_STORAGE_HIGH_WATER || '0.85');
      return {
        state_bytes: stateBytes,
        free_bytes:  freeBytes,
        total_bytes: totalBytes,
        pressure,
        high_water:  highWater,
        tier: pressure >= highWater ? 'light' : 'full',
      };
    } catch (_) {
      return { state_bytes: 0, free_bytes: 0, total_bytes: 0, pressure: 0, high_water: 0.85, tier: 'full' };
    }
  }

  _runMaintenance() {
    const now = Date.now();
    try { this._db.pragma('incremental_vacuum'); } catch (_) {}  // reclaim freed pages (no-op unless auto_vacuum=INCREMENTAL)

    // Prune expired pending messages
    this._db.prepare('DELETE FROM sov_pending_messages WHERE expires_at < ?').run(now);

    // Prune expired spend locks
    this._db.prepare('DELETE FROM sov_spend_locks WHERE expires_at < ?').run(now);

    // Prune old transaction records (respects tx_retention_days governance param)
    // King's design: keep the relay light. Delete confirmed txs older than
    // tx_retention_days (default 7 = one week), BUT always keep each citizen's 5
    // most recent (as sender or recipient). Citizens own their full history
    // on-device (backed up alongside keys + contacts).
    const retentionDays = parseInt(this.getGovParam('tx_retention_days', '7'));
    const txCutoff      = now - (retentionDays * 24 * 60 * 60 * 1000);
    const pruned = this._db.prepare(`
      DELETE FROM sov_transactions
      WHERE status = 'confirmed'
        AND confirmed_at < ?
        AND tx_id NOT IN (
          SELECT tx_id FROM (
            SELECT tx_id, ROW_NUMBER() OVER (PARTITION BY citizen ORDER BY confirmed_at DESC) AS rn
            FROM (
              SELECT tx_id, from_id AS citizen, confirmed_at FROM sov_transactions
              UNION ALL
              SELECT tx_id, to_id   AS citizen, confirmed_at FROM sov_transactions
            )
          ) WHERE rn <= 5
        )
    `).run(txCutoff).changes;

    if (pruned > 0) {
      global.sovLog.info(`Maintenance: pruned ${pruned} transactions older than ${retentionDays} days`);
    }

    // Prune old message metadata (message_retention_days)
    const msgRetentionDays = parseInt(this.getGovParam('message_retention_days', '90'));
    const msgCutoff        = now - (msgRetentionDays * 24 * 60 * 60 * 1000);
    this._db.prepare('DELETE FROM sov_message_records WHERE created_at < ?').run(msgCutoff);
  }

  // ── Palm embeddings — one-human-one-wallet duplicate detection ───────────────
  storePalmEmbedding(sovereignId, embeddingJson, handType = 'LEFT') {
    try {
      // Tier-4 fix: store the CANCELABLE-TRANSFORMED template (R·embedding), never
      // the raw biometric. Same size (replicable + light-speed sync), cosine
      // preserved (dedup identical), revocable, breach yields non-raw vectors.
      const protectedJson = require('../security/palm_cancelable').protectForStorage(embeddingJson);
      this._db.prepare(`
        INSERT OR REPLACE INTO palm_embeddings (sovereign_id, embedding_json, hand_type, enrolled_at)
        VALUES (?, ?, ?, ?)
      `).run(sovereignId, protectedJson, handType, Date.now());
    } catch (e) {
      global.sovLog.warn(`[DB] Failed to store palm embedding for ${sovereignId}: ${e.message}`);
    }
  }

  getAllPalmEmbeddings() {
    try {
      return this._db.prepare(
        'SELECT sovereign_id, embedding_json, hand_type FROM palm_embeddings'
      ).all();
    } catch (_) {
      return [];
    }
  }

  // ── Face embeddings — FACE-LOCK cross-hand duplicate detection ──────────────
  // Same cancelable-biometric model as palms, but with the face-specific R
  // (192-dim, seed + ':face-v1'). Stores ONLY the protected template; if the
  // input is malformed the row is NOT stored (strict — never store raw).
  storeFaceEmbedding(sovereignId, embeddingJson) {
    try {
      const protectedJson = require('../security/face_cancelable').protectForStorage(embeddingJson);
      if (!protectedJson) {
        global.sovLog.warn(`[DB] Face embedding for ${sovereignId} rejected (malformed) — not stored`);
        return false;
      }
      this._db.prepare(`
        INSERT OR REPLACE INTO face_embeddings (sovereign_id, embedding_json, enrolled_at)
        VALUES (?, ?, ?)
      `).run(sovereignId, protectedJson, Date.now());
      return true;
    } catch (e) {
      global.sovLog.warn(`[DB] Failed to store face embedding for ${sovereignId}: ${e.message}`);
      return false;
    }
  }

  // Store an ALREADY-PROTECTED face template verbatim (peer replication path —
  // NEVER re-transform).
  storeFaceEmbeddingProtected(sovereignId, protectedJson, enrolledAt) {
    try {
      this._db.prepare(`
        INSERT OR IGNORE INTO face_embeddings (sovereign_id, embedding_json, enrolled_at)
        VALUES (?, ?, ?)
      `).run(sovereignId, protectedJson, enrolledAt || Date.now());
    } catch (e) {
      global.sovLog.warn(`[DB] Failed to replicate face embedding for ${sovereignId}: ${e.message}`);
    }
  }

  getAllFaceEmbeddings() {
    try {
      return this._db.prepare(
        'SELECT sovereign_id, embedding_json, enrolled_at FROM face_embeddings'
      ).all();
    } catch (_) {
      return [];
    }
  }

  // ── Palm name helper — called from citizen_gateway.js on legacy HELLO ───────
  updatePalmNameIfEmpty(sovereignId, palmName) {
    try {
      this._db.prepare(`
        UPDATE sov_enrollments SET palm_name = ?
        WHERE sovereign_id = ? AND (palm_name IS NULL OR palm_name = '')
      `).run(palmName, sovereignId);
    } catch (_) {}
  }

  // ── Network stats helpers — for NODE_STATS handler in citizen_gateway.js ────

  getEnrolledCount() {
    const row = this._db.prepare('SELECT COUNT(*) as cnt FROM sov_enrollments').get();
    return row ? row.cnt : 0;
  }

  getTotalCirculation() {
    const row = this._db.prepare('SELECT SUM(balance_seeds) as total FROM sov_disc').get();
    return row && row.total ? Number(row.total) : 0;
  }

  getTransferCount24h() {
    const cutoff = Date.now() - 86400000;
    const row = this._db.prepare(
      'SELECT COUNT(*) as cnt FROM sov_transactions WHERE confirmed_at > ?'
    ).get(cutoff);
    return row ? row.cnt : 0;
  }

  getTransferVolume24h() {
    const cutoff = Date.now() - 86400000;
    const row = this._db.prepare(
      'SELECT SUM(amount_seeds) as vol FROM sov_transactions WHERE confirmed_at > ?'
    ).get(cutoff);
    return row && row.vol ? Number(row.vol) : 0;
  }

  // ── Shutdown ───────────────────────────────────────────────────────────────

  close() {
    this._db.close();
  }

  // ─── Supply pool ops (Blueprint v14.0 §2.3 + Fair-Launch Refactor 2026-05-27) ──
  //
  // FIVE canonical pools that together cap at 50M SOV. Each pool tracks its
  // own allocation, remaining seeds, and distributed seeds.
  //
  // [FAIR-LAUNCH REFACTOR 2026-05-27] — the previous SIX-pool design with a
  // founder_allocation (5M SOV) and a separate early_contributors pool was
  // replaced. The freed 7.5M (5M founder_allocation + 2.5M early_contributors)
  // was redistributed to witness_operator (10M → 17.5M). early_contributors
  // was renamed community_contributors with cap 0 — citizens may vote, after
  // 10,000 citizens are enrolled, to allocate from witness_operator surplus
  // into this pool. See SOV_PROTOCOL_FAIRNESS_AUDIT.md for rationale.
  //
  // Cap math: 20M + 17.5M + 5M + 7.5M + 0M = 50,000,000 SOV ✓
  _initSupplyPools() {
    const pools = [
      ['citizen_enrollment',     30_000_000_000_000],
      // Holds refundable bonds (Academy article/upvote) while they are
      // outstanding. Allocated 0: it never issues anything, it only holds
      // what a citizen has put up. Without it a held bond sits in no pool
      // and no wallet, and the 50M invariant reads it as missing supply.
      ['bonds_held',             0],  // 20M  SOV — tier-gradient citizen rewards
      ['witness_operator',       20_000_000_000_000],  // 17.5M SOV — per-tx + uptime to operators (+7.5M from former founder_allocation + early_contributors)
      ['community_contributors',                  0],  // 0    SOV — governance-released only after 10k citizens enrolled
    ];
    const ins = this._db.prepare(
      'INSERT OR IGNORE INTO sov_supply_pools (pool_id, allocated_seeds, remaining_seeds, distributed_seeds, updated_at) VALUES (?, ?, ?, 0, ?)'
    );
    const now = Date.now();
    for (const [id, amt] of pools) ins.run(id, amt, amt, now);
  }

  // Deduct seeds from a pool. Returns the actual amount deducted (may be
  // less than requested if pool nearing exhaustion, or 0 if depleted).
  // Atomic and version-safe.
  refundPool(poolId, seeds) {
    if (seeds <= 0) return;
    const tx = this._db.transaction(() => {
      this._db.prepare(
        'UPDATE sov_supply_pools SET remaining_seeds = remaining_seeds + ?, distributed_seeds = distributed_seeds - ?, updated_at = ? WHERE pool_id = ?'
      ).run(seeds, seeds, Date.now(), poolId);
      this._recordLocalPoolDelta(poolId, +seeds, -seeds, 'refund');
    });
    tx();
  }

  // [PI-11] Add INCOMING seeds to a pool reserve WITHOUT touching distributed_seeds.
  // For fees/idle funds collected from circulating wallets routed into a protocol
  // reserve (platform_register_fee, stewarded vaults -> witness_operator). refundPool
  // is wrong here (it drives distributed_seeds negative). Supply-neutral.
  // True inverse of addToPool: remove seeds from a pool reserve WITHOUT touching
  // distributed_seeds. Restores a stewarded vault to its owner/heir so the
  // steward(addToPool)+restore(drawFromPool) round-trip nets exactly zero on the
  // pool. Guarded so remaining_seeds never goes negative. (deductFromPool is for
  // genuine operator payouts, which legitimately increment distributed_seeds.)
  drawFromPool(poolId, seeds) {
    if (seeds <= 0) return 0;
    const row = this._db.prepare('SELECT remaining_seeds FROM sov_supply_pools WHERE pool_id = ?').get(poolId);
    if (!row) return 0;
    const actual = Math.min(seeds, row.remaining_seeds);
    if (actual <= 0) return 0;
    this._db.prepare('UPDATE sov_supply_pools SET remaining_seeds = remaining_seeds - ?, updated_at = ? WHERE pool_id = ?').run(actual, Date.now(), poolId);
    return actual;
  }

  /**
   * Credit a pool, and if that fails record the debt instead of losing it.
   * Returns true when the pool was credited. Callers MUST NOT treat a false
   * return as "burned" — the seeds are recorded in sov_fee_unrouted and remain
   * owed to the pool.
   */
  addToPoolOrRecord(poolId, seeds, { source = 'unknown', ref = null } = {}) {
    if (!(seeds > 0)) return true;
    try {
      this.addToPool(poolId, seeds);
      return true;
    } catch (err) {
      try {
        this._db.prepare(
          `INSERT INTO sov_fee_unrouted (pool_id, seeds, source, ref, reason, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        ).run(poolId, seeds, source, ref, String(err && err.message || err), Date.now());
      } catch (_) { /* last resort: the throw below still surfaces it */ }
      if (global.sovLog && global.sovLog.error) {
        global.sovLog.error(
          `[FEE-ROUTE] FAILED to credit ${poolId} with ${seeds} seeds (${source}` +
          `${ref ? ' ' + ref : ''}) — recorded in sov_fee_unrouted, NOT burned: ` +
          String(err && err.message || err));
      }
      return false;
    }
  }

  addToPool(poolId, seeds) {
    if (seeds <= 0) return;
    const tx = this._db.transaction(() => {
      this._db.prepare(
        'UPDATE sov_supply_pools SET remaining_seeds = remaining_seeds + ?, updated_at = ? WHERE pool_id = ?'
      ).run(seeds, Date.now(), poolId);
      this._recordLocalPoolDelta(poolId, +seeds, 0, 'add');
    });
    tx();
    // KEPT from the live file — the staged patch omitted this and would have
    // silently deleted it. Payouts spend FEE INFLOW FIRST (operator economy
    // spec); without it the budget sees zero fees and draws on the reserve.
    // Outside the transaction: it broadcasts, and an unreachable peer must not
    // roll back the pool write.
    try { this.recordPoolInflow(poolId, seeds); } catch (_) {}
  }

  // ── Pool inflow accounting (per 30-day payout period) ──────────────────────
  // Period id matches OperatorEngine._currentPayoutPeriod(): floor(now / 30d).
  static poolPeriodId(ts) {
    return Math.floor((ts || Date.now()) / (30 * 24 * 3600 * 1000));
  }

  /**
   * Called with (poolId, periodId, totalSeeds) after a local inflow is recorded,
   * so the node can tell its peers. Set by index.js once the mesh exists; left
   * null on a node with no peers, where it is simply never called.
   */
  setInflowBroadcaster(fn) { this._inflowBroadcaster = fn; }

  /**
   * Apply a peer's inflow figure. Takes the LARGER of the two.
   *
   * The wire carries an absolute total rather than a delta precisely so this can
   * be applied twice, out of order, or from three peers at once and still land
   * on the same number. Inflow within a period only grows, so max is the correct
   * merge: it can never lose a fee we already knew about, and never invent one.
   */
  mergePoolInflow(poolId, periodId, totalSeeds) {
    if (!poolId || !Number.isFinite(totalSeeds) || totalSeeds <= 0) return;
    this._db.prepare(`
      INSERT INTO sov_pool_inflow (pool_id, period_id, seeds, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(pool_id, period_id) DO UPDATE SET
        seeds = MAX(seeds, excluded.seeds), updated_at = excluded.updated_at
    `).run(poolId, periodId, Math.floor(totalSeeds), Date.now());
  }

  recordPoolInflow(poolId, seeds) {
    if (seeds <= 0) return;
    const period = NodeDB.poolPeriodId();
    this._db.prepare(`
      INSERT INTO sov_pool_inflow (pool_id, period_id, seeds, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(pool_id, period_id) DO UPDATE SET
        seeds = seeds + excluded.seeds, updated_at = excluded.updated_at
    `).run(poolId, period, seeds, Date.now());
    // Tell the peers the resulting TOTAL, not the delta — see mergePoolInflow.
    try {
      if (this._inflowBroadcaster) {
        const row = this._db.prepare(
          'SELECT seeds FROM sov_pool_inflow WHERE pool_id = ? AND period_id = ?'
        ).get(poolId, period);
        if (row) this._inflowBroadcaster(poolId, period, row.seeds);
      }
    } catch (_) { /* accounting must never break the write that earned it */ }
  }

  /// Total fees collected into [poolId] during [periodId] (0 if none).
  getPoolInflow(poolId, periodId) {
    try {
      const row = this._db.prepare(
        'SELECT seeds FROM sov_pool_inflow WHERE pool_id = ? AND period_id = ?'
      ).get(poolId, periodId);
      return row ? row.seeds : 0;
    } catch (_) { return 0; }
  }

  deductFromPool(poolId, requestedSeeds) {
    if (requestedSeeds <= 0) return 0;
    const row = this._db.prepare('SELECT remaining_seeds FROM sov_supply_pools WHERE pool_id = ?').get(poolId);
    if (!row) return 0;
    const actual = Math.min(requestedSeeds, row.remaining_seeds);
    if (actual <= 0) return 0;
    const tx = this._db.transaction(() => {
      this._db.prepare(
        'UPDATE sov_supply_pools SET remaining_seeds = remaining_seeds - ?, distributed_seeds = distributed_seeds + ?, updated_at = ? WHERE pool_id = ?'
      ).run(actual, actual, Date.now(), poolId);
      this._recordLocalPoolDelta(poolId, -actual, +actual, 'deduct');
    });
    tx();
    return actual;
  }

  getPool(poolId) {
    return this._db.prepare('SELECT * FROM sov_supply_pools WHERE pool_id = ?').get(poolId);
  }

  allPools() {
    return this._db.prepare('SELECT * FROM sov_supply_pools ORDER BY pool_id').all();
  }

  // ── PI-13 pool delta propagation ──────────────────────────────────────────
  setNodeId(id)        { this._nodeId = id; }
  setPoolDeltaSink(fn) { this._onPoolDelta = fn; }

  _recordLocalPoolDelta(poolId, remainingDelta, distributedDelta, reason) {
    if (!this._nodeId) return; // pre-mesh boot — genesis seeding is identical everywhere
    const seq = this._db.prepare(
      'SELECT COALESCE(MAX(seq),0)+1 AS s FROM sov_pool_deltas WHERE origin_node = ?'
    ).get(this._nodeId).s;
    const deltaId = `${this._nodeId}:${seq}`;
    const now = Date.now();
    this._db.prepare(
      `INSERT INTO sov_pool_deltas
         (delta_id, origin_node, seq, pool_id, remaining_delta, distributed_delta, reason, created_at)
       VALUES (?,?,?,?,?,?,?,?)`
    ).run(deltaId, this._nodeId, seq, poolId, remainingDelta, distributedDelta, reason || '', now);
    if (this._onPoolDelta) {
      try {
        this._onPoolDelta({
          delta_id: deltaId, origin_node: this._nodeId, seq, pool_id: poolId,
          remaining_delta: remainingDelta, distributed_delta: distributedDelta,
          reason: reason || '', created_at: now,
        });
      } catch (e) { global.sovLog.warn(`[POOL] delta sink threw: ${e.message}`); }
    }
  }

  // Idempotent: peers apply the ORIGIN's computed delta, never re-running the
  // clamp, so every node lands on identical values regardless of local state.
  applyRemotePoolDelta(d) {
    if (!d || !d.delta_id || !d.pool_id) return false;
    if (this._nodeId && d.origin_node === this._nodeId) return false;
    const tx = this._db.transaction(() => {
      const ins = this._db.prepare(
        `INSERT OR IGNORE INTO sov_pool_deltas
           (delta_id, origin_node, seq, pool_id, remaining_delta, distributed_delta, reason, created_at)
         VALUES (?,?,?,?,?,?,?,?)`
      ).run(d.delta_id, d.origin_node, d.seq, d.pool_id,
            d.remaining_delta, d.distributed_delta, d.reason || '', d.created_at || Date.now());
      if (ins.changes === 0) return false;
      this._db.prepare(
        `UPDATE sov_supply_pools
            SET remaining_seeds = remaining_seeds + ?, distributed_seeds = distributed_seeds + ?, updated_at = ?
          WHERE pool_id = ?`
      ).run(d.remaining_delta, d.distributed_delta, Date.now(), d.pool_id);
      return true;
    });
    return tx();
  }

  poolDeltaDigest() {
    const rows = this._db.prepare(
      'SELECT origin_node, MAX(seq) AS max_seq FROM sov_pool_deltas GROUP BY origin_node'
    ).all();
    const out = {};
    for (const r of rows) out[r.origin_node] = r.max_seq;
    return out;
  }

  poolDeltasAfter(originNode, afterSeq) {
    return this._db.prepare(
      'SELECT * FROM sov_pool_deltas WHERE origin_node = ? AND seq > ? ORDER BY seq ASC'
    ).all(originNode, afterSeq);
  }

  // ── Supply-invariant reconciler (self-healing) ───────────────────────────────
  // The 50M genesis mint is split across pools; as SOV moves into wallets, pool
  // `remaining` must fall so that  Σ(pool.remaining) + Σ(wallets) = 50,000,000.
  //
  // Pools are per-node accounting buckets, but wallet balances replicate globally
  // via consensus / state-delta. A node therefore holds wallet SOV it never
  // distributed-from-pool: the direct ENROLL broadcast deducts the enrollment pool,
  // but the state-delta replication path credits the wallet WITHOUT deducting any
  // pool. That drift is what breaks the "SUPPLY INVARIANT" the economy widget shows.
  //
  // Fix: make the primary distribution pool (citizen_enrollment) the balancing
  // RESIDUAL so the whole-node total lands exactly on the 50M cap. Wallets and the
  // fee-fed operator/community pools are the ground truth and are NEVER touched —
  // only the enrollment pool's accounting is corrected, so no citizen balance
  // changes. Any correction is logged so a genuine minting bug can never hide here.
  // Returns the correction applied, in seeds (0 if already balanced).
  reconcileSupplyPools() {
    try {
      const CAP = 50_000_000 * 1_000_000; // 50M SOV, in seeds
      const w = this._db.prepare('SELECT COALESCE(SUM(balance_seeds),0) s FROM sov_disc').get();
      const walletTotal = w.s || 0;
      const pools = this.allPools();
      const enr = pools.find(p => p.pool_id === 'citizen_enrollment');
      if (!enr) return 0; // no residual pool to balance against
      let otherRemaining = 0;
      for (const p of pools) {
        if (p.pool_id !== 'citizen_enrollment') otherRemaining += (p.remaining_seeds || 0);
      }
      let target = CAP - walletTotal - otherRemaining;
      if (target < 0) target = 0;
      if (target > enr.allocated_seeds) target = enr.allocated_seeds;
      const delta = target - (enr.remaining_seeds || 0);
      if (delta === 0) return 0;
      const newDistributed = enr.allocated_seeds - target;
      this._db.prepare(
        'UPDATE sov_supply_pools SET remaining_seeds = ?, distributed_seeds = ?, updated_at = ? WHERE pool_id = ?'
      ).run(target, newDistributed, Date.now(), 'citizen_enrollment');
      const SOV = 1e6;
      global.sovLog && global.sovLog.info(
        `[SUPPLY] reconciled citizen_enrollment by ${(delta / SOV).toFixed(4)} SOV ` +
        `(wallets=${(walletTotal / SOV).toFixed(2)}, remaining→${(target / SOV).toFixed(2)}) — invariant restored`
      );
      return delta;
    } catch (e) {
      global.sovLog && global.sovLog.warn('[SUPPLY] reconcile error: ' + e.message);
      return 0;
    }
  }

  // Start a low-frequency self-heal loop so the invariant stays true even as
  // wallet balances arrive via consensus between enrollment broadcasts. Idempotent.
  startSupplyReconciler(intervalMs = 5 * 60 * 1000) {
    this.reconcileSupplyPools(); // heal immediately on boot
    if (this._supplyTimer) return;
    this._supplyTimer = setInterval(() => this.reconcileSupplyPools(), intervalMs);
    if (this._supplyTimer.unref) this._supplyTimer.unref();
  }
}

module.exports = { NodeDB };
