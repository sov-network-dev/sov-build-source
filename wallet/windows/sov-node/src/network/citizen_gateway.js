// ─────────────────────────────────────────────────────────────────────────────
// CITIZEN GATEWAY — WebSocket server for citizen phones
// ─────────────────────────────────────────────────────────────────────────────
// This is the door into the node for SOV citizen apps.
//
// Phones connect here via outbound WSS connection. No phone has an inbound port.
// All communication is initiated by the phone. The gateway holds messages for
// offline citizens and delivers them on reconnect.
//
// Security layers:
//   1. TLS — all connections over WSS (HTTPS WebSocket)
//   2. Ed25519 — every message signed by citizen's enrollment key
//   3. Sovereign ID verification — relay rejects messages where sig doesn't match
//   4. Rate limiting — prevents message flooding
//   5. Nonce chain — prevents message replay attacks
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const WebSocket  = require('ws');
const { bootstrapNodes } = require('./bootstrap');
const https      = require('https');
const http       = require('http');
const fs         = require('fs');
const crypto     = require('crypto');
const path       = require('path');

// ── Op codebook — the "secret dictionary" ─────────────────────────────────────
// These same codes are compiled into the Flutter app.
// On the wire: 2-char codes. Off the wire: full protocol operations.
// An observer cannot tell what operation is happening.
const MSG_TYPE = {
  // Identity and session
  HELLO:                  'HL',  // Phone registers with node
  HELLO_ACK:              'HA',  // Node acknowledges phone
  PING:                   'PI',  // Keep-alive ping
  PONG:                   'PO',  // Keep-alive pong
  LIVENESS_CHECK:         'LK',  // Citizen proof-of-life / login (writes sov_disc.liveness_ts)
  LIVENESS_RESULT:        'LZ',  // Node ack of a liveness check
  // Reassigned at genesis. 'PR' and 'PK' were each used in BOTH directions:
  // inbound 'PR' dispatched PLATFORM_REGISTER while outbound 'PR' carried the
  // palm-name result, and inbound 'PK' dispatched PUBLIC_KEY_QUERY while
  // outbound 'PK' carried this result — so a wallet platform-register reply
  // decoded on the app as a public-key answer. Own codes now.
  PLATFORM_REGISTER:      'TF',  // Wallet-side: citizen-signed external-platform register
  PLATFORM_REGISTER_RESULT: 'TG', // Node result of a wallet platform registration

  // Messaging
  MESSAGE_SEND:           'MS',  // Send a message to another citizen
  MESSAGE_INCOMING:       'MI',  // Deliver incoming message to phone
  MESSAGE_ACK:            'MA',  // Message delivery confirmed
  MESSAGE_READ:           'MR',  // Mark message as read
  MESSAGE_READ_RECEIPT:   'RR',  // Read receipt forwarded to sender

  // Presence
  CITIZEN_ONLINE:         'CO',  // Notify watcher that citizen is online
  CITIZEN_OFFLINE:        'CF',  // Notify watcher that citizen went offline
  WATCH_ADD:              'WA',  // Watch for citizen coming online
  WATCH_REMOVE:           'WX',  // Stop watching citizen

  // SOV transfers
  SOV_TRANSFER:           'ST',  // Initiate SOV transfer
  SOV_TRANSFER_RESULT:    'SR',  // Transfer confirmed or rejected
  SOV_TRANSFER_RECEIVED:  'SV',  // Notify recipient of incoming transfer

  // Automated-wallet spend policy (network-enforced caps + allowlist)
  AUTOMATION_POLICY_SET:    'AZ', // Set/update caps + allowlist
  AUTOMATION_POLICY_GET:    'AR', // Query current policy + 24h spend
  AUTOMATION_POLICY_CANCEL: 'AC', // Cancel a pending relaxation
  AUTOMATION_POLICY_STATE:  'AS', // Server → client: policy state / result

  // Balance and history
  BALANCE_QUERY:          'BQ',  // Query current balance
  BALANCE_RESULT:         'BR',  // Balance response
  TX_HISTORY_REQUEST:     'TH',  // Request transaction history
  TX_HISTORY_RESULT:      'TR',  // Transaction history response

  // Relay list — phone asks for all known relay nodes so it can failover
  // Reassigned at genesis. 'RL' was shared with PAY_REQ_LIST and the payment
  // case came FIRST in the dispatch switch, so the relay-list branch was dead
  // code; the app worked around it by sending HOP_BRIDGE_DISCOVER ('HD'),
  // which happens to return the same shape. 'RR' likewise collided with
  // MESSAGE_READ_RECEIPT. Both now have their own codes and the HD hack retires.
  RELAY_LIST_REQUEST:     'RN',  // Phone requests list of all known relay nodes
  RELAY_LIST_RESULT:      'RS',  // Response with array of relay entries
  HOP_BRIDGE_DISCOVER:    'HD',  // Phone's 5-min periodic re-discovery (same response as RELAY_LIST)

  // Node discovery (for phone mesh)
  NODE_QUERY:             'NQ',  // Find which node a citizen belongs to
  NODE_RESPONSE:          'NR',  // Node location response

  // Fragment routing (phone mesh)
  FRAG_ANNOUNCE:          'FA',  // Announce fragment locations
  FRAG_REQUEST:           'FR',  // Request a specific fragment
  FRAG_DELIVER:           'FD',  // Deliver a fragment
  MESH_HELLO:             'MP',  // Phone joining the mesh
  MESH_GONE:              'MG',  // Phone leaving the mesh

  // Enrollment
  ENROLL_REQUEST:         'EN',  // Phone submits palm biometric for enrollment
  ENROLL_RESULT:          'ER',  // Node returns sovereign_id or rejection

  // ── Financial engine — inbound op codes (phone → node) ──────────────────
  // SOV Request (payment requests)
  PAY_REQ_CREATE:         'RC',  // Create a payment request QR
  PAY_REQ_LIST:           'RL',  // List own payment requests
  PAY_REQ_CANCEL:         'RX',  // Cancel a payment request

  // SOV Vault (deadman switch)
  VAULT_LOCK:             'VL',  // Lock SOV in vault with claim key
  VAULT_CLAIM_INIT:       'VI',  // Initiate vault claim

  // UBI Issuance
  ISSUANCE_CLAIM:         'IC',  // Claim pending epoch allocation

  // Guardian recovery
  GUARDIAN_ADD:           'UA',  // Add a guardian contact
  GUARDIAN_REMOVE:        'UR',  // Remove a guardian
  GUARDIAN_LIST:          'UL',  // List guardians
  RECOVERY_REQUEST:       'UI',  // Initiate guardian recovery
  GUARDIAN_APPROVE:       'UP',  // Approve a recovery request
  GUARDIAN_REJECT:        'UJ',  // Reject a recovery request

  // ── Exchange engine — inbound op codes (phone → node) ───────────────────
  EXCHANGE_LIST_ORDER:    'XL',  // Seller lists SOV for sale
  EXCHANGE_FILL_ORDER:    'XF',  // Buyer fills an order
  EXCHANGE_CONFIRM:       'XC',  // Seller confirms delivery
  EXCHANGE_REFUND:        'XR',  // Buyer requests refund
  EXCHANGE_EDIT_ORDER:    'XE',  // Seller edits price/memo
  EXCHANGE_CANCEL_ORDER:  'XX',  // Seller cancels open order
  EXCHANGE_ORDER_BOOK:    'XO',  // Get order book depth
  EXCHANGE_PRICE_HISTORY: 'XP',  // Get price history chart data
  EXCHANGE_MY_ORDERS:     'XM',  // List own orders
  EXCHANGE_VIEW_ORDERS:   'XV',  // Browse all open orders
  EXCHANGE_VIEW_MY_LISTINGS:'XY',// Seller's own listings (any status)
  EXCHANGE_VIEW_MY_FILLS: 'XW',  // Orders this citizen filled as buyer
  EXCHANGE_CHAT_SEND:     'XH',  // Send exchange chat message
  EXCHANGE_CHAT_LIST:     'XK',  // List chat messages for order
  EXCHANGE_CHAT_THREADS:  'XT',  // Seller negotiation inbox (per-buyer threads)
  EXCHANGE_CHAT_INCOMING: 'XI',  // Live push: chat message delivered to recipient
  EXCHANGE_VIEW_REPUTATION:'XZ', // View trader reputation score
  EXCHANGE_SUBSCRIBE:     'XB',  // Subscribe to live order push stream
  EXCHANGE_UNSUBSCRIBE:   'XQ',  // Unsubscribe from live order push stream

  // ── Justice engine — inbound op codes (phone → node) ────────────────────
  DISPUTE_OPEN:           'DO',  // Open a dispute
  DISPUTE_LIST:           'DR',  // List own disputes / jury invitations
  DISPUTE_GET:            'DG',  // Get a single dispute with jurors
  JUSTICE_VOTE:           'DV',  // Cast a jury vote
  JUROR_RESPOND:          'DJ',  // Accept or decline jury invitation
  EXPAND_PANEL:           'DX',  // Add one more juror to panel

  // ── Governance engine — inbound op codes (phone → node) ─────────────────
  POLL_CREATE:            'PC',  // Create a governance poll
  POLL_VOTE:              'PV',  // Cast a vote on a poll
  POLL_LIST:              'PL',  // List polls (by status)
  POLL_GET:               'PG',  // Get a single poll with tally
  PETITION_CREATE:        'EC',  // Create a petition
  PETITION_SIGN:          'ES',  // Sign a petition
  PETITION_LIST:          'EL',  // List open petitions
  GOV_PARAM_GET:          'KG',  // Get a single governance param
  GOV_PARAMS_ALL:         'KA',  // Get all governance params
  SOV_VALUE_STATUS:       'QS',  // Get current SOV USD rate + vote status (price oracle)
  SOV_VALUE_SUBMIT:       'QV',  // Submit a USD price proposal for this epoch

  // ── Social engine — inbound op codes (phone → node) ─────────────────────
  // SOV Academy
  ACADEMY_PUBLISH:        'AP',  // Publish an article (bond held, see note)
  ACADEMY_LIST:           'AL',  // List articles (with optional category filter)
  ACADEMY_GET:            'AG',  // Get full article body
  ACADEMY_UPVOTE:         'AU',  // Upvote an article

  // SOV Enclave (community forum — gate: sov_enclave gov param, seeded '1'/ON).
  // Renamed from citizen_forum at genesis so the protocol matches the product
  // name; a param key is the identity a vote attaches to, so genesis was the
  // only moment this could change without orphaning cast votes.
  // The FORUM_* op codes keep their letters — they are wire identifiers, and
  // renaming them would break every already-shipped client for no gain.
  ENCLAVE_POST:             'FP',  // Create a new post
  ENCLAVE_REPLY:            'FY',  // Reply to a post
  ENCLAVE_LIST:             'FL',  // List posts (paginated)
  ENCLAVE_GET:              'FG',  // Get a post with replies


  // SOV Login (gate: sov_login gov param)
  LOGIN_CHALLENGE_CREATE: 'LG',  // External site requests a challenge QR
  LOGIN_RESPOND:          'LR',  // Citizen app signs the challenge
  LOGIN_VERIFY:           'LV',  // External site polls for verification status

  // Palm Name
  PALM_NAME_QUERY:        'PN',  // Query palm name for a sovereign_id
  // ── Groups + message reactions ───────────────────────────────────────────
  // Dispatched by LITERAL case 'GC': etc. rather than case MSG_TYPE.X:.
  // Declared here so collision detection can see them — undeclared codes are
  // invisible to the audit, so a future op could silently reuse one.
  GROUP_CREATE:           'GC',
  GROUP_SEND:             'GS',
  GROUP_LIST:             'GL',
  GROUP_HISTORY:          'GH',
  GROUP_ADD_MEMBER:       'GA',
  GROUP_LEAVE:            'GV',
  MESSAGE_REACT:          'MZ',
  MESSAGE_UNREACT:        'MU',


  // ── Pioneer Program — inbound op codes (phone → node) ──────────────────────
  PIONEER_VERIFY:           'YV',  // Validate a pioneer code before enrollment (pre-auth)
  PIONEER_REGISTER:         'YR',  // Register as a pioneer after enrollment
  PIONEER_GET_STATUS:       'YS',  // Get own pioneer rank, certs, earnings
  PIONEER_START_ASSESSMENT: 'YA',  // Begin a specialisation assessment quiz
  PIONEER_SUBMIT_ASSESSMENT:'YU',  // Submit quiz answers for grading

  // ── Allocation engine — inbound op codes (phone → node) ─────────────────
  ALLOCATION_CREATE:        'OC',  // Create a new time-locked SOV allocation
  ALLOCATION_LIST:          'OL',  // List own allocations + locked total
  ALLOCATION_CANCEL:        'OX',  // Cancel a locked allocation (returns escrow)
  ALLOCATION_CLAIM_STAGE1:  'O1',  // Direct claim: claim key + release date reached
  ALLOCATION_CLAIM_STAGE2:  'O2',  // Council review claim: family keys + community
  ALLOCATION_COUNCIL_VOTE:  'OV',  // Council member casts approve/reject/abstain
  ALLOCATION_MY_COUNCILS:   'OK',  // List councils citizen is claimant or member of
  UNCLAIMED_BROADCAST_SEARCH: 'OS', // Descendant searches matured unclaimed allocations by family-name hash

  // ── Calls engine — RETIRED (king directive 2026-08-07) ───────────────────
  // Voice/video calling was decommissioned in the app on 2026-05-20 (call
  // buttons removed, LiveKit left down) but sov_calls/sov_video_calls stayed
  // seeded at '1' from a 2026-05-13 activation — the protocol advertised a
  // feature that could not work. Both params, and call_max_duration_minutes,
  // are now gone from PARAM_MAP and both seeding arrays, so _getGovParam
  // returns the '0' fallback and calls_engine refuses every call. There is no
  // PARAM_MAP entry, so no vote can switch them back on.
  // calls_engine.js is left on disk, unreferenced, so a future network that
  // genuinely wants calls can revive it deliberately rather than by accident.
  CALL_INVITE:            'CI',  // Caller initiates a call (creates room, mints tokens)
  CALL_ANSWER:            'CA',  // Callee accepts the call
  CALL_END:               'CE',  // Either party ends the call
  CALL_REJECT:            'CJ',  // Callee declines the call

  // ── Node stats — used by node_status_screen.dart ────────────────────────────
  // Also accepts old relay message type 'NETWORK_STATS' (via LEGACY_TYPE_MAP)
  NODE_STATS:             'ZS',  // Phone queries connected node statistics
  NODE_STATS_RESULT:      'ZR',  // Node responds with stats payload

  // ── Watch list (already handled inline but needs short codes) ───────────────
  WATCH_ADD:              'WA',
  WATCH_REMOVE:           'WX',

  // ── Ledger sync (used by recovery_screen after seed restore) ───────────────
  LEDGER_SYNC_REQUEST:    'LQ',  // Phone requests ledger sync
  LEDGER_SYNC_RESPONSE:   'LY',  // Node responds with balance + tx history + palm name

  // ── Misc protocol ────────────────────────────────────────────────────────────
  LEDGER_SYNC_ACK:        'LA',  // Phone acknowledges offline tx delivery
  MESSAGE_DELIVERY_RECEIPT:'DL', // Phone confirms MESSAGE_INCOMING received

  // Error
  ERROR:                  'EX',  // Protocol error response
};

// ── Op-to-type reverse lookup (for backward-compat outbound messages) ────────
// Old relay_connector.dart reads msg.type (full string). New apps read msg.op.
// _send() includes BOTH fields so both old and new apps understand the message.
const _TYPE_TO_OP = {};     // Built from MSG_TYPE after the class — see bottom of file

// ── Type-to-op forward lookup (for backward-compat inbound messages) ─────────
// Old relay_connector.dart sends msg.type (full string). SOV Node switch reads
// msg.op (2-char). _handleMessage() normalises: if msg.op missing, look up type.
const LEGACY_TYPE_MAP = {
  EXCHANGE_CONFIRM_DELIVERY: 'XC', // bugfix 20260722: app/CLI send this longer type; route to seller-confirm/refund/dispute
  HELLO:                  'HL',
  ENROLL_REQUEST:         'EN',
  PING:                   'PI',
  LIVENESS_CHECK:         'LK',
  PLATFORM_REGISTER:      'TF',
  PLATFORM_REGISTER_RESULT: 'TG',
  MESSAGE_SEND:           'MS',
  MESSAGE_READ:           'MR',
  SOV_TRANSFER:           'ST',
  AUTOMATION_POLICY_SET:    'AZ',
  AUTOMATION_POLICY_GET:    'AR',
  AUTOMATION_POLICY_CANCEL: 'AC',
  BALANCE_QUERY:          'BQ',
  TX_HISTORY_REQUEST:     'TH',
  NODE_QUERY:             'NQ',
  FRAG_ANNOUNCE:          'FA',
  FRAG_REQUEST:           'FR',
  FRAG_DELIVER:           'FD',
  MESH_HELLO:             'MP',
  PAY_REQ_CREATE:         'RC',
  PAY_REQ_LIST:           'RL',
  PAY_REQ_CANCEL:         'RX',
  VAULT_LOCK:             'VL',
  VAULT_CLAIM_INIT:       'VI',
  ISSUANCE_CLAIM:         'IC',
  GUARDIAN_ADD:           'UA',
  GUARDIAN_REMOVE:        'UR',
  GUARDIAN_LIST:          'UL',
  RECOVERY_REQUEST:       'UI',
  GUARDIAN_APPROVE:       'UP',
  GUARDIAN_REJECT:        'UJ',
  EXCHANGE_LIST_ORDER:    'XL',
  EXCHANGE_FILL_ORDER:    'XF',
  EXCHANGE_CONFIRM:       'XC',
  EXCHANGE_REFUND:        'XR',
  EXCHANGE_EDIT_ORDER:    'XE',
  EXCHANGE_CANCEL_ORDER:  'XX',
  EXCHANGE_ORDER_BOOK:    'XO',
  EXCHANGE_PRICE_HISTORY: 'XP',
  EXCHANGE_MY_ORDERS:     'XM',
  EXCHANGE_VIEW_ORDERS:   'XV',  // Browse all open orders
  EXCHANGE_VIEW_MY_LISTINGS:'XY',// Seller's own listings (any status)
  EXCHANGE_VIEW_MY_FILLS: 'XW',  // Orders this citizen filled as buyer
  EXCHANGE_CHAT_SEND:     'XH',
  EXCHANGE_CHAT_LIST:     'XK',
  EXCHANGE_CHAT_THREADS:  'XT',
  EXCHANGE_CHAT_INCOMING: 'XI',
  EXCHANGE_VIEW_REPUTATION:'XZ',
  EXCHANGE_SUBSCRIBE:     'XB',
  EXCHANGE_UNSUBSCRIBE:   'XQ',
  DISPUTE_OPEN:           'DO',
  DISPUTE_LIST:           'DR',
  DISPUTE_GET:            'DG',
  JUSTICE_VOTE:           'DV',
  JUROR_RESPOND:          'DJ',
  EXPAND_PANEL:           'DX',
  POLL_CREATE:            'PC',
  POLL_VOTE:              'PV',
  POLL_LIST:              'PL',
  POLL_GET:               'PG',
  PETITION_CREATE:        'EC',
  PETITION_SIGN:          'ES',
  PETITION_LIST:          'EL',
  GOV_PARAM_GET:          'KG',
  GOV_PARAMS_ALL:         'KA',
  SOV_VALUE_STATUS:       'QS',
  SOV_VALUE_SUBMIT:       'QV',
  ACADEMY_PUBLISH:        'AP',
  ACADEMY_LIST:           'AL',
  ACADEMY_GET:            'AG',
  ACADEMY_UPVOTE:         'AU',
  ENCLAVE_POST:             'FP',
  ENCLAVE_REPLY:            'FY',
  ENCLAVE_LIST:             'FL',
  ENCLAVE_GET:              'FG',
  LOGIN_CHALLENGE_CREATE: 'LG',
  LOGIN_RESPOND:          'LR',
  LOGIN_VERIFY:           'LV',
  PALM_NAME_QUERY:        'PN',
  PIONEER_VERIFY:           'YV',
  PIONEER_REGISTER:         'YR',
  PIONEER_GET_STATUS:       'YS',
  PIONEER_START_ASSESSMENT: 'YA',
  PIONEER_SUBMIT_ASSESSMENT:'YU',
  ALLOCATION_CREATE:        'OC',
  ALLOCATION_LIST:          'OL',
  ALLOCATION_CANCEL:        'OX',
  UNCLAIMED_BROADCAST_SEARCH: 'OS',
  ALLOCATION_CLAIM_STAGE1:  'O1',
  ALLOCATION_CLAIM_STAGE2:  'O2',
  ALLOCATION_COUNCIL_VOTE:  'OV',
  ALLOCATION_MY_COUNCILS:   'OK',
  CALL_INVITE:            'CI',
  CALL_ANSWER:            'CA',
  CALL_END:               'CE',
  CALL_REJECT:            'CJ',
  // ── Old relay message types used by relay_connector.dart ────────────────────
  NETWORK_STATS:          'ZS',  // Old relay name for node stats query
  SOV_BALANCE_QUERY:      'BQ',  // Old relay name for balance query
  // RELAY_LIST_REQUEST already has the same name in MSG_TYPE — maps to 'RL'
  WATCH_ADD:              'WA',
  WATCH_REMOVE:           'WX',
  LEDGER_SYNC_REQUEST:    'LQ',
  LEDGER_SYNC_RESPONSE:   'LY',
  LEDGER_SYNC_ACK:        'LA',
  MESSAGE_DELIVERY_RECEIPT:'DL',
  // ── Legacy 2-step enrollment — old Flutter app sends these before BCH was added ─
  ENROLLMENT_REGISTER:     'LE',  // Step 1 — stores sovereign_id + public_key
  PALM_EMBEDDING_REGISTER: 'LP',  // Step 2 — triggers actual citizen creation
  PALM_DUPLICATE_CHECK:    'PD',  // Pre-enrollment duplicate check (old app sends this first)
};

// Rate limiting — max messages per citizen per second
const RATE_LIMIT_MSG_PER_SEC = 20;
const RATE_LIMIT_WINDOW_MS   = 1000;

// Ping interval — keep connections alive through mobile NAT
const PING_INTERVAL_MS = 30000; // 30 seconds

class CitizenGateway {

  constructor(identity, db, peerMesh, phoneMesh, protocolEngine) {
    this._identity       = identity;
    this._db             = db;
    this._peerMesh       = peerMesh;
    this._phoneMesh      = phoneMesh;
    this._protocolEngine = protocolEngine;

    // Active citizen connections
    this._citizens       = new Map(); // sovereignId → { ws, connectedAt, lastSeen }

    // Rate limiting state
    this._rateLimits     = new Map(); // sovereignId → { count, windowStart }

    // Pending message queue — messages for offline citizens
    this._pendingQueue   = new Map(); // sovereignId → [{ type, payload, ts }]

    this._server         = null;
    this._wss            = null;
    this._pingTimer      = null;
    this._startTime      = Date.now();  // For uptime calculation in NODE_STATS
  }

  static async start(identity, db, peerMesh, phoneMesh, protocolEngine) {
    const gw = new CitizenGateway(identity, db, peerMesh, phoneMesh, protocolEngine);
    await gw._startServer();
    gw._startPingLoop();

    // When a peer node delivers a message for one of our citizens
    peerMesh.on('CITIZEN_MESSAGE_FORWARD', (msg) => gw._deliverToConnected(msg.to, msg.type, msg.payload));
    peerMesh.on('CITIZEN_ONLINE_RELAY',    (msg) => gw._handleCrossRelayOnline(msg));

    // ── Merkle self-heal: respond to state delta requests from peers ──────────
    // When a peer requests a state delta (after detecting a Merkle mismatch),
    // send back our full disc table so they can apply rows we have at higher version.
    peerMesh.on('STATE_DELTA_REQUEST', (msg) => {
      try {
        const rows = db._db.prepare('SELECT sovereign_id, balance_seeds, version, nonce, last_tx_hash FROM sov_disc ORDER BY sovereign_id ASC').all();
        // V40: also carry enrollments (auth records). Enrollments are NOT in the
        // disc Merkle, so without this a synced node has balances but cannot
        // verify citizen signatures (no public_key_hex). INSERT OR IGNORE on apply.
        const enrollments = db._db.prepare('SELECT sovereign_id, public_key_hex, mcc, enrolled_at, referrer_id, palm_name FROM sov_enrollments').all();
        // Tier-4: carry the cancelable-transformed palm templates so EVERY node
        // holds the replica (network-wide dedup; small ~0.5KB; INSERT OR IGNORE).
        const embeddings = db._db.prepare('SELECT sovereign_id, embedding_json, hand_type, enrolled_at FROM palm_embeddings').all();
        // FACE-LOCK: carry the protected face templates too (same replication
        // rules as palm templates — small, verbatim, INSERT OR IGNORE on apply).
        const faceTemplates = db._db.prepare('SELECT sovereign_id, embedding_json, enrolled_at FROM face_embeddings').all();
        // Exchange anti-entropy: carry open + recently-updated orders (local +
        // replicas, newest wins) and recent messages so cross-node trades and
        // negotiation chat reconcile over the reliable PULL path (the push
        // broadcast is lossy on flapping links). Applied idempotently below.
        let exchange_orders = [], exchange_messages = [];
        try {
          const xcut = Date.now() - 7 * 24 * 60 * 60 * 1000;
          const om = new Map();
          const addO = (r) => { const e = om.get(r.order_id); if (!e || r.updated_at > e.updated_at) om.set(r.order_id, r); };
          for (const r of db._db.prepare("SELECT order_id,seller_id,sov_amount,price_per_sov,currency_code,status,filled_by,source_node,created_at,updated_at,expires_at,payment_method FROM sov_exchange_orders WHERE status='open' OR updated_at > ?").all(xcut)) addO(r);
          try { for (const r of db._db.prepare("SELECT order_id,seller_id,sov_amount,price_per_sov,currency_code,status,filled_by,source_node,created_at,updated_at,expires_at,payment_method FROM sov_exchange_replicas WHERE status='open' OR updated_at > ?").all(xcut)) addO(r); } catch (_) {}
          exchange_orders = [...om.values()];
          exchange_messages = db._db.prepare("SELECT msg_id,order_id,from_id,to_id,buyer_id,content,created_at,read_ts FROM sov_exchange_messages WHERE created_at > ?").all(xcut);
        } catch (_) {}
        peerMesh.sendTo(msg.node_id, 'STATE_DELTA_RESPONSE', {
          node_id: identity.nodeId,
          rows,
          enrollments,
          embeddings,
          face_templates: faceTemplates,
          exchange_orders,
          exchange_messages,
          consensus: (db.exportConsensus ? db.exportConsensus() : {}),
        });
        global.sovLog.debug(`[Mesh] STATE_DELTA_RESPONSE sent to ${msg.node_id.slice(0,16)}... (${rows.length} rows)`);
      } catch (e) {
        global.sovLog.warn(`[Mesh] STATE_DELTA_REQUEST handling error: ${e.message}`);
      }
    });

    // Apply state delta received from a peer — use "higher version wins" rule.
    // Balance is updated ONLY when the remote version is strictly higher than ours.
    peerMesh.on('STATE_DELTA_RESPONSE', (msg) => {
      try {
        let applied = 0;
        // C2 mitigation (2026-08-05): a peer must NOT be able to mint supply past the
        // 50M cap by asserting a huge balance via STATE_DELTA. Track how much room is
        // left under the cap and refuse any balance-raising row that would exceed it.
        // This stops the "assert balance=huge → ledger takeover" mint. It does NOT stop
        // a conservation-neutral redistribution (one wallet up, another down) — closing
        // that fully needs signed disc state / transaction-replay reconciliation, which
        // is a larger design change tracked as the remaining C2 work.
        const _MAX_CAP = 50000000000000; // MAX_TOTAL_SUPPLY_SEEDS (50M SOV × 1e6)
        let _capRoom;
        try { _capRoom = _MAX_CAP - db.currentTotalSupply(); } catch (_) { _capRoom = _MAX_CAP; }
        for (const row of (msg.rows || [])) {
          const local = db._db.prepare(
            'SELECT balance_seeds, version, nonce, last_tx_hash FROM sov_disc WHERE sovereign_id = ?'
          ).get(row.sovereign_id);
          // H4: never RESET nonce/last_tx_hash to 0/'' just because a pre-H4 peer
          // omitted them from the delta — that would itself open a replay window.
          // Take the peer's value only when present; otherwise keep what we hold.
          const _n   = (row.nonce != null)        ? Number(row.nonce)        : (local ? local.nonce : 0);
          const _lth = (row.last_tx_hash != null) ? String(row.last_tx_hash) : (local ? (local.last_tx_hash || '') : '');
          if (!local) {
            // V39 fix: peer has a citizen we lack — INSERT it so a node behind on
            // enrollments can reach Merkle parity. Previously skipped, so the disc
            // anti-entropy only updated existing rows and never inserted missing
            // ones → permanent Merkle mismatch for any node missing a citizen.
            const _newBal = Number(row.balance_seeds) || 0;
            if (_newBal > _capRoom) {  // C2 mitigation: would mint past the cap
              global.sovLog.warn(`[Mesh] STATE_DELTA REFUSED (over-cap insert) ${row.sovereign_id} bal=${row.balance_seeds} room=${_capRoom}`);
              continue;
            }
            try {
              db.ensureDiscEntry(row.sovereign_id);
              db._db.prepare('UPDATE sov_disc SET balance_seeds = ?, version = ?, nonce = ?, last_tx_hash = ? WHERE sovereign_id = ?')
                .run(row.balance_seeds, row.version, _n, _lth, row.sovereign_id);
              _capRoom -= _newBal;
              applied++;
              global.sovLog.info(`[Mesh] STATE_DELTA: inserted ${row.sovereign_id} v${row.version} bal=${row.balance_seeds}`);
            } catch (e) { global.sovLog.warn(`[Mesh] STATE_DELTA insert error: ${e.message}`); }
            continue;
          }
          if (row.version > local.version) {
            const _delta = (Number(row.balance_seeds) || 0) - (Number(local.balance_seeds) || 0);
            if (_delta > 0 && _delta > _capRoom) {  // C2 mitigation: would mint past the cap
              global.sovLog.warn(`[Mesh] STATE_DELTA REFUSED (over-cap raise) ${row.sovereign_id} delta=${_delta} room=${_capRoom}`);
              continue;
            }
            db._db.prepare(
              'UPDATE sov_disc SET balance_seeds = ?, spendable_seeds = ?, version = ?, nonce = ?, last_tx_hash = ? WHERE sovereign_id = ? AND version < ?'
            ).run(row.balance_seeds, row.balance_seeds, row.version, _n, _lth, row.sovereign_id, row.version);
            if (_delta > 0) _capRoom -= _delta;
            applied++;
            global.sovLog.info(`[Mesh] STATE_DELTA: applied ${row.sovereign_id} v${local.version}->${row.version} bal=${row.balance_seeds}`);
          } else if (row.version === local.version && row.balance_seeds !== local.balance_seeds) {
            // Same-version balance fork — only ever produced by the legacy
            // transfer-fee bug (normal ops always bump version). Higher-version-wins
            // cannot heal it. Deterministic, NON-INFLATIONARY tie-break: the LOWER
            // balance wins (= the fee-deducted, correct value). Each node only
            // reduces toward the minimum, so the mesh converges to a single root and
            // total supply can never increase. Verified-peer trust model (same as the
            // higher-version-wins update path above).
            if (row.balance_seeds < local.balance_seeds) {
              db._db.prepare(
                'UPDATE sov_disc SET balance_seeds = ?, spendable_seeds = ? WHERE sovereign_id = ? AND version = ?'
              ).run(row.balance_seeds, row.balance_seeds, row.sovereign_id, row.version);
              applied++;
              global.sovLog.info(`[Mesh] FORK-HEAL ${row.sovereign_id} v${row.version} ${local.balance_seeds}->${row.balance_seeds} (min-wins) src=${(msg.node_id||'').slice(0,12)}`);
            }
          }
        }
        if (applied > 0) {
          global.sovLog.info(`[Mesh] STATE_DELTA_RESPONSE from ${(msg.node_id||'').slice(0,16)}...: ${applied} rows updated`);
        }
        // V40: sync enrollments (auth records) carried alongside the disc delta.
        let enrApplied = 0;
        const insEnr = db._db.prepare('INSERT OR IGNORE INTO sov_enrollments (sovereign_id, public_key_hex, mcc, enrolled_at, referrer_id, palm_name) VALUES (?, ?, ?, ?, ?, ?)');
        for (const e of (msg.enrollments || [])) {
          try {
            if (!e || !e.sovereign_id || !e.public_key_hex) continue;
            enrApplied += insEnr.run(e.sovereign_id, e.public_key_hex, e.mcc || '', e.enrolled_at || 0, e.referrer_id || '', e.palm_name || '').changes;
          } catch (_) {}
        }
        if (enrApplied > 0) {
          global.sovLog.info(`[Mesh] STATE_DELTA: synced ${enrApplied} enrollments`);
        }
        // Tier-4: replicate cancelable-transformed palm templates verbatim
        // (already R-transformed — INSERT OR IGNORE, NEVER re-transform).
        let embApplied = 0;
        const insEmb = db._db.prepare('INSERT OR IGNORE INTO palm_embeddings (sovereign_id, embedding_json, hand_type, enrolled_at) VALUES (?, ?, ?, ?)');
        for (const em of (msg.embeddings || [])) {
          try {
            if (!em || !em.sovereign_id || !em.embedding_json) continue;
            embApplied += insEmb.run(em.sovereign_id, em.embedding_json, em.hand_type || 'LEFT', em.enrolled_at || 0).changes;
          } catch (_) {}
        }
        if (embApplied > 0) {
          global.sovLog.info(`[Mesh] STATE_DELTA: synced ${embApplied} palm templates`);
        }
        // FACE-LOCK: replicate protected face templates verbatim (already
        // R_face-transformed — INSERT OR IGNORE, NEVER re-transform).
        let faceApplied = 0;
        const insFace = db._db.prepare('INSERT OR IGNORE INTO face_embeddings (sovereign_id, embedding_json, enrolled_at) VALUES (?, ?, ?)');
        for (const ft of (msg.face_templates || [])) {
          try {
            if (!ft || !ft.sovereign_id || !ft.embedding_json) continue;
            faceApplied += insFace.run(ft.sovereign_id, ft.embedding_json, ft.enrolled_at || 0).changes;
          } catch (_) {}
        }
        if (faceApplied > 0) {
          global.sovLog.info(`[Mesh] STATE_DELTA: synced ${faceApplied} face templates`);
        }
        // Exchange anti-entropy apply: orders -> replicas (skip our own
        // authoritative orders; upsert only when the incoming copy is newer),
        // messages -> INSERT OR IGNORE. Wrapped so a fault here can never break
        // the balance/enrollment sync above.
        try {
          let xoApplied = 0;
          const upO = db._db.prepare(`INSERT INTO sov_exchange_replicas
              (order_id, seller_id, sov_amount, price_per_sov, currency_code, status, filled_by, source_node, created_at, updated_at, expires_at, payment_method)
            VALUES (@order_id,@seller_id,@sov_amount,@price_per_sov,@currency_code,@status,@filled_by,@source_node,@created_at,@updated_at,@expires_at,@payment_method)
            ON CONFLICT(order_id) DO UPDATE SET
              status=excluded.status, filled_by=excluded.filled_by, price_per_sov=excluded.price_per_sov,
              payment_method=excluded.payment_method, updated_at=excluded.updated_at
            WHERE excluded.updated_at >= sov_exchange_replicas.updated_at`);
          for (const o of (msg.exchange_orders || [])) {
            try {
              if (!o || !o.order_id || o.source_node === identity.nodeId) continue;
              xoApplied += upO.run({
                order_id:o.order_id, seller_id:o.seller_id||'', sov_amount:o.sov_amount||0,
                price_per_sov:o.price_per_sov||0, currency_code:o.currency_code||'OTC',
                status:o.status||'open', filled_by:o.filled_by||'', source_node:o.source_node||'',
                created_at:o.created_at||0, updated_at:o.updated_at||0, expires_at:o.expires_at||0,
                payment_method:o.payment_method||'',
              }).changes;
            } catch (_) {}
          }
          let xmApplied = 0;
          const insXM = db._db.prepare('INSERT OR IGNORE INTO sov_exchange_messages (msg_id, order_id, from_id, to_id, buyer_id, content, created_at, read_ts) VALUES (?,?,?,?,?,?,?,?)');
          // Repair identity fields that an earlier push-path insert (which omits
          // buyer_id) may have left empty; never overwrite good local data.
          const fixXM = db._db.prepare("UPDATE sov_exchange_messages SET buyer_id = COALESCE(NULLIF(buyer_id,''), @b), from_id = COALESCE(NULLIF(from_id,''), @f), to_id = COALESCE(NULLIF(to_id,''), @t) WHERE msg_id = @id AND (buyer_id='' OR from_id='' OR to_id='')");
          for (const mm of (msg.exchange_messages || [])) {
            try {
              if (!mm || !mm.msg_id) continue;
              xmApplied += insXM.run(mm.msg_id, mm.order_id||'', mm.from_id||'', mm.to_id||'', mm.buyer_id||'', mm.content||'', mm.created_at||0, (mm.read_ts!=null?mm.read_ts:null)).changes;
              if (mm.buyer_id || mm.from_id || mm.to_id) fixXM.run({ b: mm.buyer_id||'', f: mm.from_id||'', t: mm.to_id||'', id: mm.msg_id });
            } catch (_) {}
          }
          if (xoApplied || xmApplied) global.sovLog.info(`[Mesh] STATE_DELTA: synced ${xoApplied} exch orders, ${xmApplied} exch msgs`);
        } catch (e) { global.sovLog.warn(`[Mesh] STATE_DELTA exchange apply error: ${e.message}`); }
        // Generic consensus anti-entropy apply (guardians/justice/groups/social/
        // platforms/messaging-keys/etc) — INSERT-OR-IGNORE, wrapped so it can never break
        // the balance/enrollment/exchange sync above.
        try {
          if (db.applyConsensus && msg.consensus) {
            const n = db.applyConsensus(msg.consensus);
            if (n > 0) global.sovLog.info(`[Mesh] STATE_DELTA: synced ${n} consensus rows`);
          }
        } catch (e) { global.sovLog.warn(`[Mesh] STATE_DELTA consensus apply error: ${e.message}`); }
      } catch (e) {
        global.sovLog.warn(`[Mesh] STATE_DELTA_RESPONSE handling error: ${e.message}`);
      }
    });

    // ── Circuit-relay (Task #26): decentralized serving behind hard NAT ───────
    // Any node can serve citizens THROUGH a reachable mesh peer — no port-forward,
    // no external service, no single point of failure (any relay peer will do, and
    // if one drops the node re-registers with another). R-side handlers are always
    // on (we may front others); if WE are not directly reachable, register with
    // reachable peers so citizens can find us via them.
    try {
      const { CircuitRelay } = require('./circuit_relay');
      gw._circuitRelay = new CircuitRelay({ peerMesh, identity, gateway: gw, log: global.sovLog });
      gw._circuitRelay.registerHandlers();
      // Register with a relay ONLY while we are not directly reachable, and
      // RE-CHECK every tick. A node commonly boots as 'circuit-relay(-unverified)'
      // for a few seconds before UPnP/STUN/the inbound reach-proof flips it to
      // direct — VPS1 did exactly that and self-registered as a relay CLIENT at
      // boot, then never let go. Each tick: if we are now directly reachable,
      // release any registration and stop; else, if we are in relay mode, keep
      // trying until one sticks (the keepalive loop then maintains it).
      let announced = false;
      const bootAt = Date.now();
      const REACH_FALLBACK_MS = 120 * 1000;   // grace before assuming NAT'd
      const t = setInterval(() => {
        const nm    = peerMesh._network;
        const reach = String((nm && nm.reachabilityMethod) || '');
        if (reach === '') return;                        // route still settling — wait
        if (!reach.startsWith('circuit-relay')) {
          // AUTO-FALLBACK: a direct/ingress address that never earned a GENUINE
          // inbound proof (nm.provenAt — set only by a real inbound, never
          // assumed) within the grace window is behind NAT / a filtered port / a
          // dead ingress host — serve THROUGH a peer instead, no port-forward and
          // no external account. A truly reachable node earns provenAt (a peer
          // reach-probe or a real citizen) well inside the window and never falls
          // back; if a fallen-back node later earns a real inbound,
          // markInboundVerified() promotes it back to direct and we stop below.
          if (nm && nm.provenAt) { gw._circuitRelay.stopRegistering(); clearInterval(t); return; }
          if ((Date.now() - bootAt) < REACH_FALLBACK_MS) return;   // still in grace — wait for a proof
          global.sovLog.warn(`      Reachability '${reach}' earned no inbound proof in ${Math.round(REACH_FALLBACK_MS/1000)}s — falling back to circuit-relay (serving through peers; no port-forward/Tailscale needed).`);
          if (nm) { nm.reachabilityMethod = 'circuit-relay'; nm.inboundVerified = false; }
        }
        // MAINTAIN up to 3 relays on EVERY tick — not once. registerWithRelays
        // prunes any relay whose peer dropped and tops up from newly-available
        // relays, so the node is never pinned to a single relay and self-heals
        // when one dies. Idempotent: a tick already holding 3 relays sends nothing.
        const held = gw._circuitRelay.registerWithRelays(3);
        if (held > 0 && !announced) { announced = true; global.sovLog.info(`      Circuit-relay: serving through the mesh (${held} relay[s])`); }
      }, 30000);
      t.unref && t.unref();
      global.sovLog.info(`      Circuit-relay: R-side ready; maintains up to 3 relays, auto-falls-back if unreachable`);
    } catch (e) {
      global.sovLog.warn(`      Circuit-relay init skipped: ${e.message}`);
    }

    global.sovLog.info(`      Citizen gateway ready`);
    return gw;
  }

  // ── Server startup ─────────────────────────────────────────────────────────

  async _startServer() {
    const port = parseInt(process.env.SOV_PORT || '443');

    // Try TLS first — use certificate from data directory
    const dataDir  = process.env.SOV_DATA_DIR || require('os').homedir() + '/.sov-node';
    const certFile = path.join(dataDir, 'tls', 'node.crt');
    const keyFile  = path.join(dataDir, 'tls', 'node.key');

    // First-run: self-sign a cert so the gateway serves WSS (not plain WS) out of
    // the box. A real CA cert (or a TLS-terminating tunnel) supersedes it by simply
    // dropping node.crt/node.key in. No-op when a cert already exists.
    if (process.env.SOV_NO_TLS !== '1') {
      try { this._ensureSelfSignedCert(dataDir, certFile, keyFile); }
      catch (e) { global.sovLog.warn(`      TLS self-sign skipped: ${e.message}`); }
    }

    let server;
    if (fs.existsSync(certFile) && fs.existsSync(keyFile)) {
      const httpsServer = https.createServer({
        cert: fs.readFileSync(certFile),
        key:  fs.readFileSync(keyFile),
      });
      this._server = httpsServer;
      // V6 hardening (2026-05-21): cap WebSocket frame size at 1 MB. Without
      // this, a single oversized frame can OOM the node. Patch log claimed
      // this was deployed 2026-05-18 but was never actually applied; confirmed
      // missing on live VPS1 during pre-snap-lock audit 2026-05-21.
      this._wss    = new WebSocket.Server({ server: httpsServer, maxPayload: 1024 * 1024 });
      httpsServer.listen(port, () => {
        global.sovLog.info(`      Citizen gateway listening on WSS :${port} (TLS)`);
      });
    } else {
      // Self-signed cert generated on first run for testing
      // In production: replaced by cert from snap install
      const httpServer = http.createServer();
      this._server = httpServer;
      // V6 hardening (2026-05-21): cap WebSocket frame size at 1 MB (see TLS branch above).
      this._wss    = new WebSocket.Server({ server: httpServer, maxPayload: 1024 * 1024 });
      httpServer.listen(port, () => {
        global.sovLog.info(`      Citizen gateway listening on WS :${port} (no TLS — generate cert for production)`);
      });
    }

    this._wss.on('connection', (ws, req) => this._handleConnection(ws, req));
  }

  // ── First-run self-signed TLS ───────────────────────────────────────────────
  _ensureSelfSignedCert(dataDir, certFile, keyFile) {
    if (fs.existsSync(certFile) && fs.existsSync(keyFile)) return;
    const forge = require('node-forge');
    const pki = forge.pki;
    const tlsDir = path.join(dataDir, 'tls');
    fs.mkdirSync(tlsDir, { recursive: true });
    const host = (process.env.SOV_PUBLIC_HOST || '').replace(/:\d+$/, '').trim();
    const cn = host || 'sov-node';
    const keys = pki.rsa.generateKeyPair(2048);
    const cert = pki.createCertificate();
    cert.publicKey = keys.publicKey;
    cert.serialNumber = '00' + (this._identity && this._identity.nodeId ? this._identity.nodeId.slice(0, 16) : '01');
    cert.validity.notBefore = new Date(0); cert.validity.notAfter = new Date(0);
    cert.validity.notBefore.setFullYear(2026, 0, 1);
    cert.validity.notAfter.setFullYear(2036, 0, 1);
    const attrs = [{ name: 'commonName', value: cn }, { name: 'organizationName', value: 'SOV Network' }];
    cert.setSubject(attrs); cert.setIssuer(attrs);
    const altNames = [{ type: 2, value: 'localhost' }, { type: 7, ip: '127.0.0.1' }];
    if (host && !/^\d+\.\d+\.\d+\.\d+$/.test(host)) altNames.push({ type: 2, value: host });
    if (host && /^\d+\.\d+\.\d+\.\d+$/.test(host)) altNames.push({ type: 7, ip: host });
    cert.setExtensions([
      { name: 'basicConstraints', cA: false },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames },
    ]);
    cert.sign(keys.privateKey, forge.md.sha256.create());
    fs.writeFileSync(certFile, pki.certificateToPem(cert), { mode: 0o600 });
    fs.writeFileSync(keyFile, pki.privateKeyToPem(keys.privateKey), { mode: 0o600 });
    global.sovLog.info(`      ✓ Self-signed TLS cert generated (CN=${cn}) → ${tlsDir}`);
  }

  // ── Connection lifecycle ───────────────────────────────────────────────────

  _handleConnection(ws, req) {
    // ── OPERATOR ENFORCEMENT (king 2026-08-14) ────────────────────────────────
    // A node serves citizens ONLY if it is an authorized operator (see
    // OperatorEngine.isAuthorizedToServe): a registered operator whose sovereign id
    // is an enrolled citizen, OR a genesis/standalone bootstrap node. A JOINING node
    // whose operator is not a valid enrolled citizen does NO work — the operator
    // identity is the economic anchor (infra → earn SOV → maintain), so an
    // unaccountable node that never earns must not carry citizens either.
    if (this._operatorEngine && typeof this._operatorEngine.isAuthorizedToServe === 'function'
        && !this._operatorEngine.isAuthorizedToServe()) {
      global.sovLog.warn('[GW] Refused citizen connection — node is NOT an authorized operator. '
        + 'Set OPERATOR_SOVEREIGN_ID to an enrolled citizen and restart.');
      try { ws.close(4090, 'OPERATOR_NOT_AUTHORIZED'); } catch (_) {}
      return;
    }
    const remoteIP = req.headers['x-forwarded-for'] || req.socket.remoteAddress;

    // reach-probe-v1: Funnel exposes ONLY :443, never the peer port, so no peer
    // can ever dial a tunnelled node. A citizen arriving from off-network proves
    // the same thing. Private/loopback/tailnet sources excluded — the operator's
    // own wallet proves nothing about the outside world.
    try {
      const ip = String(remoteIP || '').replace(/^::ffff:/, '');
      const isLocal = !ip || ip === '::1' || ip.startsWith('127.') ||
        ip.startsWith('10.') || ip.startsWith('192.168.') ||
        /^172\.(1[6-9]|2\d|3[01])\./.test(ip) ||
        ip.startsWith('100.') || ip.startsWith('169.254.') || ip.startsWith('fe80:');
      const net = this._peerMesh && this._peerMesh._network;
      if (!isLocal && net && typeof net.markInboundVerified === 'function') {
        net.markInboundVerified(`citizen ${ip}`);
      }
    } catch (_) { /* never let a status update break a citizen connection */ }
    // ── IP connection flood protection ────────────────────────────────────────
    if (!this._ipConnCount) this._ipConnCount = new Map();
    const ipKey = (remoteIP || '').split(',')[0].trim();
    const MAX_CONN_PER_IP = 8;
    const ipCurCount = (this._ipConnCount.get(ipKey) || 0) + 1;
    this._ipConnCount.set(ipKey, ipCurCount);
    if (ipCurCount > MAX_CONN_PER_IP) {
      global.sovLog.warn(`[GW] IP flood from ${ipKey}: ${ipCurCount} connections — rejecting`);
      ws.close(4029, 'TOO_MANY_CONNECTIONS');
      this._ipConnCount.set(ipKey, ipCurCount - 1);
      return;
    }
    ws._remoteIP     = remoteIP;
    ws._sovereignId  = null;
    ws._verified     = false;
    ws._connectedAt  = Date.now();

    global.sovLog.info(`[GW] New citizen connection from ${remoteIP}`);

    ws.on('message', (raw)  => this._handleMessage(ws, raw));
    ws.on('close',   ()     => this._handleDisconnect(ws));
    ws.on('error',   (err)  => this._handleError(ws, err));
    ws.on('pong',    ()     => { ws._lastSeen = Date.now(); });

    // Send greeting — old relay_connector.dart sends HELLO only when it receives RELAY_HELLO.
    // Without this, the app waits forever and HELLO_TIMEOUT fires on every connection → "Offline".
    ws.send(JSON.stringify({ type: 'RELAY_HELLO', op: 'RH', ts: Date.now() }));

    // Reap a connection that opened but never sent a HELLO/ENROLL within 30s.
    // (30s, not less: an enrollment connection's ENROLL_REQUEST — which clears
    // this timeout — can legitimately arrive late in the palm/face capture flow.)
    // Logged at DEBUG, not info: this path is almost always benign — the app's
    // connection RACE opens a socket to every candidate relay, sends HELLO only
    // to the winner, and closes the losers; a loser's close frame lost on a
    // flaky hotspot leaves its socket here until this reap. A genuinely failing
    // handshake instead closes with a specific code (HELLO_STALE_TIMESTAMP /
    // HELLO_KEY_MISMATCH / HELLO_INVALID_SIGNATURE), never this timeout.
    ws._helloTimeout = setTimeout(() => {
      if (!ws._verified) {
        global.sovLog.debug(`[GW] HELLO_TIMEOUT for ${remoteIP} — closing unauthenticated connection`);
        ws.close(4001, 'HELLO_TIMEOUT');
      }
    }, 30000);
  }

  _handleDisconnect(ws) {
    // Decrement IP connection counter on ALL disconnects (auth or pre-auth).
    // MUST come before the early return below — pre-auth connections that
    // timeout or close still need to release their IP slot; without this
    // the counter leaks and legitimate IPs get permanently blocked after
    // 8 unauthenticated timeouts.
    if (this._ipConnCount && ws._remoteIP) {
      const _ipk = (ws._remoteIP || '').split(',')[0].trim();
      const _ipc = this._ipConnCount.get(_ipk) || 0;
      if (_ipc > 0) this._ipConnCount.set(_ipk, _ipc - 1);
    }

    if (!ws._sovereignId) return;
    const sovereignId = ws._sovereignId;

    this._citizens.delete(sovereignId);
    this._phoneMesh.handlePhoneDisconnected(sovereignId);

    // Terminate any ringing/active calls this citizen is part of so the
    // other party's UI doesn't get stuck on "in call". Must come BEFORE
    // setPresenceOffline so the calls engine can still locate the peer's
    // presence row to forward CALL_END across nodes.
    if (this._callsEngine && typeof this._callsEngine.handleCitizenDisconnect === 'function') {
      try { this._callsEngine.handleCitizenDisconnect(sovereignId); } catch (_) {}
    }

    // Update presence in DB
    this._db.setPresenceOffline(sovereignId);

    // Notify watchers on this node
    const watchers = this._db.getWatchersFor(sovereignId);
    for (const watcherId of watchers) {
      this._deliverToConnected(watcherId, MSG_TYPE.CITIZEN_OFFLINE, { cid: sovereignId });
    }

    // Remove from exchange subscriber set
    if (this._exchangeEngine) this._exchangeEngine.removeSubscriber(ws);

    // Notify peer nodes
    this._peerMesh.broadcast('CITIZEN_OFFLINE_RELAY', {
      sovereign_id: sovereignId,
      node_id:      this._identity.nodeId,
    });
  }

  _handleError(ws, err) {
    global.sovLog.debug(`Gateway error for ${ws._sovereignId || 'unknown'}: ${err.message}`);
  }

  // ── Message routing ───────────────────────────────────────────────────────

  // Circuit-relay N-side: a bridged citizen frame arrived via a relay peer. Feed it
  // through the normal message path on the relay's virtual socket — its send()/close()
  // route replies back over the mesh to the relay, which forwards them to the citizen.
  handleVirtualMessage(vws, frame) {
    try { return this._handleMessage(vws, frame); }
    catch (e) { global.sovLog.warn(`[GW] virtual (relayed) message error: ${e.message}`); }
  }

  _handleMessage(ws, raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }

    // ── Backward compat — old relay_connector.dart sends msg.type (full string).
    // SOV Node protocol uses msg.op (2-char code). Normalise here so the switch
    // below works regardless of which format the phone app is using.
    if (!msg.op && msg.type) {
      msg.op = LEGACY_TYPE_MAP[msg.type] || msg.type;
    }

    // Circuit-relay R-side: if this citizen frame is addressed to a NAT'd node we
    // front (msg.target_node_id), pipe it there opaquely and stop — we are a dumb
    // relay for that node, not its gateway, so no local auth/handling applies.
    if (this._circuitRelay && this._circuitRelay.maybeBridge(ws, msg)) return;

    // First message must be HELLO or ENROLL_REQUEST (or legacy 2-step enrollment)
    // Enrollment is allowed before authentication — citizen has no ID yet
    if (!ws._verified && msg.op !== MSG_TYPE.HELLO && msg.op !== MSG_TYPE.ENROLL_REQUEST
        && msg.op !== 'LE' && msg.op !== 'LP' && msg.op !== 'PD'
        && msg.op !== MSG_TYPE.PIONEER_VERIFY) {
      ws.close(4002, 'AUTH_REQUIRED');
      return;
    }

    // PIONEER_VERIFY is pre-auth — phone sends it before enrollment to check a referral code
    if (msg.op === MSG_TYPE.PIONEER_VERIFY) {
      return this._pioneerEngine && this._pioneerEngine.handleVerify(ws, msg);
    }

    // Rate limiting — after auth
    if (ws._sovereignId && !this._checkRateLimit(ws._sovereignId)) {
      this._send(ws, MSG_TYPE.ERROR, { code: 'RATE_LIMITED', msg: 'Slow down' });
      return;
    }

    ws._lastSeen = Date.now();

    // ── C3 FIX (2026-08-05): money-moving ops require a SIGNED (non-legacy) session ──
    // An unsigned "legacy" HELLO can set ws._sovereignId to any citizen (impersonation).
    // Transfers already block legacy mode, but the EXCHANGE, VAULT and ALLOCATION engines
    // did NOT — letting an impostor list/drain/mint on a victim's behalf. Gate them here,
    // once, before dispatch. Read-only exchange ops (order book, my orders, subscribe) are
    // intentionally NOT in this set so browsing still works on legacy connections.
    const _MONEY_OPS = new Set([
      MSG_TYPE.EXCHANGE_LIST_ORDER, MSG_TYPE.EXCHANGE_FILL_ORDER, MSG_TYPE.EXCHANGE_CONFIRM,
      MSG_TYPE.EXCHANGE_REFUND, MSG_TYPE.EXCHANGE_EDIT_ORDER, MSG_TYPE.EXCHANGE_CANCEL_ORDER,
      MSG_TYPE.VAULT_LOCK, MSG_TYPE.VAULT_CLAIM_INIT,
      MSG_TYPE.ALLOCATION_CREATE, MSG_TYPE.ALLOCATION_CANCEL,
      MSG_TYPE.ALLOCATION_CLAIM_STAGE1, MSG_TYPE.ALLOCATION_CLAIM_STAGE2,
    ]);
    if (_MONEY_OPS.has(msg.op) && (ws._legacyMode || !ws._verified || !ws._sovereignId)) {
      return this._send(ws, MSG_TYPE.ERROR, {
        code: 'SIGNATURE_REQUIRED',
        message: 'This operation requires a signed connection — please update your SOV app.',
      });
    }

    switch (msg.op) {
      case MSG_TYPE.HELLO:             return this._handleHello(ws, msg);
      case MSG_TYPE.ENROLL_REQUEST:
        // Clear the HELLO timeout — enrollment connections have no sovereign_id yet
        // so they never send HELLO. Without this the gateway kills the connection
        // after 10s and the enrollment screen sees "Relay offline" at step 4.
        clearTimeout(ws._helloTimeout);
        return this._enrollmentEngine && this._enrollmentEngine.handleEnroll(ws, msg);
      // ── Legacy 2-step enrollment (old Flutter app) ─────────────────────────
      case 'LE': return this._handleLegacyEnrollRegister(ws, msg);
      case 'LP': return this._enrollmentEngine && this._enrollmentEngine.handleLegacyEnroll(ws, msg);
      // ── Legacy duplicate check (sent before ENROLLMENT_REGISTER in old app) ─
      // sov-node has no palm embedding DB from the old system, so we can't do a
      // real duplicate check. Return duplicate:false so enrollment proceeds.
      case 'PD': return this._handleLegacyDuplicateCheck(ws, msg);
      case MSG_TYPE.PING:              return this._send(ws, MSG_TYPE.PONG, { ts: Date.now() });
      case MSG_TYPE.LIVENESS_CHECK:    return this._handleLivenessCheck(ws, msg);
      case MSG_TYPE.PLATFORM_REGISTER: return this._handlePlatformRegister(ws, msg);
      case MSG_TYPE.MESSAGE_SEND:      return this._messageEngine
                                         ? this._messageEngine.handleMessageSend(ws, msg)
                                         : this._handleMessageSend(ws, msg);
      case MSG_TYPE.MESSAGE_READ:      return this._messageEngine
                                         ? this._messageEngine.handleMessageRead(ws, msg)
                                         : this._handleMessageRead(ws, msg);
      case 'MZ':                       return this._messageEngine && this._messageEngine.handleReact(ws, msg);
      case 'MU':                       return this._messageEngine && this._messageEngine.handleUnreact(ws, msg);
      case 'PK':                       return this._messageEngine && this._messageEngine.handlePublicKeyQuery(ws, msg);
      case 'GC':                       return this._groupEngine   && this._groupEngine.handleGroupCreate(ws, msg);
      case 'GS':                       return this._groupEngine   && this._groupEngine.handleGroupSend(ws, msg);
      case 'GL':                       return this._groupEngine   && this._groupEngine.handleGroupList(ws, msg);
      case 'GH':                       return this._groupEngine   && this._groupEngine.handleGroupHistory(ws, msg);
      case 'GA':                       return this._groupEngine   && this._groupEngine.handleAddMember(ws, msg);
      case 'GV':                       return this._groupEngine   && this._groupEngine.handleGroupLeave(ws, msg);
      // ── Exchange engine routes ───────────────────────────────────────────
      case MSG_TYPE.EXCHANGE_LIST_ORDER:  return this._exchangeEngine && this._exchangeEngine.handleListOrder(ws, msg);
      case MSG_TYPE.EXCHANGE_FILL_ORDER:  return this._exchangeEngine && this._exchangeEngine.handleFillOrder(ws, msg);
      case MSG_TYPE.EXCHANGE_CONFIRM:     return this._exchangeEngine && this._exchangeEngine.handleConfirmDelivery(ws, msg);
      case MSG_TYPE.EXCHANGE_REFUND:      return this._exchangeEngine && this._exchangeEngine.handleRequestRefund(ws, msg);
      case MSG_TYPE.EXCHANGE_EDIT_ORDER:  return this._exchangeEngine && this._exchangeEngine.handleEditOrder(ws, msg);
      case MSG_TYPE.EXCHANGE_CANCEL_ORDER:return this._exchangeEngine && this._exchangeEngine.handleCancelOrder(ws, msg);
      case MSG_TYPE.EXCHANGE_ORDER_BOOK:  return this._exchangeEngine && this._exchangeEngine.handleOrderBook(ws, msg);
      case MSG_TYPE.EXCHANGE_PRICE_HISTORY:return this._exchangeEngine && this._exchangeEngine.handlePriceHistory(ws, msg);
      case MSG_TYPE.EXCHANGE_MY_ORDERS:   return this._exchangeEngine && this._exchangeEngine.handleMyOrders(ws, msg);
      case MSG_TYPE.EXCHANGE_VIEW_ORDERS:      return this._exchangeEngine && this._exchangeEngine.handleViewOrders(ws, msg);
      case MSG_TYPE.EXCHANGE_VIEW_MY_LISTINGS: return this._exchangeEngine && this._exchangeEngine.handleViewMyListings(ws, msg);
      case MSG_TYPE.EXCHANGE_VIEW_MY_FILLS:    return this._exchangeEngine && this._exchangeEngine.handleViewMyFills(ws, msg);
      case MSG_TYPE.EXCHANGE_CHAT_SEND:   return this._exchangeEngine && this._exchangeEngine.handleChatSend(ws, msg);
      case MSG_TYPE.EXCHANGE_CHAT_LIST:        return this._exchangeEngine && this._exchangeEngine.handleChatList(ws, msg);
      case MSG_TYPE.EXCHANGE_CHAT_THREADS:     return this._exchangeEngine && this._exchangeEngine.handleChatThreads(ws, msg);
      case MSG_TYPE.EXCHANGE_VIEW_REPUTATION:  return this._exchangeEngine && this._exchangeEngine.handleViewReputation(ws, msg);
      case MSG_TYPE.EXCHANGE_SUBSCRIBE:        return this._exchangeEngine && this._exchangeEngine.handleSubscribe(ws);
      case MSG_TYPE.EXCHANGE_UNSUBSCRIBE:      return this._exchangeEngine && this._exchangeEngine.handleUnsubscribe(ws);
      // ── Justice engine routes ────────────────────────────────────────────
      case MSG_TYPE.DISPUTE_OPEN:      return this._justiceEngine && this._justiceEngine.handleDisputeOpen(ws, msg);
      case MSG_TYPE.DISPUTE_LIST:      return this._justiceEngine && this._justiceEngine.handleDisputeList(ws, msg);
      case MSG_TYPE.DISPUTE_GET:       return this._justiceEngine && this._justiceEngine.handleDisputeGet(ws, msg);
      case MSG_TYPE.JUSTICE_VOTE:      return this._justiceEngine && this._justiceEngine.handleJusticeVote(ws, msg);
      case MSG_TYPE.JUROR_RESPOND:     return this._justiceEngine && this._justiceEngine.handleJurorRespond(ws, msg);
      case MSG_TYPE.EXPAND_PANEL:      return this._justiceEngine && this._justiceEngine.handleExpandPanel(ws, msg);
      // ── Governance engine routes ─────────────────────────────────────────
      case MSG_TYPE.POLL_CREATE:       return this._governanceEngine && this._governanceEngine.handlePollCreate(ws, msg);
      case MSG_TYPE.POLL_VOTE:         return this._governanceEngine && this._governanceEngine.handlePollVote(ws, msg);
      case MSG_TYPE.POLL_LIST:         return this._governanceEngine && this._governanceEngine.handlePollList(ws, msg);
      case MSG_TYPE.POLL_GET:          return this._governanceEngine && this._governanceEngine.handlePollGet(ws, msg);
      case MSG_TYPE.PETITION_CREATE:   return this._governanceEngine && this._governanceEngine.handlePetitionCreate(ws, msg);
      case MSG_TYPE.PETITION_SIGN:     return this._governanceEngine && this._governanceEngine.handlePetitionSign(ws, msg);
      case MSG_TYPE.PETITION_LIST:     return this._governanceEngine && this._governanceEngine.handlePetitionList(ws, msg);
      case MSG_TYPE.GOV_PARAM_GET:     return this._governanceEngine && this._governanceEngine.handleGovParamGet(ws, msg);
      case MSG_TYPE.GOV_PARAMS_ALL:    return this._governanceEngine && this._governanceEngine.handleGovParamsAll(ws, msg);
      case MSG_TYPE.SOV_VALUE_STATUS:  return this._governanceEngine && this._governanceEngine.handleSovValueStatus(ws, msg);
      case MSG_TYPE.SOV_VALUE_SUBMIT:  return this._governanceEngine && this._governanceEngine.handleSovValueSubmit(ws, msg);
      // ── Social engine routes ─────────────────────────────────────────────
      case MSG_TYPE.ACADEMY_PUBLISH:        return this._socialEngine && this._socialEngine.handleAcademyPublish(ws, msg);
      case MSG_TYPE.ACADEMY_LIST:           return this._socialEngine && this._socialEngine.handleAcademyList(ws, msg);
      case MSG_TYPE.ACADEMY_GET:            return this._socialEngine && this._socialEngine.handleAcademyGet(ws, msg);
      case MSG_TYPE.ACADEMY_UPVOTE:         return this._socialEngine && this._socialEngine.handleAcademyUpvote(ws, msg);
      case MSG_TYPE.ENCLAVE_POST:             return this._socialEngine && this._socialEngine.handleEnclavePost(ws, msg);
      case MSG_TYPE.ENCLAVE_REPLY:            return this._socialEngine && this._socialEngine.handleEnclaveReply(ws, msg);
      case MSG_TYPE.ENCLAVE_LIST:             return this._socialEngine && this._socialEngine.handleEnclaveList(ws, msg);
      case MSG_TYPE.ENCLAVE_GET:              return this._socialEngine && this._socialEngine.handleEnclaveGet(ws, msg);
      case MSG_TYPE.LOGIN_CHALLENGE_CREATE: return this._socialEngine && this._socialEngine.handleLoginChallengeCreate(ws, msg);
      case MSG_TYPE.LOGIN_RESPOND:          return this._socialEngine && this._socialEngine.handleLoginRespond(ws, msg);
      case MSG_TYPE.LOGIN_VERIFY:           return this._socialEngine && this._socialEngine.handleLoginVerify(ws, msg);
      case MSG_TYPE.PALM_NAME_QUERY:        return this._socialEngine && this._socialEngine.handlePalmNameQuery(ws, msg);
      // ── Pioneer engine routes ──────────────────────────────────────────────
      // Note: PIONEER_VERIFY is pre-auth (phone sends before enrollment) — handled above switch
      case MSG_TYPE.PIONEER_REGISTER:         return this._pioneerEngine && this._pioneerEngine.handleRegister(ws, msg);
      case MSG_TYPE.PIONEER_GET_STATUS:       return this._pioneerEngine && this._pioneerEngine.handleGetStatus(ws, msg);
      case MSG_TYPE.PIONEER_START_ASSESSMENT: return this._pioneerEngine && this._pioneerEngine.handleStartAssessment(ws, msg);
      case MSG_TYPE.PIONEER_SUBMIT_ASSESSMENT:return this._pioneerEngine && this._pioneerEngine.handleSubmitAssessment(ws, msg);
      // ── Calls engine routes ──────────────────────────────────────────────
      case MSG_TYPE.CALL_INVITE:            return this._callsEngine && this._callsEngine.handleCallInvite(ws, msg);
      case MSG_TYPE.CALL_ANSWER:            return this._callsEngine && this._callsEngine.handleCallAnswer(ws, msg);
      case MSG_TYPE.CALL_END:               return this._callsEngine && this._callsEngine.handleCallEnd(ws, msg);
      case MSG_TYPE.CALL_REJECT:            return this._callsEngine && this._callsEngine.handleCallReject(ws, msg);
      // ── Financial engine routes ──────────────────────────────────────────
      case MSG_TYPE.PAY_REQ_CREATE:    return this._financialEngine && this._financialEngine.handleRequestCreate(ws, msg);
      case MSG_TYPE.PAY_REQ_LIST:      return this._financialEngine && this._financialEngine.handleRequestList(ws, msg);
      case MSG_TYPE.PAY_REQ_CANCEL:    return this._financialEngine && this._financialEngine.handleRequestCancel(ws, msg);
      case MSG_TYPE.VAULT_LOCK:        return this._financialEngine && this._financialEngine.handleVaultLock(ws, msg);
      case MSG_TYPE.VAULT_CLAIM_INIT:  return this._financialEngine && this._financialEngine.handleVaultClaimInit(ws, msg);
      case MSG_TYPE.ISSUANCE_CLAIM:    return this._financialEngine && this._financialEngine.handleIssuanceClaim(ws, msg);
      case MSG_TYPE.GUARDIAN_ADD:      return this._financialEngine && this._financialEngine.handleGuardianAdd(ws, msg);
      case MSG_TYPE.GUARDIAN_REMOVE:   return this._financialEngine && this._financialEngine.handleGuardianRemove(ws, msg);
      case MSG_TYPE.GUARDIAN_LIST:     return this._financialEngine && this._financialEngine.handleGuardianList(ws, msg);
      case MSG_TYPE.RECOVERY_REQUEST:  return this._financialEngine && this._financialEngine.handleRecoveryRequest(ws, msg);
      case MSG_TYPE.GUARDIAN_APPROVE:  return this._financialEngine && this._financialEngine.handleGuardianApprove(ws, msg);
      case MSG_TYPE.GUARDIAN_REJECT:   return this._financialEngine && this._financialEngine.handleGuardianReject(ws, msg);
      // ── Allocation engine ────────────────────────────────────────────────────
      case MSG_TYPE.ALLOCATION_CREATE:       return this._allocationEngine && this._allocationEngine.handleCreate(ws, msg);
      case MSG_TYPE.ALLOCATION_LIST:         return this._allocationEngine && this._allocationEngine.handleList(ws, msg);
      case MSG_TYPE.ALLOCATION_CANCEL:       return this._allocationEngine && this._allocationEngine.handleCancel(ws, msg);
      case MSG_TYPE.ALLOCATION_CLAIM_STAGE1: return this._allocationEngine && this._allocationEngine.handleClaimStage1(ws, msg);
      case MSG_TYPE.ALLOCATION_CLAIM_STAGE2: return this._allocationEngine && this._allocationEngine.handleClaimStage2(ws, msg);
      case MSG_TYPE.ALLOCATION_COUNCIL_VOTE: return this._allocationEngine && this._allocationEngine.handleCouncilVote(ws, msg);
      case MSG_TYPE.UNCLAIMED_BROADCAST_SEARCH: return this._allocationEngine && this._allocationEngine.handleUnclaimedSearch(ws, msg);
      case MSG_TYPE.ALLOCATION_MY_COUNCILS:  return this._allocationEngine && this._allocationEngine.handleMyCouncils(ws, msg);
      // ─────────────────────────────────────────────────────────────────────
      case MSG_TYPE.SOV_TRANSFER:      return this._protocolEngine.handleTransfer(ws, msg, this);
      case MSG_TYPE.AUTOMATION_POLICY_SET:    return this._protocolEngine.handleAutomationPolicySet(ws, msg, this);
      case MSG_TYPE.AUTOMATION_POLICY_GET:    return this._protocolEngine.handleAutomationPolicyGet(ws, msg, this);
      case MSG_TYPE.AUTOMATION_POLICY_CANCEL: return this._protocolEngine.handleAutomationPolicyCancel(ws, msg, this);
      case MSG_TYPE.BALANCE_QUERY:      return this._handleBalanceQuery(ws, msg);
      case MSG_TYPE.TX_HISTORY_REQUEST: return this._handleTxHistoryRequest(ws, msg);
      case 'TX_HISTORY_CONFIRMED': return this._handleTxHistoryConfirmed(ws, msg);
      case MSG_TYPE.RELAY_LIST_REQUEST: return this._handleRelayListRequest(ws, msg);
      case MSG_TYPE.HOP_BRIDGE_DISCOVER:return this._handleRelayListRequest(ws, msg); // 5-min refresh
      case MSG_TYPE.WATCH_ADD:         return this._handleWatchAdd(ws, msg);
      case MSG_TYPE.WATCH_REMOVE:      return this._handleWatchRemove(ws, msg);
      case MSG_TYPE.NODE_STATS:        return this._handleNodeStats(ws, msg);
      // ── Acks that require no relay-side action (just absorb gracefully) ──────
      case MSG_TYPE.LEDGER_SYNC_REQUEST: return this._handleLedgerSyncRequest(ws, msg);
      case MSG_TYPE.LEDGER_SYNC_ACK:   return; // Acknowledged — no further action
      case MSG_TYPE.MESSAGE_DELIVERY_RECEIPT: return; // Delivery confirmed — already logged on send
      case MSG_TYPE.NODE_QUERY:        return this._phoneMesh.handlePhoneMessage(ws._sovereignId, ws, raw);
      case MSG_TYPE.FRAG_ANNOUNCE:     return this._phoneMesh.handlePhoneMessage(ws._sovereignId, ws, raw);
      case MSG_TYPE.FRAG_REQUEST:      return this._phoneMesh.handlePhoneMessage(ws._sovereignId, ws, raw);
      case MSG_TYPE.FRAG_DELIVER:      return this._phoneMesh.handlePhoneMessage(ws._sovereignId, ws, raw);
      case MSG_TYPE.MESH_HELLO:        return this._phoneMesh.handlePhoneMessage(ws._sovereignId, ws, raw);
    }
  }

  // ── Enrollment engine registration ────────────────────────────────────────
  // Called from index.js after both gateway and enrollment engine are started.

  setEnrollmentEngine(enrollmentEngine) {
    this._enrollmentEngine = enrollmentEngine;
  }

  // ── Legacy enrollment Step 1 — ENROLLMENT_REGISTER ───────────────────────
  // Old Flutter app sends this before BCH biometric verification was added.
  // It pre-generates a sovereign_id on the phone and registers the key pair.
  // We store the data on the ws object and send back ENROLLMENT_ACK so the
  // phone proceeds to step 2 (PALM_EMBEDDING_REGISTER).
  _handleLegacyEnrollRegister(ws, msg) {
    clearTimeout(ws._helloTimeout);
    const { sovereign_id, public_key } = msg;
    if (!sovereign_id || !public_key) {
      ws.send(JSON.stringify({ type: 'ENROLLMENT_ACK', success: false,
        error: 'MISSING_FIELDS', timestamp: Date.now() }));
      return;
    }
    // Stash for step 2
    ws._legacySovId    = sovereign_id;
    ws._legacyPubKey   = public_key;
    global.sovLog.info(`[GW] Legacy enroll step 1 from ${ws._remoteIP}: ${sovereign_id}`);
    ws.send(JSON.stringify({
      type:        'ENROLLMENT_ACK',
      success:     true,
      sovereign_id,
      timestamp:   Date.now(),
    }));
  }

  // ── Legacy PALM_DUPLICATE_CHECK — one-human-one-wallet enforcement ──────────
  // Compares the incoming 128-dim palm embedding against all enrolled citizens
  // using cosine similarity. Returns duplicate:true if a match exceeds the
  // configured threshold (env: PALM_DEDUP_THRESHOLD, default 0.92).
  // Same palm + different enrollment attempt = same person detected → blocked.
  _handleLegacyDuplicateCheck(ws, msg) {
    clearTimeout(ws._helloTimeout);
    try {
      const newEmbedding = JSON.parse(msg.embedding || '[]');
      if (!Array.isArray(newEmbedding) || newEmbedding.length !== 128) {
        global.sovLog.warn(`[GW] PALM_DUPLICATE_CHECK: invalid embedding (len=${Array.isArray(newEmbedding) ? newEmbedding.length : 'not-array'})`);
        return ws.send(JSON.stringify({
          type:      'PALM_DUPLICATE_RESULT',
          duplicate: false,
          error:     'Invalid embedding',
          timestamp: Date.now(),
        }));
      }
      // Threshold loaded from environment so the value never appears in source code
      const THRESHOLD = parseFloat(process.env.PALM_DEDUP_THRESHOLD || '0.92');
      // Tier-4 fix: stored templates are cancelable-transformed (R·embedding).
      // Transform the incoming embedding with the same R so the cosine match is
      // identical to the old plaintext one — the raw embedding is never compared.
      // network-seed-join-v1: without the network's seed this node would compare
      // the incoming scan in a different space from the replicated templates,
      // match nobody, and answer a confident "not a duplicate" — letting one
      // human enrol twice. Refuse instead. A node that cannot do the job
      // correctly must say so rather than guess.
      const _netSeed = require('../security/network_seed');
      if (!_netSeed.has()) {
        global.sovLog.error(
          '[GW] PALM_DUPLICATE_CHECK refused — this node has no network biometric seed yet ' +
          '(not joined/approved). Answering would risk admitting a duplicate enrolment.');
        return ws.send(JSON.stringify({
          type:      'PALM_DUPLICATE_RESULT',
          duplicate: false,
          error:     'NODE_NOT_READY_NO_NETWORK_SEED',
        }));
      }
      const _cancelable = require('../security/palm_cancelable');
      const newProtected = _cancelable.transform(_cancelable.getR(), newEmbedding);
      const all = this._db.getAllPalmEmbeddings();
      let maxSim = 0, matchedId = null, matchedHandType = null;
      for (const row of all) {
        try {
          const stored = JSON.parse(row.embedding_json);
          const sim = this._cosineSimilarity(newProtected, stored);
          if (sim > maxSim) {
            maxSim = sim;
            if (sim >= THRESHOLD) {
              matchedId       = row.sovereign_id;
              matchedHandType = row.hand_type || 'LEFT';
            }
          }
        } catch (_) { /* skip malformed row */ }
      }
      const isDuplicate = maxSim >= THRESHOLD;
      global.sovLog.info(
        `[GW] PALM_DUPLICATE_CHECK: checked ${all.length} embeddings — maxSim=${maxSim.toFixed(4)} — ${isDuplicate ? 'DUPLICATE → ' + matchedId : 'no match'}`
      );
      ws.send(JSON.stringify({
        type:         'PALM_DUPLICATE_RESULT',
        duplicate:    isDuplicate,
        sovereign_id: matchedId,
        similarity:   maxSim,
        hand_type:    matchedHandType,
        checked:      all.length,
        timestamp:    Date.now(),
      }));
    } catch (e) {
      global.sovLog.error(`[GW] PALM_DUPLICATE_CHECK error: ${e.message}`);
      ws.send(JSON.stringify({
        type:      'PALM_DUPLICATE_RESULT',
        duplicate: false,
        error:     e.message,
        timestamp: Date.now(),
      }));
    }
  }

  // ── Cosine similarity — used for palm biometric duplicate detection ──────────
  _cosineSimilarity(a, b) {
    if (a.length !== b.length) return 0;
    let dot = 0, nA = 0, nB = 0;
    for (let i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      nA  += a[i] * a[i];
      nB  += b[i] * b[i];
    }
    if (nA === 0 || nB === 0) return 0;
    return dot / (Math.sqrt(nA) * Math.sqrt(nB));
  }

  // ── HELLO — citizen authentication ────────────────────────────────────────

  _handleHello(ws, msg) {
    clearTimeout(ws._helloTimeout);

    // ── Field normalisation — backward compat with old relay_connector.dart ────
    // Old app sends: { type:'HELLO', sovereign_id, public_key_hex, version }
    //                (no signature, no timestamp)
    // New app sends: { op:'HL', sovereign_id, public_key, signature, timestamp }
    const sovereign_id         = msg.sovereign_id;
    const public_key           = msg.public_key || msg.public_key_hex || '';
    const signature            = msg.signature   || null;
    const timestamp            = msg.timestamp   || null;
    const messaging_public_key = msg.messaging_public_key || null;
    const palm_name            = msg.palm_name   || '';
    const legacyMode           = !signature;  // Old app — no signature in HELLO

    if (!sovereign_id || !public_key) {
      ws.close(4003, 'HELLO_MISSING_FIELDS');
      return;
    }

    if (!legacyMode) {
      // ── New-format HELLO: verify timestamp freshness and Ed25519 signature ───
      if (!timestamp || Math.abs(Date.now() - timestamp) > 60000) {
        // Clock-skew self-correction: send OUR time before closing so the app
        // can compute an offset, re-sign, and retry (else skewed devices loop forever).
        try { this._send(ws, MSG_TYPE.ERROR, { code: 'HELLO_STALE_TIMESTAMP', node_time: Date.now() }); } catch (_) {}
        ws.close(4004, 'HELLO_STALE_TIMESTAMP');
        return;
      }

      const payload = Buffer.from(`${sovereign_id}:${timestamp}`);
      let sigValid  = false;
      try {
        const pubKeyBytes = Buffer.from(public_key, 'hex');
        const sigBytes    = Buffer.from(signature, 'hex');
        sigValid = require('../security/node_identity').NodeIdentity.verify(payload, sigBytes, pubKeyBytes);
      } catch (_) {
        sigValid = false;
      }

      if (!sigValid) {
        ws.close(4005, 'HELLO_INVALID_SIGNATURE');
        return;
      }
    } else {
      // ── Legacy HELLO: no signature. Log warning; accept for backward compat. ─
      // Remove this branch once all apps are updated to sign HELLOs.
      global.sovLog.debug(`[GW] Legacy unsigned HELLO from ${sovereign_id} — upgrade app for full security`);
    }

    // Look up enrollment — citizen must be enrolled in the network
    const enrollment = this._db.getEnrollment(sovereign_id);

    // ── Bind the presented key to the enrolled key ───────────────────────────
    // The signature check above proves the caller holds the private key for the
    // public key THEY SUPPLIED. On its own that proves nothing about identity —
    // anyone can generate a keypair and claim any Sovereign ID with it. Without
    // this comparison, knowing a citizen's ID was enough to be authenticated as
    // them, and every downstream check (SENDER_MISMATCH, the per-transaction
    // signature) then verified against the impostor's own key and passed.
    //
    // Only enforced when we actually hold the enrollment: a citizen whose record
    // lives on another node is handled by the redirect below, and must not be
    // locked out by a node that has never seen them.
    if (enrollment && enrollment.public_key_hex && !legacyMode) {
      const presented = String(public_key || '').toLowerCase();
      const enrolled  = String(enrollment.public_key_hex || '').toLowerCase();
      if (presented !== enrolled) {
        global.sovLog.warn(
          `[HELLO] key mismatch for ${String(sovereign_id).slice(0, 20)} — ` +
          `presented ${presented.slice(0, 16)}... but enrolled key is ${enrolled.slice(0, 16)}...`);
        try { this._send(ws, MSG_TYPE.ERROR, { code: 'HELLO_KEY_MISMATCH' }); } catch (_) {}
        ws.close(4007, 'HELLO_KEY_MISMATCH');
        return;
      }
    }

    if (!enrollment) {
      // Not enrolled here — check if we know which node they belong to
      const presence = this._db.getCitizenPresence(sovereign_id);
      if (presence && presence.node_id !== this._identity.nodeId) {
        // Redirect to their home node
        this._send(ws, MSG_TYPE.ERROR, {
          code:    'CITIZEN_ON_OTHER_NODE',
          node_id: presence.node_id,
          address: presence.node_address,
        });
        ws.close(4006, 'WRONG_NODE');
        return;
      }
    }

    // Citizen authenticated
    ws._sovereignId = sovereign_id;
    ws._verified    = true;
    ws._publicKey   = public_key;
    ws._legacyMode  = legacyMode;  // true = old app — no per-message signature verification
    ws._connectedAt = Date.now();
    // Liveness wiring (king 2026-06-04): every authenticated login IS proof-of-life —
    // record it so allocation council selection + the inheritance dead-man logic have
    // real liveness data. (LIVENESS_CHECK is the explicit path; this is the passive one.)
    try { this._db.touchLiveness(sovereign_id); } catch (_) {}
    ws._lastSeen    = Date.now();

    // Register in active citizens map
    this._citizens.set(sovereign_id, { ws, connectedAt: ws._connectedAt });

    // Update presence in DB
    this._db.setPresenceOnline(sovereign_id, this._identity.nodeId, this._identity.publicAddress);

    // Store messaging public key if provided (for E2E encryption)
    if (messaging_public_key) {
      this._db.setMessagingPublicKey(sovereign_id, messaging_public_key);
    }

    // Store palm name if provided and row currently empty
    if (palm_name) {
      this._db.updatePalmNameIfEmpty(sovereign_id, palm_name);
    }

    // Register with phone mesh
    this._phoneMesh.handlePhoneConnected(sovereign_id, ws);

    // Send ACK
    this._send(ws, MSG_TYPE.HELLO_ACK, {
      node_id:   this._identity.nodeId,
      sovereign_id,
      connected_at: ws._connectedAt,
    });

    // Deliver any pending messages
    this._deliverPending(sovereign_id, ws);

    // Check for unclaimed UBI issuance epochs (push ISSUANCE_AVAILABLE if any)
    if (this._financialEngine) {
      this._financialEngine.checkIssuanceOnHello(sovereign_id, ws);
    }

    // Notify watchers on this node that citizen is online
    this._notifyWatchersOnline(sovereign_id);

    // Tell peer nodes this citizen is now online here
    this._peerMesh.broadcast('CITIZEN_ONLINE_RELAY', {
      sovereign_id,
      node_id:      this._identity.nodeId,
      node_address: this._identity.publicAddress,
    });
  }

  // ── Message send ──────────────────────────────────────────────────────────

  async _handleMessageSend(ws, msg) {
    const { to, msg_id, content, media_type, timestamp, signature } = msg;
    const from = ws._sovereignId;

    if (!to || !msg_id || !content) {
      this._send(ws, MSG_TYPE.ERROR, { code: 'MISSING_FIELDS', ref: msg_id });
      return;
    }

    // Verify message signature
    const payload = Buffer.from(`${msg_id}:${from}:${to}:${timestamp}`);
    let sigValid  = false;
    try {
      const pubKeyBytes = Buffer.from(ws._publicKey, 'hex');
      const sigBytes    = Buffer.from(signature || '', 'hex');
      sigValid = require('../security/node_identity').NodeIdentity.verify(payload, sigBytes, pubKeyBytes);
    } catch (_) {
      sigValid = false;
    }

    if (!sigValid) {
      this._send(ws, MSG_TYPE.ERROR, { code: 'INVALID_SIGNATURE', ref: msg_id });
      return;
    }

    // Store message metadata in DB (not content — content is E2E encrypted, relay never decrypts)
    this._db.storeMessageRecord({
      msg_id, from, to, media_type: media_type || 'text',
      created_at: timestamp || Date.now(),
    });

    // Try to deliver immediately if recipient is on this node
    const delivered = this._deliverToConnected(to, MSG_TYPE.MESSAGE_INCOMING, {
      msg_id, from, to, content, media_type, timestamp,
    });

    if (delivered) {
      this._send(ws, MSG_TYPE.MESSAGE_ACK, { msg_id, status: 'delivered' });
      return;
    }

    // Try to forward to peer node where recipient is registered
    const presence = this._db.getCitizenPresence(to);
    if (presence && presence.node_id !== this._identity.nodeId) {
      const forwarded = this._peerMesh.sendTo(presence.node_id, 'CITIZEN_MESSAGE_FORWARD', {
        to, from, msg_id, content, media_type, timestamp,
        type: MSG_TYPE.MESSAGE_INCOMING,
        payload: { msg_id, from, to, content, media_type, timestamp },
      });
      if (forwarded) {
        this._send(ws, MSG_TYPE.MESSAGE_ACK, { msg_id, status: 'delivered' });
        return;
      }
    }

    // Recipient offline — queue for delivery when they reconnect
    this._queueForOfflineCitizen(to, MSG_TYPE.MESSAGE_INCOMING, {
      msg_id, from, to, content, media_type, timestamp,
    });
    this._send(ws, MSG_TYPE.MESSAGE_ACK, { msg_id, status: 'offline' });
  }

  // ── Liveness check (king 2026-06-04 greenlight) ─────────────────────────────
  // Explicit proof-of-life from the app. Records sov_disc.liveness_ts (the column
  // allocation_engine's council selection reads). Requires an authenticated session.
  // ── Wallet-side external-platform registration (no inbound IP needed) ──────
  // The website owner registers their platform from the Flutter/desktop wallet:
  // the wallet connects OUT over WSS, signs the canonical payload with its
  // enrolled Ed25519 key, and DEDUCTS platform_register_fee SOV, crediting it to the
  // witness_operator pool. Supply is unchanged: the money moves, it is not
  // destroyed. The relay
  // delegates to the SAME shared core the HTTP endpoint uses (relayPool
  // .platformRegister), so logic never drifts between the two paths.
  _handlePlatformRegister(ws, msg) {
    const sovereignId = ws._sovereignId || msg.registering_sovereign_id;
    if (!sovereignId || !ws._verified) {
      return this._send(ws, MSG_TYPE.PLATFORM_REGISTER_RESULT, { success: false, error: 'AUTH_REQUIRED' });
    }
    // A connected citizen may only register under their OWN sovereign id
    // (the Ed25519 signature also enforces this inside the shared core).
    if (msg.registering_sovereign_id && msg.registering_sovereign_id !== sovereignId) {
      return this._send(ws, MSG_TYPE.PLATFORM_REGISTER_RESULT, { success: false, error: 'SOVEREIGN_ID_MISMATCH' });
    }
    if (!this._relayPool || typeof this._relayPool.platformRegister !== 'function') {
      return this._send(ws, MSG_TYPE.PLATFORM_REGISTER_RESULT, { success: false, error: 'REGISTRATION_UNAVAILABLE' });
    }
    try {
      const input = { ...msg, registering_sovereign_id: sovereignId };
      const reg = this._relayPool.platformRegister(input);
      const body = reg && reg.body ? { ...reg.body } : { success: false, error: 'INTERNAL_ERROR' };
      // Wallet path: surface the PLAINTEXT callback_secret over this WSS-TLS
      // channel so the owner can paste it into their site without nacl-box
      // decryption. Safe: the channel is TLS and the citizen owns this platform
      // (sig-verified). The HTTP path keeps returning ONLY the sealed secret.
      if (body.success && body.platform_id) {
        try {
          const row = this._db._db.prepare('SELECT callback_secret FROM sov_platforms WHERE platform_id = ?').get(body.platform_id);
          if (row && row.callback_secret) body.callback_secret = row.callback_secret;
        } catch (_) {}
      }
      // Generator (king's design): bake the owner's domain + platform_id + secret +
      // relay pool into a ready-to-install PHP plugin + README, zipped, so the owner
      // just downloads + drops it in their web root — zero manual config.
      if (body.success && body.callback_secret) {
        try {
          const { generateBundle } = require('./sdk_generator');
          const cleanDomain = (msg.domain || '').toLowerCase().replace(/^https?:\/\//, '').split('/')[0];
          const zip = generateBundle({
            domain: cleanDomain, platformId: body.platform_id,
            callbackSecret: body.callback_secret, returnUrl: msg.return_url || '',
            relays: body.canonical_relay_ips || [],
            nowIso: new Date().toISOString().slice(0, 10),
          });
          body.sdk_zip_base64 = zip.toString('base64');
          body.sdk_filename = 'sov-login-sdk-' + cleanDomain.replace(/[^a-z0-9.]/g, '_') + '.zip';
        } catch (e) { global.sovLog.warn('[GATEWAY] SDK bundle generation: ' + e.message); }
      }
      this._send(ws, MSG_TYPE.PLATFORM_REGISTER_RESULT, body);
    } catch (e) {
      global.sovLog.error('[GATEWAY] _handlePlatformRegister: ' + e.message);
      this._send(ws, MSG_TYPE.PLATFORM_REGISTER_RESULT, { success: false, error: 'INTERNAL_ERROR' });
    }
  }

    _handleLivenessCheck(ws, msg) {
    const sovereignId = ws._sovereignId || msg.sovereign_id;
    if (!sovereignId || !ws._verified) {
      return this._send(ws, MSG_TYPE.LIVENESS_RESULT, { success: false, error: 'AUTH_REQUIRED' });
    }
    const tsSec = this._db.touchLiveness(sovereignId);
    // Liveness is "fresh" for 30 days (matches allocation council thirtyDaysAgoSec window).
    const nextRequiredBy = (tsSec + 30 * 24 * 3600) * 1000;  // ms, for the app display
    this._send(ws, MSG_TYPE.LIVENESS_RESULT, {
      success: true, liveness_ts: tsSec, next_required_by: nextRequiredBy,
    });
  }

  // ── Balance query ──────────────────────────────────────────────────────────

  _handleBalanceQuery(ws, msg) {
    // Use ws._sovereignId (set by HELLO) as primary source.
    // Fall back to msg.sovereign_id so that wallet-file restore can query
    // balance immediately after key storage, before a fresh HELLO completes.
    const sovereignId = (ws._sovereignId && ws._sovereignId.length > 0)
      ? ws._sovereignId
      : (msg.sovereign_id || '');
    const disc        = this._db.readDisc(sovereignId);

    if (ws.readyState !== WebSocket.OPEN) return;

    // Guard: citizen must be enrolled. Return NOT_ENROLLED so Flutter cannot
    // create a ghost wallet from a seed phrase that has no enrollment on chain.
    if (!disc) {
      ws.send(JSON.stringify({
        op:           MSG_TYPE.BALANCE_RESULT,
        type:         'SOV_BALANCE_RESULT',
        sovereign_id: sovereignId,
        success:      false,
        error:        'NOT_ENROLLED',
      }));
      return;
    }

    const balSeeds = disc.balance_seeds;
    const spdSeeds = disc.spendable_seeds;
    ws.send(JSON.stringify({
      op:              MSG_TYPE.BALANCE_RESULT,
      type:            'SOV_BALANCE_RESULT',
      sovereign_id:    sovereignId,
      success:         true,
      seeds:           balSeeds,
      balance_seeds:   balSeeds,
      spendable_seeds: spdSeeds,
      locked_seeds:    balSeeds - spdSeeds,
      _n:              this._identity.nodeId.slice(0, 8),
    }));
  }

  // ── TX history ────────────────────────────────────────────────────────────

  // Client confirms it received & stored these txs → delete the pending records
  // (king's design: a queued transfer is deleted only once the client confirms).
  _handleTxHistoryConfirmed(ws, msg) {
    const sovereignId = ws._sovereignId;
    const ids = Array.isArray(msg.confirmed_tx_ids) ? msg.confirmed_tx_ids : [];
    let deleted = 0;
    try { if (sovereignId && ids.length && this._db.deletePendingByTxIds) deleted = this._db.deletePendingByTxIds(sovereignId, ids); } catch (_) {}
    try { ws.send(JSON.stringify({ op: 'TD', type: 'TX_HISTORY_DELETE_RESULT', success: true, deleted })); } catch (_) {}
  }

  _handleTxHistoryRequest(ws, msg) {
    const sovereignId = ws._sovereignId;
    const { after_ts, limit } = msg;

    const txs = this._db.getTransactionHistory(sovereignId, {
      after_ts: after_ts || 0,
      limit:    Math.min(limit || 50, 200),
    });

    // Include balance from disc so Flutter can update wallet immediately on sync.
    // CRITICAL: must use TX_HISTORY_RESULT ('TR') not BALANCE_RESULT ('BR').
    // Flutter's syncTransactionHistory() uses sendAndWait(responseType:'TX_HISTORY_RESULT')
    // and will ALWAYS time out if we return BALANCE_RESULT ('BR').
    const disc     = this._db.readDisc(sovereignId);
    const balSeeds = disc ? disc.balance_seeds : 0;

    this._send(ws, MSG_TYPE.TX_HISTORY_RESULT, {
      sovereign_id:  sovereignId,
      transactions:  txs,
      balance:       balSeeds / 1_000_000,
      balance_seeds: balSeeds,
    });
  }

  // ── Ledger sync (recovery screen after seed restore) ─────────────────────

  _handleLedgerSyncRequest(ws, msg) {
    const sovereignId = ws._sovereignId;
    if (!sovereignId) return;

    const disc     = this._db.readDisc(sovereignId);
    const balSeeds = disc ? disc.balance_seeds : 0;
    const txs      = this._db.getTransactionHistory(sovereignId, { after_ts: 0, limit: 50 });

    // Return stored palm name so the app can restore the correct citizen name
    // without requiring biometric re-enrollment.
    let palmName = '';
    try {
      const enrollRow = this._db._db.prepare(
        'SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?'
      ).get(sovereignId);
      palmName = (enrollRow && enrollRow.palm_name) ? enrollRow.palm_name : '';
    } catch (_) {}

    if (ws.readyState !== 1 /* WebSocket.OPEN */) return;
    ws.send(JSON.stringify({
      op:            MSG_TYPE.LEDGER_SYNC_RESPONSE,
      type:          'LEDGER_SYNC_RESPONSE',
      sovereign_id:  sovereignId,
      balance:       balSeeds / 1_000_000,
      balance_seeds: balSeeds,
      transactions:  txs,
      palm_name:     palmName,
      _n:            this._identity.nodeId.slice(0, 8),
    }));
    global.sovLog && global.sovLog.debug(`[GW] Ledger sync: ${sovereignId} — ${balSeeds} seeds, ${txs.length} txs`);
  }

  // ── Read receipt ──────────────────────────────────────────────────────────

  _handleMessageRead(ws, msg) {
    const { msg_id, conversation_id } = msg;
    if (!msg_id) return;

    // Forward read receipt to the original sender
    const record = this._db.getMessageRecord(msg_id);
    if (!record) return;

    const delivered = this._deliverToConnected(record.from_sovereign_id, MSG_TYPE.MESSAGE_READ_RECEIPT, {
      msg_id, read_at: Date.now(), reader_id: ws._sovereignId,
    });

    if (!delivered) {
      // Forward to peer node
      const presence = this._db.getCitizenPresence(record.from_sovereign_id);
      if (presence && presence.node_id !== this._identity.nodeId) {
        this._peerMesh.broadcast('READ_RECEIPT_FORWARD', {
          to:      record.from_sovereign_id,
          msg_id,
          read_at: Date.now(),
          reader_id: ws._sovereignId,
        });
      }
    }
  }

  // ── Watch list management ──────────────────────────────────────────────────

  _handleWatchAdd(ws, msg) {
    const watcherId  = msg.watcher_sovereign_id || ws._sovereignId;
    const watchingId = msg.watching_sovereign_id;
    if (!watchingId) return;

    this._db.addWatch(watcherId, watchingId);

    // If they are already online, notify immediately
    if (this._citizens.has(watchingId)) {
      this._deliverToConnected(watcherId, MSG_TYPE.CITIZEN_ONLINE, {
        sovereign_id: watchingId,
        ts:           Date.now(),
      });
    }
  }

  _handleWatchRemove(ws, msg) {
    this._db.removeWatch(ws._sovereignId, msg.watching_sovereign_id);
  }

  // ── Cross-relay events ─────────────────────────────────────────────────────

  _handleCrossRelayOnline(msg) {
    const { sovereign_id } = msg;
    this._notifyWatchersOnline(sovereign_id);
  }

  // ── Delivery helpers ───────────────────────────────────────────────────────

  // Try to deliver to a connected citizen — returns true if delivered
  _deliverToConnected(sovereignId, op, payload) {
    const citizen = this._citizens.get(sovereignId);
    if (!citizen || citizen.ws.readyState !== WebSocket.OPEN) return false;
    this._send(citizen.ws, op, payload);
    return true;
  }

  // Queue a message for an offline citizen
  _queueForOfflineCitizen(sovereignId, op, payload) {
    const queue = this._pendingQueue.get(sovereignId) || [];
    queue.push({ op, payload, ts: Date.now() });
    // Keep max 100 pending messages per citizen
    if (queue.length > 100) queue.shift();
    this._pendingQueue.set(sovereignId, queue);

    // Also persist to DB for durability (survives node restart)
    this._db.queuePendingMessage(sovereignId, op, payload);
  }

  // Deliver all pending messages when citizen reconnects
  _deliverPending(sovereignId, ws) {
    // From memory queue (fast path)
    const memQueue = this._pendingQueue.get(sovereignId) || [];
    for (const item of memQueue) {
      this._send(ws, item.op, item.payload);
    }
    this._pendingQueue.delete(sovereignId);

    // From DB (in case node restarted while citizen was offline)
    const dbQueue = this._db.getPendingMessages(sovereignId);
    for (const item of dbQueue) {
      this._send(ws, item.op, item.payload);
    }
    this._db.clearPendingMessages(sovereignId);
  }

  // Notify all watchers on this node that sovereignId came online
  _notifyWatchersOnline(sovereignId) {
    const watchers = this._db.getWatchersFor(sovereignId);
    for (const watcherId of watchers) {
      this._deliverToConnected(watcherId, MSG_TYPE.CITIZEN_ONLINE, {
        sovereign_id: sovereignId,
        ts:           Date.now(),
      });
    }
  }

  // ── Wire send ─────────────────────────────────────────────────────────────
  // Includes BOTH `op` (2-char) AND `type` (full string) in every outbound
  // message so old relay_connector.dart (reads `type`) and future apps (reads
  // `op`) both understand the response. The `type` field is derived from the
  // reverse of MSG_TYPE. Remove the `type` field once all apps migrate.

  _send(ws, op, payload) {
    if (ws.readyState !== WebSocket.OPEN) return;
    try {
      // Build reverse lookup lazily (once per process)
      if (!CitizenGateway._opToType) {
        CitizenGateway._opToType = {};
        for (const [name, code] of Object.entries(MSG_TYPE)) {
          CitizenGateway._opToType[code] = name;
        }
      }
      const type = CitizenGateway._opToType[op] || op;
      ws.send(JSON.stringify({ op, type, ...payload, _n: this._identity.nodeId.slice(0, 8) }));
    } catch (_) {}
  }

  // ── Rate limiting ──────────────────────────────────────────────────────────

  _checkRateLimit(sovereignId) {
    const now    = Date.now();
    const state  = this._rateLimits.get(sovereignId) || { count: 0, windowStart: now };

    if (now - state.windowStart > RATE_LIMIT_WINDOW_MS) {
      state.count       = 1;
      state.windowStart = now;
    } else {
      state.count++;
    }

    this._rateLimits.set(sovereignId, state);
    return state.count <= RATE_LIMIT_MSG_PER_SEC;
  }

  // ── Ping loop — keep mobile connections alive through NAT ─────────────────

  _startPingLoop() {
    this._pingTimer = setInterval(() => {
      const now = Date.now();
      for (const [sovereignId, citizen] of this._citizens) {
        const ws = citizen.ws;
        if (ws.readyState === WebSocket.OPEN) {
          // Terminate if no pong received in 2 full ping intervals
          if (ws._lastSeen && now - ws._lastSeen > PING_INTERVAL_MS * 2) {
            ws.terminate();
          } else {
            ws.ping();
          }
        }
      }
    }, PING_INTERVAL_MS);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  connectedCount() { return this._citizens.size; }

  // OPERATOR ENFORCEMENT (king 2026-08-14): drop every connected citizen — called by
  // the operator engine when this node loses operator authorization (signup rejected).
  // New connections are already refused in _handleConnection; this clears any that were
  // accepted during the signup window.
  closeAllCitizens(reason = 'OPERATOR_NOT_AUTHORIZED') {
    let n = 0;
    for (const [, citizen] of this._citizens) {
      try { if (citizen && citizen.ws) { citizen.ws.close(4090, reason); n++; } } catch (_) {}
    }
    if (n) global.sovLog.warn(`[GW] Closed ${n} citizen connection(s): ${reason}`);
    return n;
  }

  isConnected(sovereignId) { return this._citizens.has(sovereignId); }

  // Returns the WebSocket connection for a citizen, or null
  getConnection(sovereignId) {
    const citizen = this._citizens.get(sovereignId);
    return (citizen && citizen.ws.readyState === WebSocket.OPEN) ? citizen.ws : null;
  }

  // Called by protocol engine to push messages to a citizen
  push(sovereignId, op, payload) {
    return this._deliverToConnected(sovereignId, op, payload);
  }

  // Queue a message for offline delivery (public wrapper for engines)
  queue(sovereignId, op, payload) {
    this._queueForOfflineCitizen(sovereignId, op, payload);
  }

  // Deliver if connected, otherwise queue for reconnect (convenience for engines)
  deliverOrQueue(sovereignId, op, payload) {
    const delivered = this._deliverToConnected(sovereignId, op, payload);
    if (!delivered) {
      this._queueForOfflineCitizen(sovereignId, op, payload);
    }
    return delivered;
  }

  // Register message and group engines
  setMessageEngine(messageEngine) {
    this._messageEngine = messageEngine;
    // When a citizen reconnects, flush their message queue
    const original_deliverPending = this._deliverPending.bind(this);
    this._deliverPending = (sovereignId, ws) => {
      original_deliverPending(sovereignId, ws);
      messageEngine.onCitizenReconnected(sovereignId, ws);
    };
  }

  setGroupEngine(groupEngine) {
    this._groupEngine = groupEngine;
  }

  setFinancialEngine(financialEngine) {
    this._financialEngine = financialEngine;
  }

  setExchangeEngine(exchangeEngine) {
    this._exchangeEngine = exchangeEngine;
  }

  setJusticeEngine(justiceEngine) {
    this._justiceEngine = justiceEngine;
  }

  setGovernanceEngine(governanceEngine) {
    this._governanceEngine = governanceEngine;
  }

  setSocialEngine(socialEngine) {
    this._socialEngine = socialEngine;
  }

  setCallsEngine(callsEngine) {
    this._callsEngine = callsEngine;
  }

  setPioneerEngine(pioneerEngine) {
    this._pioneerEngine = pioneerEngine;
  }

  setAllocationEngine(allocationEngine) {
    this._allocationEngine = allocationEngine;
  }

  setOperatorEngine(operatorEngine) {
    this._operatorEngine = operatorEngine;
  }

  setRelayPool(relayPool) {
    this._relayPool = relayPool;
  }

  // ── Relay list — phone requests all known relay nodes for failover ────────
  // Old relay_connector.dart sends RELAY_LIST_REQUEST after connecting.
  // We return every non-stale node from the relay pool so the phone can:
  //   1. Cache them locally
  //   2. Race them all on next connect() call
  //   3. Automatically switch to a different node if this one goes offline
  // Response uses RELAY_LIST_RESPONSE (old WSS name) so relay_connector.dart
  // routes it through _handleRelayListResponse without any changes.

  _handleRelayListRequest(ws, msg) {
    const pool  = this._relayPool;
    const relays = [];

    // ── IP masking rule — NEVER expose raw VPS IPs in WebSocket messages ──────
    // IPs are included (required for phone TCP connections) but names/labels are
    // always opaque node identifiers derived from the node's public key hash.
    // This prevents a passive observer from trivially mapping node IDs to IPs.
    const _nodeTag = (nodeId) => 'node_' + nodeId.slice(0, 12);

    // Always include this node itself
    relays.push({
      relay_id:  _nodeTag(this._identity.nodeId),   // opaque tag — not raw IP
      ip:        this._identity.publicAddress ? this._identity.publicAddress.split(':')[0] : '',
      port:      443,
      name:      process.env.RELAY_ID || 'SOV Node', // human label from config
      nickname:  process.env.RELAY_ID || 'SOV Node',
      added_at:  Date.now(),
    });

    // Add all other known nodes from the relay pool
    if (pool) {
      const addrs = (typeof pool.getAliveAddresses === 'function') ? pool.getAliveAddresses(50) : pool.getBootstrapAddresses(50);
      let peerIdx = 1;
      for (const addr of addrs) {
        // addr is "host:port" (peer mesh uses 7771) or just "host"
        // ALWAYS return port 443 — citizens connect via the TLS citizen gateway,
        // NOT the peer mesh port. The relay pool stores peer mesh addresses (7771)
        // which must never be sent to phones as their WebSocket endpoint.
        const parts = addr.split(':');
        const ip    = parts[0];
        const port  = 443; // Always 443 for citizen WSS — peer mesh is on 7771
        if (!ip || relays.some(r => r.ip === ip)) continue;
        // Derive opaque tag from IP hash — consistent but non-revealing
        const ipTag  = require('crypto').createHash('sha256').update(ip).digest('hex').slice(0, 12);
        const label  = `SOV Node ${peerIdx++}`;
        relays.push({
          relay_id:  'node_' + ipTag,   // opaque tag — not raw IP
          ip,
          port,
          name:      label,             // human-readable label without IP
          nickname:  label,
          added_at:  Date.now(),
        });
      }
    }

    // Circuit-relay: advertise the NAT'd nodes WE front, so a citizen learns it can
    // reach node N by connecting to us (R) and tagging target_node_id=N in its frames.
    if (this._circuitRelay && typeof this._circuitRelay.relayedEntries === 'function') {
      try { for (const e of this._circuitRelay.relayedEntries()) relays.push(e); } catch (_) {}
    }

    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({
      op:     MSG_TYPE.RELAY_LIST_RESULT,
      type:   'RELAY_LIST_RESPONSE',   // old relay_connector.dart handles this type
      relays,
      _n:     this._identity.nodeId.slice(0, 8),
    }));

    global.sovLog.debug(`[GW] Sent relay list (${relays.length} nodes) to ${ws._sovereignId || ws._remoteIP}`);
  }

  // ── Node stats — for node_status_screen.dart ─────────────────────────────
  // Returns live statistics about this node. Accepts both 'NODE_STATS' (new op
  // 'ZS') and old relay_connector.dart format 'NETWORK_STATS' (also maps to 'ZS'
  // via LEGACY_TYPE_MAP). All fields match what network_stats_screen.dart expects.

  _handleNodeStats(ws, msg) {
    const uptimeMs  = Date.now() - this._startTime;
    const uptimeSec = Math.floor(uptimeMs / 1000);

    // Core node stats
    // NOTE: node_address is intentionally omitted — raw IPs must not be sent over WebSocket.
    //       relay_id uses the RELAY_ID env label (e.g. "VPS1") for human display.
    const stats = {
      node_id:            this._identity.nodeId,
      relay_id:           process.env.RELAY_ID || 'SOV Node',  // human label, never raw IP
      enrolled_citizens:  this._db.getEnrolledCount ? this._db.getEnrolledCount() : 0,
      connected_citizens: this._citizens.size,
      active_relays:      (this._peerMesh.peerCount ? this._peerMesh.peerCount() : 0) + 1,
      peer_count:         this._peerMesh.peerCount ? this._peerMesh.peerCount() : 0,
      uptime_sec:         uptimeSec,
      version:            (() => { try { return require('../../package.json').version; } catch(_) { return '1.0.0'; } })(),
    };

    // Governance + justice stats
    try {
      if (this._governanceEngine) {
        const govStats = this._governanceEngine.getStats ? this._governanceEngine.getStats() : {};
        stats.open_polls     = govStats.open_polls     ?? 0;
        stats.open_disputes  = govStats.open_disputes  ?? 0;
      }
    } catch (_) {}

    // Financial stats (total SOV in circulation)
    try {
      const totalSeeds = this._db.getTotalCirculation ? this._db.getTotalCirculation() : 0;
      stats.total_sov_seeds    = totalSeeds;
      stats.transfers_24h      = this._db.getTransferCount24h ? this._db.getTransferCount24h() : 0;
      stats.volume_seeds_24h   = this._db.getTransferVolume24h ? this._db.getTransferVolume24h() : 0;
    } catch (_) {}

    // Operator-specific stats (earnings, proof score)
    try {
      if (this._operatorEngine) {
        const reg = this._operatorEngine.getRegistrationInfo ? this._operatorEngine.getRegistrationInfo() : {};
        stats.operator_id        = reg.operatorId       || '';
        stats.is_registered      = reg.isRegistered     || false;
        stats.proof_score        = reg.proofScore        || 0;
        // LIVE network size = verified peers + self. This replaces the old
        // sov_operator_registry active-count (which included operators whose nodes
        // are long dead), so the operator card no longer contradicts Peer/Known Nodes.
        stats.live_nodes         = (this._peerMesh && this._peerMesh.peerCount ? this._peerMesh.peerCount() : 0) + 1;
        stats.registered_nodes   = stats.live_nodes;   // kept for app back-compat (same live number)
        stats.network_nodes      = stats.live_nodes;
        // Operators-ever-registered kept as a SEPARATE, clearly-named field for the
        // operator dashboard — not a node count shown next to Peer/Known Nodes.
        stats.operators_registered = this._operatorEngine.getRegisteredNodeCount
          ? this._operatorEngine.getRegisteredNodeCount() : 0;
      }
    } catch (_) {}

    // Send with both op code (new protocol) and relay_connector.dart type name.
    // relay_connector.dart getNodeStats() waits for responseType:'NODE_STATS_RESULT'
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({
      op:   MSG_TYPE.NODE_STATS_RESULT,
      type: 'NODE_STATS_RESULT',   // relay_connector.dart sendAndWait matches on msg['type']
      ...stats,
      _n:   this._identity.nodeId.slice(0, 8),
    }));
  }

  // Broadcast an op to every connected citizen (used by governance for live tally updates)
  pushToAll(op, payload) {
    for (const citizen of this._citizens.values()) {
      if (citizen.ws.readyState === WebSocket.OPEN) {
        this._send(citizen.ws, op, payload);
      }
    }
  }

  stop() {
    if (this._pingTimer) clearInterval(this._pingTimer);
    for (const citizen of this._citizens.values()) {
      try { citizen.ws.close(); } catch (_) {}
    }
    if (this._server) this._server.close();
  }
}

module.exports = { CitizenGateway, MSG_TYPE };
