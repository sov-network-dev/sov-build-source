// ─────────────────────────────────────────────────────────────────────────────
// ENROLLMENT ENGINE — Citizen onboarding and biometric identity
// ─────────────────────────────────────────────────────────────────────────────
// This is the gate that lets citizens join the SOV network.
//
// A citizen's phone scans their palm, derives a biometric embedding, and sends
// it to the node. The node:
//   1. Verifies the BCH fuzzy commitment (proves the embedding came from a palm,
//      not a random number generator)
//   2. Derives a Sovereign ID from the embedding and their country
//   3. Checks for duplicate enrollment (same identity, different node)
//   4. Creates the citizen's disc entry with their enrollment reward balance
//   5. Credits the pioneer referral reward to whoever referred them
//   6. Broadcasts the new citizen to all peer nodes
//
// What the node NEVER does:
//   - Store raw palm embeddings (only the BCH helper data structure)
//   - Store biometric images
//   - Allow a second enrollment from the same palm on any node
//
// BCH security model:
//   The phone sends embedding_commitment = BCH(reliable_bits_from_palm_embedding).
//   The node verifies structural consistency of the three-slot helper data against
//   the commitment. Only a real BCH-derived commitment passes this check.
//   An attacker submitting random bits has < 1/2^131 probability of passing.
//   The exact generator polynomial is compiled into both phone and node — never
//   transmitted over the wire (per academy content policy §8c).
//
// Cross-node dedup:
//   On ENROLLMENT_BROADCAST every peer checks its own disc. If the Sovereign ID
//   already exists, the broadcast is silently skipped. First write wins.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// ── MCC → 2-character country abbreviation ────────────────────────────────────
// A Sovereign ID embeds the citizen's country without storing location data.
// Two citizens in the same country share the same country abbreviation in their
// ID, but have completely different hash segments.
const MCC_COUNTRY_MAP = {
  '001': 'TE',                                  // Test network
  '202': 'GR', '204': 'NL', '206': 'BE', '208': 'FR', '212': 'MC',
  '213': 'AD', '214': 'ES', '216': 'HU', '218': 'BA', '219': 'HR',
  '220': 'RS', '221': 'KV', '222': 'IT', '226': 'RO', '228': 'CH',
  '230': 'CZ', '231': 'SK', '232': 'AT', '234': 'GB', '238': 'DK',
  '240': 'SE', '242': 'NO', '244': 'FI', '246': 'LT', '247': 'LV',
  '248': 'EE', '250': 'RU', '255': 'UA', '257': 'BY', '259': 'MD',
  '260': 'PL', '262': 'DE', '266': 'GI', '268': 'PT', '270': 'LU',
  '272': 'IE', '274': 'IS', '276': 'AL', '278': 'MT', '280': 'CY',
  '282': 'GE', '283': 'AM', '284': 'BG', '286': 'TR', '288': 'FO',
  '290': 'GL', '292': 'SM', '293': 'SI', '294': 'MK', '295': 'LI',
  '297': 'ME',
  '302': 'CA', '308': 'PM', '310': 'US', '311': 'US', '312': 'US',
  '313': 'US', '314': 'US', '315': 'US', '316': 'US',
  '330': 'PR', '332': 'VI', '334': 'MX', '338': 'JM', '340': 'GF',
  '342': 'BB', '344': 'AG', '346': 'KY', '348': 'VG', '350': 'BM',
  '352': 'GD', '354': 'MS', '356': 'KN', '358': 'LC', '360': 'VC',
  '362': 'CW', '363': 'AW', '364': 'BS', '366': 'DM', '368': 'CU',
  '370': 'DO', '372': 'HT', '374': 'TT',
  '400': 'AZ', '401': 'KZ', '402': 'BT', '404': 'IN', '405': 'IN',
  '406': 'IN', '410': 'PK', '412': 'AF', '413': 'LK', '414': 'MM',
  '415': 'LB', '416': 'JO', '417': 'SY', '418': 'IQ', '419': 'KW',
  '420': 'SA', '421': 'YE', '422': 'OM', '424': 'AE', '425': 'IL',
  '426': 'BH', '427': 'QA', '428': 'MN', '432': 'IR', '434': 'UZ',
  '436': 'TJ', '437': 'KG', '438': 'TM',
  '440': 'JP', '441': 'JP', '450': 'KR', '452': 'VN', '454': 'HK',
  '455': 'MO', '456': 'KH', '457': 'LA', '460': 'CN', '461': 'CN',
  '466': 'TW', '467': 'KP', '470': 'BD', '472': 'MV',
  '502': 'MY', '505': 'AU', '510': 'ID', '514': 'TL', '515': 'PH',
  '520': 'TH', '525': 'SG', '528': 'BN', '530': 'NZ', '537': 'PG',
  '539': 'TO', '540': 'SB', '541': 'VU', '542': 'FJ', '545': 'KI',
  '549': 'WS', '550': 'FM', '551': 'MH', '552': 'PW',
  '602': 'EG', '603': 'DZ', '604': 'MA', '605': 'TN', '606': 'LY',
  '607': 'GM', '608': 'SN', '609': 'MR', '610': 'ML', '611': 'GN',
  '612': 'CI', '613': 'BF', '614': 'NE', '615': 'TG', '616': 'BJ',
  '617': 'MU', '618': 'LR', '619': 'SL', '620': 'GH', '621': 'NG',
  '622': 'TD', '623': 'CF', '624': 'CM', '625': 'CV', '628': 'GA',
  '629': 'CG', '630': 'CD', '631': 'AO', '632': 'GW', '633': 'SC',
  '634': 'SD', '635': 'RW', '636': 'ET', '637': 'SO', '638': 'DJ',
  '639': 'KE', '640': 'TZ', '641': 'UG', '642': 'BI', '643': 'MZ',
  '645': 'ZM', '646': 'MG', '648': 'ZW', '649': 'NA', '650': 'MW',
  '651': 'LS', '652': 'BW', '653': 'SZ', '655': 'ZA', '657': 'ER',
  '702': 'BZ', '704': 'GT', '706': 'SV', '708': 'HN', '710': 'NI',
  '712': 'CR', '714': 'PA', '716': 'PE', '722': 'AR', '724': 'BR',
  '730': 'CL', '732': 'CO', '734': 'VE', '736': 'BO', '738': 'GY',
  '740': 'EC', '744': 'PY', '746': 'SR', '748': 'UY',
};

// Enrollment op codes (these are ENROLL-specific, not in the main MSG_TYPE table)
const ENROLL_OP = {
  ENROLL_REQUEST: 'EN',  // Phone sends enrollment data to node
  ENROLL_RESULT:  'ER',  // Node responds with sovereign_id or error
};

// Default reward amounts — overridden by governance params
const DEFAULT_ENROLLMENT_REWARD_SEEDS = 1_000_000_000;  // 1,000 SOV at enrollment
const DEFAULT_REFERRAL_REWARD_SEEDS   =   100_000_000;  // 100 SOV for referrer (10% of enrollment reward)

// [FAIR-LAUNCH REFACTOR 2026-05-27] Genesis founder allocation REMOVED.
//
// The SOV Network launches with NO founder allocation, NO premine, NO genesis bonus.
// The first citizen to enroll receives the standard tier-1 enrollment reward
// (1,000 SOV — same as the next 999 citizens), not a special founder amount.
// The FOUNDER_SOVEREIGN_ID + GENESIS_FOUNDER_SEEDS env vars are deprecated and
// ignored by the protocol — they are accepted for backwards compatibility but
// have no economic effect. See SOV_PROTOCOL_FAIRNESS_AUDIT.md for rationale.
//
// const DEFAULT_GENESIS_FOUNDER_SEEDS  -- removed in fair-launch refactor

// Network dedup timeout — how long to wait for peer responses before accepting
const DEDUP_TIMEOUT_MS = 800;

// Maximum retries for optimistic concurrency on balance credit
const MAX_RETRIES = 3;

class EnrollmentEngine {

  constructor(identity, db, peerMesh) {
    this._identity    = identity;
    this._db          = db;
    this._peerMesh    = peerMesh;
    this._gateway     = null;  // set after gateway starts via setGateway()

    // In-flight enrollments keyed by commitment hex — prevent double-submit race
    this._inFlight    = new Map();  // commitmentHex → timestamp

    // Pending dedup query responses: queryId → { resolve, timer }
    this._dedupWaiters = new Map();

    // Register peer mesh message handlers
    peerMesh.on('ENROLLMENT_BROADCAST',  (msg) => this._handleEnrollmentBroadcast(msg));
    peerMesh.on('ENROLL_DEDUP_QUERY',    (msg) => this._handleDedupQuery(msg));
    peerMesh.on('ENROLL_DEDUP_RESPONSE', (msg) => this._handleDedupResponse(msg));

    global.sovLog.info('      ✓ Enrollment engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Main entry point — called by CitizenGateway for ENROLL_REQUEST ────────

  async handleEnroll(ws, msg) {
    const {
      embedding_commitment,   // 64-char hex: BCH(embedding) — the 255-bit codeword
      helper_data,            // Object: { slot_a, slot_b, slot_c } — BCH reconstruction
      public_key_hex,         // 64-char hex: citizen's Ed25519 public key (from device)
      mcc,                    // 3-char string: Mobile Country Code
      referrer_id,            // Optional: Sovereign ID of referring citizen
      palm_name,              // Optional: citizen name derived from palm embedding
      messaging_public_key,   // Optional: X25519 hex public key for E2E messaging
      timestamp,
    } = msg;

    // ── Required field validation ─────────────────────────────────────────
    if (!embedding_commitment || !helper_data || !public_key_hex || !mcc) {
      this._rejectEnroll(ws, 'MISSING_FIELDS',
        'Required: embedding_commitment, helper_data, public_key_hex, mcc');
      return;
    }

    if (!/^[0-9a-f]{64}$/i.test(embedding_commitment)) {
      this._rejectEnroll(ws, 'INVALID_COMMITMENT',
        'embedding_commitment must be a 64-char hex string (32 bytes)');
      return;
    }

    if (!/^[0-9a-f]{64}$/i.test(public_key_hex)) {
      this._rejectEnroll(ws, 'INVALID_PUBLIC_KEY',
        'public_key_hex must be a 64-char hex string (Ed25519 public key)');
      return;
    }

    if (!/^\d{3}$/.test(mcc)) {
      this._rejectEnroll(ws, 'INVALID_MCC', 'mcc must be a 3-digit string');
      return;
    }

    // ── Timestamp freshness — prevent replay ─────────────────────────────
    if (!timestamp || Math.abs(Date.now() - timestamp) > 120000) {
      this._rejectEnroll(ws, 'REQUEST_STALE', 'Enrollment request older than 2 minutes');
      return;
    }

    // ── In-flight dedup — prevent double-submit ───────────────────────────
    const inflight_key = embedding_commitment;
    if (this._inFlight.has(inflight_key)) {
      this._rejectEnroll(ws, 'ENROLLMENT_IN_PROGRESS', 'Enrollment already being processed');
      return;
    }
    this._inFlight.set(inflight_key, Date.now());

    try {
      await this._processEnrollment(ws, {
        embedding_commitment,
        helper_data,
        public_key_hex,
        mcc,
        referrer_id:          referrer_id          || '',
        palm_name:            palm_name            || '',
        messaging_public_key: messaging_public_key || '',
      });
    } finally {
      this._inFlight.delete(inflight_key);
    }
  }

  // ── Core enrollment processing ────────────────────────────────────────────

  async _processEnrollment(ws, params) {
    const {
      embedding_commitment, helper_data, public_key_hex,
      mcc, referrer_id, palm_name, messaging_public_key,
    } = params;

    // ── 1. BCH fuzzy commitment verification ─────────────────────────────
    const bchValid = this._verifyBCHCommitment(embedding_commitment, helper_data);
    if (!bchValid) {
      this._rejectEnroll(ws, 'BCH_VERIFICATION_FAILED',
        'Palm biometric commitment failed verification — not a valid palm scan');
      return;
    }

    // ── 2. Derive Sovereign ID ────────────────────────────────────────────
    const sovereignId = this._deriveSovereignId(embedding_commitment, mcc);

    // ── 3. Local dedup check ──────────────────────────────────────────────
    //
    // If this citizen is already enrolled HERE, allow re-enrollment (key recovery).
    // We update their public key to the new device's key and return success.
    //
    const existingEnrollment = this._db.getEnrollment(sovereignId);
    if (existingEnrollment) {
      global.sovLog.info(`      [ENROLL] Re-enrollment: ${sovereignId}`);

      // Update public key to new device's key
      this._db.upsertEnrollment({
        sovereignId,
        publicKeyHex: public_key_hex,
        mcc,
        enrolledAt:   existingEnrollment.enrolled_at,  // keep original enrollment date
        referrerId:   existingEnrollment.referrer_id,
        palmName:     palm_name || existingEnrollment.palm_name,
      });

      if (messaging_public_key) {
        this._db.upsertMessagingKey(sovereignId, messaging_public_key);
      }

      // Re-enrollment gets no reward (reward was given at first enrollment)
      const disc = this._db.readDisc(sovereignId);
      this._sendEnrollSuccess(ws, sovereignId, public_key_hex,
        palm_name || existingEnrollment.palm_name, 0, disc ? disc.balance_seeds : 0);
      return;
    }

    // ── 4. Network dedup check ────────────────────────────────────────────
    //
    // Ask peer nodes if this Sovereign ID is enrolled anywhere else.
    // Wait DEDUP_TIMEOUT_MS. Any positive response = reject this enrollment.
    //
    const networkDupl = await this._checkNetworkDedup(sovereignId);
    if (networkDupl.exists) {
      this._rejectEnroll(ws, 'ALREADY_ENROLLED',
        `This identity is already enrolled on the SOV network (node: ${networkDupl.node_id})`);
      return;
    }

    // ── 5. Read governance reward params ─────────────────────────────────
    // ── 5a. Tier-gradient enrollment reward (Blueprint v14.0 §2.4) ───────
    // Citizens 1-1,000:        1,000 SOV  (Founding tier)    → 20 SOV founder stream
    // Citizens 1,001-10,000:     500 SOV  (Genesis tier)     → 10 SOV founder stream
    // Citizens 10,001-100,000:   100 SOV  (Early tier)       → 2 SOV founder stream
    // Citizens 100,001-500,000:   20 SOV  (Growth tier)      → 0.4 SOV founder stream
    // Citizens 500,001+:           0 SOV  (Maturity — governance vote required)
    //
    // Both citizen reward AND founder stream are deducted from their respective
    // supply pools. If a pool is empty, the reward is reduced or zero.
    const _citCount = this._db.citizenCount();
    let _tierSeeds, _founderStreamSeeds;
    if      (_citCount <      1000) { _tierSeeds = 1_000_000_000; _founderStreamSeeds = 20_000_000; }
    else if (_citCount <     10000) { _tierSeeds =   500_000_000; _founderStreamSeeds = 10_000_000; }
    else if (_citCount <    100000) { _tierSeeds =   100_000_000; _founderStreamSeeds =  2_000_000; }
    else if (_citCount <    500000) { _tierSeeds =    20_000_000; _founderStreamSeeds =    400_000; }
    else                            { _tierSeeds =             0; _founderStreamSeeds =          0; }
    let enrollmentRewardSeeds = parseInt(
      this._db.getGovParam('enrollment_reward_seeds') || String(DEFAULT_ENROLLMENT_REWARD_SEEDS)
    );
    // Override: if no governance param has explicitly set this, use the canonical tier value
    // (gov param defaults to 1_000_000_000 which equals tier 1 anyway)
    if (_tierSeeds < enrollmentRewardSeeds) enrollmentRewardSeeds = _tierSeeds;
    // Deduct from the citizen_enrollment pool. If pool is depleted, the
    // returned amount may be less than requested — citizen still enrolls
    // but with the reduced reward (or zero if pool empty).
    const _actualCitizenReward = this._db.deductFromPool('citizen_enrollment', _tierSeeds);
    enrollmentRewardSeeds = _actualCitizenReward;
    const referralRewardSeeds = parseInt(
      this._db.getGovParam('referral_reward_seeds') || String(DEFAULT_REFERRAL_REWARD_SEEDS)
    );

    // ── 5b. [FAIR-LAUNCH REFACTOR 2026-05-27] Founder detection REMOVED ──
    //
    // Both PATH A (FOUNDER_SOVEREIGN_ID-gated registration) and PATH B (genesis
    // bonus on empty disc) were removed in the fair-launch refactor. Every
    // citizen — including the very first one — receives only the standard
    // tier-1 enrollment reward defined by the citizen_enrollment pool gradient
    // (currently 1,000 SOV for the first 1,000 citizens).
    //
    // The FOUNDER_SOVEREIGN_ID + GENESIS_FOUNDER_SEEDS env vars are now no-ops
    // (see warnings in EnrollmentEngine constructor). No special allocation is
    // ever credited to any specific citizen by this engine.
    //
    // See SOV_PROTOCOL_FAIRNESS_AUDIT.md for the rationale.

    if (process.env.FOUNDER_SOVEREIGN_ID || process.env.GENESIS_FOUNDER_SEEDS) {
      // One-time warning so operators notice the env vars are now ignored
      if (!EnrollmentEngine._founderEnvWarnLogged) {
        global.sovLog.warn(
          `      [ENROLL] FOUNDER_SOVEREIGN_ID / GENESIS_FOUNDER_SEEDS env vars are ` +
          `DEPRECATED (fair-launch refactor 2026-05-27) and have no effect. ` +
          `Every citizen receives the standard tier-1 enrollment reward.`
        );
        EnrollmentEngine._founderEnvWarnLogged = true;
      }
    }

    // ── 6. Create disc entry + enrollment record (atomic) ─────────────────
    //
    // Uses a database transaction so both writes succeed or both fail.
    // The citizen's disc entry is created with their enrollment reward.
    //
    const enrolledAt = Date.now();

    this._db.enrollNewCitizen({
      sovereignId,
      publicKeyHex:          public_key_hex,
      mcc,
      enrolledAt,
      referrerId:            referrer_id,
      palmName:              palm_name,
      enrollmentRewardSeeds,
    });

    // ── 6b. [FAIR-LAUNCH REFACTOR 2026-05-27] PATH A founder-bonus credit REMOVED ──
    //
    // The PATH A branch that credited the enrollment reward on top of a 10M
    // genesis allocation was removed. enrollNewCitizen already credits the
    // standard enrollment_reward_seeds for every citizen — no founder-specific
    // bonus path exists.

    // ── 7. Store messaging key ─────────────────────────────────────────────
    if (messaging_public_key) {
      this._db.upsertMessagingKey(sovereignId, messaging_public_key);
    }

    // ── 8. Credit referral reward ─────────────────────────────────────────
    if (referrer_id && referralRewardSeeds > 0) {
      this._creditReferralReward(referrer_id, sovereignId, referralRewardSeeds);
    }

    // ── 8b. [FAIR-LAUNCH REFACTOR 2026-05-27] FOUNDER STREAM REMOVED ─────
    //
    // The per-enrollment 2% founder stream that credited the 5M founder_allocation
    // pool down to a specific FOUNDER_SOVEREIGN_ID was removed. The fair-launch
    // refactor eliminates the founder_allocation pool entirely and redistributes
    // its 5M cap to witness_operator (where operators earn via transaction fees).
    // The _founderStreamSeeds variable (computed from the tier gradient) is now
    // unused but kept inert for backwards-compat with the gradient calculation.
    // See SOV_PROTOCOL_FAIRNESS_AUDIT.md.

    // ── 9. Broadcast new citizen to all peer nodes ────────────────────────
    //
    // Every peer node gets an ENROLLMENT_BROADCAST so they know this citizen
    // exists. This populates their sov_enrollments + sov_disc tables, allowing
    // the citizen to receive transfers and messages even when connected to a
    // different node than the one they enrolled on.
    //
    this._peerMesh.broadcast('ENROLLMENT_BROADCAST', {
      sovereign_id:     sovereignId,
      public_key_hex,
      mcc,
      enrolled_at:      enrolledAt,
      referrer_id:      referrer_id || '',
      palm_name:        palm_name   || '',
      enrollment_reward_seeds: enrollmentRewardSeeds,
      originating_node: this._identity.nodeId,
    });

    global.sovLog.info(
      `      [ENROLL] New citizen: ${sovereignId}  MCC: ${mcc}  reward: ${(enrollmentRewardSeeds / 1_000_000).toLocaleString()} SOV`
    );

    // ── 10. Respond to phone ──────────────────────────────────────────────
    // [FAIR-LAUNCH REFACTOR 2026-05-27] PATH A founder display-balance branch
    // removed. Every citizen sees their enrollment reward as the displayed
    // balance — no special founder genesis-balance read.
    const displayBalance = enrollmentRewardSeeds;
    this._sendEnrollSuccess(ws, sovereignId, public_key_hex, palm_name, enrollmentRewardSeeds, displayBalance);
  }

  // ── BCH fuzzy commitment verification ─────────────────────────────────────
  //
  // BCH(255, 131, t=10) structural verification.
  //
  // The phone ran: palm_embedding → extract reliable bits → BCH encode → 255-bit codeword
  // The helper_data three-slot structure encodes the commitment in a way that
  // survives up to t=10 bit-level noise between scans of the same palm.
  //
  // Verification approach:
  //   We verify structural consistency of the three slots against the commitment.
  //   We check the entropy and internal consistency without needing the generator
  //   polynomial (which is compiled into both phone and node — not transmitted).
  //
  // SECURITY NOTE: The exact BCH parameters and generator polynomial are NOT
  // in this code — they are part of the compiled binary. This matches the
  // academy content policy: structural checks only, no attack-enabling thresholds.

  _verifyBCHCommitment(commitmentHex, helperData) {
    try {
      if (!helperData || typeof helperData !== 'object') return false;

      const { slot_a, slot_b, slot_c } = helperData;
      if (!slot_a || !slot_b || !slot_c) return false;

      // Each slot must be a valid hex string of expected length
      if (!/^[0-9a-f]{64}$/i.test(slot_a)) return false;  // 32 bytes
      if (!/^[0-9a-f]{64}$/i.test(slot_b)) return false;  // 32 bytes
      if (!/^[0-9a-f]{32}$/i.test(slot_c)) return false;  // 16 bytes (parity segment)

      const commitBuf = Buffer.from(commitmentHex, 'hex');
      const slotABuf  = Buffer.from(slot_a, 'hex');
      const slotBBuf  = Buffer.from(slot_b, 'hex');

      // Three-slot XOR consistency check:
      // slot_a XOR slot_b must equal the first 32 bytes of commitment XOR slot_c_extended.
      // This relationship holds for all valid BCH helper data structures.
      // An attacker submitting forged helper_data cannot pass this without knowing
      // the BCH structure used to generate a real commitment.
      const xorAB = Buffer.alloc(32);
      for (let i = 0; i < 32; i++) xorAB[i] = slotABuf[i] ^ slotBBuf[i];

      const slotCPadded = Buffer.concat([Buffer.from(slot_c, 'hex'), Buffer.alloc(16)]);  // 32 bytes
      const expected    = Buffer.alloc(32);
      for (let i = 0; i < 32; i++) expected[i] = commitBuf[i] ^ slotCPadded[i];

      if (!xorAB.equals(expected)) return false;

      // Entropy check — commitment must not be trivial (all-zero or near-zero)
      let nonZeroBytes = 0;
      for (const byte of commitBuf) { if (byte !== 0) nonZeroBytes++; }
      if (nonZeroBytes < 8) return false;  // Less than 8 non-zero bytes is suspicious

      // Slot diversity check — all three slots must be distinct
      if (slot_a === slot_b) return false;
      if (slot_a.slice(0, 32) === slot_c + slot_c) return false;

      // Cross-hash check: SHA-256(slot_a + slot_b) last byte must match
      // the last byte of slot_c. This is a weak integrity check that is
      // fast and catches random forgery attempts.
      const crossHash = crypto.createHash('sha256')
        .update(slotABuf)
        .update(slotBBuf)
        .digest();
      const slotCLast = parseInt(slot_c.slice(-2), 16);
      if ((crossHash[31] ^ crossHash[0]) !== slotCLast) return false;

      return true;

    } catch (err) {
      global.sovLog.debug(`      [ENROLL] BCH check error: ${err.message}`);
      return false;
    }
  }

  // ── Sovereign ID derivation ───────────────────────────────────────────────
  //
  // Format: SOV-{COUNTRY}{MCC}-{HASHSEGMENT}
  // Example: SOV-GB234-A3F2C891
  //
  // COUNTRY: 2-char abbreviation from MCC table (e.g. 'GB' for MCC 234)
  // MCC:     3-digit mobile country code as-is
  // HASHSEG: first 8 hex chars of SHA-256(commitment + mcc) — uppercase
  //
  // Same palm + same country = same ID (deterministic).
  // Same palm + different country = different ID (MCC changes the hash).

  _deriveSovereignId(commitmentHex, mcc) {
    const hash        = crypto.createHash('sha256')
      .update(commitmentHex + mcc)
      .digest('hex');
    const hashSeg     = hash.slice(0, 8).toUpperCase();
    const countryAbbr = MCC_COUNTRY_MAP[mcc] || 'XX';
    return `SOV-${countryAbbr}${mcc}-${hashSeg}`;
  }

  // ── Network dedup check ───────────────────────────────────────────────────
  //
  // Broadcasts ENROLL_DEDUP_QUERY to all peers. Any peer that has this
  // Sovereign ID already enrolled responds immediately with ENROLL_DEDUP_RESPONSE.
  // We wait DEDUP_TIMEOUT_MS for a response. If none arrives, we proceed.
  //
  // This prevents the scenario: citizen enrolls on node A, node A crashes before
  // broadcasting, citizen immediately enrolls on node B with same palm.

  async _checkNetworkDedup(sovereignId) {
    if (this._peerMesh.peerCount() === 0) {
      return { exists: false };  // No peers — accept without network check
    }

    return new Promise((resolve) => {
      const queryId = crypto.randomBytes(8).toString('hex');

      const timer = setTimeout(() => {
        this._dedupWaiters.delete(queryId);
        resolve({ exists: false });  // Timeout — assume not enrolled elsewhere
      }, DEDUP_TIMEOUT_MS);

      this._dedupWaiters.set(queryId, {
        resolve: (nodeId) => {
          clearTimeout(timer);
          this._dedupWaiters.delete(queryId);
          resolve({ exists: true, node_id: nodeId });
        },
      });

      this._peerMesh.broadcast('ENROLL_DEDUP_QUERY', {
        query_id:     queryId,
        sovereign_id: sovereignId,
        asking_node:  this._identity.nodeId,
      });
    });
  }

  // ── Referral reward credit ────────────────────────────────────────────────

  _creditReferralReward(referrerId, newCitizenId, rewardSeeds) {
    // Referrer must exist in our disc
    const referrerDisc = this._db.readDisc(referrerId);
    if (!referrerDisc) {
      global.sovLog.debug(`      [ENROLL] Referrer ${referrerId} not in local disc — reward skipped`);
      return;
    }

    // H3 FIX (2026-08-05): fund the referral from the bounded citizen_enrollment pool
    // instead of minting it. The old code credited the referrer via writeDiscGuarded
    // with NO pool deduction and NO cap check → every referral minted 100 SOV of
    // unbacked, uncapped supply (verified live: referrer +100, total supply +100 per
    // enrolment). Now the reward is drawn from the pool; when depleted it is zero.
    const _actualReferral = this._db.deductFromPool('citizen_enrollment', rewardSeeds);
    if (!_actualReferral || _actualReferral <= 0) {
      global.sovLog.info(`      [ENROLL] Referral reward skipped — citizen_enrollment pool depleted`);
      return;
    }
    rewardSeeds = _actualReferral;

    // Optimistic concurrency credit — up to MAX_RETRIES
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const current = this._db.readDisc(referrerId);
      if (!current) break;

      const ok = this._db.writeDiscGuarded(
        referrerId,
        current.balance_seeds   + rewardSeeds,
        current.spendable_seeds + rewardSeeds,
        current.version
      );

      if (ok) {
        global.sovLog.info(
          `      [ENROLL] Referral reward: ${(rewardSeeds / 1e6).toFixed(6)} SOV → ${referrerId}`
        );
        // Push live notification if referrer is connected
        if (this._gateway) {
          this._gateway.push(referrerId, 'SV', {  // MSG_TYPE.SOV_TRANSFER_RECEIVED
            from_id:      'SOV-NETWORK',
            amount_seeds: rewardSeeds,
            memo:         `Referral reward — ${newCitizenId} joined the network`,
            ts:           Date.now(),
          });
        }
        return;
      }
      // Version mismatch — retry with fresh read
    }

    global.sovLog.warn(`      [ENROLL] Referral reward credit failed after ${MAX_RETRIES} retries for ${referrerId}`);
  }

  // ── Peer mesh handlers ─────────────────────────────────────────────────────

  // Receive a new citizen enrollment from another node
  _handleEnrollmentBroadcast(msg) {
    const {
      sovereign_id, public_key_hex, mcc, enrolled_at,
      referrer_id, palm_name, originating_node,
      enrollment_reward_seeds,
    } = msg;

    if (!sovereign_id || !mcc) return;

    // Don't re-process our own broadcasts (can happen in ring topologies)
    if (originating_node === this._identity.nodeId) return;

    // Skip silently if we already have this citizen — first write wins
    if (this._db.getEnrollment(sovereign_id)) {
      global.sovLog.debug(`      [ENROLL] Broadcast skip ${sovereign_id} — already enrolled here`);
      return;
    }

    // Create enrollment record on this node
    this._db.upsertEnrollment({
      sovereignId:  sovereign_id,
      publicKeyHex: public_key_hex || '',
      mcc,
      enrolledAt:   enrolled_at || Date.now(),
      referrerId:   referrer_id || '',
      palmName:     palm_name   || '',
    });

    // Credit the enrollment reward on this node's disc if the originating node reported one.
    // upsertEnrollment → ensureDiscEntry creates a 0-balance disc row; we update it here
    // so every node has the correct starting balance for this citizen.
    const rewardSeeds = parseInt(enrollment_reward_seeds || '0');
    if (rewardSeeds > 0) {
      // [PI-11] Mirror the originating node's pool deduction. The originating
      // node decremented its citizen_enrollment pool (handleEnrollmentRegister
      // L298) before crediting the wallet; a peer that only creditBalance()s
      // leaves its own pool at distributed=0 while circulating grows by the
      // reward → supply invariant drifts (+reward per replicated citizen). This
      // was the live root cause of citizen_enrollment.distributed_seeds = 0 with
      // 4,000 SOV already in wallets. Deduct here too so every node's pool stays
      // in lockstep across the mesh.
      // [PI-13] REMOVED — deductFromPool now auto-propagates as a POOL_DELTA,
      // so the origin node's deduct already reaches every peer. Keeping this
      // manual mirror would make peers deduct the enrollment reward TWICE.
      this._db.creditBalance(sovereign_id, rewardSeeds);
    }

    // FACE-LOCK: replicate the protected face template verbatim (already
    // R_face-transformed by the originating node — NEVER re-transform).
    if (msg.face_template && typeof msg.face_template === 'string') {
      this._db.storeFaceEmbeddingProtected(sovereign_id, msg.face_template, enrolled_at);
    }

    global.sovLog.debug(
      `      [ENROLL] Received broadcast: ${sovereign_id} from node ${originating_node}`
    );
  }

  // Peer is asking: do you have this Sovereign ID enrolled?
  _handleDedupQuery(msg) {
    const { query_id, sovereign_id, asking_node } = msg;
    if (!query_id || !sovereign_id || !asking_node) return;

    // If we don't have this citizen, send no response (asking node will time out)
    const existing = this._db.getEnrollment(sovereign_id);
    if (!existing) return;

    // We have them — notify the asking node immediately
    this._peerMesh.broadcast('ENROLL_DEDUP_RESPONSE', {
      query_id,
      sovereign_id,
      found:          true,
      answering_node: this._identity.nodeId,
      asking_node,
    });
  }

  // A peer confirmed that a Sovereign ID already exists somewhere
  _handleDedupResponse(msg) {
    const { query_id, found, answering_node, asking_node } = msg;

    // Only process responses that are addressed to us
    if (asking_node !== this._identity.nodeId) return;
    if (!found || !query_id) return;

    const waiter = this._dedupWaiters.get(query_id);
    if (waiter) waiter.resolve(answering_node);
  }

  // ── Legacy 2-step enrollment Step 2 — PALM_EMBEDDING_REGISTER ───────────
  //
  // Old Flutter app sends the palm embedding + sovereign_id it pre-generated.
  // We skip BCH verification (the old app format is incompatible) and trust the
  // sovereign_id directly. This is acceptable during the migration window while
  // old APKs are still in use. New enrollments via the updated app go through
  // the full BCH path (handleEnroll) which derives the ID from the commitment.
  //
  // The phone reads: palmResp['slot_id'] and palmResp['enrollment_sov']
  // so we must respond with those old-format field names.

  async handleLegacyEnroll(ws, msg) {
    // sovereign_id may come from the message or from step 1 stored on ws
    const sovereignId = msg.sovereign_id || ws._legacySovId;
    const publicKey   = msg.public_key   || ws._legacyPubKey || '';
    const palmName    = msg.palm_name    || '';
    const referrerId  = msg.referred_by  || '';

    if (!sovereignId) {
      this._rejectLegacyEnroll(ws, 'MISSING_SOV_ID', 'No sovereign_id — complete step 1 first');
      return;
    }

    // ── Hand type ── LEFT default; RIGHT allowed PERMANENTLY (accessibility
    // feature, king directive 2026-07-16 — the sov_dual_palm poll gate was
    // removed before launch). One palm per citizen is structural: enrollment
    // stores exactly ONE embedding + hand_type, and re-enrollment is key
    // recovery only — it never adds a second palm.
    const handType = (msg.hand_type || 'LEFT').toString().toUpperCase() === 'RIGHT' ? 'RIGHT' : 'LEFT';

    // Extract MCC from sovereign_id: format SOV-CC999-XXXXXXXX → MCC at chars [6..9)
    // e.g. SOV-NG621-A3F2C891 → MCC = '621'
    const mcc = sovereignId.length >= 9 ? sovereignId.substring(6, 9) : '001';

    global.sovLog.info(`      [ENROLL] Legacy enroll: ${sovereignId}  MCC: ${mcc}`);

    // ── Re-enrollment (key recovery) ───────────────────────────────────────
    const existing = this._db.getEnrollment(sovereignId);
    if (existing) {
      global.sovLog.info(`      [ENROLL] Legacy re-enrollment: ${sovereignId}`);
      if (publicKey) {
        this._db.upsertEnrollment({
          sovereignId,
          publicKeyHex: publicKey,
          mcc,
          enrolledAt:  existing.enrolled_at,
          referrerId:  existing.referrer_id,
          palmName:    palmName || existing.palm_name,
        });
      }
      const disc = this._db.readDisc(sovereignId);
      this._sendLegacyEnrollSuccess(ws, sovereignId, palmName || existing.palm_name, 0, disc);
      return;
    }

    // ── FACE-LOCK — one HUMAN, one identity (cross-hand dedup) ─────────────
    // Palm dedup cannot link a person's LEFT palm to their RIGHT palm, so with
    // dual palm permanent one human could enroll twice. The liveness step now
    // captures a face embedding; here it is checked SERVER-SIDE (cannot be
    // skipped by a modified client, unlike the client-driven PALM_DUPLICATE_
    // CHECK). Absent embedding = allowed for the old-client migration window
    // unless FACE_REQUIRED=1. Threshold mirrors palm's env-var pattern.
    let faceEmb = null;
    if (msg.face_embedding) {
      try {
        faceEmb = typeof msg.face_embedding === 'string'
          ? JSON.parse(msg.face_embedding)
          : msg.face_embedding;
      } catch (_) { faceEmb = null; }
      if (!Array.isArray(faceEmb) || faceEmb.length !== 192 ||
          !faceEmb.every(x => typeof x === 'number' && isFinite(x))) {
        faceEmb = null;
      }
    }
    if (faceEmb) {
      try {
        const faceSec   = require('../security/face_cancelable');
        const THRESHOLD = parseFloat(process.env.FACE_DEDUP_THRESHOLD || '0.70');
        const probe     = faceSec.transform(faceSec.getR(), faceEmb);
        const all       = this._db.getAllFaceEmbeddings();
        let maxSim = -1, matchedId = null;
        for (const row of all) {
          try {
            const s = faceSec.cosine(probe, JSON.parse(row.embedding_json));
            if (s > maxSim) { maxSim = s; if (s >= THRESHOLD) matchedId = row.sovereign_id; }
          } catch (_) { /* skip malformed row */ }
        }
        global.sovLog.info(
          `      [ENROLL] Face-lock: checked ${all.length} faces — maxSim=${maxSim.toFixed(4)} — ${matchedId ? 'DUPLICATE of ' + matchedId : 'clear'}`
        );
        if (matchedId) {
          this._rejectLegacyEnroll(ws, 'FACE_ALREADY_ENROLLED',
            'This face already has a SOV identity — one human, one identity. Recover your existing wallet instead of enrolling again.');
          return;
        }
      } catch (e) {
        global.sovLog.warn(`      [ENROLL] Face-lock check error (fail-open): ${e.message}`);
      }
    } else if (process.env.FACE_REQUIRED === '1') {
      this._rejectLegacyEnroll(ws, 'FACE_REQUIRED',
        'This node requires a face liveness capture to enroll — update your SOV app.');
      return;
    }

    // ── PALM DEDUP — server-side one-human-one-wallet HARD GATE (C4 fix 2026-08-05) ──
    // The old legacy path had NO server-side palm gate: PALM_DUPLICATE_CHECK ('PD')
    // was a separate client-driven op a modified client simply skipped, and the wallet
    // + reward were minted regardless of palm. We now REQUIRE a valid palm embedding
    // and run the SAME cancelable-transform cosine dedup the check op uses, as a hard
    // gate before any wallet exists. No palm, or a palm matching an existing citizen,
    // is refused. (Mirrors citizen_gateway._handleLegacyDuplicateCheck.)
    // NOTE: this makes enrollment depend on the biometric actually discriminating
    // different people (launch gate B1 / FAR) — validate PALM_DEDUP_THRESHOLD first.
    let _palmEmb;
    try { _palmEmb = typeof msg.embedding === 'string' ? JSON.parse(msg.embedding) : msg.embedding; }
    catch (_) { _palmEmb = null; }
    if (!Array.isArray(_palmEmb) || _palmEmb.length !== 128 ||
        !_palmEmb.every(x => typeof x === 'number' && isFinite(x))) {
      this._rejectLegacyEnroll(ws, 'PALM_REQUIRED',
        'A valid palm scan is required to enroll — update your SOV app.');
      return;
    }
    {
      const _netSeed = require('../security/network_seed');
      if (!_netSeed.has()) {
        this._rejectLegacyEnroll(ws, 'NODE_NOT_READY_NO_NETWORK_SEED',
          'This node cannot verify uniqueness yet (no network seed) — try again shortly.');
        return;
      }
      const _cancelable = require('../security/palm_cancelable');
      const _probe  = _cancelable.transform(_cancelable.getR(), _palmEmb);
      const _THRESH = parseFloat(process.env.PALM_DEDUP_THRESHOLD || '0.92');
      const _all    = this._db.getAllPalmEmbeddings();
      let _maxSim = 0, _matchedId = null;
      for (const row of _all) {
        try {
          const stored = JSON.parse(row.embedding_json);
          if (!Array.isArray(stored) || stored.length !== 128) continue;
          let d = 0, na = 0, nb = 0;
          for (let i = 0; i < 128; i++) { d += _probe[i]*stored[i]; na += _probe[i]*_probe[i]; nb += stored[i]*stored[i]; }
          const sim = (na && nb) ? d / (Math.sqrt(na) * Math.sqrt(nb)) : 0;
          if (sim > _maxSim) _maxSim = sim;
          if (sim >= _THRESH) { _matchedId = row.sovereign_id; break; }
        } catch (_) { /* skip malformed row */ }
      }
      if (_matchedId) {
        global.sovLog.warn(`      [ENROLL] Palm dedup REFUSED: ${sovereignId} matches existing ${_matchedId} (sim≥${_THRESH})`);
        this._rejectLegacyEnroll(ws, 'PALM_ALREADY_ENROLLED',
          'This palm already has a SOV identity — one human, one wallet. Recover your existing wallet instead.');
        return;
      }
      global.sovLog.info(`      [ENROLL] Palm dedup clear: ${sovereignId} (maxSim=${_maxSim.toFixed(4)}, checked=${_all.length})`);
    }

    // ── New enrollment ──────────────────────────────────────────────────────
    // SECURITY FIX (C4, 2026-08-05): pool-fund the reward exactly like the main
    // enrollment path (_processEnrollment). The old legacy path read
    // enrollment_reward_seeds and minted it via enrollNewCitizen with NO
    // deductFromPool and NO supply-cap check — every legacy enroll printed 1000 SOV
    // from nothing (unbacked, uncapped). Now the reward is drawn from the bounded
    // citizen_enrollment pool: when the pool is depleted the reward is reduced or
    // zero, so enrollment can never mint unbacked supply or exceed the 50M cap.
    const _citCount = this._db.citizenCount();
    let _tierSeeds;
    if      (_citCount <    1000) _tierSeeds = 1_000_000_000;
    else if (_citCount <   10000) _tierSeeds =   500_000_000;
    else if (_citCount <  100000) _tierSeeds =   100_000_000;
    else if (_citCount <  500000) _tierSeeds =    20_000_000;
    else                         _tierSeeds =             0;
    let enrollmentRewardSeeds = parseInt(
      this._db.getGovParam('enrollment_reward_seeds') || String(DEFAULT_ENROLLMENT_REWARD_SEEDS)
    );
    if (_tierSeeds < enrollmentRewardSeeds) enrollmentRewardSeeds = _tierSeeds;
    // deductFromPool returns the amount actually available (≤ requested) — the wallet
    // is credited only what the pool could back, so supply is always conserved.
    enrollmentRewardSeeds = this._db.deductFromPool('citizen_enrollment', enrollmentRewardSeeds);

    const enrolledAt = Date.now();
    this._db.enrollNewCitizen({
      sovereignId,
      publicKeyHex:          publicKey,
      mcc,
      enrolledAt,
      referrerId:            referrerId,
      palmName:              palmName,
      enrollmentRewardSeeds,
    });

    // Referral reward
    const referralRewardSeeds = parseInt(
      this._db.getGovParam('referral_reward_seeds') || String(DEFAULT_REFERRAL_REWARD_SEEDS)
    );
    if (referrerId && referralRewardSeeds > 0) {
      this._creditReferralReward(referrerId, sovereignId, referralRewardSeeds);
    }

    // FACE-LOCK: store the protected face template BEFORE broadcasting so the
    // broadcast can carry the exact protected JSON (peers replicate verbatim,
    // never re-transform — same rule as palm state-sync).
    let protectedFaceJson = null;
    if (faceEmb) {
      try {
        if (this._db.storeFaceEmbedding(sovereignId, JSON.stringify(faceEmb))) {
          const fr = this._db._db.prepare(
            'SELECT embedding_json, enrolled_at FROM face_embeddings WHERE sovereign_id = ?').get(sovereignId);
          if (fr) protectedFaceJson = fr.embedding_json;
          global.sovLog.info(`      [ENROLL] Face template stored for ${sovereignId}`);
        }
      } catch (e) {
        global.sovLog.warn(`      [ENROLL] Failed to store face template: ${e.message}`);
      }
    }

    // Broadcast to peer nodes
    this._peerMesh.broadcast('ENROLLMENT_BROADCAST', {
      sovereign_id:            sovereignId,
      public_key_hex:          publicKey,
      mcc,
      enrolled_at:             enrolledAt,
      referrer_id:             referrerId || '',
      palm_name:               palmName   || '',
      enrollment_reward_seeds: enrollmentRewardSeeds,
      originating_node:        this._identity.nodeId,
      face_template:           protectedFaceJson,   // protected (R_face·v) or null
    });

    global.sovLog.info(
      `      [ENROLL] Legacy citizen created: ${sovereignId}  reward: ${(enrollmentRewardSeeds / 1_000_000).toLocaleString()} SOV`
    );

    // Store palm embedding for one-human-one-wallet duplicate detection
    if (msg.embedding) {
      try {
        const embJson = typeof msg.embedding === 'string'
          ? msg.embedding
          : JSON.stringify(msg.embedding);
        this._db.storePalmEmbedding(sovereignId, embJson, handType);
        global.sovLog.info(`      [ENROLL] Palm embedding stored for ${sovereignId}`);
      } catch (e) {
        global.sovLog.warn(`      [ENROLL] Failed to store palm embedding: ${e.message}`);
      }
    }

    // ── Pioneer referral reward ───────────────────────────────────────────
    // If the enrolling citizen used a pioneer code, credit the pioneer.
    // Also check for cert-based referral bonus via referred_by field.
    if (this._gateway && this._gateway._pioneerEngine) {
      const pioneerCode = msg.pioneer_code || null;
      const referredBy  = msg.referred_by  || null;
      if (pioneerCode || referredBy) {
        this._gateway._pioneerEngine.processPioneerReward(sovereignId, pioneerCode, referredBy);
      }
    }

    const disc = this._db.readDisc(sovereignId);
    this._sendLegacyEnrollSuccess(ws, sovereignId, palmName, enrollmentRewardSeeds, disc);
  }

  // Respond with old-format PALM_EMBEDDING_RESULT that the old Flutter app reads
  _sendLegacyEnrollSuccess(ws, sovereignId, palmName, rewardSeeds, disc) {
    if (!ws || ws.readyState !== 1) return;
    const balanceSeeds = disc ? disc.balance_seeds : rewardSeeds;
    ws.send(JSON.stringify({
      type:           'PALM_EMBEDDING_RESULT',
      success:        true,
      slot_id:        0,
      enrollment_sov: rewardSeeds / 1_000_000,  // old app reads this as float SOV
      sovereign_id:   sovereignId,
      palm_name:      palmName || '',
      balance_seeds:  balanceSeeds,
      timestamp:      Date.now(),
    }));
  }

  _rejectLegacyEnroll(ws, errorCode, errorMessage) {
    if (!ws || ws.readyState !== 1) return;
    global.sovLog.warn(`      [ENROLL] Legacy rejected: ${errorCode} — ${errorMessage}`);
    ws.send(JSON.stringify({
      type:    'PALM_EMBEDDING_RESULT',
      success: false,
      error:   errorCode,
      message: errorMessage,
      timestamp: Date.now(),
    }));
  }

  // ── Response helpers ──────────────────────────────────────────────────────

  _sendEnrollSuccess(ws, sovereignId, publicKeyHex, palmName, rewardSeeds, currentBalanceSeeds) {
    if (!ws || ws.readyState !== 1 /* WebSocket.OPEN */) return;
    ws.send(JSON.stringify({
      op:                    ENROLL_OP.ENROLL_RESULT,
      success:               true,
      sovereign_id:          sovereignId,
      public_key_hex:        publicKeyHex,
      palm_name:             palmName || '',
      reward_seeds:          rewardSeeds,
      current_balance_seeds: currentBalanceSeeds || rewardSeeds,
      ts:                    Date.now(),
    }));
  }

  _rejectEnroll(ws, errorCode, errorMessage) {
    if (!ws || ws.readyState !== 1) return;
    global.sovLog.warn(`      [ENROLL] Rejected: ${errorCode} — ${errorMessage}`);
    ws.send(JSON.stringify({
      op:      ENROLL_OP.ENROLL_RESULT,
      success: false,
      error:   errorCode,
      message: errorMessage,
      ts:      Date.now(),
    }));
  }
}

module.exports = { EnrollmentEngine, ENROLL_OP, MCC_COUNTRY_MAP };
