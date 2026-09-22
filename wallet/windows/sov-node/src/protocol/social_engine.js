// ─────────────────────────────────────────────────────────────────────────────
// SOCIAL ENGINE — Academy, SOV Enclave, SOV Login, Palm Names
// ─────────────────────────────────────────────────────────────────────────────
// Everything citizens do together beyond messaging.
//
// Four subsystems:
//
//   1. SOV Academy — citizen-published articles with bond deduction + upvotes
//   2. SOV Enclave — community forum. Binary gate: sov_enclave, seeded '1' (ON).
//      The param is a citizen KILL SWITCH, not an activation gate: the Enclave
//      ships live and citizens can vote it off if they ever need to.
//   4. SOV Login — sovereign single sign-on for external websites (gate: sov_login)
//   5. Palm Names — query and broadcast palm-derived citizen names
//
// Op codes (inbound from phone):
//   AP — ACADEMY_PUBLISH          AL — ACADEMY_LIST
//   AG — ACADEMY_GET              AU — ACADEMY_UPVOTE
//   FP — ENCLAVE_POST               FY — ENCLAVE_REPLY
//   FL — ENCLAVE_LIST               FG — ENCLAVE_GET
//   LG — LOGIN_CHALLENGE_CREATE
//   LR — LOGIN_RESPOND            LV — LOGIN_VERIFY
//   NQ — PALM_NAME_QUERY (reuses NODE_QUERY slot on different ws context)
//        (Note: NODE_QUERY 'NQ' is phone mesh; palm name uses 'PN')
//   PN — PALM_NAME_QUERY
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

class SocialEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    this._initSocialTables();

    // Register peer mesh handlers
    peerMesh.on('ACADEMY_ARTICLE_BROADCAST',  (msg) => this._handleAcademyBroadcast(msg));
    peerMesh.on('ENCLAVE_POST_BROADCAST',       (msg) => this._handleEnclavePostBroadcast(msg));
    peerMesh.on('ENCLAVE_REPLY_BROADCAST',      (msg) => this._handleEnclaveReplyBroadcast(msg));
    peerMesh.on('PALM_NAME_BROADCAST',        (msg) => this._handlePalmNameBroadcast(msg));
    peerMesh.on('SOV_LOGIN_VERIFIED_FORWARD', (msg) => this._handleLoginVerifiedForward(msg));

    // Hourly: cleanup login sessions
    setTimeout(() => this._runMaintenance(), 20 * 1000);
    setInterval(() => this._runMaintenance(), 60 * 60 * 1000);

    global.sovLog.info('      ✓ Social engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initSocialTables() {
    this._db._db.exec(`

      -- ── Academy ───────────────────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_academy_articles (
        article_id    TEXT PRIMARY KEY,
        author_id     TEXT NOT NULL,
        title         TEXT NOT NULL,
        body          TEXT NOT NULL,
        category      TEXT NOT NULL DEFAULT 'general',
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL DEFAULT 0,
        upvote_count  INTEGER NOT NULL DEFAULT 0,
        bond_held     INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_academy_author   ON sov_academy_articles(author_id);
      CREATE INDEX IF NOT EXISTS idx_academy_category ON sov_academy_articles(category);

      CREATE TABLE IF NOT EXISTS sov_academy_upvotes (
        article_id    TEXT NOT NULL,
        voter_id      TEXT NOT NULL,
        voted_at      INTEGER NOT NULL,
        PRIMARY KEY (article_id, voter_id)
      );

      -- ── SOV Enclave (Forum) ───────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_enclave_posts (
        post_id       TEXT PRIMARY KEY,
        author_id     TEXT NOT NULL,
        title         TEXT NOT NULL,
        body          TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        reply_count   INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_enclave_posts_ts ON sov_enclave_posts(created_at);

      CREATE TABLE IF NOT EXISTS sov_enclave_replies (
        reply_id      TEXT PRIMARY KEY,
        post_id       TEXT NOT NULL,
        author_id     TEXT NOT NULL,
        body          TEXT NOT NULL,
        created_at    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_enclave_replies ON sov_enclave_replies(post_id);


      -- ── SOV Login ─────────────────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_login_sessions (
        session_id    TEXT PRIMARY KEY,
        challenge     TEXT NOT NULL,
        sovereign_id  TEXT NOT NULL DEFAULT '',
        client_origin TEXT NOT NULL DEFAULT '',
        status        TEXT NOT NULL DEFAULT 'pending',  -- pending | verified | expired
        created_at    INTEGER NOT NULL,
        verified_at   INTEGER NOT NULL DEFAULT 0,
        expires_at    INTEGER NOT NULL
      );

      -- ── Profiles (palm names) ─────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_profiles (
        sovereign_id  TEXT PRIMARY KEY,
        palm_name     TEXT NOT NULL DEFAULT '',
        updated_at    INTEGER NOT NULL DEFAULT 0
      );

    `);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 1 — SOV ACADEMY
  // ═══════════════════════════════════════════════════════════════════════════

  handleAcademyPublish(ws, msg) {
    const { article_id, title, body, category } = msg;
    const author_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!article_id || !title || !body) {
      this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    // Check article size limit (governance param in KB)
    const maxKb    = parseInt(this._getGovParam('academy_max_article_size_kb', '50'));
    const bodyKb   = Buffer.byteLength(body, 'utf8') / 1024;
    if (bodyKb > maxKb) {
      this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: false, error: 'ARTICLE_TOO_LARGE', max_kb: maxKb });
      return;
    }

    // Deduct article bond
    const bondSeeds = parseInt(this._getGovParam('academy_article_bond', '5')) * 1_000_000;
    if (bondSeeds > 0 && !this._deductBalance(author_id, bondSeeds)) {
      this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: false, error: 'INSUFFICIENT_BALANCE_FOR_BOND' });
      return;
    }

    const now = Date.now();
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_academy_articles
          (article_id, author_id, title, body, category, created_at, updated_at, upvote_count, bond_held)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
      `).run(article_id, author_id, title, body, category || 'general', now, now, bondSeeds);
    } catch (_) {
      if (bondSeeds > 0) this._creditBalance(author_id, bondSeeds);
      this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: false, error: 'ARTICLE_ID_EXISTS' });
      return;
    }

    const article = this._db._db.prepare('SELECT article_id, author_id, title, category, created_at, upvote_count FROM sov_academy_articles WHERE article_id = ?').get(article_id);
    this._send(ws, 'AD', { type: 'ACADEMY_PUBLISH_RESULT', success: true, article });

    this._peerMesh.broadcast('ACADEMY_ARTICLE_BROADCAST', {
      article: { ...article, body }, node_id: this._identity.nodeId,
    });
  }

  handleAcademyList(ws, msg) {
    const { category, limit, offset } = msg;
    let query = 'SELECT article_id, author_id, title, category, created_at, upvote_count FROM sov_academy_articles';
    const params = [];
    if (category && category !== 'all') {
      query += ' WHERE category = ?';
      params.push(category);
    }
    query += ' ORDER BY created_at DESC LIMIT ? OFFSET ?';
    params.push(Math.min(limit || 50, 200), offset || 0);

    const articles = this._db._db.prepare(query).all(...params);
    this._send(ws, 'AL', { type: 'ACADEMY_LIST_RESULT', articles, ts: Date.now() });
  }

  handleAcademyGet(ws, msg) {
    const { article_id } = msg;
    if (!article_id) return;

    const article = this._db._db.prepare('SELECT * FROM sov_academy_articles WHERE article_id = ?').get(article_id);
    if (!article) {
      this._send(ws, 'AG', { type: 'ACADEMY_GET_RESULT', success: false, error: 'ARTICLE_NOT_FOUND' });
      return;
    }
    this._send(ws, 'AG', { type: 'ACADEMY_GET_RESULT', success: true, article });
  }

  handleAcademyUpvote(ws, msg) {
    const { article_id } = msg;
    const voter_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'AU', { type: 'ACADEMY_UPVOTE_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!article_id) return;

    // Optional upvote bond
    const bondSeeds = parseInt(this._getGovParam('academy_upvote_bond', '1')) * 1_000_000;
    if (bondSeeds > 0 && !this._deductBalance(voter_id, bondSeeds)) {
      this._send(ws, 'AU', { type: 'ACADEMY_UPVOTE_RESULT', success: false, error: 'INSUFFICIENT_BALANCE' });
      return;
    }

    const result = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_academy_upvotes (article_id, voter_id, voted_at) VALUES (?, ?, ?)
    `).run(article_id, voter_id, Date.now());

    if (result.changes === 0) {
      if (bondSeeds > 0) this._creditBalance(voter_id, bondSeeds);
      this._send(ws, 'AU', { type: 'ACADEMY_UPVOTE_RESULT', success: false, error: 'ALREADY_UPVOTED' });
      return;
    }

    this._db._db.prepare('UPDATE sov_academy_articles SET upvote_count = upvote_count + 1 WHERE article_id = ?').run(article_id);
    const row = this._db._db.prepare('SELECT upvote_count FROM sov_academy_articles WHERE article_id = ?').get(article_id);
    this._send(ws, 'AU', { type: 'ACADEMY_UPVOTE_RESULT', success: true, article_id, upvote_count: row ? row.upvote_count : 1 });
  }

  _handleAcademyBroadcast(msg) {
    const { article, node_id } = msg;
    if (node_id === this._identity.nodeId || !article) return;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_academy_articles
          (article_id, author_id, title, body, category, created_at, updated_at, upvote_count, bond_held)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
      `).run(article.article_id, article.author_id, article.title, article.body || '',
             article.category || 'general', article.created_at, article.created_at);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 2 — SOV ENCLAVE (Forum)
  // ═══════════════════════════════════════════════════════════════════════════

  _requireEnclave(ws) {
    if (this._getGovParam('sov_enclave', '1') !== '1') {
      this._send(ws, 'FE', { success: false, error: 'ENCLAVE_NOT_ACTIVATED' });
      return false;
    }
    return true;
  }

  handleEnclavePost(ws, msg) {
    if (!this._requireEnclave(ws)) return;
    const { post_id, title, body } = msg;
    const author_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'FD', { type: 'ENCLAVE_POST_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!post_id || !title || !body) {
      this._send(ws, 'FD', { type: 'ENCLAVE_POST_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const now = Date.now();
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_enclave_posts (post_id, author_id, title, body, created_at, reply_count)
        VALUES (?, ?, ?, ?, ?, 0)
      `).run(post_id, author_id, title, body, now);
    } catch (_) {}

    const post = this._db._db.prepare('SELECT * FROM sov_enclave_posts WHERE post_id = ?').get(post_id);
    this._send(ws, 'FD', { type: 'ENCLAVE_POST_RESULT', success: true, post });

    // Push live to all connected citizens
    this._gateway && this._gateway.pushToAll('FN', { post, ts: now });

    this._peerMesh.broadcast('ENCLAVE_POST_BROADCAST', { post, node_id: this._identity.nodeId });
  }

  handleEnclaveReply(ws, msg) {
    if (!this._requireEnclave(ws)) return;
    const { reply_id, post_id, body } = msg;
    const author_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'FY', { type: 'ENCLAVE_REPLY_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!reply_id || !post_id || !body) {
      this._send(ws, 'FY', { type: 'ENCLAVE_REPLY_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const now = Date.now();
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_enclave_replies (reply_id, post_id, author_id, body, created_at)
        VALUES (?, ?, ?, ?, ?)
      `).run(reply_id, post_id, author_id, body, now);
      this._db._db.prepare('UPDATE sov_enclave_posts SET reply_count = reply_count + 1 WHERE post_id = ?').run(post_id);
    } catch (_) {}

    const reply = this._db._db.prepare('SELECT * FROM sov_enclave_replies WHERE reply_id = ?').get(reply_id);
    this._send(ws, 'FY', { type: 'ENCLAVE_REPLY_RESULT', success: true, reply });

    // Push live to all connected citizens ('FO' = ENCLAVE_NEW_REPLY; 'FR' reserved for FRAG_REQUEST)
    this._gateway && this._gateway.pushToAll('FO', { reply, ts: now });

    this._peerMesh.broadcast('ENCLAVE_REPLY_BROADCAST', { reply, node_id: this._identity.nodeId });
  }

  handleEnclaveList(ws, msg) {
    if (!this._requireEnclave(ws)) return;
    const { limit, offset } = msg;
    const posts = this._db._db.prepare(`
      SELECT * FROM sov_enclave_posts ORDER BY created_at DESC LIMIT ? OFFSET ?
    `).all(Math.min(limit || 50, 200), offset || 0);
    this._send(ws, 'FL', { type: 'ENCLAVE_LIST_RESULT', posts, enclave_active: true, ts: Date.now() });
  }

  handleEnclaveGet(ws, msg) {
    if (!this._requireEnclave(ws)) return;
    const { post_id } = msg;
    if (!post_id) return;

    const post    = this._db._db.prepare('SELECT * FROM sov_enclave_posts WHERE post_id = ?').get(post_id);
    const replies = this._db._db.prepare('SELECT * FROM sov_enclave_replies WHERE post_id = ? ORDER BY created_at ASC').all(post_id);
    this._send(ws, 'FG', { type: 'ENCLAVE_REPLIES_RESULT', post, replies, ts: Date.now() });
  }

  _handleEnclavePostBroadcast(msg) {
    const { post, node_id } = msg;
    if (node_id === this._identity.nodeId || !post) return;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_enclave_posts (post_id, author_id, title, body, created_at, reply_count)
        VALUES (?, ?, ?, ?, ?, ?)
      `).run(post.post_id, post.author_id, post.title, post.body, post.created_at, post.reply_count || 0);
    } catch (_) {}
    // Push to locally connected citizens
    this._gateway && this._gateway.pushToAll('FN', { post, ts: Date.now() });
  }

  _handleEnclaveReplyBroadcast(msg) {
    const { reply, node_id } = msg;
    if (node_id === this._identity.nodeId || !reply) return;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_enclave_replies (reply_id, post_id, author_id, body, created_at)
        VALUES (?, ?, ?, ?, ?)
      `).run(reply.reply_id, reply.post_id, reply.author_id, reply.body, reply.created_at);
      this._db._db.prepare('UPDATE sov_enclave_posts SET reply_count = reply_count + 1 WHERE post_id = ?').run(reply.post_id);
    } catch (_) {}
    this._gateway && this._gateway.pushToAll('FO', { reply, ts: Date.now() });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ═══════════════════════════════════════════════════════════════════════════





  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 4 — SOV LOGIN (Single Sign-On)
  // ═══════════════════════════════════════════════════════════════════════════

  // External website calls this to create a challenge session
  handleLoginChallengeCreate(ws, msg) {
    const { session_id, client_origin } = msg;

    if (this._getGovParam('sov_login', '0') !== '1') {
      this._send(ws, 'LD', { success: false, error: 'SOV_LOGIN_NOT_ACTIVATED' });
      return;
    }

    if (!session_id) {
      this._send(ws, 'LD', { success: false, error: 'MISSING_SESSION_ID' });
      return;
    }

    const challenge = crypto.randomBytes(32).toString('hex');
    const now       = Date.now();
    const expiresAt = now + 10 * 60 * 1000;  // 10-minute challenge window

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_login_sessions
          (session_id, challenge, client_origin, status, created_at, expires_at)
        VALUES (?, ?, ?, 'pending', ?, ?)
      `).run(session_id, challenge, client_origin || '', now, expiresAt);
    } catch (_) {}

    const nodeIp = this._identity.publicAddress || '127.0.0.1';
    this._send(ws, 'LD', {
      success:     true,
      session_id,
      challenge,
      qr_payload:  `sovlogin://${nodeIp}?s=${session_id}&c=${challenge}`,
      expires_at:  expiresAt,
      ts:          now,
    });
  }

  // Citizen app calls this after scanning the QR code
  handleLoginRespond(ws, msg) {
    const { session_id, signature } = msg;
    const sovereign_id = ws._sovereignId;

    if (this._getGovParam('sov_login', '0') !== '1') {
      this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: false, error: 'SOV_LOGIN_NOT_ACTIVATED' });
      return;
    }

    if (!session_id || !signature) {
      this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const session = this._db._db.prepare(`
      SELECT * FROM sov_login_sessions WHERE session_id = ? AND status = 'pending' AND expires_at > ?
    `).get(session_id, Date.now());

    if (!session) {
      this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: false, error: 'SESSION_NOT_FOUND_OR_EXPIRED' });
      return;
    }

    // Verify Ed25519 signature over (session_id + challenge)
    const enrollment = this._db.getEnrollment(sovereign_id);
    if (!enrollment) {
      this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: false, error: 'NOT_ENROLLED' });
      return;
    }

    let sigValid = false;
    try {
      const payload     = Buffer.from(`${session_id}:${session.challenge}`);
      const pubKeyBytes = Buffer.from(enrollment.public_key_hex, 'hex');
      const sigBytes    = Buffer.from(signature, 'hex');
      sigValid = require('../security/node_identity').NodeIdentity.verify(payload, sigBytes, pubKeyBytes);
    } catch (_) { sigValid = false; }

    if (!sigValid) {
      this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: false, error: 'INVALID_SIGNATURE' });
      return;
    }

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_login_sessions SET status = 'verified', sovereign_id = ?, verified_at = ?
      WHERE session_id = ?
    `).run(sovereign_id, now, session_id);

    this._send(ws, 'LR', { type: 'SOV_LOGIN_RESPOND_RESULT', success: true, session_id, ts: now });
  }

  // External website polls this to check if citizen approved
  handleLoginVerify(ws, msg) {
    const { session_id } = msg;
    if (!session_id) return;

    const session = this._db._db.prepare('SELECT * FROM sov_login_sessions WHERE session_id = ?').get(session_id);
    if (!session) {
      this._send(ws, 'LV', { status: 'not_found' });
      return;
    }

    if (session.expires_at < Date.now() && session.status === 'pending') {
      this._db._db.prepare(`UPDATE sov_login_sessions SET status = 'expired' WHERE session_id = ?`).run(session_id);
      this._send(ws, 'LV', { status: 'expired', session_id });
      return;
    }

    this._send(ws, 'LV', {
      status:       session.status,
      session_id,
      sovereign_id: session.sovereign_id || null,
      verified_at:  session.verified_at || null,
    });
  }

  _handleLoginVerifiedForward(msg) {
    // Not currently used — sessions live on single nodes
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 5 — PALM NAMES
  // ═══════════════════════════════════════════════════════════════════════════

  handlePalmNameQuery(ws, msg) {
    const { sovereign_id } = msg;
    const sid = sovereign_id || ws._sovereignId;

    const row = this._db._db.prepare('SELECT palm_name FROM sov_profiles WHERE sovereign_id = ?').get(sid);
    // Also check sov_enrollments which stores palm_name during enrollment
    let palmName = row ? row.palm_name : null;
    if (!palmName) {
      const enroll = this._db._db.prepare('SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?').get(sid);
      palmName = enroll ? enroll.palm_name : '';
    }

    this._send(ws, 'PR', { sovereign_id: sid, palm_name: palmName || '', ts: Date.now() });
  }

  // Called from EnrollmentEngine when a palm_name arrives with HELLO
  storePalmName(sovereignId, palmName) {
    if (!sovereignId || !palmName) return;
    const now = Date.now();
    this._db._db.prepare(`
      INSERT INTO sov_profiles (sovereign_id, palm_name, updated_at) VALUES (?, ?, ?)
      ON CONFLICT (sovereign_id) DO UPDATE SET
        palm_name  = CASE WHEN excluded.palm_name != '' THEN excluded.palm_name ELSE sov_profiles.palm_name END,
        updated_at = excluded.updated_at
      WHERE excluded.updated_at >= sov_profiles.updated_at
    `).run(sovereignId, palmName, now);
  }

  _handlePalmNameBroadcast(msg) {
    const { sovereign_id, palm_name, updated_at, node_id } = msg;
    if (node_id === this._identity.nodeId || !sovereign_id || !palm_name) return;
    this.storePalmName(sovereign_id, palm_name);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MAINTENANCE
  // ═══════════════════════════════════════════════════════════════════════════

  _runMaintenance() {
    const now = Date.now();


    // Expire login sessions
    this._db._db.prepare(`
      UPDATE sov_login_sessions SET status = 'expired'
      WHERE status = 'pending' AND expires_at < ?
    `).run(now);

    // Prune old login sessions
    this._db._db.prepare(`
      DELETE FROM sov_login_sessions WHERE created_at < ?
    `).run(now - 24 * 60 * 60 * 1000);

    // Prune old forum posts (message_retention_days)
    const retentionDays = parseInt(this._getGovParam('message_retention_days', '90'));
    const retentionCutoff = now - retentionDays * 24 * 60 * 60 * 1000;
    this._db._db.prepare('DELETE FROM sov_enclave_replies WHERE created_at < ?').run(retentionCutoff);
    this._db._db.prepare('DELETE FROM sov_enclave_posts WHERE created_at < ? AND reply_count = 0').run(retentionCutoff);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  _deductBalance(citizenId, amountSeeds) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const disc = this._db.readDisc(citizenId);
      if (!disc || disc.spendable_seeds < amountSeeds) return false;
      const result = this._db._db.prepare(`
        UPDATE sov_disc
        SET balance_seeds   = balance_seeds   - ?,
            spendable_seeds = spendable_seeds - ?,
            version   = version + 1,
            updated_at = ?
        WHERE sovereign_id = ? AND version = ? AND spendable_seeds >= ?
      `).run(amountSeeds, amountSeeds, Date.now(), citizenId, disc.version, amountSeeds);
      if (result.changes > 0) {
        // The bond has to land somewhere nameable. Parked in the bonds_held
        // pool it stays inside the 50M invariant and can be given back; left
        // as a bare subtraction it simply left circulation for good.
        try { this._db.addToPoolOrRecord('bonds_held', amountSeeds,
              { source: 'academy_bond', ref: citizenId }); } catch (_) {}
        return true;
      }
    }
    return false;
  }

  _creditBalance(citizenId, amountSeeds) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const disc = this._db.readDisc(citizenId);
      if (!disc) return false;
      const result = this._db._db.prepare(`
        UPDATE sov_disc
        SET balance_seeds   = balance_seeds   + ?,
            spendable_seeds = spendable_seeds + ?,
            version   = version + 1,
            updated_at = ?
        WHERE sovereign_id = ? AND version = ?
      `).run(amountSeeds, amountSeeds, Date.now(), citizenId, disc.version);
      if (result.changes > 0) {
        // Take it back out of the pool it was parked in. Drawn first and only
        // the drawn amount is credited: crediting more than the pool holds
        // would invent supply, which is worse than the bug this fixes.
        try { this._db.drawFromPool('bonds_held', amountSeeds); } catch (_) {}
        return true;
      }
    }
    return false;
  }

  _getGovParam(key, fallback = '0') {
    const row = this._db._db.prepare(
      'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
    ).get(key);
    return row ? row.param_value.toString() : fallback.toString();
  }

  // ── Op-to-type mapping for outbound messages ─────────────────────────────
  // Flutter's sendAndWait() matches on msg['type'], not op.
  // social_engine responses use short result op codes that differ from the
  // inbound request op code — they must be mapped to the full type string
  // that Flutter expects as responseType.
  static get _RESULT_TYPE() {
    return {
      // Academy results
      'AD': 'ACADEMY_PUBLISH_RESULT',
      'AL': 'ACADEMY_LIST_RESULT',
      'AG': 'ACADEMY_GET_RESULT',
      'AU': 'ACADEMY_UPVOTE_RESULT',
      // SOV Enclave results
      'FD': 'ENCLAVE_POST_RESULT',      // NB: 'FD' would be FRAG_DELIVER without this map
      'FY': 'ENCLAVE_REPLY_RESULT',
      'FL': 'ENCLAVE_LIST_RESULT',
      'FG': 'ENCLAVE_REPLIES_RESULT',  // app sends ENCLAVE_GET, expects this
      'FE': 'ENCLAVE_ERROR',
      // Live push op codes (pushToAll)
      'FN': 'ENCLAVE_NEW_POST',
      'FO': 'ENCLAVE_NEW_REPLY',        // Changed from 'FR' (conflicted with FRAG_REQUEST)
      // SOV Login results
      'LD': 'SOV_LOGIN_CHALLENGE_RESULT',
      'LR': 'SOV_LOGIN_RESPOND_RESULT',
      'LV': 'SOV_LOGIN_VERIFY_RESULT',
      // Palm name result ('PR' = result op; PN was the query op -- corrected)
      'PR': 'PALM_NAME_RESULT',
    };
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    const type = (payload && payload.type) || SocialEngine._RESULT_TYPE[op] || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }
}

module.exports = { SocialEngine };
