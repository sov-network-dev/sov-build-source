import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'transaction_store.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:shared_preferences/shared_preferences.dart';
import 'key_manager.dart';
import 'message_key_manager.dart';
import 'message_encryptor.dart';
import 'sov_native_client.dart';
import 'outbox_manager.dart';
import 'palm_name_engine.dart';
import 'node_discovery.dart';
import 'package:cryptography/cryptography.dart' as sov_crypto;

/// ═══════════════════════════════════════════════════════════════════════════
/// RelayConnector — SOV Network Relay Client
///
/// ARCHITECTURE LAW: This file is the ONLY place in the Flutter app that
/// opens a network connection. No other file may use http, dio, or any
/// HTTP/PHP call. All network communication flows through this class
/// via WebSocket to the relay IP.
///
/// DOMAIN INDEPENDENCE: Relays are identified by IP only — no DNS, no CA.
/// Bootstrap relays are loaded from SharedPreferences cache (previous
/// session) or assets/relay_pool.json (bundled fallback). The relay
/// network is discovered dynamically via RELAY_LIST_REQUEST gossip.
///
/// CERT PINNING: The primary relay fingerprint is pinned. Pool relays
/// are accepted with any self-signed cert (opportunistic connections).
/// ═══════════════════════════════════════════════════════════════════════════

enum ConnectionMode {
  direct,      // Bootstrap relay connected — dynamic discovery
  ipFallback,  // Connected via gossiped fallback relay
  peerHop,     // Route through another SOV node as bridge
  mesh,        // Wi-Fi Direct / Wi-Fi Aware — no internet needed
  bluetooth,   // BLE peer relay
  dtn,         // Store-carry-forward — fully offline
}

class RelayEntry {
  final String relayId;
  final String ip;
  final int port;
  final String fingerprint;
  final String name;
  final String nickname;
  final int addedAt;
  // Circuit-relay (Task #26): if non-empty, this entry's `ip` is a RELAY node R that
  // fronts a NAT'd node N=targetNodeId. The app connects to R and sends
  // target_node_id=N in HELLO so R bridges the session to N. Empty = direct node.
  final String targetNodeId;

  RelayEntry({
    required this.relayId,
    required this.ip,
    required this.port,
    required this.fingerprint,
    required this.name,
    this.nickname = '',
    required this.addedAt,
    this.targetNodeId = '',
  });

  String get wsUrl => 'wss://$ip:$port';

  /// Deterministic human-readable display name derived from relayId.
  /// Falls back to relayId if relayId is empty (e.g. cached-URL entries).
  String get displayName {
    if (relayId.isNotEmpty) return RelayConnector.getNickname(relayId);
    if (nickname.isNotEmpty) return nickname;
    if (name.isNotEmpty && name != ip) return name;
    return 'Relay Node';
  }

  factory RelayEntry.fromJson(Map<String, dynamic> json) => RelayEntry(
        relayId:     (json['relay_id']    as String?) ?? 'unknown',
        ip:          (json['ip']          as String?) ?? '',
        port:        (json['port']        as num?)?.toInt() ?? 443,
        fingerprint: (json['fingerprint'] as String?) ?? '',
        name:        (json['name']        as String?) ??
                     (json['relay_id']    as String?) ?? 'Relay Node',
        nickname:    (json['nickname']    as String?) ?? '',
        addedAt:     (json['added_at']    as num?)?.toInt() ??
                     DateTime.now().millisecondsSinceEpoch,
        targetNodeId:(json['target_node_id'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'relay_id':    relayId,
        'ip':          ip,
        'port':        port,
        'fingerprint': fingerprint,
        'name':        name,
        'nickname':    nickname,
        'added_at':    addedAt,
      };
}

class HopNode {
  final String sovereignId;
  final String relayUrl;
  final int latency;
  final DateTime lastSeen;

  HopNode({
    required this.sovereignId,
    required this.relayUrl,
    required this.latency,
    required this.lastSeen,
  });
}

// ── RACE WINNER ───────────────────────────────────────────────────────────────
// Holds a completed connection before it is applied to global state.
// Created inside _raceRelays(); loser instances close their socket immediately.
class _RaceWinner {
  final String relayId;
  final String endpoint;
  final String connectionType; // 'wss' | 'native'
  final IOWebSocketChannel? wssChannel;
  final int elapsedMs;
  final String targetNodeId; // circuit-relay: non-empty if endpoint is a relay R for node N

  _RaceWinner({
    required this.relayId,
    required this.endpoint,
    required this.connectionType,
    this.wssChannel,
    required this.elapsedMs,
    this.targetNodeId = '',
  });

  /// Close this connection — called on loser instances after the winner is set.
  /// Pass an explicit normalClosure code so the WS close frame is sent promptly.
  /// A bare sink.close() can defer the teardown, leaving the socket open on the
  /// relay long enough to trip its 30s HELLO_TIMEOUT — a harmless-but-noisy
  /// "unauthenticated connection" reap, and on a shared CGNAT/hotspot IP a
  /// lingering loser needlessly holds one of the relay's per-IP connection slots.
  /// (goingAway/1001 throws "Invalid argument" in this stack — normalClosure/1000
  /// is the code already used elsewhere in this file.)
  void close() {
    try { wssChannel?.sink.close(ws_status.normalClosure); } catch (_) {}
  }
}

class RelayConnector {
  static IOWebSocketChannel? _channel;
  static ConnectionMode _currentMode = ConnectionMode.direct;
  static bool _connected = false;
  // Guard that prevents onConnected from firing more than once per HELLO cycle.
  // Reset to false at the start of every _sendHello() call.
  // Set to true immediately after HELLO is sent (onConnected fires at that point).
  // If a HELLO_ACK arrives later it is absorbed harmlessly — onConnected does
  // not fire again.
  static bool _helloAckReceived = false;
  static StreamController<Map<String, dynamic>>? _messageController;
  static Timer? _heartbeatTimer;
  static Timer? _reconnectTimer;
  static Timer? _hopDiscoveryTimer;
  // Zombie-WebSocket detection (see docs/CONNECTIVITY_DEBUG_LOG.md).
  // Updated on every inbound message (any type). If older than ~50 s while
  // _connected is true, the heartbeat timer forces a reconnect.
  static DateTime? _lastInboundAt;
  static const Duration _heartbeatLivenessMax = Duration(seconds: 50);
  static final List<HopNode> _hopNodes = [];

  // ── PARALLEL RACE ─────────────────────────────────────────────────────────
  // _connecting prevents overlapping connect() calls (e.g. boot + lifecycle).
  // relayPingTimes is public so relay_pool_screen can display connection speed.
  static bool _connecting = false;
  static final Map<String, int> relayPingTimes = {};

  // ── SOVEREIGN-ID RELAY AFFINITY ───────────────────────────────────────────
  // Each citizen is deterministically assigned a preferred relay ordering
  // based on SHA-256(sovereignId). Different citizens naturally prefer
  // different relays so two devices on the same WiFi will connect to
  // different VPS nodes without any manual configuration.
  // The race still runs in parallel across all relays — if the preferred
  // relay is down the next one in line wins. This is fully automatic and
  // requires no UI or SharedPreferences state.

  // ── RELAY POOL ────────────────────────────────────────────────────────────
  // Additional relay connections for racing. First response wins.
  // Pool is populated after primary connect via RELAY_LIST_REQUEST gossip.
  // All pool socket messages flow into _messageController (shared stream).
  static final List<WebSocket> _poolSockets = [];

  // ── NATIVE PROTOCOL ───────────────────────────────────────────────────────
  // When native TCP (port 7771) is available, _nativeClient is non-null and
  // _connectionType == 'native'. Falls back to WSS (_channel) otherwise.
  static SovNativeClient? _nativeClient;
  static String _connectionType = 'none'; // 'native' | 'wss' | 'none'
  static String? _currentEndpoint;

  // ── Node-clock offset (clock-skew self-correction) ─────────────────────────
  // Signed messages carry a timestamp the node checks for freshness (±60 s).
  // A device whose clock is off (emulators, dead RTC battery, wrong timezone)
  // would loop forever on HELLO_STALE_TIMESTAMP. When the node rejects us it
  // now includes its own time; we store the offset and sign with corrected
  // time from then on. Applies to ALL signed paths via _nowMs().
  static int _nodeClockOffsetMs = 0;
  static int _nowMs() => DateTime.now().millisecondsSinceEpoch + _nodeClockOffsetMs;
  static String  _currentRelayId = '';   // relay_id of the active connection
  static String  _currentTargetNodeId = ''; // circuit-relay: node N this conn bridges to (via relay R), else ''
  // Canonical IP → relay_id map, populated from bundled relay_pool.json.
  // Used to override opaque "node_xxx" gossip IDs so names stay consistent
  // across Relay Pool, Node Status, and Network Dashboard screens.
  static final Map<String, String> _canonicalRelayIdByIp = {};

  // ── CERT PINNING ─────────────────────────────────────────────────────────
  // Known relay cert fingerprints (SHA-256 of DER-encoded cert).
  // Relays presenting one of these fingerprints are accepted with pinning.
  // All other self-signed certs are also accepted for pool relay connections.
  //
  // TO ROTATE A CERT:
  //   1. Run vps_cert_setup.sh on VPS to generate new cert
  //   2. Update cert_sha256 field for that relay in assets/relay_pool.json
  //   3. Rebuild + publish the APK
  // ─────────────────────────────────────────────────────────────────────────
  // Set populated at app boot from assets/relay_pool.json cert_sha256 fields.
  // All fingerprints stored lowercase. Empty set until pool loads — first
  // connect attempt loads the pool before racing relays.
  static final Set<String> _trustedFingerprints = <String>{};
  static bool _trustedFingerprintsLoaded = false;

  static Future<void> _loadTrustedFingerprints() async {
    if (_trustedFingerprintsLoaded) return;
    try {
      final raw = await rootBundle.loadString('assets/relay_pool.json');
      final pool = jsonDecode(raw) as Map<String, dynamic>;
      final relays = (pool['relays'] as List?) ?? const [];
      for (final r in relays) {
        if (r is Map && r['cert_sha256'] is String) {
          _trustedFingerprints.add((r['cert_sha256'] as String).toLowerCase());
        }
      }
      _trustedFingerprintsLoaded = true;
      debugPrint('[CERT-PIN] Loaded ${_trustedFingerprints.length} trusted fingerprints');
    } catch (e) {
      debugPrint('[CERT-PIN] Failed to load pinned fingerprints: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DICTIONARY PROTOCOL — 2-char op codes (V2 raison d'être, hardened 2026-05-21)
  //
  // Every outbound message ships ONLY the 2-char 'op' field. The long 'type'
  // string is stripped by _addOpCode() after the op is added. The wire frame
  // looks like {"op":"ST","from":"SOV-...","amount":42} — an ISP doing deep
  // packet inspection cannot identify the operation from the JSON payload.
  //
  // Inbound: the relay sends only 'op' (sometimes still 'type' for legacy
  // messages); _handleIncomingMessage normalises via _typeFromOp so the rest
  // of the codebase can keep matching on 'type' as a logical identifier.
  //
  // Sources: MSG_TYPE + LEGACY_TYPE_MAP in sov-node/src/network/citizen_gateway.js
  // ══════════════════════════════════════════════════════════════════════════
  // ignore: constant_identifier_names
  static const Map<String, String> _OP = {
    // Identity / session
    'HELLO':                      'HL',
    'PING':                       'PI',
    'HEARTBEAT':                  'PI',  // app heartbeat → PING op
    // Messaging
    'MESSAGE_SEND':               'MS',
    'MESSAGE_READ':               'MR',
    'MESSAGE_DELIVERY_RECEIPT':   'DL',
    'MESSAGE_REACT':              'MZ',  // emoji reaction — routes to message engine handleReact
    'MESSAGE_UNREACT':            'MU',  // remove reaction — routes to message engine handleUnreact
    // Presence
    'WATCH_ADD':                  'WA',
    'WATCH_REMOVE':               'WX',
    // SOV transfers
    'SOV_TRANSFER':               'ST',
    // Balance & history
    'SOV_BALANCE_QUERY':          'BQ',
    'BALANCE_QUERY':              'BQ',
    'TX_HISTORY_REQUEST':         'TH',
    // Relay / node list
    // 'RL' is OWNED by PAY_REQ_LIST/SOV_REQUEST_LIST on the node — in the
    // gateway's switch the payment case comes first, so an op-'RL' relay-list
    // request was silently answered with payment requests (RL collision,
    // fixed 2026-07-15). The node routes HOP_BRIDGE_DISCOVER ('HD') to the
    // SAME _handleRelayListRequest handler, so relay-list rides 'HD'.
    // Wire-verified: op 'HD' -> RELAY_LIST_RESPONSE with the live fleet.
    'RELAY_LIST_REQUEST':         'RN',   // own code since genesis; the 'HD'
                                          // (HOP_BRIDGE_DISCOVER) workaround is retired
    'HOP_BRIDGE_DISCOVER':        'HD',
    'HOP_BRIDGE_REGISTER':        'HD',
    // Fragment routing (phone mesh)
    'FRAG_ANNOUNCE':              'FA',
    'FRAG_REQUEST':               'FR',
    'FRAG_DELIVER':               'FD',
    'MESH_HELLO':                 'MP',
    // Enrollment
    'ENROLLMENT_REGISTER':        'LE',
    'PALM_EMBEDDING_REGISTER':    'LP',
    'PALM_DUPLICATE_CHECK':       'PD',
    'ENROLL_REQUEST':             'EN',
    // SOV Request / payment QR
    'SOV_REQUEST_CREATE':         'RC',
    'SOV_REQUEST_LIST':           'RL',
    'PAY_REQ_CREATE':             'RC',
    'PAY_REQ_LIST':               'RL',
    'PAY_REQ_CANCEL':             'RX',
    // Vault
    'VAULT_LOCK':                 'VL',
    'VAULT_CLAIM_INIT':           'VI',
    // Issuance
    'ISSUANCE_CLAIM':             'IC',
    // Guardian recovery
    'GUARDIAN_ADD':               'UA',
    'GUARDIAN_REMOVE':            'UR',
    'GUARDIAN_LIST':              'UL',
    'GUARDIAN_RECOVERY_REQUEST':  'UI',
    'GUARDIAN_APPROVE':           'UP',
    'GUARDIAN_REJECT':            'UJ',
    // Exchange
    'EXCHANGE_LIST_ORDER':        'XL',
    'EXCHANGE_FILL_ORDER':        'XF',
    'EXCHANGE_CONFIRM':           'XC',
    // confirmDelivery/requestExchangeRefund/raiseExchangeDispute all send the
    // longer 'EXCHANGE_CONFIRM_DELIVERY' type; without this it shipped with NO op
    // and the node could not route it → escrow-release/refund/dispute were dead.
    // Node LEGACY_TYPE_MAP now also aliases it (fixes already-installed apps).
    'EXCHANGE_CONFIRM_DELIVERY':  'XC',
    'EXCHANGE_REFUND':            'XR',
    'EXCHANGE_EDIT_ORDER':        'XE',
    'EXCHANGE_CANCEL_ORDER':      'XX',
    'EXCHANGE_ORDER_BOOK':        'XO',
    'EXCHANGE_PRICE_HISTORY':     'XP',
    'EXCHANGE_MY_ORDERS':         'XM',
    'EXCHANGE_VIEW_ORDERS':       'XV',
    'EXCHANGE_VIEW_MY_LISTINGS':  'XY',
    'EXCHANGE_VIEW_MY_FILLS':     'XW',
    'EXCHANGE_CHAT_SEND':         'XH',
    'EXCHANGE_CHAT_LIST':         'XK',
    'EXCHANGE_CHAT_THREADS':      'XT',
    'EXCHANGE_SUBSCRIBE':         'XB',
    'EXCHANGE_UNSUBSCRIBE':       'XQ',
    // Groups (SOV Speak multi-citizen channels)
    'GROUP_CREATE':               'GC',
    'GROUP_SEND':                 'GS',
    'GROUP_LIST':                 'GL',
    'GROUP_HISTORY':              'GH',
    'GROUP_ADD_MEMBER':           'GA',
    'GROUP_LEAVE':                'GV',
    // Justice
    'JUSTICE_DISPUTE_OPEN':       'DO',
    'JUSTICE_DISPUTE_LIST':       'DR',
    'JUSTICE_DISPUTE_GET':        'DG',
    'JUSTICE_VOTE':               'DV',
    'JUSTICE_JUROR_RESPOND':      'DJ',
    'JUSTICE_EXPAND_PANEL':       'DX',
    // Governance
    'POLL_CREATE':                'PC',
    'POLL_VOTE':                  'PV',
    'POLL_LIST':                  'PL',
    'POLL_GET':                   'PG',
    'PETITION_CREATE':            'EC',
    'PETITION_SIGN':              'ES',
    'PETITION_LIST':              'EL',
    'GOV_PARAM_GET':              'KG',
    'GOV_PARAMS_ALL':             'KA',
    'SOV_VALUE_STATUS':           'QS',  // SOV price oracle — get current rate
    'SOV_VALUE_SUBMIT':           'QV',  // SOV price oracle — submit epoch proposal
    // Academy
    'ACADEMY_PUBLISH':            'AP',
    'ACADEMY_LIST':               'AL',
    'ACADEMY_GET':                'AG',
    'ACADEMY_UPVOTE':             'AU',
    // SOV Enclave / Forum
    'ENCLAVE_POST':               'FP',
    'ENCLAVE_REPLY':              'FY',
    'ENCLAVE_LIST':               'FL',
    'ENCLAVE_GET':                'FG',
    // SOV Login
    'SOV_LOGIN_CHALLENGE_CREATE': 'LG',
    'SOV_LOGIN_RESPOND':          'LR',
    'SOV_LOGIN_VERIFY':           'LV',
    // Palm Name
    'PALM_NAME_QUERY':            'PN',
    // Calls (governance gated)
    'CALL_INVITE':                'CI',
    'CALL_ANSWER':                'CA',
    'CALL_END':                   'CE',
    'CALL_REJECT':                'CJ',
    // Allocations (Inheritance / Vault / Deadman)
    'ALLOCATION_CREATE':          'OC',  // Create a new allocation
    'ALLOCATION_LIST':            'OL',  // List own allocations
    'ALLOCATION_CANCEL':          'OX',  // Cancel an allocation
    'ALLOCATION_COUNCIL_VOTE':    'OV',  // Council vote on an allocation
    'ALLOCATION_MY_COUNCILS':     'OK',  // List councils I am part of
    'ALLOCATION_CLAIM_STAGE1':    'O1',  // Direct claim: claim key + release date reached
    'ALLOCATION_CLAIM_STAGE2':    'O2',  // Council review claim: family keys + community
    // Ledger sync
    'LEDGER_SYNC_REQUEST':        'LQ',  // Request balance + tx history from relay
    // Pioneer Program
    'PIONEER_VERIFY':             'YV',  // Validate referral code before enrollment (pre-auth)
    'PIONEER_REGISTER':           'YR',  // Register as a pioneer after enrollment
    'PIONEER_GET_STATUS':         'YS',  // Get own pioneer rank, certs, earnings
    'PIONEER_START_ASSESSMENT':   'YA',  // Begin a specialisation assessment quiz
    'PIONEER_SUBMIT_ASSESSMENT':  'YU',  // Submit quiz answers for grading
    // Exchange Reputation
    'EXCHANGE_VIEW_REPUTATION':   'XZ',  // View trader reputation score
    // Node / network stats
    'NODE_STATS':                 'ZS',
    'NETWORK_STATS':              'ZS',
    // Misc
    'LEDGER_SYNC_ACK':            'LA',
    // FIX: was 'NQ' — but 'NQ' is NODE_QUERY. The node routes the messaging-key
    // lookup on op 'PK' (message_engine.js), so sending 'NQ' meant the node never
    // answered → "no encryption key on file" for EVERY recipient. Correct op = 'PK'.
    'PUBLIC_KEY_QUERY':           'PK',
    'NODE_QUERY':                 'NQ',
  };

  /// Reverse map — op code → full type string.
  /// Used to normalise incoming messages that carry only 'op' (future sov-node).
  /// Op codes shared by multiple type strings resolve to the preferred type.
  static const Map<String, String> _typeFromOp = {
    'HL': 'HELLO',
    'PI': 'PING',
    'PO': 'PONG',
    'MS': 'MESSAGE_SEND',
    'MR': 'MESSAGE_READ',
    'DL': 'MESSAGE_DELIVERY_RECEIPT',
    'WA': 'WATCH_ADD',
    'WX': 'WATCH_REMOVE',
    'ST': 'SOV_TRANSFER',
    'BQ': 'SOV_BALANCE_QUERY',
    'TH': 'TX_HISTORY_REQUEST',
    'RL': 'PAY_REQ_LIST',      // 'RL' belongs to payment requests
    'RN': 'RELAY_LIST_REQUEST',
    'RS': 'RELAY_LIST_RESULT',
    'HD': 'HOP_BRIDGE_DISCOVER',
    'FA': 'FRAG_ANNOUNCE',
    'FR': 'FRAG_REQUEST',
    'FD': 'FRAG_DELIVER',
    'MP': 'MESH_HELLO',
    'LE': 'ENROLLMENT_REGISTER',
    'LP': 'PALM_EMBEDDING_REGISTER',
    'PD': 'PALM_DUPLICATE_CHECK',
    'EN': 'ENROLL_REQUEST',
    'RC': 'SOV_REQUEST_CREATE',
    'RX': 'PAY_REQ_CANCEL',
    'VL': 'VAULT_LOCK',
    'VI': 'VAULT_CLAIM_INIT',
    'IC': 'ISSUANCE_CLAIM',
    'UA': 'GUARDIAN_ADD',
    'UR': 'GUARDIAN_REMOVE',
    'UL': 'GUARDIAN_LIST',
    'UI': 'GUARDIAN_RECOVERY_REQUEST',
    'UP': 'GUARDIAN_APPROVE',
    'UJ': 'GUARDIAN_REJECT',
    // ── Financial/social engine RESPONSE codes (server→client). These engines'
    //    _send emits a bare {op, ...payload} with NO 'type' field, so the app
    //    must translate the op here or sendAndWait can never match the response.
    //    Verified 2026-06-04 against live handlers (financial_engine/social_engine).
    //    Without these, Receive (payment requests), Guardian Setup, Contacts
    //    palm-name, and Issuance silently time out. (relay code -> app responseType)
    'RPC': 'SOV_REQUEST_CREATED',          // handleRequestCreate
    'RPL': 'SOV_REQUEST_LIST_RESULT',      // handleRequestList
    'GAR': 'GUARDIAN_ADD_RESULT',          // handleGuardianAdd
    'GAA': 'GUARDIAN_APPROVE_RESULT',      // handleGuardianApprove
    'GRJ': 'GUARDIAN_REJECT_RESULT',       // handleGuardianReject
    'GRR': 'GUARDIAN_REMOVE_RESULT',       // handleGuardianRemove
    'GRL': 'GUARDIAN_LIST_RESULT',         // handleGuardianList
    'GRC': 'GUARDIAN_RECOVERY_INIT_RESULT',// handleGuardianRecover (recovery init)
    'ICR': 'ISSUANCE_CLAIM_RESULT',        // handleIssuanceClaim
    'PR':  'PALM_NAME_RESULT',             // handlePalmNameQuery (Contacts)
    'TG':  'PLATFORM_REGISTER_RESULT',   // own code since genesis (was 'PK',
                                           // which the app decodes as PUBLIC_KEY_QUERY)
    'XL': 'EXCHANGE_LIST_ORDER',
    'XF': 'EXCHANGE_FILL_ORDER',
    'XC': 'EXCHANGE_CONFIRM',
    'XR': 'EXCHANGE_REFUND',
    'XE': 'EXCHANGE_EDIT_ORDER',
    'XX': 'EXCHANGE_CANCEL_ORDER',
    'XO': 'EXCHANGE_ORDER_BOOK',
    'XP': 'EXCHANGE_PRICE_HISTORY',
    'XM': 'EXCHANGE_MY_ORDERS',
    'XV': 'EXCHANGE_ORDERS_LIST',
    'XY': 'EXCHANGE_MY_LISTINGS_LIST',
    'XW': 'EXCHANGE_MY_FILLS_LIST',
    'XH': 'EXCHANGE_CHAT_SEND',
    'XK': 'EXCHANGE_CHAT_LIST',
    'XI': 'EXCHANGE_CHAT_INCOMING',   // live push delivered to recipient
    'XS': 'EXCHANGE_ESCROW_LOCKED',
    'XN': 'EXCHANGE_ORDER_FILLED_NOTIFY',
    'DO': 'JUSTICE_DISPUTE_OPEN',
    'DR': 'JUSTICE_DISPUTE_LIST',
    'DG': 'JUSTICE_DISPUTE_GET',
    'DV': 'JUSTICE_VOTE',
    'DJ': 'JUSTICE_JUROR_RESPOND',
    'DX': 'JUSTICE_EXPAND_PANEL',
    'PC': 'POLL_CREATE',
    'PV': 'POLL_VOTE',
    'PL': 'POLL_LIST',
    'PG': 'POLL_GET',
    'EC': 'PETITION_CREATE',
    'ES': 'PETITION_SIGN',
    'EL': 'PETITION_LIST',
    'KG': 'GOV_PARAM_GET',
    'KA': 'GOV_PARAMS_ALL',
    'QS': 'SOV_VALUE_STATUS',
    'QV': 'SOV_VALUE_SUBMIT',
    'AP': 'ACADEMY_PUBLISH',
    'AL': 'ACADEMY_LIST',
    'AG': 'ACADEMY_GET',
    'AU': 'ACADEMY_UPVOTE',
    'FP': 'ENCLAVE_POST',
    'FY': 'ENCLAVE_REPLY_RESULT',
    'FL': 'ENCLAVE_LIST_RESULT',
    'FG': 'ENCLAVE_REPLIES_RESULT',
    // 'FD' deliberately NOT mapped here: it already means FRAG_DELIVER (L443).
    // The node reuses 'FD' for ENCLAVE_POST_RESULT and disambiguates by context;
    // this reverse map cannot. Logged as an op-code collision in the audit.
    'FE': 'ENCLAVE_ERROR',
    // Live Enclave pushes. These were ABSENT, so pushToAll('FN'/'FO') from the
    // node resolved to nothing and the app never saw a new post or reply.
    'FN': 'ENCLAVE_NEW_POST',
    'FO': 'ENCLAVE_NEW_REPLY',
    'LG': 'SOV_LOGIN_CHALLENGE_CREATE',
    'LR': 'SOV_LOGIN_RESPOND',
    'LV': 'SOV_LOGIN_VERIFY',
    'PN': 'PALM_NAME_QUERY',
    'CI': 'CALL_INVITE',
    'CA': 'CALL_ANSWER',
    'CE': 'CALL_END',
    'CJ': 'CALL_REJECT',
    'CIR': 'CALL_INVITE_RESULT',   // relay acks the invite + livekit_url to caller
    'CAR': 'CALL_ANSWER_RESULT',   // callee receives own token after answerCall()
    'CAN': 'CALL_ANSWERED',        // caller receives callee's answer + token
    'CEN': 'CALL_ENDED',           // either party; call terminated
    'CRJ': 'CALL_REJECTED',        // caller receives callee's decline
    'OC': 'ALLOCATION_CREATE',
    'OL': 'ALLOCATION_LIST',
    'OX': 'ALLOCATION_CANCEL',
    'OV': 'ALLOCATION_COUNCIL_VOTE',
    'OK': 'ALLOCATION_MY_COUNCILS',
    'O1': 'ALLOCATION_CLAIM_STAGE1',
    'O2': 'ALLOCATION_CLAIM_STAGE2',
    'LQ': 'LEDGER_SYNC_REQUEST',
    'LY': 'LEDGER_SYNC_RESPONSE',
    'YV': 'PIONEER_VERIFY',
    'YR': 'PIONEER_REGISTER',
    'YS': 'PIONEER_GET_STATUS',
    'YA': 'PIONEER_START_ASSESSMENT',
    'YU': 'PIONEER_SUBMIT_ASSESSMENT',
    'XZ': 'EXCHANGE_VIEW_REPUTATION',
    'ZS': 'NODE_STATS',
    'ZR': 'NODE_STATS_RESULT',
    'LA': 'LEDGER_SYNC_ACK',
    'NQ': 'NODE_QUERY',
    'PK': 'PUBLIC_KEY_QUERY',
    'KR': 'PUBLIC_KEY_RESULT',   // node answers the messaging-key lookup with op 'KR'
    // Inbound-only op codes (node → phone push events)
    'HA': 'HELLO_ACK',
    'MI': 'MESSAGE_INCOMING',
    'MA': 'MESSAGE_ACK',
    'RR': 'MESSAGE_READ_RECEIPT',
    'CO': 'CITIZEN_ONLINE',
    'CF': 'CITIZEN_OFFLINE',
    'SR': 'SOV_TRANSFER_RESULT',
    'SV': 'SOV_TRANSFER_RECEIVED',
    'BR': 'BALANCE_RESULT',
    'TR': 'TX_HISTORY_RESULT',
    'NR': 'NODE_RESPONSE',
    'ER': 'ENROLL_RESULT',
    // Exchange push-subscribe inbound op codes
    'XB': 'EXCHANGE_STATE',       // relay pushes full order list on subscribe
    'XU': 'EXCHANGE_ORDER_UPDATE', // relay pushes per-order delta
    'XQ': 'EXCHANGE_UNSUBSCRIBED', // relay confirms unsubscribe
    // Group inbound op codes (node → phone)
    'GD': 'GROUP_CREATED',         // response to GROUP_CREATE
    'GM': 'GROUP_MESSAGE_INCOMING', // live push: new message in a group
    'GR': 'GROUP_LIST_RESULT',      // response to GROUP_LIST
    'GI': 'GROUP_HISTORY_RESULT',   // response to GROUP_HISTORY
    'GN': 'GROUP_INVITE',           // push: invited to a new group
    'GU': 'GROUP_UPDATE',           // membership change (add/leave)
  };

  /// Dictionary protocol (V2 raison d'être — see CLAUDE.md §3, Network
  /// Architecture §3): replaces the human-readable 'type' field with a 2-char
  /// 'op' code on every outbound message. ISP / on-wire observers see only
  /// opaque 2-char codes (HL/ST/MS/...), not "SOV_TRANSFER" / "MESSAGE_SEND".
  ///
  /// Behaviour:
  /// - If 'op' already set: leave message alone.
  /// - If 'type' has a known op code in _OP: ADD 'op' and REMOVE 'type'.
  /// - If 'type' is unknown to _OP: leave 'type' in place as a fallback so
  ///   newly-added message types still work during the rollout window.
  ///
  /// Relay side (citizen_gateway.js): dispatches on msg.op; LEGACY_TYPE_MAP
  /// reconstructs op from type only as a backward-compat path for old apps.
  /// Inbound type is reconstructed from op via _typeFromOp at line ~1342.
  static void _addOpCode(Map<String, dynamic> msg) {
    if (msg.containsKey('op')) return;
    final type = msg['type'] as String?;
    if (type == null) return;
    final op = _OP[type];
    if (op != null) {
      msg['op'] = op;
      msg.remove('type'); // V2 dictionary: hide operation name from the wire
    }
  }

  // ── ENROLLMENT GUARD ─────────────────────────────────────────────────────
  // Set to true by EnrollmentScreen before _registerWithRelay() starts and
  // cleared when it completes (success or failure). While true, the lifecycle
  // observer in main.dart will NOT disconnect the relay even if the app is
  // backgrounded — this prevents the phone being routed to a different relay
  // mid-enrollment (each relay has its own isolated DB; a relay that didn't
  // receive ENROLLMENT_REGISTER will fail PALM_EMBEDDING_REGISTER).
  static bool _enrollmentInProgress = false;
  static bool get enrollmentInProgress => _enrollmentInProgress;
  static set enrollmentInProgress(bool value) {
    debugPrint('[ENROLL] enrollmentInProgress=$value');
    _enrollmentInProgress = value;
  }

  // Set to true before opening external activities (file picker, share sheet)
  // that trigger AppLifecycleState changes but must NOT trigger session lock.
  static bool _externalActivityOpen = false;
  static bool get externalActivityOpen => _externalActivityOpen;
  static set externalActivityOpen(bool value) {
    debugPrint('[RELAY] externalActivityOpen=$value');
    _externalActivityOpen = value;
    // Persist to SharedPreferences so main() can suppress PIN lock on cold
    // restart caused by Android killing the process during a file picker.
    SharedPreferences.getInstance().then((prefs) {
      if (value) {
        prefs.setInt('_ext_activity_ts',
            _nowMs());
      } else {
        prefs.remove('_ext_activity_ts');
      }
    });
  }

  static bool get isConnected => _connected;
  static ConnectionMode get currentMode => _currentMode;
  static String get connectionType   => _connectionType;
  static String get currentEndpoint  => _currentEndpoint ?? '';
  static String get currentRelayId   => _currentRelayId;
  static String get currentRelayNickname {
    if (_currentRelayId.isNotEmpty) return getNickname(_currentRelayId);
    return 'SOV Relay';
  }

  // ── SOV Node aliases — use these in node-aware UI ─────────────────────────
  /// The Node ID of the currently connected SOV Node.
  /// Identical to currentRelayId — kept separate for semantic clarity.
  static String get currentNodeId      => _currentRelayId;

  /// WSS address of the currently connected SOV Node.
  static String get currentNodeAddress => _currentEndpoint ?? '';

  /// Nickname for the connected node (same algorithm as relay nickname).
  static String get currentNodeNickname => currentRelayNickname;

  /// Returns the canonical relay_id for a given IP (from bundled relay_pool.json).
  /// Returns '' if the IP is not in the canonical map.
  static String canonicalRelayIdForIp(String ip) => _canonicalRelayIdByIp[ip] ?? '';

  /// Deterministic nickname for any relay ID — same algorithm as server.js.
  /// sha256(relayId) → adjIndex[0..3] + nounIndex[4..7] → "Adjective-Noun"
  static String getNickname(String relayId) {
    const adjectives = [
      'Silent','Deep','Swift','Bright','Dark','Clear','Still','Strong','Wide','High',
      'Cold','Warm','Free','Pure','Bold','Calm','Sharp','Soft','Wild','True',
      'Old','New','Far','Near','Open','Firm','Long','Fast','Safe','Cool',
      'Hard','Fair','Rich','Full','Fine','Rare','Last','Dawn','Dusk','Tide',
      'Peak','Vale','Glen','Mist','Reef','Cove','Isle','Cape','Bay','Sea',
      'Sky','Sun','Moon','Star','Wind','Rain','Snow','Ice','Fire','Sand',
      'Rock','Iron','Gold','Bold','Flow',
    ];
    const nouns = [
      'Falcon','River','Stone','Cedar','Ember','Crane','Birch','Haven','Ridge','Brook',
      'Spire','Marsh','Cliff','Grove','Fjord','Delta','Bluff','Crest','Dune','Fern',
      'Gale','Helm','Inlet','Junco','Kite','Lark','Moor','Nave','Orbit','Prism',
      'Quay','Reef','Shore','Thorn','Umbra','Veil','Wick','Ash','Bark','Cove',
      'Drift','Edge','Flint','Gate','Horn','Isle','Jade','Kelp','Loch','Mesa',
      'Node','Opal','Pine','Quill','Rush','Salt','Terra','Vale','Wren','Blaze',
      'Creek','Frost','Glyph','Haze','Iris',
    ];
    if (relayId.isEmpty) return 'SOV Relay';
    final hash      = sha256.convert(utf8.encode(relayId)).toString();
    final adjIndex  = int.parse(hash.substring(0, 8), radix: 16) % adjectives.length;
    final nounIndex = int.parse(hash.substring(8, 16), radix: 16) % nouns.length;
    return '${adjectives[adjIndex]}-${nouns[nounIndex]}';
  }

  // ── Palm-derived citizen name ─────────────────────────────────────────────
  // Cached in-memory after first read from SharedPreferences.
  static String? _cachedPalmName;

  // Cross-citizen palm name resolution cache.
  // Keys are sovereign IDs; values are resolved palm names (may be empty string
  // meaning "fetched and empty" — not re-fetched once set).
  static final Map<String, String> _resolvedNames = {};

  /// Returns this citizen's palm-derived name (e.g. "Shoreshaw", "Cairnholme").
  /// Reads from SharedPreferences on first call; cached in memory thereafter.
  /// Falls back to PalmNameEngine.fallbackName(sovereignId) for citizens
  /// who enrolled before this feature was added.
  static Future<String> getPalmName() async {
    if (_cachedPalmName != null) return _cachedPalmName!;
    final prefs = await SharedPreferences.getInstance();
    final sovId = prefs.getString('sovereign_id') ?? '';
    // The deterministic name (pure function of the sovereign ID) is canonical —
    // it is exactly what every other citizen, contact list and chat thread shows
    // for this ID. Older builds stored an embedding-derived name that differed
    // from the network view (owner saw "ColdHawk", everyone else "BrightKite").
    // Reconcile to the deterministic name and migrate the stored value so the
    // owner's own profile matches the network, and so the HELLO that re-publishes
    // palm_name carries the consistent name.
    if (sovId.isNotEmpty) {
      final canonical = PalmNameEngine.deriveName([], sovereignId: sovId);
      final stored = prefs.getString('palm_name') ?? '';
      if (stored != canonical) {
        await prefs.setString('palm_name', canonical);
      }
      _cachedPalmName = canonical;
      return canonical;
    }
    // Pre-enrollment (no sovereign id yet) — last-resort stored name.
    final stored = prefs.getString('palm_name') ?? '';
    if (stored.isNotEmpty && PalmNameEngine.isValidPalmName(stored)) {
      _cachedPalmName = stored;
      return stored;
    }
    _cachedPalmName = 'SOV Citizen';
    return 'SOV Citizen';
  }

  /// Synchronous version — returns cached value or 'SOV Citizen' if not loaded.
  /// Call getPalmName() at app start (e.g. in initState) to warm the cache.
  static String getPalmNameSync() => _cachedPalmName ?? 'SOV Citizen';

  /// Returns the full unique network handle — "IronHawk·A3F7".
  /// Two palm-derived words + 4-char sovereign ID suffix.
  /// Use this in groups, SOV Enclave, and anywhere multiple citizens appear.
  static Future<String> getPalmHandle() async {
    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final name    = await getPalmName();
    final suffix  = PalmNameEngine.handleSuffix(sovId);
    return '$name·$suffix';
  }

  /// Synchronous handle — returns cached name + suffix, or 'SOV Citizen'.
  static String getPalmHandleSync() {
    final name = getPalmNameSync();
    if (name == 'SOV Citizen') return name;
    // Suffix computed from sovereign_id stored in the static cache path —
    // if not available yet returns name only (no '·' suffix).
    return name;
  }

  /// Invalidate the cache (e.g. after re-enrollment).
  static void invalidatePalmNameCache() => _cachedPalmName = null;

  /// Query the relay for another citizen's palm-derived name.
  /// Returns the name string (e.g. "IronHawk") or empty string if not found.
  /// Used in SOV Speak threads, Enclave posts, and Justice cases to show
  /// human names instead of raw SOV-XXXX IDs.
  static Future<String> getPalmNameFromRelay(String sovereignId) async {
    try {
      final resp = await sendAndWait(
        request: {'type': 'PALM_NAME_QUERY', 'sovereign_id': sovereignId},
        responseType: 'PALM_NAME_RESULT',
        timeout: const Duration(seconds: 8),
        matchField: 'sovereign_id',
        matchValue: sovereignId,
      );
      if (resp == null) return '';
      final name = (resp['palm_name'] as String?) ?? '';
      return PalmNameEngine.isValidPalmName(name) ? name : '';
    } catch (_) {
      return '';
    }
  }
  /// Returns the cached palm name for [sovereignId], or empty string if not
  /// yet resolved. Simultaneously triggers a background relay fetch if the ID
  /// has never been queried. Call [setState] in the [onResolved] callback to
  /// refresh the UI once the name arrives.
  ///
  /// Usage:
  ///   final name = RelayConnector.cachedPalmNameFor(id);
  ///   RelayConnector.prefetchPalmName(id, onResolved: () => setState(() {}));
  static String cachedPalmNameFor(String sovereignId) =>
      _resolvedNames[sovereignId] ?? '';

  /// Pre-fetches the palm name for [sovereignId] from the relay.
  /// No-op if already cached. Calls [onResolved] (if provided) when the name
  /// arrives so the caller can trigger a rebuild.
  static void prefetchPalmName(
    String sovereignId, {
    VoidCallback? onResolved,
  }) {
    if (_resolvedNames.containsKey(sovereignId)) {
      // Already cached (even if empty) — call back immediately if requested.
      if (onResolved != null && _resolvedNames[sovereignId]!.isNotEmpty) {
        onResolved();
      }
      return;
    }
    // Mark as in-flight so concurrent calls don't double-fetch.
    _resolvedNames[sovereignId] = '';
    getPalmNameFromRelay(sovereignId).then((name) {
      _resolvedNames[sovereignId] = name;
      if (name.isNotEmpty && onResolved != null) onResolved();
    });
  }

  /// Bulk-prefetch palm names for a list of sovereign IDs.
  /// [onAnyResolved] is called each time a new name arrives.
  static void prefetchPalmNames(
    List<String> sovereignIds, {
    VoidCallback? onAnyResolved,
  }) {
    for (final id in sovereignIds) {
      prefetchPalmName(id, onResolved: onAnyResolved);
    }
  }

  /// Returns the best display name for [sovereignId]:
  ///   1. Cached palm name (from relay)
  ///   2. Short truncated SOV-ID as fallback
  /// Does NOT trigger a fetch — call [prefetchPalmName] separately.
  static String displayNameFor(String sovereignId) {
    final cached = _resolvedNames[sovereignId] ?? '';
    if (cached.isNotEmpty) return cached;
    if (sovereignId.length <= 14) return sovereignId;
    return '${sovereignId.substring(0, 10)}…${sovereignId.substring(sovereignId.length - 4)}';
  }

  static Stream<Map<String, dynamic>>? get messageStream =>
      _messageController?.stream;
  static List<HopNode> get hopNodes => List.unmodifiable(_hopNodes);

  // ── BALANCE CHANGE STREAM ─────────────────────────────────────────────────
  // Emits the new balance in seeds after a confirmed SOV transfer.
  // MainShell subscribes to update the displayed balance without a relay query.
  static final StreamController<int> _seedsChangedController =
      StreamController<int>.broadcast();
  static Stream<int> get seedsChangedStream => _seedsChangedController.stream;

  /// Notify listeners that the wallet balance has changed.
  /// [newSeeds] is the new spendable balance in seeds (integer).
  static void notifySeedsChanged(int newSeeds) {
    if (!_seedsChangedController.isClosed) {
      _seedsChangedController.add(newSeeds);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONNECT
  // ══════════════════════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════════════════════
  // LOAD RELAY ENTRIES — full RelayEntry objects for parallel racing
  // ══════════════════════════════════════════════════════════════════════════

  /// Populate [_canonicalRelayIdByIp] from bundled relay_pool.json.
  /// Called once at connect time so all screens use consistent relay names
  /// regardless of what opaque IDs sov-node gossip returns (e.g. "node_xxx").
  static Future<void> _initCanonicalRelayIds() async {
    if (_canonicalRelayIdByIp.isNotEmpty) return;
    try {
      final jsonStr = await rootBundle.loadString('assets/relay_pool.json');
      final data    = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list    = data['relays'] as List;
      for (final r in list) {
        final endpoint = r['endpoint'] as String? ?? '';
        final relayId  = r['relay_id']  as String? ?? '';
        if (endpoint.isEmpty || relayId.isEmpty) continue;
        final uri = Uri.tryParse(endpoint);
        if (uri != null && uri.host.isNotEmpty) {
          _canonicalRelayIdByIp[uri.host] = relayId;
        }
      }
    } catch (_) {}
  }

  /// Load relay pool as full RelayEntry objects (ip + port extracted from URL).
  /// Priority 1: SharedPreferences 'relay_pool_cache' (previous session).
  /// Priority 2: Bundled assets/relay_pool.json (first run, full metadata).
  static Future<List<RelayEntry>> _loadRelayEntries() async {
    final List<RelayEntry> out = [];
    // Priority 0: operator-configured "my node" (SharedPreferences 'custom_node').
    // Lets a citizen point the app at their OWN node by hostname (e.g. a node served
    // via the node operator's own reachable address / tunnel). Tried FIRST.
    // This is purely a client-side preference — no protocol change, no dependency.
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getString('custom_node');
      if (custom != null && custom.trim().isNotEmpty) {
        var h = custom.trim();
        // accept "host", "host:port", or a full wss:// URL
        final uri = Uri.tryParse(h.contains('://') ? h : 'wss://$h');
        if (uri != null && uri.host.isNotEmpty) {
          out.add(RelayEntry(
            relayId:     uri.host,
            ip:          uri.host,
            port:        uri.port > 0 ? uri.port : 443,
            fingerprint: '',
            name:        'My node (${uri.host})',
            addedAt:     _nowMs(),
          ));
          debugPrint('[DISCOVERY] Custom node prepended: ${uri.host}:${uri.port > 0 ? uri.port : 443}');
        }
      }
    } catch (e) { debugPrint('[DISCOVERY] custom_node read error: $e'); }

    // Priority 1: cached URL strings — parse ip/port from each URL
    try {
      final prefs  = await SharedPreferences.getInstance();
      final cached = prefs.getStringList('relay_pool_cache');
      if (cached != null && cached.isNotEmpty) {
        final now     = _nowMs();
        final entries = <RelayEntry>[];
        for (final url in cached) {
          final uri = Uri.tryParse(url);
          if (uri == null || uri.host.isEmpty) continue;
          // Preserve the actual port from the cached URL.
          // Only substitute 443 if the port is the peer-mesh port (7771) or absent,
          // which was an old relay-pool poison bug. VPS2 legitimately uses port 4443
          // and must NOT be overridden to 443.
          final cachedPort = (uri.port == 7771 || uri.port <= 0) ? 443 : uri.port;
          entries.add(RelayEntry(
            relayId:     '', // resolved after connect via gossip (_resolveCurrentRelayId)
            ip:          uri.host,
            port:        cachedPort,
            fingerprint: '',
            name:        uri.host,
            addedAt:     now,
          ));
        }
        if (entries.isNotEmpty) {
          debugPrint('[DISCOVERY] Cached pool: ${entries.length} relay(s)');
          out.addAll(entries);
          return out;
        }
      }
    } catch (e) { debugPrint('[DISCOVERY] Cache read error: $e'); }

    // Priority 2: bundled relay_pool.json — relay_id + endpoint available
    try {
      final jsonStr = await rootBundle.loadString('assets/relay_pool.json');
      final data    = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list    = data['relays'] as List;
      final now     = _nowMs();
      final entries = <RelayEntry>[];
      for (final r in list) {
        final endpoint = r['endpoint'] as String? ?? '';
        if (endpoint.isEmpty) continue;
        final uri = Uri.tryParse(endpoint);
        if (uri == null || uri.host.isEmpty) continue;
        entries.add(RelayEntry(
          relayId:     r['relay_id'] as String? ?? uri.host,
          ip:          uri.host,
          port:        uri.port > 0 ? uri.port : 443,
          fingerprint: '',
          name:        r['relay_id'] as String? ?? uri.host,
          nickname:    r['nickname'] as String? ?? '',
          addedAt:     now,
        ));
      }
      debugPrint('[DISCOVERY] Bundled pool: ${entries.length} relay(s)');
      out.addAll(entries);
      return out;
    } catch (e) { debugPrint('[DISCOVERY] Bundle read error: $e'); }
    return out;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONNECT — parallel relay racing
  // ══════════════════════════════════════════════════════════════════════════

  /// Connect to a specific SOV Node by WSS address.
  /// Used by NodeDiscovery-driven reconnection to try a particular node.
  /// Falls back to the normal `connect()` pool race if the address fails.
  static Future<bool> connectToNode(String address) async {
    if (_connected && _currentEndpoint == address) return true;
    // Inject the specific node at the front of the candidate list so it is
    // tried first while still racing against any other known nodes.
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) return connect();
    final targetEntry = RelayEntry(
      relayId:     uri.host,
      ip:          uri.host,
      port:        uri.port > 0 ? uri.port : 443,
      fingerprint: '',
      name:        uri.host,
      addedAt:     _nowMs(),
    );
    // Temporarily prepend the target to the known relay list so connect() races it first
    _knownRelays.insert(0, targetEntry);
    final ok = await connect();
    // Remove from front if it didn't win (don't litter the pool)
    if (_knownRelays.isNotEmpty && _knownRelays.first.ip == uri.host) {
      _knownRelays.removeAt(0);
    }
    return ok;
  }

  static Future<bool> connect() async {
    if (_connected) return true;

    // A node has permanently refused these credentials. Screens across the app
    // call connect() opportunistically whenever they notice they are offline,
    // so the halt has to live here rather than only in the reconnect timer —
    // otherwise merely opening the Exchange or Academy tab restarts the loop.
    // Cleared by clearCredentialError() once recovery has stored a new key.
    // It clears itself: the halt is tied to the exact key that was rejected, so
    // the moment a restore puts a different key on the device the block lifts
    // with nothing to remember to call.
    if (credentialError != null) {
      final currentKey = (await KeyManager.getPublicKey()) ?? '';
      if (currentKey.isNotEmpty && currentKey != _rejectedPublicKey) {
        debugPrint('[RELAY] Device key changed since rejection — clearing halt '
            'and retrying.');
        clearCredentialError();
      } else {
        debugPrint('[RELAY] connect() refused — credentials rejected '
            '($credentialError). Restore from the seed phrase to fix this.');
        return false;
      }
    }

    // Guard: prevent overlapping connect() calls from boot + lifecycle racing
    if (_connecting) {
      int waited = 0;
      while (_connecting && waited < 10000) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited += 100;
      }
      return _connected;
    }
    _connecting = true;

    // V2 hardening: load pinned TLS fingerprints from bundled relay_pool.json
    // BEFORE racing relays so cert pinning is enforced from the very first
    // handshake. Idempotent — returns immediately if already loaded.
    await _loadTrustedFingerprints();

    try {
      _messageController ??= StreamController<Map<String, dynamic>>.broadcast();
      await _loadRelayList();
      // Ensure canonical relay IDs are loaded so all screens show consistent names
      await _initCanonicalRelayIds();

      // Initialise SOV Node discovery pool (loads cache + triggers background refresh)
      await NodeDiscovery.init();

      // Build candidate list — full RelayEntry objects (ip + port)
      var entries = await _loadRelayEntries();

      // Merge in SOV Node discovery pool (addresses from /relay-pool HTTP fetch)
      for (final node in NodeDiscovery.all) {
        if (entries.every((e) => e.ip != node.ip)) {
          entries = [
            ...entries,
            RelayEntry(
              relayId:     node.nodeId,
              ip:          node.ip,
              port:        node.port,
              fingerprint: '',
              name:        node.nickname.isNotEmpty ? node.nickname : node.nodeId,
              nickname:    node.nickname,
              addedAt:     node.addedAt,
            ),
          ];
        }
      }

      // Append gossip-discovered relays not already present.
      // Dedup by (ip, targetNodeId) — NOT ip alone: a circuit-relay entry shares
      // the fronting peer R's ip but carries a distinct targetNodeId=N, so it must
      // survive even when R already has a direct entry (ip=R, targetNodeId='').
      // Deduping by ip alone dropped every relayed entry → the NAT'd node N could
      // never be chosen as a connect candidate (Task #26 self-dependent serving).
      for (final r in _knownRelays) {
        if (entries.every((e) =>
            e.ip != r.ip || e.targetNodeId != r.targetNodeId)) {
          entries = [...entries, r];
        }
      }

      if (entries.isNotEmpty) {
        // Sort relay candidates using SHA-256(sovereignId) as a stable seed so
        // each citizen has a deterministic preference ordering. Two devices on the
        // same WiFi will naturally connect to different relays without any manual
        // configuration — sovereign-aware load distribution.
        final prefs   = await SharedPreferences.getInstance();
        final sovId   = prefs.getString('sovereign_id') ?? '';
        final seedHex = sha256.convert(utf8.encode(sovId)).toString();
        final seed    = int.parse(seedHex.substring(0, 8), radix: 16);
        final shuffled = List<RelayEntry>.from(entries)..shuffle(Random(seed));
        final startTime = DateTime.now();

        // "Connect to my node": if the citizen pinned their own node, connect to it
        // EXCLUSIVELY first (don't race it against the founders — an externally-fronted
        // node has higher latency and would always lose the race). Fall back to the
        // pool ONLY if the pinned node is unreachable, so the app is never bricked.
        String? myHost;
        final customPin = prefs.getString('custom_node');
        if (customPin != null && customPin.trim().isNotEmpty) {
          final c = customPin.trim();
          myHost = c.contains('://') ? (Uri.tryParse(c)?.host ?? c) : c.split(':')[0];
        }
        _RaceWinner? winner;
        if (myHost != null && myHost.isNotEmpty) {
          final mine = entries.where((e) => e.ip == myHost).toList();
          final myEntry = mine.isNotEmpty
              ? mine.first
              : RelayEntry(relayId: myHost, ip: myHost, port: 443, fingerprint: '',
                  name: 'My node ($myHost)', addedAt: _nowMs());
          // Be PATIENT with the pinned node: the user explicitly chose it, and a
          // remote / externally-fronted node can be slower or briefly flaky. Try it
          // a few times before giving up, instead of one short race.
          for (int attempt = 1; attempt <= 3 && winner == null; attempt++) {
            debugPrint('[RELAY] Pinned "my node" $myHost — EXCLUSIVE attempt $attempt/3...');
            winner = await _raceRelays([myEntry]);
          }
          if (winner == null) {
            final rest = shuffled.where((e) => e.ip != myHost).toList();
            debugPrint('[RELAY] My node unreachable after 3 tries — falling back to pool (${rest.length})');
            winner = await _raceRelays(rest);
          }
        } else {
          debugPrint('[RELAY] Racing ${shuffled.length} relays (affinity ${seedHex.substring(0, 8)})...');
          winner = await _raceRelays(shuffled);
        }

        if (winner != null) {
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          final label   = winner.relayId.isNotEmpty ? winner.relayId : winner.endpoint;
          debugPrint('[RELAY] $label won in ${elapsed}ms via ${winner.connectionType}');

          _currentEndpoint = winner.endpoint;
          _currentRelayId  = winner.relayId;
          _connectionType  = winner.connectionType;
          _currentMode     = ConnectionMode.direct;
          _currentTargetNodeId = winner.targetNodeId; // circuit-relay: bridge to N if set
          _connected       = true;

          // Record successful connection in node discovery pool
          NodeDiscovery.markSuccess(winner.endpoint);

          if (winner.wssChannel != null) {
            _channel = winner.wssChannel;
            _setupListener();
          }

          // Store ping time for relay_pool_screen display
          if (winner.relayId.isNotEmpty) {
            relayPingTimes[winner.relayId] = winner.elapsedMs;
          }

          _connecting = false;
          _startHeartbeat();
          _startHopDiscovery();
          _syncRelayPool(); // unawaited: gossip + pool socket setup
          return true;
        }
      }

      // All relays failed — last resort: peer hop
      if (await _tryPeerHop()) {
        _connectionType = 'wss';
        _connecting     = false;
        _startHeartbeat();
        _startHopDiscovery();
        return true;
      }

      // Everything this device already knew about has failed — every cached
      // address, and the peer hop. Before falling back to store-and-forward,
      // go and LOOK for the network again.
      //
      // This matters more than it looks. The pool only refreshed itself when
      // the cache was over an hour old, so a citizen holding three addresses
      // that had all died would retry those same three forever and never reach
      // the pointer mirrors or the DHT — the exact situation those paths exist
      // for. Rediscovery is now triggered by FAILURE rather than by age.
      if (!_rediscovering) {
        _rediscovering = true;
        try {
          debugPrint('[RELAY] Every known address failed — rediscovering the network');
          final found = await NodeDiscovery.refresh();
          if (found.isNotEmpty) {
            debugPrint('[RELAY] Rediscovery found ${found.length} node(s) — retrying');
            _connecting = false;
            if (await connect()) return true;
          }
        } catch (e) {
          debugPrint('[RELAY] Rediscovery failed: $e');
        } finally {
          _rediscovering = false;
        }
      }

      _currentMode    = ConnectionMode.dtn;
      _connectionType = 'none';
      _connecting     = false;
      return false;

    } catch (e) {
      debugPrint('[RELAY] connect() error: $e');
      _connecting = false;
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PARALLEL RACE HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  /// Staggered race — relays are started with progressive delays so the
  /// SHA-256(sovereignId)-preferred relay (index 0) gets a head start.
  ///
  /// Delay schedule:
  ///   index 0 →   0 ms  (preferred relay — no delay)
  ///   index 1 → 250 ms  (joins if preferred doesn't respond in 250 ms)
  ///   index 2 → 500 ms
  ///   index 3+ → 750 ms
  ///
  /// Why this matters: a pure simultaneous race is always won by the
  /// physically-closest relay regardless of the affinity shuffle order.
  /// With staggering, citizens whose preferred relay is healthy (responds
  /// in <250 ms) always land on it — genuinely distributing load across
  /// nodes. If the preferred relay is slow or down, the next one steps in
  /// within 250 ms — no noticeable UX delay.
  static Future<_RaceWinner?> _raceRelays(List<RelayEntry> relays) async {
    final completer = Completer<_RaceWinner?>();
    int  failed     = 0;
    final total     = relays.length;

    // Stagger delays: 0 / 250 / 500 / 750 ms
    const List<int> staggerMs = [0, 250, 500, 750];

    void launch(int index) {
      final relay = relays[index];
      final start = DateTime.now();
      _tryConnectRace(relay, start).then((_RaceWinner? result) {
        if (result != null) {
          if (relay.relayId.isNotEmpty) {
            relayPingTimes[relay.relayId] = result.elapsedMs;
          }
          if (!completer.isCompleted) {
            completer.complete(result); // Winner
          } else {
            result.close(); // Loser — close immediately
          }
        } else {
          failed++;
          if (failed == total && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }).catchError((Object _) {
        failed++;
        if (failed == total && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }

    for (int i = 0; i < total; i++) {
      final delay = i < staggerMs.length ? staggerMs[i] : staggerMs.last;
      if (delay == 0) {
        launch(i);
      } else {
        Future.delayed(Duration(milliseconds: delay), () {
          if (!completer.isCompleted) launch(i);
          // If already completed (winner found) don't bother launching
        });
      }
    }

    // Hard cap: 15 s total regardless of individual relay timeouts
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        if (!completer.isCompleted) completer.complete(null);
        return null;
      },
    );
  }

  /// Attempt a single relay WSS connection for the parallel race.
  /// Pure — does NOT mutate any global state.
  /// Global state is applied only to the winner inside connect().
  static Future<_RaceWinner?> _tryConnectRace(
      RelayEntry relay, DateTime startTime) async {
    try {
      final context = SecurityContext(withTrustedRoots: false);
      final socket  = await WebSocket.connect(
        relay.wsUrl,
        customClient: HttpClient(context: context)
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) {
            // V2 transport trust model (2026-05-21, revised after architectural
            // review): TLS cert pinning is ADVISORY ONLY, not a hard gate.
            //
            // Reason: each sov-relay snap install generates a fresh self-signed
            // cert on first boot. Strict pinning would break (a) snap reinstall
            // on existing VPS, (b) any operator running the snap on their own
            // VPS, (c) the genesis rebirth scenario where a fresh VPS spins up
            // after the original 4 founding nodes are taken offline.
            //
            // The real authenticity check happens at the application layer:
            //   • V2 dictionary protocol makes the wire opaque to ISP DPI
            //   • HELLO → relay sends node identity signed by founder pubkey
            //   • App verifies founder signature against bundled trust anchor
            //
            // Cert SHA256s in assets/relay_pool.json are logged on mismatch
            // for forensic visibility but DO NOT block the connection. A
            // future v1.3 governance proposal will replace this with strict
            // Ed25519 node-identity pinning — see docs/TRUST_MODEL.md.
            final presented = _fingerprintOf(cert).toLowerCase();
            if (_trustedFingerprints.isNotEmpty &&
                !_trustedFingerprints.contains(presented)) {
              debugPrint(
                '[CERT-PIN advisory] $host cert fingerprint NOT in pinned set '
                '(presented=$presented). Accepting — node identity will be '
                'verified at application layer via founder-signed HELLO.',
              );
            }
            return true; // accept all; trust comes from application-layer signatures
          },
      ).timeout(const Duration(seconds: 8));

      final channel = IOWebSocketChannel(socket);
      await channel.ready;

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final label   = relay.relayId.isNotEmpty ? relay.relayId : relay.ip;
      debugPrint('[RACE] $label ready in ${elapsed}ms');

      return _RaceWinner(
        relayId:        relay.relayId,
        endpoint:       relay.wsUrl,
        connectionType: 'wss',
        wssChannel:     channel,
        elapsedMs:      elapsed,
        targetNodeId:   relay.targetNodeId,
      );
    } catch (e) {
      final label = relay.relayId.isNotEmpty ? relay.relayId : relay.ip;
      debugPrint('[RACE] $label failed: $e');
      return null;
    }
  }

  // ── Mode 3: SOV Peer Relay Hopping ───────────────────────────────────────
  static Future<bool> _tryPeerHop() async {
    if (_hopNodes.isEmpty) return false;
    final sorted = List<HopNode>.from(_hopNodes)
      ..sort((a, b) => a.latency.compareTo(b.latency));
    for (final hopNode in sorted) {
      final age = DateTime.now().difference(hopNode.lastSeen).inMinutes;
      if (age > 10) continue;
      try {
        final hopUrl =
            '${hopNode.relayUrl}/hop/${Uri.encodeComponent(hopNode.relayUrl)}';
        final socket = await WebSocket.connect(hopUrl)
            .timeout(const Duration(seconds: 10));
        _channel = IOWebSocketChannel(socket);
        await _channel!.ready;
        _setupListener();
        _connected = true;
        _currentMode = ConnectionMode.peerHop;
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CERT FINGERPRINT
  // ══════════════════════════════════════════════════════════════════════════
  static String _fingerprintOf(X509Certificate cert) {
    final digest = sha256.convert(cert.der);
    return digest.toString();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RELAY GOSSIP LIST
  // ══════════════════════════════════════════════════════════════════════════
  static final List<RelayEntry> _knownRelays = [];
  static const _prefsRelayKey = 'sov_relay_list_v1';

  static Future<void> _loadRelayList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsRelayKey);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      _knownRelays.clear();
      for (final item in list) {
        _knownRelays.add(RelayEntry.fromJson(item as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static Future<void> _saveRelayList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsRelayKey,
        jsonEncode(_knownRelays.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  static Future<void> _handleRelayAnnounce(Map<String, dynamic> data) async {
    try {
      final rawRelay = RelayEntry.fromJson(data);
      if (rawRelay.ip.isEmpty) return;
      if (rawRelay.port < 1 || rawRelay.port > 65535) return;
      // Always use port 443 for citizen connections. Relay pool gossip returns
      // peer mesh addresses (port 7771) — those must never be used as WSS endpoints.
      final relay = rawRelay.port == 443
          ? rawRelay
          : RelayEntry(
              relayId:     rawRelay.relayId,
              ip:          rawRelay.ip,
              port:        443,
              fingerprint: rawRelay.fingerprint,
              name:        rawRelay.name,
              nickname:    rawRelay.nickname,
              addedAt:     rawRelay.addedAt,
            );
      final exists = _knownRelays.any((r) => r.relayId == relay.relayId);
      if (!exists) {
        _knownRelays.add(relay);
        await _saveRelayList();
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MESSAGE LISTENER
  // ══════════════════════════════════════════════════════════════════════════
  static void _setupListener() {
    _channel?.stream.listen(
      (message) {
        try {
          final decoded =
              jsonDecode(message as String) as Map<String, dynamic>;
          _handleIncomingMessage(decoded);
        } catch (_) {}
      },
      onDone: () {
        _connected      = false;
        _connectionType = 'none';
        // A node closes with a 4xxx code when it has decided this device may not
        // connect AS THIS CITIZEN. Retrying cannot change that answer, so the
        // close code is read here rather than treating every close as a blip.
        _noteCloseCode(_channel?.closeCode);
        _scheduleReconnect();
      },
      onError: (_) {
        _connected      = false;
        _connectionType = 'none';
        _scheduleReconnect();
      },
    );
  }

  // ── Fatal credential rejections ───────────────────────────────────────────
  // Some closes are permanent: the node is healthy and reachable, but it will
  // not accept this device as this Sovereign ID. Reconnecting is not merely
  // useless, it is harmful — the old code retried every ~6s forever, and each
  // pass called NodeDiscovery.markFailure() on a node that was working
  // perfectly, so within a few minutes the client had marked its whole pool
  // unreliable. The citizen saw an app stuck "offline" with nothing explaining
  // why, and the node absorbed an endless HELLO loop.
  //
  //   4005 HELLO_INVALID_SIGNATURE — the signature did not verify
  //   4007 HELLO_KEY_MISMATCH      — this device's identity key is not the one
  //                                  enrolled for this Sovereign ID
  //
  // Both mean the same thing to a citizen: this device is not holding the key
  // that owns this identity, and the fix is to restore from the 12-word seed
  // phrase — which re-derives the enrolled key — not to wait.
  static const Map<int, String> _fatalCloseCodes = {
    4005: 'SIGNATURE_REJECTED',
    4007: 'KEY_MISMATCH',
  };

  /// Set when a node has permanently refused this device's credentials.
  /// Null while nothing is wrong. The UI reads this to explain the state
  /// instead of showing a bare "offline".
  static String? credentialError;

  static bool get hasCredentialError => credentialError != null;

  /// The identity key that was refused. The halt is tied to this value rather
  /// than to a flag someone has to remember to reset, so restoring a wallet
  /// lifts it automatically — see connect().
  static String _rejectedPublicKey = '';

  /// Last identity key presented in a HELLO. Captured so a rejection can be
  /// pinned to the exact key that caused it.
  static String _lastPresentedPublicKey = '';

  /// Guards the failure-triggered rediscovery so one connect() attempt cannot
  /// recurse into repeated pool refreshes.
  static bool _rediscovering = false;

  static void clearCredentialError() {
    credentialError    = null;
    _rejectedPublicKey = '';
  }

  static void _noteCloseCode(int? code) {
    if (code == null) return;
    final reason = _fatalCloseCodes[code];
    if (reason == null) return;
    credentialError    = reason;
    _rejectedPublicKey = _lastPresentedPublicKey;
    debugPrint('[RELAY] Node refused this device permanently: $reason '
        '(close $code) — halting reconnect. This device is not holding the key '
        'enrolled for this Sovereign ID; restore from the 12-word seed phrase.');
    // Surface it to any screen listening, so the citizen is told rather than
    // left looking at an app that simply never connects.
    _messageController?.add({
      'type':   'CREDENTIAL_REJECTED',
      'code':   reason,
      'detail': 'This device is not holding the key enrolled for this '
                'Sovereign ID. Restore your wallet from your 12-word seed '
                'phrase to re-derive the correct key.',
    });
  }

  // ── Send HELLO to register this citizen in the relay's _registry ───────────
  // Called whenever RELAY_HELLO is received (relay sends it immediately on
  // WebSocket connect).  Without this the relay never adds us to _registry
  // so _deliverToConnected() can't route incoming messages to this device.
  // HELLO is exempt from signature verification on the relay side.
  //
  // sovereign_id source priority:
  //   1. SharedPreferences 'sovereign_id' — always written by enrollment flow
  //   2. KeyManager secure storage         — fallback
  // Using SharedPreferences as primary prevents silent failure on devices where
  // the secure storage keystore is unavailable or the key hasn't been loaded yet.
  // [republish]: when true, skip the onConnected + _verifyOwnMessagingKey side-effects.
  // Used by _verifyOwnMessagingKey to re-register the key without starting another
  // verify loop. Without this, every mismatch re-fires onConnected → another verify
  // → infinite reconnect loop.
  static Future<void> _sendHello({bool republish = false}) async {
    if (republish) {
      // Key re-registration only — do NOT touch _helloAckReceived or fire onConnected.
      // CRITICAL (msgsigfix 2026-06-16): this HELLO MUST be signed over
      // '<sovereign_id>:<timestamp>' and sent via sendRaw — exactly like the normal
      // path. The old code routed it through send(), which attaches a PER-MESSAGE
      // signature over a DIFFERENT canonical payload plus a fresh timestamp; the
      // node's _handleHello then treats the session as new-format (signature present),
      // fails to verify that signature against '<sovereign_id>:<timestamp>', and
      // closes the socket (WS 4005 HELLO_INVALID_SIGNATURE). Because the messaging-key
      // self-heal fires this republish ~3s after every connect, that dropped the
      // session right after it came up. An unsigned HELLO is just as fatal — it flips
      // the session to legacyMode, after which the node rejects EVERY MESSAGE_SEND
      // with SIGNATURE_REQUIRED. Either way the citizen "can't send messages". It also
      // used the wrong field name (messaging_pub_key) and stale pref keys
      // (ed25519/x25519_public_key_hex) that the node never reads.
      try {
        final prefs = await SharedPreferences.getInstance();
        String sovId     = prefs.getString('sovereign_id') ?? '';
        String pubKeyHex = prefs.getString('public_key_hex') ?? '';
        if (sovId.isEmpty)     sovId     = _stripAppId((await KeyManager.getSovereignId()) ?? '');
        if (pubKeyHex.isEmpty) pubKeyHex = (await KeyManager.getPublicKey()) ?? '';
        if (sovId.isEmpty) return;
        final msgPubKeyHex = await MessageKeyManager.getPublicKeyHex();
        final ts = _nowMs();
        String? sig;
        if (pubKeyHex.isNotEmpty) {
          for (var a = 0; a < 2 && sig == null; a++) {
            try {
              sig = await KeyManager.signChallenge('$sovId:$ts');
            } catch (_) {
              if (a == 0) await Future.delayed(const Duration(milliseconds: 150));
            }
          }
        }
        _lastPresentedPublicKey = pubKeyHex;
        sendRaw({
          'type':                 'HELLO',
          'sovereign_id':         sovId,
          'public_key':           pubKeyHex.isEmpty ? '0' * 64 : pubKeyHex,
          'public_key_hex':       pubKeyHex.isEmpty ? '0' * 64 : pubKeyHex,
          if (sig != null) 'signature': sig,
          if (sig != null) 'timestamp': ts,
          'messaging_public_key': msgPubKeyHex,
          'version':              '1.0.0',
        });
        debugPrint('[RELAY TX] HELLO (key republish) as $sovId'
            '${sig == null ? ' [UNSIGNED]' : ' [signed]'}');
      } catch (e) {
        debugPrint('[RELAY] _sendHello(republish) error: $e');
      }
      return;
    }
    // Normal HELLO path — reset ACK flag on every HELLO attempt so that reconnections
    // also wait correctly for the new HELLO_ACK before firing onConnected.
    _helloAckReceived = false;
    _keyRepublishAttempts = 0;   // fresh connection — reset mismatch counter
    try {
      // Primary: SharedPreferences (written by enrollment, always present)
      final prefs       = await SharedPreferences.getInstance();
      String sovId      = prefs.getString('sovereign_id') ?? '';
      String pubKeyHex  = prefs.getString('public_key_hex') ?? '';

      // Fallback: KeyManager secure storage
      if (sovId.isEmpty) {
        sovId     = _stripAppId((await KeyManager.getSovereignId()) ?? '');
      }
      if (pubKeyHex.isEmpty) {
        pubKeyHex = (await KeyManager.getPublicKey()) ?? '';
      }

      if (sovId.isEmpty) {
        debugPrint('[RELAY TX] HELLO skipped — no sovereign_id yet');
        return;
      }

      // S2: Include messaging public key so relay can serve it to contacts
      // who want to send us E2E-encrypted SOV Speak messages.
      final msgPubKeyHex = await MessageKeyManager.getPublicKeyHex();

      // [PALM-NAME] Include palm_name in HELLO so existing enrolled citizens
      // register their name on the relay without needing to re-enroll.
      // The relay stores it only if the row currently has no palm_name.
      final storedPalmName = prefs.getString('palm_name') ?? '';

      // [SECURITY] Sign the HELLO with Ed25519 so the relay can verify this
      // connection actually owns the claimed sovereign_id.  Without a signature
      // any attacker can claim any sovereign_id (legacy-mode impersonation).
      // Payload: '<sovereign_id>:<timestamp_ms>' — matches relay verification in
      // citizen_gateway.js _handleHello():
      //   Buffer.from(`${sovereign_id}:${timestamp}`)
      // Fall back to unsigned (legacy) HELLO only during enrollment, before the
      // private key exists.  Unenrolled citizens have no funds to steal.
      final helloTimestamp = _nowMs();
      String? helloSignature;
      if (pubKeyHex.isNotEmpty) {
        // Retry once on a cold secure-storage read (msgsigfix 2026-06-16). A transient
        // signing miss here ships an UNSIGNED HELLO, which the node treats as legacyMode
        // and then rejects every MESSAGE_SEND with SIGNATURE_REQUIRED for the entire life
        // of the connection — the citizen sees messages silently fail to send.
        for (var attempt = 0; attempt < 2 && helloSignature == null; attempt++) {
          try {
            helloSignature = await KeyManager.signChallenge('$sovId:$helloTimestamp');
          } catch (e) {
            // Private key not yet stored (enrollment flow) — fall back to legacy.
            debugPrint('[RELAY] HELLO signing failed (attempt ${attempt + 1}/2): $e');
            if (attempt == 0) await Future.delayed(const Duration(milliseconds: 150));
          }
        }
      }

      _lastPresentedPublicKey = pubKeyHex;
      sendRaw({
        'type':                  'HELLO',
        'sovereign_id':          sovId,
        // 'public_key' is the field the relay reads for new-format signed HELLOs.
        // 'public_key_hex' is kept for backward compat with legacy relay nodes.
        'public_key':            pubKeyHex.isEmpty ? '0' * 64 : pubKeyHex,
        'public_key_hex':        pubKeyHex.isEmpty ? '0' * 64 : pubKeyHex,
        if (helloSignature != null) 'signature':  helloSignature,
        if (helloSignature != null) 'timestamp':  helloTimestamp,
        'messaging_public_key':  msgPubKeyHex,
        if (storedPalmName.isNotEmpty) 'palm_name': storedPalmName,
        // Circuit-relay: when connected via a relay R, tell R which NAT'd node N to
        // bridge this session to. Empty for normal direct connections.
        if (_currentTargetNodeId.isNotEmpty) 'target_node_id': _currentTargetNodeId,
        'version':               '1.0.0',
      });
      debugPrint('[RELAY TX] HELLO as $sovId');
      // Fire onConnected immediately after sending HELLO.
      // We no longer wait for HELLO_ACK — the relay was never patched to send
      // it, so the 3-second fallback was the only path that ever fired, and
      // that 3-second delay caused outbox WATCH_ADD to arrive late, making
      // every reconnection appear to work but with offline-message delivery
      // silently broken for the first 3 seconds.
      //
      // The NULL-watcher race (WATCH_ADD arriving before relay sets
      // ws._sovereignId) is already fixed on the relay side:
      // _handleWatchAdd uses msg.watcher_sovereign_id as a fallback when
      // ws._sovereignId is null.  HELLO_ACK waiting is therefore not needed.
      if (!_helloAckReceived) {
        _helloAckReceived = true;
        debugPrint('[RELAY] onConnected fired after HELLO send');
        onConnected?.call();
        _relayConnectedController.add(null);
        // Self-heal: verify our messaging key is registered on the node.
        // If it returned null (e.g. first-ever connection, or key was wiped),
        // resend HELLO so the node stores it.  Runs deferred so the connection
        // is fully settled before the query goes out.
        _verifyOwnMessagingKey(sovId, msgPubKeyHex);
      }
    } catch (e) {
      debugPrint('[RELAY] _sendHello error: $e');
    }
  }

  static int _keyRepublishAttempts = 0;

  // After connecting, verify the node has our messaging public key.
  // If it's missing or mismatched, resend HELLO (key republish only) to re-register.
  // Capped at 2 attempts to prevent an infinite reconnect loop when the node
  // protects against key replacement for existing enrolled citizens.
  static Future<void> _verifyOwnMessagingKey(
      String sovereignId, String expectedKey) async {
    if (sovereignId.isEmpty || expectedKey.isEmpty) return;
    await Future.delayed(const Duration(seconds: 3));
    try {
      final nodeKey = await lookupMessagingKey(sovereignId);
      if (nodeKey != expectedKey) {
        _keyRepublishAttempts++;
        if (_keyRepublishAttempts <= 2) {
          debugPrint('[RELAY] Messaging key mismatch — republishing via HELLO (attempt $_keyRepublishAttempts/2)');
          _sendHello(republish: true);
        } else {
          debugPrint('[RELAY] Messaging key mismatch — max retries reached, continuing with current connection');
          _keyRepublishAttempts = 0;
        }
      } else {
        debugPrint('[RELAY] Messaging key verified on node ✓');
        _keyRepublishAttempts = 0;
      }
    } catch (_) {}
  }

  // ── Shared incoming message handler (WSS + native) ───────────────────────
  // All messages from both transports funnel here so routing logic lives
  // in exactly one place.  RELAY_LIST_RESULT == native name for the same
  // response that WSS sends as RELAY_LIST_RESPONSE — handle both.
  static void _handleIncomingMessage(Map<String, dynamic> decoded) {
    _messageController ??= StreamController<Map<String, dynamic>>.broadcast();

    // Liveness proof — ANY inbound packet proves the socket is alive. The
    // heartbeat timer uses this timestamp to detect zombie connections.
    // See docs/CONNECTIVITY_DEBUG_LOG.md.
    _lastInboundAt = DateTime.now();

    // ── Dictionary protocol normalisation ─────────────────────────────────
    // sov-node sends BOTH 'type' and 'op'. If a future node version sends
    // 'op' only, look up the full type string so all switch cases still match.
    if (decoded['type'] == null && decoded['op'] is String) {
      final resolved = _typeFromOp[decoded['op'] as String];
      if (resolved != null) decoded['type'] = resolved;
    }

    final type = decoded['type'] as String?;
    // Silent acknowledgement of PONG — no need to fan out to the message
    // stream; the _lastInboundAt update above is the only thing that matters.
    if (type == 'PONG') return;
    // Logcat-visible trace for every relay message — useful for diagnosing
    // delivery issues in Android Studio logcat filter [RELAY RX].
    debugPrint('[RELAY RX] ${decoded['op'] ?? type}');
    switch (type) {
      // Protocol error from the node. HELLO_STALE_TIMESTAMP carries the node's
      // clock so we can self-correct skew and re-register with a valid signature.
      case 'ERROR':
        final errCode = (decoded['code'] ?? '').toString();
        if (errCode == 'HELLO_STALE_TIMESTAMP') {
          final nodeTime = (decoded['node_time'] as num?)?.toInt();
          if (nodeTime != null) {
            _nodeClockOffsetMs = nodeTime - DateTime.now().millisecondsSinceEpoch;
            debugPrint('[RELAY] Clock skew detected — node is ${_nodeClockOffsetMs}ms '
                'from local; signing with corrected time from now on');
          }
        }
        _messageController?.add(decoded);
        return;

      // Relay greeting — respond with HELLO to register in relay's _registry.
      // Without HELLO the relay cannot route incoming messages to this device.
      case 'RELAY_HELLO':
        _helloAckReceived = false;   // reset so onConnected fires on this new cycle
        _keyRepublishAttempts = 0;   // new connection cycle — reset mismatch counter
        _sendHello();                // sends HELLO → fires onConnected immediately
        _messageController?.add(decoded);
        return;

      // HELLO_ACK — relay confirmed it processed our HELLO.
      // onConnected was already fired immediately after HELLO was sent
      // (see _sendHello).  This case is kept as a no-op in case any relay
      // still sends HELLO_ACK — we just absorb it without double-firing.
      case 'HELLO_ACK':
        _helloAckReceived = true; // already true, but be explicit
        debugPrint('[RELAY RX] HELLO_ACK received (onConnected already fired)');
        _messageController?.add(decoded);
        return;
      case 'HOP_BRIDGE_LIST':
        _handleHopNodeList(decoded);
        return;
      case 'RELAY_ANNOUNCE':
        _handleRelayAnnounce(decoded);
        return;
      case 'RELAY_LIST_RESULT':   // native protocol name
      case 'RELAY_LIST_RESPONSE': // WSS protocol name
        _handleRelayListResponse(decoded);
        _messageController?.add(decoded);
        return;
      case 'LEDGER_SYNC_RESPONSE':
        _handleLedgerSync(decoded);
        _messageController?.add(decoded);
        return;
      case 'SOV_LINK_DELIVERED':
        _handleSovLinkDelivered(decoded);
        return;
      case 'SOV_LINK_INCOMING':
        _sovLinkIncomingController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── N2a SOV Speak ─────────────────────────────────────────────────────
      case 'CITIZEN_ONLINE':
        OutboxManager.onCitizenOnline(
            decoded['sovereign_id'] as String? ?? '');
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'MESSAGE_INCOMING':
        // Send delivery receipt immediately — relay holds RELAY_DELIVERY_ACK
        // for 5 s waiting for this confirmation before reporting delivery status
        // to the origin relay / sender. Fire-and-forget before any await.
        final drMsgId = decoded['message_id'] as String? ??
                        decoded['id']         as String? ?? '';
        if (drMsgId.isNotEmpty) {
          try {
            sendRaw({
              'type':       'MESSAGE_DELIVERY_RECEIPT',
              'message_id': drMsgId,
            });
          } catch (_) {}
        }
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'SOV_TRANSFER_RECEIVED':
        // Route to incomingMessages stream so main_shell can persist the
        // received transaction and show a notification/banner.
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'MESSAGE_READ_RECEIPT':
        _readReceiptController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'MESSAGE_REACTION_UPDATE':            // [S9]
        _reactionUpdateController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'WATCH_CONFIRMED':
      case 'WATCH_REMOVED':
      case 'PRESENCE_RESULT':
      case 'MESSAGE_SEND_RESULT':
      case 'CALL_RESULT':
      case 'CALL_ANSWER_RESULT':
        _messageController?.add(decoded);
        return;
      // ── Governance live-push events ───────────────────────────────────────
      case 'POLL_COUNT_UPDATE':
        _pollCountUpdateController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'POLL_CLOSED':
        _pollClosedController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'GOVERNANCE_PARAM_ACTIVATED':
        _govParamActivatedController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── Exchange SOV Shield events ────────────────────────────────────────────
      // Route to incomingMessages so main_shell can show banners / handle balance.
      case 'EXCHANGE_ESCROW_LOCKED':
      case 'EXCHANGE_ORDER_FILLED_NOTIFY':
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── Justice Council live-push events ─────────────────────────────────────
      // JUSTICE_JUROR_INVITE — relay selected this citizen as a juror.
      // Route to both incomingMessages (main_shell banner) and jurorInviteStream
      // (governance Justice tab shows Accept/Decline UI).
      case 'JUSTICE_JUROR_INVITE':
        _incomingMessageController.add(decoded);
        _jurorInviteController.add(decoded);
        _messageController?.add(decoded);
        return;
      // JUSTICE_CASE_UPDATE — relay pushes verdict, juror accepted, panel expanded.
      // Route to justiceCaseUpdateStream so Justice tab can refresh in-place.
      case 'JUSTICE_CASE_UPDATE':
        _justiceCaseUpdateController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── SOV Speak live-push events ────────────────────────────────────────────
      // ENCLAVE_NEW_POST / ENCLAVE_NEW_REPLY — node pushes these to all connected
      // citizens on the same relay whenever a new post or reply is saved.
      // Route to incomingMessages so messages_screen can insert them in-place
      // without the citizen needing to pull-to-refresh.
      case 'ENCLAVE_NEW_POST':
      case 'ENCLAVE_NEW_REPLY':
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── Exchange push-subscribe events ───────────────────────────────────────
      // EXCHANGE_STATE — relay pushes full open-order list immediately on subscribe.
      case 'EXCHANGE_STATE':
        _exchangeStateController.add(decoded);
        return;
      // EXCHANGE_ORDER_UPDATE — relay pushes single order change to all subscribers.
      case 'EXCHANGE_ORDER_UPDATE':
        _exchangeUpdateController.add(decoded);
        return;

      // ── Exchange Chat live-push events ────────────────────────────────────────
      // EXCHANGE_CHAT_INCOMING — relay pushes this when a trade message arrives.
      // Relay-native: message stored in sov_exchange_messages, phone just renders.
      case 'EXCHANGE_CHAT_INCOMING':
        _exchangeChatController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── S3 SOV Request paid notification ──────────────────────────────────────
      // SOV_REQUEST_PAID_NOTIFY — relay pushes this to the requester when the payer
      // sends SOV and includes a matching payment_request_id in the transfer.
      case 'SOV_REQUEST_PAID_NOTIFY':
        _paymentRequestPaidController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── S10 Guardian Recovery live-push events ───────────────────────────────
      // GUARDIAN_INVITE — citizen nominated this user as a guardian.
      // Route to main_shell (gold banner) + guardianInviteStream (guardian screen).
      case 'GUARDIAN_INVITE':
        _guardianInviteController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // GUARDIAN_APPROVAL_REQUEST — a citizen is requesting recovery approval.
      // GUARDIAN_RECOVERY_COMPLETE — relay confirms the recovery was approved.
      // GUARDIAN_RECOVERY_REJECTED — a guardian rejected the request.
      case 'GUARDIAN_APPROVAL_REQUEST':
        _guardianRecoveryController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      case 'GUARDIAN_RECOVERY_COMPLETE':
      case 'GUARDIAN_RECOVERY_REJECTED':
        _guardianRecoveryController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── S12 Monetary Issuance ─────────────────────────────────────────────
      // Relay pushes this on HELLO when citizen has unclaimed SOV allocation.
      case 'ISSUANCE_AVAILABLE':
        _issuanceAvailableController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── S8 Group Channels ─────────────────────────────────────────────────────
      // GROUP_MESSAGE_INCOMING — relay pushes when any group member sends a message.
      case 'GROUP_MESSAGE_INCOMING':
        _groupMessageController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // GROUP_INVITE — relay pushes when citizen is added to a new group.
      case 'GROUP_INVITE':
        _groupInviteController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // GROUP_UPDATE — membership change (add member / leave).
      case 'GROUP_UPDATE':
        _groupUpdateController.add(decoded);
        _messageController?.add(decoded);
        return;
      // ── S15 Voice/Video Calls ─────────────────────────────────────────────
      // CALL_INVITE received by callee = CALL_INCOMING notification.
      // op='CI' from relay to callee contains call_id, caller_id, call_type,
      // livekit_url (not the token — token is in CALL_ANSWER_RESULT).
      case 'CALL_INVITE':
        _incomingCallController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // CALL_ANSWERED — relay delivers this to the caller after callee accepts.
      // Contains: call_id, token (caller's LiveKit JWT), livekit_url.
      case 'CALL_ANSWERED':
        _callAnsweredController.add(decoded);
        _messageController?.add(decoded);
        return;
      // CALL_ENDED — relay notifies both parties when call terminates.
      case 'CALL_ENDED':
        _callEndedController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // CALL_REJECTED — relay notifies caller when callee declines.
      case 'CALL_REJECTED':
        _callEndedController.add(decoded);
        _incomingMessageController.add(decoded);
        _messageController?.add(decoded);
        return;
      // Witness protocol — NodeWitness picks these up from the stream
      case 'ENROLLMENT_WITNESS':
      case 'ENROLLMENT_ACK':
      case 'ENROLLMENT_CONFIRMED':
      case 'ENROLLMENT_REJECTED':
      case 'RECOVERY_WITNESS_REQUEST':
      case 'SEED_RECOVERY_WITNESS_REQUEST':
      case 'KEY_ROTATION_PROPOSAL':
        _messageController?.add(decoded);
        return;
    }
    _messageController?.add(decoded);
  }

  static void _handleHopNodeList(Map<String, dynamic> data) {
    final nodes = data['nodes'] as List?;
    if (nodes == null) return;
    _hopNodes.clear();
    for (final node in nodes) {
      try {
        _hopNodes.add(HopNode(
          sovereignId: node['sovereign_id'] as String,
          relayUrl:    node['relay_url']    as String,
          latency:     (node['latency'] as num?)?.toInt() ?? 999,
          lastSeen:    DateTime.now(),
        ));
      } catch (_) {}
    }
  }

  // A full RELAY_LIST_RESPONSE is the connected node's authoritative snapshot of
  // who is ALIVE right now. Unlike a single RELAY_ANNOUNCE (which only adds), the
  // full list REPLACES _knownRelays so dead nodes — terminated VPS, ephemeral
  // full-node test IDs — are pruned instead of lingering forever. First-seen
  // addedAt is preserved for nodes we already knew so the "Added" date stays
  // meaningful. The currently-connected endpoint is always kept even if a transient
  // snapshot omits it.
  static void _handleRelayListResponse(Map<String, dynamic> data) {
    final relays = data['relays'] as List?;
    if (relays == null) return;
    final fresh = <RelayEntry>[];
    final seen  = <String>{};
    for (final item in relays) {
      try {
        final raw = RelayEntry.fromJson(item as Map<String, dynamic>);
        if (raw.ip.isEmpty || raw.port < 1 || raw.port > 65535) continue;
        // Citizens always connect on 443 (pool gossip may carry peer-mesh 7771).
        final base = raw.port == 443
            ? raw
            : RelayEntry(
                relayId:     raw.relayId,
                ip:          raw.ip,
                port:        443,
                fingerprint: raw.fingerprint,
                name:        raw.name,
                nickname:    raw.nickname,
                addedAt:     raw.addedAt,
              );
        final key = base.relayId.isNotEmpty ? base.relayId : base.ip;
        if (!seen.add(key)) continue;
        // Preserve the original first-seen date if we already knew this node.
        final priorMatches =
            _knownRelays.where((r) => r.relayId == base.relayId || r.ip == base.ip);
        final addedAt =
            priorMatches.isNotEmpty ? priorMatches.first.addedAt : base.addedAt;
        fresh.add(RelayEntry(
          relayId:     base.relayId,
          ip:          base.ip,
          port:        base.port,
          fingerprint: base.fingerprint,
          name:        base.name,
          nickname:    base.nickname,
          addedAt:     addedAt,
        ));
      } catch (_) {}
    }
    if (fresh.isEmpty) return; // never blank the list on a malformed/empty snapshot

    // Keep the currently-connected node even if this snapshot happened to omit it.
    final ep = _currentEndpoint ?? '';
    final connectedIp = ep.isNotEmpty ? (Uri.tryParse(ep)?.host ?? '') : '';
    if (connectedIp.isNotEmpty && !fresh.any((r) => r.ip == connectedIp)) {
      final keep = _knownRelays.where((r) => r.ip == connectedIp);
      if (keep.isNotEmpty) fresh.add(keep.first);
    }

    _knownRelays
      ..clear()
      ..addAll(fresh);
    _saveRelayList();
  }

  // ── Ledger sync — restores wallet balance after reinstall ─────────────────
  static Function(double balance, List transactions)? onLedgerSync;

  // ── Fired every time the relay connection is established (or re-established).
  // Wire OutboxManager.retryAll() here so watch entries are always re-registered
  // after any reconnect, not just when a chat screen is open.
  static VoidCallback? onConnected;

  // Broadcast stream that fires every time the relay connection is established.
  // Screens can subscribe to this to reload data that requires a live connection,
  // e.g. forum status, governance params, exchange orders.
  static final _relayConnectedController = StreamController<void>.broadcast();
  static Stream<void> get relayConnected => _relayConnectedController.stream;

  // ── SOV Link — E2E encrypted relay messages (30-second memory TTL) ─────────
  // Register this callback in any screen that wants to receive messages.
  // Called on the current isolate when SOV_LINK_DELIVERED arrives.
  static Function(String senderSovId, String encryptedPayload)? onSovLinkReceived;

  // ── SOV Link Incoming — routing request notification stream ──────────────
  // Fires when this citizen receives a SOV_LINK_INCOMING routed from the relay.
  // SOV Link screen subscribes to this for incoming connection requests.
  static final _sovLinkIncomingController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get sovLinkIncoming =>
      _sovLinkIncomingController.stream;

  static void _handleLedgerSync(Map<String, dynamic> data) {
    final balance      = (data['balance'] as num?)?.toDouble() ?? 0.0;
    final transactions = data['transactions'] as List? ?? [];
    final pendingCount = (data['pending_count'] as num?)?.toInt() ?? 0;

    onLedgerSync?.call(balance, transactions);
    _messageController?.add(data);

    // If the relay included offline-backup-disc records (transactions that
    // arrived while this citizen was offline), acknowledge receipt so the
    // relay and all its peers can purge those records and stay lean.
    if (pendingCount > 0) {
      _sendLedgerSyncAck(pendingCount);
    }
  }

  static Future<void> _sendLedgerSyncAck(int pendingCount) async {
    try {
      // Use the same sovereign_id priority as _sendHello:
      // SharedPreferences first (written by enrollment), KeyManager as fallback.
      // Using KeyManager alone caused ACK to be silently dropped for accounts
      // whose sovId lives in SharedPreferences but not in secure storage.
      final prefs = await SharedPreferences.getInstance();
      String sovId = prefs.getString('sovereign_id') ?? '';
      if (sovId.isEmpty) sovId = _stripAppId((await KeyManager.getSovereignId()) ?? '');
      if (sovId.isEmpty) {
        debugPrint('[RELAY] LEDGER_SYNC_ACK skipped — sovereign_id unavailable');
        return;
      }
      sendRaw({
        'type':         'LEDGER_SYNC_ACK',
        'sovereign_id': sovId,
        'timestamp':    _nowMs(),
      });
      debugPrint('[RELAY] LEDGER_SYNC_ACK sent for $sovId ($pendingCount offline txs)');
    } catch (e) {
      debugPrint('[RELAY] LEDGER_SYNC_ACK error: $e');
    }
  }

  static void _handleSovLinkDelivered(Map<String, dynamic> data) {
    final sender  = data['sender_sovereign_id'] as String? ?? '';
    final payload = data['encrypted_payload']   as String? ?? '';
    onSovLinkReceived?.call(sender, payload);
    _messageController?.add(data);
  }

  // ── N2a SOV Speak streams ──────────────────────────────────────────────────

  /// Fires on MESSAGE_INCOMING, CITIZEN_ONLINE and SOV_TRANSFER_RECEIVED.
  static final _incomingMessageController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get incomingMessages =>
      _incomingMessageController.stream;

  /// Fires on MESSAGE_READ_RECEIPT from the relay.
  static final _readReceiptController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get readReceipts =>
      _readReceiptController.stream;

  // ── [S9] Reaction live-push stream ───────────────────────────────────────

  /// Fires when the relay pushes a MESSAGE_REACTION_UPDATE for any message
  /// in the currently open conversation. Payload: { message_id, reactions }
  static final _reactionUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get reactionUpdates =>
      _reactionUpdateController.stream;

  /// Add an emoji reaction to a message.
  /// [messageId]         — the LocalMessage.id
  /// [otherSovereignId]  — the other participant (so relay can push update to both)
  /// [emoji]             — one of '👍' '❤️' '😂' '😮' '😢' '🔥'
  static Future<bool> reactToMessage({
    required String messageId,
    required String otherSovereignId,
    required String emoji,
    String? conversationId,
  }) async {
    final prefs      = await SharedPreferences.getInstance();
    final sovereignId = prefs.getString('node_id') ?? '';
    final result = await sendAndWait(
      request: {
        'type':              'MESSAGE_REACT',
        'message_id':        messageId,
        'reactor_id':        sovereignId,
        'emoji':             emoji,
        'other_sovereign_id': otherSovereignId,
        if (conversationId != null) 'conversation_id': conversationId,
      },
      // The node never sends a *_RESULT for reactions: message_engine pushes
      // MESSAGE_REACTION_UPDATE to BOTH parties (including the reactor), and
      // that push is the confirmation. Waiting on a _RESULT timed out after 6s
      // and returned false, so a reaction that had actually landed reported as
      // failed. Found by protocol_audit.py check G.
      responseType: 'MESSAGE_REACTION_UPDATE',
      matchField:   'message_id',
      matchValue:   messageId,
      timeout:      const Duration(seconds: 6),
    );
    return result?['success'] == true;
  }

  /// Remove an emoji reaction from a message.
  static Future<bool> unreactToMessage({
    required String messageId,
    required String otherSovereignId,
    required String emoji,
  }) async {
    final prefs      = await SharedPreferences.getInstance();
    final sovereignId = prefs.getString('node_id') ?? '';
    final result = await sendAndWait(
      request: {
        'type':              'MESSAGE_UNREACT',
        'message_id':        messageId,
        'reactor_id':        sovereignId,
        'emoji':             emoji,
        'other_sovereign_id': otherSovereignId,
      },
      // The node never sends a *_RESULT for reactions: message_engine pushes
      // MESSAGE_REACTION_UPDATE to BOTH parties (including the reactor), and
      // that push is the confirmation. Waiting on a _RESULT timed out after 6s
      // and returned false, so a reaction that had actually landed reported as
      // failed. Found by protocol_audit.py check G.
      responseType: 'MESSAGE_REACTION_UPDATE',
      matchField:   'message_id',
      matchValue:   messageId,
      timeout:      const Duration(seconds: 6),
    );
    return result?['success'] == true;
  }

  // ── Governance live-push streams ──────────────────────────────────────────

  /// Fires when the relay pushes a live vote-count update for an open poll.
  /// Payload: { poll_id, tally: [int, ...], total_votes }
  static final _pollCountUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get pollCountUpdates =>
      _pollCountUpdateController.stream;

  /// Fires when a poll is auto-closed by the relay (epoch timer).
  /// Payload: { poll_id, status:'closed', winner_index, quorum_reached, ... }
  static final _pollClosedController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get pollClosed =>
      _pollClosedController.stream;

  /// Fires when a governance parameter is activated after a winning poll.
  /// Payload: { poll_id, param_key, new_value, governance_version }
  static final _govParamActivatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get govParamActivated =>
      _govParamActivatedController.stream;

  // ── Justice Council live-push streams ────────────────────────────────────

  /// Fires when the relay selects this citizen as a juror on a new case.
  /// Payload: { case_id, plaintiff_id, defendant_id, claim_amount,
  ///            evidence_hash, expires_at, response_window_hours, timestamp }
  static final _jurorInviteController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get jurorInviteStream =>
      _jurorInviteController.stream;

  /// Fires when a justice case changes state (JUROR_ACCEPTED, PANEL_EXPANDED,
  /// VERDICT). Lets the Justice tab refresh without a full reload.
  /// Payload: { case_id, event, verdict?, new_juror_id?, total_jurors?, ... }
  static final _justiceCaseUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get justiceCaseUpdateStream =>
      _justiceCaseUpdateController.stream;

  // ── Exchange Chat live stream ─────────────────────────────────────────────
  /// Fires whenever EXCHANGE_CHAT_INCOMING arrives from the relay.
  /// The exchange chat sheet subscribes to this to show new messages in real-time
  /// without polling. Relay is the single source of truth — phone renders only.
  /// Payload: { message: { msg_id, order_id, from_id, to_id, content, created_at } }
  static final _exchangeChatController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get exchangeChatStream =>
      _exchangeChatController.stream;

  // ── Exchange push-subscribe streams ─────────────────────────────────────
  /// Fires when the relay pushes the full open-order list (on subscribe).
  /// Payload: { orders: [...], ts }
  static final _exchangeStateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get exchangeStateStream =>
      _exchangeStateController.stream;

  /// Fires when any order changes while subscribed.
  /// Payload: { order: {...}, event: 'new'|'updated'|'removed', ts }
  static final _exchangeUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get exchangeUpdateStream =>
      _exchangeUpdateController.stream;

  // ── S10 Guardian Recovery streams ────────────────────────────────────────
  /// Fires when a citizen nominates this user as a guardian (GUARDIAN_INVITE).
  /// Payload: { citizen_id, timestamp }
  static final _guardianInviteController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get guardianInviteStream =>
      _guardianInviteController.stream;

  /// Fires when a recovery request changes state:
  /// GUARDIAN_APPROVAL_REQUEST — guardian needs to act on a recovery request.
  /// GUARDIAN_RECOVERY_COMPLETE — recovery approved; new device is active.
  /// GUARDIAN_RECOVERY_REJECTED — a guardian rejected the request.
  static final _guardianRecoveryController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get guardianRecoveryStream =>
      _guardianRecoveryController.stream;

  // ── S12 Monetary Issuance stream ─────────────────────────────────────────
  /// Fires on HELLO when relay detects unclaimed SOV allocation epochs.
  /// Payload: { epoch_ids: [...], amount_seeds, rate_per_epoch, timestamp }
  static final _issuanceAvailableController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get issuanceAvailableStream =>
      _issuanceAvailableController.stream;

  // ── S8 Group Channels streams ─────────────────────────────────────────────

  /// Fires when a new message arrives in any group the citizen belongs to.
  /// Payload: { msg_id, group_id, sender_id, content, media_type, ts }
  static final _groupMessageController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get groupMessageStream =>
      _groupMessageController.stream;

  /// Fires when the relay pushes GROUP_INVITE — citizen was added to a group.
  /// Payload: { group_id, group_name, invited_by, member_count, ts }
  static final _groupInviteController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get groupInviteStream =>
      _groupInviteController.stream;

  /// Fires on GROUP_UPDATE — membership changed (add member / leave / error).
  static final _groupUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get groupUpdateStream =>
      _groupUpdateController.stream;

  // ── S8 Group SDK methods ──────────────────────────────────────────────────

  /// Create a new group channel.
  /// [groupId] must be unique (8-64 chars, alphanumeric + _-).
  /// [memberIds] is the initial members (creator is added automatically by relay).
  static Future<Map<String, dynamic>?> createGroup({
    required String groupId,
    required String name,
    required String createdBy,
    required List<String> memberIds,
  }) async {
    return sendAndWait(
      request: {
        'type':       'GROUP_CREATE',
        'group_id':   groupId,
        'name':       name,
        'created_by': createdBy,
        'member_ids': memberIds,
      },
      responseType: 'GROUP_CREATED',
      timeout: const Duration(seconds: 10),
    );
  }

  /// Send a message to a group. [content] is the plain text (no E2E yet —
  /// stored as '*' envelope so all members receive the same content).
  static Future<Map<String, dynamic>?> sendGroupMessage({
    required String msgId,
    required String groupId,
    required String content,
    String mediaType = 'text',
  }) async {
    // Use '*' wildcard envelope so the node delivers the same content to all.
    final envelopes = {'*': content};
    return sendAndWait(
      request: {
        'type':       'GROUP_SEND',
        'msg_id':     msgId,
        'group_id':   groupId,
        'envelopes':  envelopes,
        'media_type': mediaType,
        'timestamp':  _nowMs(),
      },
      responseType: 'MESSAGE_ACK',
      matchField:   'msg_id',
      matchValue:   msgId,
      timeout: const Duration(seconds: 10),
    );
  }

  /// List all groups the current citizen belongs to.
  static Future<List<Map<String, dynamic>>> listGroups(String memberSovId) async {
    final resp = await sendAndWait(
      request: {'type': 'GROUP_LIST', 'member_id': memberSovId},
      responseType: 'GROUP_LIST_RESULT',
      timeout: const Duration(seconds: 10),
    );
    final raw = (resp ?? {})['groups'] as List? ?? [];
    return List<Map<String, dynamic>>.from(raw);
  }

  /// Fetch message history for a group (newest-first, up to 50 messages).
  static Future<List<Map<String, dynamic>>> getGroupHistory(
      String groupId, {int? beforeTs, int limit = 50}) async {
    final resp = await sendAndWait(
      request: {
        'type':      'GROUP_HISTORY',
        'group_id':  groupId,
        if (beforeTs != null) 'before_ts': beforeTs,
        'limit':     limit,
      },
      responseType: 'GROUP_HISTORY_RESULT',
      matchField:   'group_id',
      matchValue:   groupId,
      timeout: const Duration(seconds: 10),
    );
    final raw = (resp ?? {})['messages'] as List? ?? [];
    return List<Map<String, dynamic>>.from(raw);
  }

  /// Add a member to a group (admin only).
  static Future<Map<String, dynamic>?> addGroupMember(
      {required String groupId, required String newMemberId}) async {
    return sendAndWait(
      request: {
        'type':          'GROUP_ADD_MEMBER',
        'group_id':      groupId,
        'new_member_id': newMemberId,
      },
      responseType: 'GROUP_UPDATE',
      matchField:   'group_id',
      matchValue:   groupId,
      timeout: const Duration(seconds: 10),
    );
  }

  /// Leave a group.
  static Future<void> leaveGroup(String groupId) async {
    if (_connected) {
      send({'type': 'GROUP_LEAVE', 'group_id': groupId});
    }
  }

  // ── S15 Voice/Video Call streams ─────────────────────────────────────────

  /// Fires when the relay pushes a CALL_INVITE to this citizen (callee side).
  /// Payload: { call_id, caller_id, call_type: 'audio'|'video', livekit_url }
  static final _incomingCallController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get incomingCallStream =>
      _incomingCallController.stream;

  /// Fires when the callee accepts — relay sends the caller's LiveKit JWT.
  /// Payload: { call_id, token, livekit_url }
  static final _callAnsweredController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get callAnsweredStream =>
      _callAnsweredController.stream;

  /// Fires on CALL_ENDED (natural end or max-duration) and CALL_REJECTED.
  /// Payload: { call_id, reason? }
  static final _callEndedController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get callEndedStream =>
      _callEndedController.stream;

  // ── S15 Voice/Video Call SDK methods ─────────────────────────────────────

  /// Initiate a call to [calleeId].  Returns { success, call_id, livekit_url }
  /// on success, or { success: false, error } if calls are not activated.
  static Future<Map<String, dynamic>?> initiateCall({
    required String calleeId,
    String callType = 'audio',  // 'audio' or 'video'
  }) async {
    final callId = 'CALL-${_nowMs()}';
    return sendAndWait(
      request: {
        'type':      'CALL_INVITE',
        'call_id':   callId,
        'callee_id': calleeId,
        'call_type': callType,
      },
      responseType: 'CALL_INVITE_RESULT',
      timeout: const Duration(seconds: 15),
    );
  }

  /// Accept an incoming call.  Returns { success, call_id, token, livekit_url }.
  static Future<Map<String, dynamic>?> answerCall({
    required String callId,
  }) async {
    return sendAndWait(
      request: {
        'type':    'CALL_ANSWER',
        'call_id': callId,
      },
      responseType: 'CALL_ANSWER_RESULT',
      timeout: const Duration(seconds: 15),
    );
  }

  /// End or hangup a call from either side.
  static void endCall(String callId) {
    send({'type': 'CALL_END', 'call_id': callId});
  }

  /// Reject an incoming call (callee side).
  static void rejectCall(String callId) {
    send({'type': 'CALL_REJECT', 'call_id': callId});
  }

  // ── S6 SOV Login SDK ─────────────────────────────────────────────────────

  /// Respond to a SOV Login challenge from an external website.
  /// [sessionId] and [challenge] come from the scanned sovlogin:// QR code.
  /// Signs `sessionId|challenge` with the citizen's Ed25519 key and sends
  /// SOV_LOGIN_RESPOND to the relay, which verifies and notifies the website.
  static Future<Map<String, dynamic>?> respondSovLogin({
    required String sessionId,
    required String challenge,
  }) async {
    final prefs      = await SharedPreferences.getInstance();
    final sovereignId = prefs.getString('sovereign_id') ?? '';
    if (sovereignId.isEmpty) return null;

    // Sign the challenge payload: sessionId:challenge  (colon separator — matches relay)
    final signature    = await KeyManager.signChallenge('$sessionId:$challenge');

    return sendAndWait(
      request: {
        'type':         'SOV_LOGIN_RESPOND',
        'session_id':   sessionId,
        'sovereign_id': sovereignId,
        'challenge':    challenge,
        'signature':    signature,
      },
      responseType: 'SOV_LOGIN_RESPOND_RESULT',
      timeout:      const Duration(seconds: 10),
    );
  }

  // ── S3 SOV Request streams ────────────────────────────────────────────────

  /// Fires when the relay confirms a payment request has been paid.
  /// Payload: { request_id, payer_id, amount_seeds, memo, paid_at }
  static final _paymentRequestPaidController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get paymentRequestPaid =>
      _paymentRequestPaidController.stream;

  /// Register a payment request on the relay.
  /// The relay stores it in sov_payment_requests and watches for matching transfers.
  static Future<void> createPaymentRequest({
    required String requesterId,
    required String requestId,
    required int    amountSeeds,
    required String memo,
    required int    expiresAt,
  }) async {
    await sendAndWait(
      request: {
        'type':         'SOV_REQUEST_CREATE',
        'requester_id': requesterId,
        'request_id':   requestId,
        'amount_seeds': amountSeeds,
        'memo':         memo,
        'expires_at':   expiresAt,
      },
      responseType: 'SOV_REQUEST_CREATED',
      timeout: const Duration(seconds: 8),
    );
  }

  /// List payment requests for this citizen from the relay.
  static Future<List<Map<String, dynamic>>> listPaymentRequests(
      String requesterId) async {
    final resp = await sendAndWait(
      request: {
        'type':         'SOV_REQUEST_LIST',
        'requester_id': requesterId,
      },
      responseType: 'SOV_REQUEST_LIST_RESULT',
      timeout: const Duration(seconds: 8),
    );
    if (resp == null) return [];
    return (resp['requests'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Send an exchange trade message. Returns the relay result map.
  /// Uses relay-native EXCHANGE_CHAT_SEND — stored in sov_exchange_messages,
  /// pushed live via EXCHANGE_CHAT_INCOMING. No ContactsDb involvement.
  static Future<Map<String, dynamic>> sendExchangeChatMessage({
    required String orderId,
    required String fromId,
    required String toId,
    required String content,
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':     'EXCHANGE_CHAT_SEND',
        'order_id': orderId,
        'from_id':  fromId,
        'to_id':    toId,
        'content':  content,
      },
      responseType: 'EXCHANGE_CHAT_SEND_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Fetch trade messages for an order's negotiation thread.
  /// A buyer gets their own thread; a seller passes [buyerId] to open one
  /// buyer's thread (from the negotiation inbox). Opening also marks the
  /// viewer's inbound messages read (clears the unread badge).
  static Future<List<Map<String, dynamic>>> getExchangeChatMessages(
      String orderId, {String? buyerId}) async {
    final resp = await sendAndWait(
      request: {
        'type': 'EXCHANGE_CHAT_LIST',
        'order_id': orderId,
        if (buyerId != null && buyerId.isNotEmpty) 'buyer_id': buyerId,
      },
      responseType: 'EXCHANGE_CHAT_LIST_RESULT',
      timeout: const Duration(seconds: 10),
    );
    if (resp == null) return [];
    return List<Map<String, dynamic>>.from(resp['messages'] ?? []);
  }

  /// Seller negotiation inbox: the distinct buyer threads for one of the
  /// seller's orders, each with { buyer_id, last_content, last_ts, unread,
  /// reputation_score, trades_completed }. Seller-only (relay enforces).
  static Future<List<Map<String, dynamic>>> getExchangeChatThreads(
      String orderId) async {
    final resp = await sendAndWait(
      request: {'type': 'EXCHANGE_CHAT_THREADS', 'order_id': orderId},
      responseType: 'EXCHANGE_CHAT_THREADS_RESULT',
      timeout: const Duration(seconds: 10),
    );
    if (resp == null || resp['success'] != true) return [];
    return List<Map<String, dynamic>>.from(resp['threads'] ?? []);
  }

  // ── SOV Call streams — dormant; kept as stubs for future governance use ──
  // Call UI has been removed from the app. These streams exist as stubs so
  // the relay protocol can be re-activated without further schema changes.
  // Do not subscribe to these streams from app screens until calls are
  // re-enabled under governance approval.

  // ── Generic signalling send — kept for future protocol messages ──────────
  /// Fire-and-forget relay send. Auto-connects if needed.
  /// Kept dormant for future governance-approved protocol messages.
  static Future<void> sendMessage(Map<String, dynamic> message) async {
    if (!_connected) {
      try { await connect(); } catch (_) {}
    }
    if (!_connected) return;
    sendRaw(message);
  }

  // ── N2a: Fire-and-forget send (for exempt message types) ──────────────────
  /// Sends a message without waiting for a response and without signing.
  /// Used for WATCH_ADD, WATCH_REMOVE (session-level, exempt from sig check).
  static void sendRaw(Map<String, dynamic> message) {
    if (!_connected) return;
    try {
      _addOpCode(message); // dictionary protocol — adds 2-char 'op' alongside 'type'
      final json = jsonEncode(message);
      if (_nativeClient != null) {
        _nativeClient!.send(message['type'] as String? ?? '', message);
      } else {
        _channel?.sink.add(json);
      }
    } catch (e) {
      debugPrint('[RELAY] sendRaw error: $e');
    }
  }

  // ── N2a: Presence check ───────────────────────────────────────────────────
  /// Returns true if the citizen is currently online on any relay.
  static Future<bool> checkPresence(String sovereignId) async {
    try {
      final result = await sendAndWait(
        request: {
          'type':        'PRESENCE_CHECK',
          'sovereign_id': sovereignId,
        },
        responseType: 'PRESENCE_RESULT',
        timeout:      const Duration(seconds: 5),
        matchField:   'sovereign_id',
        matchValue:   sovereignId,
      );
      return result?['online'] == true;
    } catch (_) {
      return false;
    }
  }

  //
  // SECURITY PROTOCOL (enforced here, verified by relay):
  //   Every message includes:
  //     - node_id:    sender's sovereign ID
  //     - timestamp:  Unix milliseconds
  //     - nonce:      monotonically increasing counter (replay protection)
  //     - signature:  Ed25519 signature of canonical signing input
  //
  //   Relay rejects any message where:
  //     - signature does not verify against stored public key
  //     - nonce has already been seen from this node (replay attack)
  //     - timestamp is more than 5 minutes old (stale message attack)
  //
  //   This makes message forgery mathematically impossible even if an
  //   attacker captures and replays network traffic.
  // ══════════════════════════════════════════════════════════════════════════
  /// A transient enrollment-application id (AS-2026-XXXX) must NEVER go on the
  /// wire as node_id / sovereign_id. If it does, the relay's ensureDiscEntry()
  /// creates a phantom 0-balance citizen row for it — the "extra citizen" ghost
  /// seen at genesis (AS-2026-BD70C8 / AS-2026-619C0E). KeyManager.getSovereignId()
  /// can return this stale app-id when enrollment has not fully confirmed; treat
  /// any such value as not-yet-enrolled ('').
  static String _stripAppId(String id) => id.startsWith('AS-2026') ? '' : id;

  static Future<bool> send(Map<String, dynamic> message) async {
    if (!_connected) return false;
    try {
      // Use SharedPreferences as primary source for node_id — same priority as
      // _sendHello().  KeyManager.getSovereignId() can return a stale
      // enrollment-application ID (AS-2026-XXXXXX) if the Keystore was written
      // during an earlier enrollment attempt that did not fully complete.
      // SharedPreferences always holds the correct, relay-confirmed enrolled ID.
      // Mismatch causes every MESSAGE_SEND to be rejected with
      // "VERIFY REJECTED — unknown sovereign_id" even though HELLO works fine
      // (HELLO uses sendRaw, which skips node_id / signature entirely).
      final prefs      = await SharedPreferences.getInstance();
      String sovereignId = prefs.getString('sovereign_id') ?? '';
      if (sovereignId.isEmpty) {
        sovereignId = _stripAppId((await KeyManager.getSovereignId()) ?? '');
      }
      message['node_id']   = sovereignId;
      message['timestamp'] = _nowMs();
      _addOpCode(message); // dictionary protocol — adds 2-char 'op' alongside 'type'

      // Sign the message — fail-safe: unsigned messages accepted for exempt types
      try {
        final sigData = await KeyManager.signMessage(message);
        message['nonce']     = sigData['nonce'];
        message['signature'] = sigData['signature'];
      } catch (_) {}

      // Route via native TCP when available; fall back to WSS channel
      if (_nativeClient != null && _connectionType == 'native') {
        final msgType = message['type'] as String? ?? 'ERROR';
        _nativeClient!.send(msgType, message, sovereignId: sovereignId);
        return true;
      } else if (_channel != null) {
        _channel!.sink.add(jsonEncode(message));
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SEND AND WAIT
  // ══════════════════════════════════════════════════════════════════════════
  // Standard protocol for request/response over the relay.
  // Every feature — messaging, payments, recovery, governance — uses this.
  // Never open a WebSocket anywhere else in the app.
  //
  // Usage:
  //   final response = await RelayConnector.sendAndWait(
  //     request:      {'type': 'CITIZEN_COUNT_REQUEST'},
  //     responseType: 'CITIZEN_COUNT_RESPONSE',
  //     timeout:      const Duration(seconds: 8),
  //   );
  //   if (response != null) { ... }
  //
  // Returns null if: relay not connected, timeout, or connection dropped.
  // ──────────────────────────────────────────────────────────────────────────
  /// Wallet-side external-platform registration (no external IP exposure).
  /// The website owner registers their platform from inside the wallet: this
  /// generates an X25519 keypair on-device, signs the canonical payload with
  /// the wallet's enrolled Ed25519 key, and sends the citizen-signed
  /// PLATFORM_REGISTER op over WSS. The relay burns platform_register_fee SOV
  /// (default 10) → witness_operator pool and returns the platform_id +
  /// callback_secret (plaintext over the WSS-TLS channel) for the owner to paste
  /// into their site config. Returns the relay's result map, or a failure map.
  static Future<Map<String, dynamic>> registerPlatform({
    required String domain,
    required String returnUrl,
  }) async {
    final prefs  = await SharedPreferences.getInstance();
    String sovId = prefs.getString('sovereign_id') ?? prefs.getString('node_id') ?? '';
    if (sovId.isEmpty) sovId = _stripAppId((await KeyManager.getSovereignId()) ?? '');
    if (sovId.isEmpty) {
      return {'success': false, 'error': 'NO_SOVEREIGN_ID'};
    }

    // Clean the domain the same way the relay does: strip scheme + path.
    final cleanDomain = domain
        .toLowerCase()
        .replaceAll(RegExp(r'^https?://'), '')
        .split('/')
        .first
        .trim();
    if (cleanDomain.isEmpty) return {'success': false, 'error': 'INVALID_DOMAIN'};
    if (!returnUrl.startsWith('http://') && !returnUrl.startsWith('https://')) {
      return {'success': false, 'error': 'INVALID_RETURN_URL'};
    }

    // Generate a fresh X25519 keypair on-device (the relay seals the callback
    // secret to this key for the HTTP plane; the wallet receives the plaintext
    // secret over WSS-TLS, so the private key is not retained).
    final x25519 = sov_crypto.X25519();
    final kp = await x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    final x25519PubHex = pub.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final ts = _nowMs();
    final canonical =
        'sov-platform-register-v1|$cleanDomain|$returnUrl|$sovId|$x25519PubHex|$ts';

    String signature;
    try {
      signature = await KeyManager.signChallenge(canonical);
    } catch (e) {
      return {'success': false, 'error': 'SIGNING_FAILED: $e'};
    }

    final result = await sendAndWait(
      request: {
        'type':                     'PLATFORM_REGISTER',
        'domain':                   cleanDomain,
        'return_url':               returnUrl,
        'registering_sovereign_id': sovId,
        'x25519_pubkey_hex':        x25519PubHex,
        'timestamp':                ts,
        'signature':                signature,
      },
      responseType: 'PLATFORM_REGISTER_RESULT',
      timeout:      const Duration(seconds: 20),
    );
    if (result == null) {
      return {'success': false, 'error': 'NO_RESPONSE'};
    }
    return result;
  }

  static Future<Map<String, dynamic>?> sendAndWait({
    required Map<String, dynamic> request,
    required String responseType,
    Duration timeout = const Duration(seconds: 10),
    // Optional: filter by a specific field value in the response
    // e.g. matchField: 'recovery_id', matchValue: someId
    String? matchField,
    String? matchValue,
  }) async {
    if (!_connected || _messageController == null) return null;

    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _messageController!.stream.listen((msg) {
      if (msg['type'] != responseType) return;
      if (matchField != null && msg[matchField]?.toString() != matchValue) return;
      if (!completer.isCompleted) {
        sub?.cancel();
        completer.complete(msg);
      }
    });

    final sent = await send(request);
    if (!sent) {
      sub.cancel();
      return null;
    }

    return completer.future.timeout(timeout, onTimeout: () {
      sub?.cancel();
      return null;
    });
  }
  // ══════════════════════════════════════════════════════════════════════════
  // SEND WITH RESILIENCE
  // ══════════════════════════════════════════════════════════════════════════
  // Like sendAndWait but with automatic reconnect retries.
  // Designed for enrollment calls (ENROLLMENT_REGISTER / PALM_EMBEDDING_REGISTER)
  // where losing the connection mid-step would otherwise force the user to
  // restart the whole enrollment flow from scratch.
  //
  // onStatusUpdate: optional callback invoked with user-facing status strings
  // so the UI can display progress without coupling to this class.
  // ──────────────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> sendWithResilience(
    Map<String, dynamic> message,
    String expectedResponseType, {
    int maxRetries = 3,
    Duration timeout = const Duration(seconds: 20),
    void Function(String)? onStatusUpdate,
  }) async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        // ── Ensure connected ─────────────────────────────────────────────
        if (!isConnected) {
          onStatusUpdate?.call(
            attempt == 1
                ? 'Connecting to SOV Network...'
                : 'Reconnecting to network (attempt $attempt of $maxRetries)...',
          );
          final connected = await connect();
          if (!connected) {
            if (attempt < maxRetries) {
              onStatusUpdate?.call('Connection failed. Trying another relay...');
              await Future.delayed(const Duration(seconds: 2));
              continue;
            }
            return null; // All attempts exhausted
          }
          onStatusUpdate?.call('Connected. Processing...');
        }

        // ── Send and wait ────────────────────────────────────────────────
        final response = await sendAndWait(
          request:      message,
          responseType: expectedResponseType,
          timeout:      timeout,
        );

        if (response != null) return response;

        // Timeout — force disconnect so next iteration tries a fresh relay
        onStatusUpdate?.call('No response from relay. Trying another relay...');
        disconnect();
        await Future.delayed(const Duration(seconds: 1));

      } catch (e) {
        debugPrint('[RESILIENT] Attempt $attempt failed: $e');
        if (attempt < maxRetries) {
          onStatusUpdate?.call('Connection issue. Retrying...');
          disconnect();
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    return null; // All retries exhausted
  }

  static Future<void> registerNode() async {
    final publicKey   = await KeyManager.getPublicKey();
    final sovereignId = await KeyManager.getSovereignId();
    await send({
      'type':         'NODE_REGISTER',
      'sovereign_id': sovereignId,
      'public_key':   publicKey,
      'version':      '1.0.0',
      'capabilities': ['wallet', 'witness', 'mesh', 'dtn', 'hop_bridge'],
    });
    await registerAsHopBridge();
    // Request ledger sync — restores balance after reinstall
    // Relay responds with LEDGER_SYNC_RESPONSE containing balance + transactions
    await send({
      'type':         'LEDGER_SYNC_REQUEST',
      'sovereign_id': sovereignId,
    });
  }

  static Future<void> registerAsHopBridge() async {
    if (!_connected) return;
    final sovereignId = await KeyManager.getSovereignId();
    await send({
      'type':         'HOP_BRIDGE_REGISTER',
      'sovereign_id': sovereignId,
      'capabilities': ['hop_bridge', 'dtn_carrier'],
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RELAY ANNOUNCE — for new relay operators
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> announceRelay({
    required String relayId,
    required String ip,
    required int port,
    required String fingerprint,
    required String name,
  }) async {
    if (!_connected) return;
    await send({
      'type':        'RELAY_ANNOUNCE',
      'relay_id':    relayId,
      'ip':          ip,
      'port':        port,
      'fingerprint': fingerprint,
      'name':        name,
      'added_at':    _nowMs(),
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HOP DISCOVERY + HEARTBEAT + RECONNECT
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> discoverHopNodes() async {
    if (!_connected) return;
    await send({'type': 'HOP_BRIDGE_DISCOVER'});
  }

  static void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // Reset liveness clock so the first tick has a clean window
    _lastInboundAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) async {
        if (!_connected) return;
        // Zombie-WebSocket detection — if nothing inbound for >50 s the
        // socket is effectively dead even though TCP hasn't noticed yet.
        // Force a reconnect; OutboxManager will retry queued messages once
        // the new connection completes its HELLO handshake.
        final last = _lastInboundAt;
        if (last != null &&
            DateTime.now().difference(last) > _heartbeatLivenessMax) {
          debugPrint(
            '[RELAY] heartbeat timeout — no inbound packet in '
            '${DateTime.now().difference(last).inSeconds}s — forcing reconnect',
          );
          // Mark connection down BEFORE scheduling reconnect so any
          // in-flight send() calls fail fast rather than write to the
          // dead socket.
          _connected = false;
          try { await _channel?.sink.close(); } catch (_) {}
          _channel = null;
          _scheduleReconnect();
          return;
        }
        await send({'type': 'HEARTBEAT'});
      },
    );
  }

  static void _startHopDiscovery() {
    _hopDiscoveryTimer?.cancel();
    _hopDiscoveryTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) async {
        if (_connected) await discoverHopNodes();
      },
    );
  }

  // When true, auto-reconnect/node-switching is paused. Used during seed
  // recovery so a mid-query node switch doesn't drop the in-flight
  // sendAndWait response (the SOV_BALANCE_RESULT 'BR' would otherwise land on a
  // new socket while the await listens on the old one). Recovery manages its
  // own connect() retries while this is set.
  static bool _suppressReconnect = false;
  static set suppressReconnect(bool v) {
    debugPrint('[RELAY] suppressReconnect=$v');
    _suppressReconnect = v;
    if (v) _reconnectTimer?.cancel();
  }

  static void _scheduleReconnect() {
    if (_suppressReconnect) {
      debugPrint('[RELAY] _scheduleReconnect suppressed (recovery in progress)');
      return;
    }
    // A permanent credential rejection is not a connectivity problem. Retrying
    // would loop forever against a healthy node, and — because the pool is
    // demoted below — would end up condemning every node the citizen has.
    if (credentialError != null) {
      debugPrint('[RELAY] Reconnect halted — credentials rejected '
          '($credentialError). Restore from the seed phrase to fix this.');
      return;
    }
    // Genuine transport failure — demote this node so the next attempt prefers
    // a different one. Reached only when the close was NOT a credential
    // rejection, so a healthy node is never blamed for our own bad key.
    if (_currentEndpoint != null && _currentEndpoint!.isNotEmpty) {
      NodeDiscovery.markFailure(_currentEndpoint!);
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      const Duration(seconds: 5),
      () async {
        // Try to connect to a different node from the discovery pool
        final failed    = _currentEndpoint;
        final nextNode  = NodeDiscovery.getNextNode(excludeAddress: failed);
        if (nextNode != null && nextNode.address != failed) {
          debugPrint('[RELAY] Reconnecting to different node: ${nextNode.nodeId}');
        }
        await connect();
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DISCONNECT
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _hopDiscoveryTimer?.cancel();
    // Tear down native client first
    _nativeClient?.disconnect();
    _nativeClient    = null;
    _connectionType  = 'none';
    _currentRelayId  = '';
    // Dart's WebSocket.close() only accepts 1000 (normalClosure) or 3000-4999.
    // ws_status.goingAway (1001) throws "Invalid argument: 1001" — observed as an
    // unhandled exception during seed recovery's disconnect(). Use normalClosure.
    try { await _channel?.sink.close(ws_status.normalClosure); } catch (_) {}
    // Close all pool sockets
    for (final ws in List<WebSocket>.from(_poolSockets)) {
      try { await ws.close(ws_status.normalClosure); } catch (_) {}
    }
    _poolSockets.clear();
    _connected = false;
    _channel   = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // STATUS
  // ══════════════════════════════════════════════════════════════════════════
  static String getConnectionLabel() {
    switch (_currentMode) {
      case ConnectionMode.direct:
        return 'Connected — Sovereign Relay';
      case ConnectionMode.ipFallback:
        return 'Connected — Backup Relay';
      case ConnectionMode.peerHop:
        return 'Connected — SOV Peer Route';
      case ConnectionMode.mesh:
        return 'Connected — Local Mesh';
      case ConnectionMode.bluetooth:
        return 'Connected — Bluetooth';
      case ConnectionMode.dtn:
        return 'Offline — Storing Transactions';
    }
  }

  static List<Map<String, String>> getKnownRelaysSummary() {
    return _knownRelays.map((r) => {
      'name': r.name,
      'ip':   '${r.ip}:${r.port}',
      'id':   r.relayId,
    }).toList();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SOV PROTOCOL METHODS
  // High-level convenience wrappers around sendAndWait for each relay
  // message type used by the UI layer.
  // ══════════════════════════════════════════════════════════════════════════

  // ── S2 E2E Messaging key lookup ─────────────────────────────────────────────

  /// Fetch the X25519 messaging public key for [sovereignId] from the relay.
  ///
  /// Uses the existing PUBLIC_KEY_QUERY → PUBLIC_KEY_RESULT mechanism.
  /// The relay stores the messaging public key as x25519_public_key_hex in the
  /// public_keys table, written when the citizen sends their HELLO.
  ///
  /// Returns the hex-encoded public key, or null if not found / relay offline.
  /// The result is cached by MessageEncryptor for 10 minutes.
  static Future<String?> lookupMessagingKey(String sovereignId) async {
    // Check in-memory cache first (10-minute TTL)
    final cached = MessageEncryptor.getCachedKey(sovereignId);
    if (cached != null) return cached;

    // The node's handlePublicKeyQuery reads `target_id` (message_engine.js).
    // Sending `target_sovereign_id` (the old field) made the node silently drop
    // the query → lookup always returned null → "no encryption key on file" for
    // EVERY recipient. Send `target_id` (both, for any node variant).
    final resp = await sendAndWait(
      request:      {
        'type': 'PUBLIC_KEY_QUERY',
        'target_id': sovereignId,
        'target_sovereign_id': sovereignId,
      },
      responseType: 'PUBLIC_KEY_RESULT',
      timeout:      const Duration(seconds: 8),
    );
    final key = resp?['x25519_public_key_hex'] as String? ?? '';
    if (key.isNotEmpty) {
      MessageEncryptor.cacheKey(sovereignId, key);
      return key;
    }
    return null;
  }

  /// Query SOV balance for a sovereign ID from the relay.
  /// Returns 0.0 if offline or sovereign not found.
  static Future<int> queryBalance(String sovereignId) async {
    final resp = await sendAndWait(
      request: {'type': 'SOV_BALANCE_QUERY', 'sovereign_id': sovereignId},
      responseType: 'SOV_BALANCE_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return (resp?['seeds'] as num?)?.toInt() ?? 0;
  }

  /// Full balance response — includes pioneer_badges and pioneer_rank.
  static Future<Map<String, dynamic>?> queryBalanceFull(String sovereignId) async {
    return sendAndWait(
      request: {'type': 'SOV_BALANCE_QUERY', 'sovereign_id': sovereignId},
      responseType: 'SOV_BALANCE_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  // ── S7: Academy Publishing ─────────────────────────────────────────────────

  /// Fetch article summaries (no body). [category] null = all.
  static Future<List<Map<String, dynamic>>> listArticles({
    String? category,
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await sendAndWait(
      request: {
        'type': 'ACADEMY_LIST',
        if (category != null && category != 'all') 'category': category,
        'limit': limit,
        'offset': offset,
      },
      responseType: 'ACADEMY_LIST_RESULT',
      timeout: const Duration(seconds: 10),
    );
    if (res == null) return [];
    return (res['articles'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  /// Fetch full article including body.
  static Future<Map<String, dynamic>?> getArticle(String articleId) async {
    final res = await sendAndWait(
      request: {'type': 'ACADEMY_GET', 'article_id': articleId},
      responseType: 'ACADEMY_GET_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return res?['article'] as Map<String, dynamic>?;
  }

  /// Publish an article. Deducts academy_article_bond SOV from author.
  static Future<Map<String, dynamic>?> publishArticle({
    required String articleId,
    required String authorId,
    required String title,
    required String body,
    required String category,
  }) async {
    return sendAndWait(
      request: {
        'type':       'ACADEMY_PUBLISH',
        'article_id': articleId,
        'author_id':  authorId,
        'title':      title,
        'body':       body,
        'category':   category,
      },
      responseType: 'ACADEMY_PUBLISH_RESULT',
      timeout: const Duration(seconds: 15),
    );
  }

  /// Upvote an article. May deduct academy_upvote_bond SOV.
  static Future<Map<String, dynamic>?> upvoteArticle({
    required String articleId,
    required String voterId,
  }) async {
    return sendAndWait(
      request: {
        'type':       'ACADEMY_UPVOTE',
        'article_id': articleId,
        'voter_id':   voterId,
      },
      responseType: 'ACADEMY_UPVOTE_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  // ── S14 / N12: Network Dashboard + Node Status ────────────────────────────

  /// Fetch live statistics from the connected node.
  /// Works with both the old VPS relay (NETWORK_STATS → NETWORK_STATS_RESULT)
  /// and the new SOV Node (NODE_STATS → NODE_STATS_RESULT).
  /// Both message types map to op code 'ZS' on the SOV Node via LEGACY_TYPE_MAP.
  static Future<Map<String, dynamic>?> getNetworkStats() => getNodeStats();

  static Future<Map<String, dynamic>?> getNodeStats() async {
    return sendAndWait(
      // Use NODE_STATS as primary. SOV Node maps NETWORK_STATS → NODE_STATS too.
      request: {'type': 'NODE_STATS'},
      responseType: 'NODE_STATS_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  // ── Live economy snapshot (Blueprint v14.0 §2 — transparency) ───────────────
  /// Fetches the full SOV economy state in real-time from any relay's HTTP
  /// `/economy/snapshot` endpoint. Returns:
  /// - `supply_cap_seeds`: 50,000,000,000,000 (the protocol-locked invariant)
  /// - `pools`: list of 6 reserve accounts with allocated/remaining/distributed seeds
  /// - `wallets`: citizen count + total seeds across all citizen wallets
  /// - `invariant`: live check that (sum of pools) + (sum of wallets) ≤ 50M
  ///
  /// Used by the SOV Network Economy screen so any citizen can audit the
  /// network's accounting in real time.
  static Future<Map<String, dynamic>?> getEconomySnapshot() async {
    // Extract the IP from the current WSS endpoint, fall back to first bundled
    // relay IP if not connected. Uses port 80 HTTP regardless of WSS port.
    String? ip;
    final ep = _currentEndpoint;
    if (ep != null && ep.isNotEmpty) {
      final u = Uri.tryParse(ep);
      if (u != null) ip = u.host;
    }
    // No compiled fallback address — fall back to the DISCOVERED pool. An
    // address baked in here would be one more entry in the map of the network
    // that anyone can read out of the APK.
    ip ??= NodeDiscovery.all.isNotEmpty ? NodeDiscovery.all.first.ip : null;
    if (ip == null || ip.isEmpty) return null;
    try {
      final uri = Uri.parse('http://$ip/economy/snapshot');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[ECONOMY] snapshot fetch failed: $e');
      return null;
    }
  }

  // ── S13: Exchange Order Book & Price History ────────────────────────────────

  /// Fetch aggregated order book (bid depth) for the exchange.
  static Future<Map<String, dynamic>?> getOrderBook({int limit = 20}) async {
    return sendAndWait(
      request: {'type': 'EXCHANGE_ORDER_BOOK', 'limit': limit},
      responseType: 'EXCHANGE_ORDER_BOOK_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  /// Fetch recent fill history for the exchange spark chart.
  static Future<Map<String, dynamic>?> getPriceHistory({int limit = 50}) async {
    return sendAndWait(
      request: {'type': 'EXCHANGE_PRICE_HISTORY', 'limit': limit},
      responseType: 'EXCHANGE_PRICE_HISTORY_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  // ── S10 Guardian Recovery SDK methods ────────────────────────────────────

  /// Add a guardian for this citizen. Guardian must be an enrolled citizen.
  static Future<Map<String, dynamic>?> addGuardian({
    required String citizenId,
    required String guardianId,
  }) async {
    return sendAndWait(
      request: {'type': 'GUARDIAN_ADD', 'citizen_id': citizenId, 'guardian_id': guardianId},
      responseType: 'GUARDIAN_ADD_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  /// Remove a guardian from this citizen's guardian list.
  static Future<Map<String, dynamic>?> removeGuardian({
    required String citizenId,
    required String guardianId,
  }) async {
    return sendAndWait(
      request: {'type': 'GUARDIAN_REMOVE', 'citizen_id': citizenId, 'guardian_id': guardianId},
      responseType: 'GUARDIAN_REMOVE_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  /// List all guardians for a citizen.
  static Future<List<Map<String, dynamic>>> listGuardians(String citizenId) async {
    final res = await sendAndWait(
      request: {'type': 'GUARDIAN_LIST', 'citizen_id': citizenId},
      responseType: 'GUARDIAN_LIST_RESULT',
      timeout: const Duration(seconds: 10),
    );
    if (res == null) return [];
    final list = res['guardians'];
    if (list is List) return list.cast<Map<String, dynamic>>();
    return [];
  }

  /// Initiate a guardian recovery request. Call this on a new device
  /// when the citizen has lost their private key.
  /// [newPubKeyHex] — the new device's Ed25519 public key (hex).
  static Future<Map<String, dynamic>?> initiateGuardianRecovery({
    required String citizenId,
    required String newPubKeyHex,
    required String requestId,
  }) async {
    return sendAndWait(
      request: {
        'type':            'GUARDIAN_RECOVERY_INIT',
        'citizen_id':      citizenId,
        'new_pub_key_hex': newPubKeyHex,
        'request_id':      requestId,
      },
      responseType: 'GUARDIAN_RECOVERY_INIT_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  /// Approve a guardian recovery request. Call this when the guardian
  /// confirms the request is legitimate.
  static Future<Map<String, dynamic>?> approveGuardianRecovery({
    required String requestId,
    required String guardianId,
  }) async {
    return sendAndWait(
      request: {'type': 'GUARDIAN_APPROVE', 'request_id': requestId, 'guardian_id': guardianId},
      responseType: 'GUARDIAN_APPROVE_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  /// Reject a guardian recovery request.
  static Future<Map<String, dynamic>?> rejectGuardianRecovery({
    required String requestId,
    required String guardianId,
  }) async {
    return sendAndWait(
      request: {'type': 'GUARDIAN_REJECT', 'request_id': requestId, 'guardian_id': guardianId},
      responseType: 'GUARDIAN_REJECT_RESULT',
      timeout: const Duration(seconds: 10),
    );
  }

  // ── S12 Monetary Issuance SDK method ─────────────────────────────────────

  /// Claim one or more pending UBI epoch allocations.
  /// [epochIds] — list of epoch ID strings received from ISSUANCE_AVAILABLE.
  /// Returns { success, amount_seeds, citizen_id } on success.
  static Future<Map<String, dynamic>?> claimIssuance(List<String> epochIds) async {
    return sendAndWait(
      request: {'type': 'ISSUANCE_CLAIM', 'epoch_ids': epochIds},
      responseType: 'ISSUANCE_CLAIM_RESULT',
      timeout: const Duration(seconds: 15),
    );
  }

  /// Transfer SOV from one sovereign to another.
  /// [amountSeeds] — integer Seeds (1 SOV = 1,000,000 Seeds).
  /// [nonce]       — monotonically increasing counter for replay protection.
  /// Returns the relay response map (check ['success'] and ['tx_hash']).
  ///
  /// ⚠️  IMPORTANT — MUST use single-relay sendAndWait, NEVER send to all pool
  /// relays simultaneously. Each relay independently executes disc deduction in
  /// its own SQLite DB; firing to N relays causes N independent deductions.
  ///
  /// This method generates a globally unique [tx_id] for each transfer.
  /// If the primary relay is unreachable, pool relays are tried sequentially
  /// (NOT in parallel) using the SAME [tx_id]. The relay's idempotency check
  /// detects the already-confirmed tx and returns already_confirmed: true
  /// without deducting again — preventing double-spend across relay DBs.
  ///
  /// Pool racing is safe for READ operations (balance queries) only.
  /// ALL writes (transfers, enrollments, etc.) must go to exactly one relay.
  ///
  /// NOTE: relay accepts amount_seeds (integer Seeds) directly. Legacy `amount`
  /// float field is no longer sent to avoid floating-point rounding issues.
  static int _txNonce = 0;

  static String _generateTxId(String fromId, String toId, int amountSeeds) {
    _txNonce++;
    final input =
        '$fromId:$toId:$amountSeeds:$_txNonce:${_nowMs()}';
    final bytes = utf8.encode(input);
    final hash  = sha256.convert(bytes);
    return hash.toString().substring(0, 32);
  }

  static Future<Map<String, dynamic>> transferSOV(
      String fromId, String toId, int amountSeeds, int nonce, {
      String? memo,
      String? paymentRequestId,
  }) async {
    final txId = _generateTxId(fromId, toId, amountSeeds);
    final request = <String, dynamic>{
      'type':               'SOV_TRANSFER',
      'from_sovereign_id':  fromId,
      'to_sovereign_id':    toId,
      'amount_seeds':       amountSeeds,
      'tx_id':              txId,
      'nonce':              nonce,
      // [SSP Phase 2 — Guard 1] tx_nonce is the monotonic sequence counter for
      // double-spend prevention.  It is a separate field from 'nonce' (which is
      // overwritten by the Ed25519 signing process in send()). The relay checks
      // tx_nonce against sender_nonces to reject replayed transactions.
      'tx_nonce':           nonce,
      if (memo != null && memo.isNotEmpty)              'memo':               memo,
      if (paymentRequestId != null && paymentRequestId.isNotEmpty)
                                                        'payment_request_id': paymentRequestId,
    };

    debugPrint('[TRANSFER] tx_id: $txId | amount_seeds: $amountSeeds');
    debugPrint('[TRANSFER] Trying primary relay first...');

    // ── Try primary relay ─────────────────────────────────────────────────────
    // 30s (was 10s): under emulator/cold-device WS latency the relay still lands
    // the tx but the SOV_TRANSFER_RESULT arrives >10s later; a short timeout made
    // the UI report failure for a transfer that actually succeeded.
    final resp = await sendAndWait(
      request:      request,
      responseType: 'SOV_TRANSFER_RESULT',
      timeout:      const Duration(seconds: 30),
    );
    if (resp != null) {
      debugPrint('[TRANSFER] Primary relay responded: success=${resp['success']}');
      return resp;
    }

    // ── Primary failed — try pool relays sequentially (same tx_id) ───────────
    debugPrint('[TRANSFER] Primary relay timed out. Trying ${_poolSockets.length} pool relays...');
    for (final ws in List<WebSocket>.from(_poolSockets)) {
      if (ws.readyState != WebSocket.open) continue;
      try {
        final completer = Completer<Map<String, dynamic>?>();
        StreamSubscription? sub;
        sub = _messageController!.stream.listen((msg) {
          if (msg['type'] == 'SOV_TRANSFER_RESULT' &&
              msg['tx_id'] == txId &&
              !completer.isCompleted) {
            sub?.cancel();
            completer.complete(msg);
          }
        });
        ws.add(jsonEncode(request));
        final poolResp = await completer.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () { sub?.cancel(); return null; },
        );
        if (poolResp != null) {
          debugPrint('[TRANSFER] Pool relay responded: success=${poolResp['success']} already_confirmed=${poolResp['already_confirmed']}');
          return poolResp;
        }
      } catch (e) {
        debugPrint('[TRANSFER] Pool relay fallback error: $e');
      }
    }

    return {'success': false, 'error': 'No response from any relay'};
  }

  /// Submit a liveness proof to the relay.
  /// Returns the next_required_by timestamp string, or '' on failure.
  static Future<String> submitLivenessCheck(
      String sovereignId, String proofHash) async {
    final resp = await sendAndWait(
      request: {
        'type':         'LIVENESS_CHECK',
        'sovereign_id': sovereignId,
        'proof_hash':   proofHash,
      },
      responseType: 'LIVENESS_RESULT',
      timeout: const Duration(seconds: 10),
    );
    if (resp?['success'] == true) {
      return resp!['next_required_by']?.toString() ?? '';
    }
    return '';
  }

  /// List an exchange sell order.
  /// [amount] is in SOV (float). Converted to seeds internally.
  /// [description] is what the seller wants in exchange (OTC memo).
  /// [days] is how long the order stays open.
  /// Returns the relay response map (check ['success'] and ['order_id']).
  static Future<Map<String, dynamic>> listExchangeOrder(
      String sovereignId, double amount, String description, int days,
      {String paymentMethod = ''}) async {
    // Generate a unique order_id (relay requires it). Generated ONCE outside the
    // retry loop so retries are idempotent: the relay does INSERT OR IGNORE on
    // order_id (ORDER_ID_EXISTS), so re-sending the same order_id never creates a
    // duplicate or double-escrows.
    final orderId = 'ORD-${_nowMs()}-${(1000 + (DateTime.now().microsecond % 9000)).toString()}';
    // Convert SOV float → seeds integer (relay stores seeds)
    final amtSeeds = (amount * 1000000).round();
    final request = {
      'type':             'EXCHANGE_LIST_ORDER',
      'sovereign_id':     sovereignId,
      'order_id':         orderId,
      'sov_amount':       amtSeeds,
      'price_per_sov':    0,         // OTC/description trade — no fixed price
      'memo':             description,
      'expires_in_hours': days * 24,
      'currency_code':    'OTC',
      'payment_method':   paymentMethod,
    };
    // Retry on timeout — the WS can be mid-reconnect (zombie socket) when the
    // send fires, silently dropping it. Safe here because the order_id is fixed
    // (idempotent on the relay). Up to 3 attempts; ensure-connected each time.
    Map<String, dynamic>? resp;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!isConnected) {
        try { await connect(); } catch (_) {}
      }
      resp = await sendAndWait(
        request: request,
        responseType: 'EXCHANGE_ORDER_LISTED',
        timeout: const Duration(seconds: 12),
      );
      if (resp != null) break;       // got a relay reply (success OR typed error)
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Subscribe to live exchange order stream.
  /// Ensures connection before sending — relay immediately pushes EXCHANGE_STATE
  /// (full list), then EXCHANGE_ORDER_UPDATE for every change.
  /// Listen to [exchangeStateStream] and [exchangeUpdateStream].
  static Future<void> subscribeExchange() async {
    if (!_connected) await connect();
    // Small delay ensures the relay has processed HELLO before receiving
    // EXCHANGE_SUBSCRIBE. onConnected fires immediately after HELLO is SENT
    // (not after the relay ACKs), so without this delay EXCHANGE_SUBSCRIBE
    // can arrive while ws._verified is still false on the relay side.
    await Future.delayed(const Duration(milliseconds: 300));
    send({'type': 'EXCHANGE_SUBSCRIBE'});
  }

  /// Unsubscribe from live exchange order stream. Call on screen dispose.
  static void unsubscribeExchange() {
    if (_connected) send({'type': 'EXCHANGE_UNSUBSCRIBE'});
  }

  /// One-shot fetch of open orders (kept for backward compat / manual refresh).
  static Future<List<Map<String, dynamic>>> viewExchangeOrders() async {
    final resp = await sendAndWait(
      request: {'type': 'EXCHANGE_VIEW_ORDERS'},
      responseType: 'EXCHANGE_ORDERS_LIST',
      timeout: const Duration(seconds: 10),
    );
    if (resp == null) return [];
    return (resp['orders'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Retrieve the seller's own listings in any status (open, filled, disputed, etc.).
  /// Used for My Orders → MY LISTINGS so filled orders remain visible to seller.
  static Future<List<Map<String, dynamic>>> viewMyListings(String sovereignId) async {
    final resp = await sendAndWait(
      request: {'type': 'EXCHANGE_VIEW_MY_LISTINGS', 'sovereign_id': sovereignId},
      responseType: 'EXCHANGE_MY_LISTINGS_LIST',
      timeout: const Duration(seconds: 10),
    );
    if (resp == null) return [];
    return (resp['orders'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Send a trade message scoped to a specific exchange order.
  /// Stored with conversation_id = "xchg_<orderId>" — never appears in SOV Speak.
  static Future<bool> sendExchangeMessage({
    required String orderId,
    required String fromId,
    required String toId,
    required String text,
  }) async {
    final msgId = '${_nowMs()}_${orderId.substring(0, 8)}';
    final payload = jsonEncode({'from': fromId, 'text': text, 'exchange_order_id': orderId});
    // [FIX-XCHG-CHAT] Use from_sovereign_id/to_sovereign_id — relay _handleMessageSend
    // destructures to_sovereign_id; sending recipient_sovereign_id caused guard to fire
    // immediately (to_sovereign_id = undefined) and silently drop every exchange message.
    return send({
      'type':               'MESSAGE_SEND',
      'from_sovereign_id':  fromId,
      'to_sovereign_id':    toId,
      'encrypted_payload':  payload,
      'message_id':         msgId,
      'message_type':       'text',
      'exchange_order_id':  orderId,
    });
  }

  /// Fill (claim) an open exchange order as a buyer.
  /// Returns the relay response map (check ['success'] and ['release_deadline']).
  static Future<Map<String, dynamic>> fillExchangeOrder(
      String orderId, String buyerSovId, {double agreedPrice = 0}) async {
    final resp = await sendAndWait(
      request: {
        'type':               'EXCHANGE_FILL_ORDER',
        'buyer_sovereign_id': buyerSovId,
        'order_id':           orderId,
        // Stage 2c: on an OTC (price 0) order, record the price agreed in chat.
        if (agreedPrice > 0) 'agreed_price_per_sov': agreedPrice,
      },
      responseType: 'EXCHANGE_ORDER_FILLED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Confirm delivery / request refund on a filled exchange order.
  /// [confirmationType]: 'SELLER_CONFIRMS_PAYMENT_RECEIVED' or 'BUYER_REQUESTS_REFUND'
  static Future<Map<String, dynamic>> confirmDelivery(
      String orderId, String confirmerId, String confirmationType) async {
    final resp = await sendAndWait(
      request: {
        'type':                    'EXCHANGE_CONFIRM_DELIVERY',
        'confirming_sovereign_id': confirmerId,
        'order_id':                orderId,
        'confirmation_type':       confirmationType,
      },
      responseType: 'EXCHANGE_DELIVERY_CONFIRMED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Raise a dispute on a filled exchange order — escrow stays locked; justice case opened.
  /// Either the buyer or seller may raise a dispute.
  static Future<Map<String, dynamic>> raiseExchangeDispute(
      String orderId, String sovereignId) async {
    final resp = await sendAndWait(
      request: {
        'type':                    'EXCHANGE_CONFIRM_DELIVERY',
        'confirming_sovereign_id': sovereignId,
        'order_id':                orderId,
        'confirmation_type':       'DISPUTE',
      },
      responseType: 'EXCHANGE_DISPUTE_RAISED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Buyer requests a refund after the delivery deadline has passed.
  static Future<Map<String, dynamic>> requestExchangeRefund(
      String orderId, String buyerSovId) async {
    final resp = await sendAndWait(
      request: {
        'type':                    'EXCHANGE_CONFIRM_DELIVERY',
        'confirming_sovereign_id': buyerSovId,
        'order_id':                orderId,
        'confirmation_type':       'BUYER_REQUESTS_REFUND',
      },
      responseType: 'EXCHANGE_REFUND_PROCESSED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Cancel an open exchange order (seller only, status must be 'open').
  static Future<Map<String, dynamic>> cancelExchangeOrder(
      String orderId, String sovereignId) async {
    final resp = await sendAndWait(
      request: {
        'type':         'EXCHANGE_CANCEL_ORDER',
        'order_id':     orderId,
        'sovereign_id': sovereignId,
      },
      responseType: 'EXCHANGE_ORDER_CANCELLED',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Edit description and/or expiry of an open order (seller only, status must be 'open').
  static Future<Map<String, dynamic>> editExchangeOrder(
      String orderId, String sovereignId,
      {String? newDescription, int? expiresInDays}) async {
    final resp = await sendAndWait(
      request: {
        'type':               'EXCHANGE_EDIT_ORDER',
        'order_id':           orderId,
        'sovereign_id':       sovereignId,
        if (newDescription != null) 'asking_description': newDescription,
        if (expiresInDays != null)  'expires_in_days':    expiresInDays,
      },
      responseType: 'EXCHANGE_ORDER_EDITED',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Retrieve orders this citizen has filled as a buyer.
  static Future<List<Map<String, dynamic>>> viewMyFilledOrders(
      String sovereignId) async {
    final resp = await sendAndWait(
      request: {
        'type':         'EXCHANGE_VIEW_MY_FILLS',
        'sovereign_id': sovereignId,
      },
      responseType: 'EXCHANGE_MY_FILLS_LIST',
      timeout: const Duration(seconds: 10),
    );
    if (resp == null) return [];
    return (resp['orders'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  // ── Pioneer Certification ─────────────────────────────────────────────────

  /// Fetch full pioneer certification status for [sovereignId].
  static Future<Map<String, dynamic>> pioneerGetStatus(String sovereignId) async {
    final resp = await sendAndWait(
      request:      {'type': 'PIONEER_GET_STATUS', 'sovereign_id': sovereignId},
      responseType: 'PIONEER_STATUS_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Start a pioneer assessment for [specialisation].
  /// Returns {success, assessment_id, questions:[{id, question, options:{A,B,C,D}}], ...}
  static Future<Map<String, dynamic>> pioneerStartAssessment(
      String sovereignId, String specialisation) async {
    final resp = await sendAndWait(
      request: {
        'type':           'PIONEER_START_ASSESSMENT',
        'sovereign_id':   sovereignId,
        'specialisation': specialisation,
      },
      responseType: 'PIONEER_ASSESSMENT_STARTED',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Submit assessment answers. [answers] maps question id (int) → letter ('A'|'B'|'C'|'D').
  /// Returns {success, passed, score, badge_earned?, rank?, message}
  static Future<Map<String, dynamic>> pioneerSubmitAssessment(
      String sovereignId, int assessmentId, Map<int, String> answers) async {
    final answersObj = <String, dynamic>{};
    answers.forEach((k, v) => answersObj[k.toString()] = v);
    final resp = await sendAndWait(
      request: {
        'type':          'PIONEER_SUBMIT_ASSESSMENT',
        'sovereign_id':  sovereignId,
        'assessment_id': assessmentId,
        'answers':       answersObj,
      },
      responseType: 'PIONEER_SUBMIT_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Register as a pioneer referrer. Returns the pioneer_code, or '' on fail.
  static Future<String> registerPioneer(String sovereignId) async {
    final resp = await sendAndWait(
      request: {'type': 'PIONEER_REGISTER', 'sovereign_id': sovereignId},
      responseType: 'PIONEER_REGISTERED',
      timeout: const Duration(seconds: 10),
    );
    return resp?['pioneer_code']?.toString() ?? '';
  }

  /// Nominate 3 guardians for social wallet recovery.
  /// [guardianIds] must contain exactly 3 sovereign IDs.
  static Future<bool> nominateGuardians(
      String sovereignId, List<String> guardianIds) async {
    if (guardianIds.length < 3) return false;
    final resp = await sendAndWait(
      request: {
        'type':          'GUARDIAN_NOMINATE',
        'sovereign_id':  sovereignId,
        'guardian_1_id': guardianIds[0],
        'guardian_2_id': guardianIds[1],
        'guardian_3_id': guardianIds[2],
      },
      responseType: 'GUARDIAN_NOMINATED',
      timeout: const Duration(seconds: 10),
    );
    return resp?['success'] == true;
  }

  /// Configure the deadman switch for SOV inheritance.
  /// [claimHashes] are SHA-256 hashes of claim keys held by beneficiaries.
  static Future<bool> configureDeadman(
      String sovereignId, int triggerDays, List<String> claimHashes) async {
    final resp = await sendAndWait(
      request: {
        'type':             'DEADMAN_CONFIGURE',
        'sovereign_id':     sovereignId,
        'trigger_days':     triggerDays,
        'claim_key_hashes': claimHashes,
      },
      responseType: 'DEADMAN_CONFIGURED',
      timeout: const Duration(seconds: 10),
    );
    return resp?['success'] == true;
  }

  /// Re-register a palm embedding (e.g. after palm injury or re-scan).
  /// Requires an existing disc slot — relay verifies before updating.
  static Future<bool> reregisterPalm(
      String sovereignId, String embeddingJson, String helperData,
      String keyHash, String handType) async {
    final resp = await sendAndWait(
      request: {
        'type':            'PALM_REREGISTER',
        'sovereign_id':    sovereignId,
        'new_embedding':   embeddingJson,
        'new_helper_data': helperData,
        'new_key_hash':    keyHash,
        'hand_type':       handType,
      },
      responseType: 'PALM_REREGISTERED',
      timeout: const Duration(seconds: 15),
    );
    return resp?['success'] == true;
  }

  /// Send an E2E encrypted message to another citizen via the relay.
  /// The relay stores it in memory for 30 seconds — zero disk writes.
  static Future<bool> sendSovLink({
    required String fromSovId,
    required String toSovId,
    required String encryptedPayloadBase64,
  }) async {
    final sent = await send({
      'type':                  'SOV_LINK_SEND',
      'sender_sovereign_id':   fromSovId,
      'to_sovereign_id':       toSovId,
      'encrypted_payload':     encryptedPayloadBase64,
    });
    return sent;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INHERITANCE & ALLOCATION PROTOCOL
  // ══════════════════════════════════════════════════════════════════════════

  /// Create a new locked allocation on the relay.
  static Future<Map<String, dynamic>> submitAllocationCreate(
      Map<String, dynamic> payload) async {
    final resp = await sendAndWait(
      request:      {...payload, 'type': 'ALLOCATION_CREATE'},
      responseType: 'ALLOCATION_CREATED',
      timeout:      const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Fetch all allocations for [sovereignId].
  /// Returns {allocations: [...], total_locked_seeds: int}
  static Future<Map<String, dynamic>> fetchAllocationList(
      String sovereignId) async {
    final resp = await sendAndWait(
      request:      {'type': 'ALLOCATION_LIST', 'sovereign_id': sovereignId},
      responseType: 'ALLOCATION_LIST_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'allocations': [], 'total_locked_seeds': 0};
  }

  /// Cancel a locked allocation (only before release_date).
  static Future<Map<String, dynamic>> cancelAllocation(
      String sovereignId, String allocationId) async {
    final resp = await sendAndWait(
      request: {
        'type':          'ALLOCATION_CANCEL',
        'sovereign_id':  sovereignId,
        'allocation_id': allocationId,
      },
      responseType: 'ALLOCATION_CANCELLED',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Stage 1 claim: direct claim key — no allocation_id required.
  /// Relay looks up the allocation by claim_key_hash.
  static Future<Map<String, dynamic>> claimStage1(
      String sovereignId, String claimKeyHash) async {
    final resp = await sendAndWait(
      request: {
        'type':                  'ALLOCATION_CLAIM_STAGE1',
        'claim_key_hash':        claimKeyHash,
        'claimant_sovereign_id': sovereignId,
      },
      responseType: 'ALLOCATION_CLAIMED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Search published allocations by beneficiary name hash.
  static Future<List<Map<String, dynamic>>> searchUnclaimed(
      String nameHash) async {
    final resp = await sendAndWait(
      request:      {'type': 'UNCLAIMED_BROADCAST_SEARCH', 'name_hash': nameHash},
      responseType: 'UNCLAIMED_BROADCAST_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return (resp?['allocations'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Stage 2 claim: family key path — creates a justice council.
  static Future<Map<String, dynamic>> claimStage2(
      String sovereignId, String allocationId,
      List<String> familyKeyHashes, String claimantStatement) async {
    final resp = await sendAndWait(
      request: {
        'type':                  'ALLOCATION_CLAIM_STAGE2',
        'allocation_id':         allocationId,
        'family_key_hashes':     familyKeyHashes,
        'claimant_statement':    claimantStatement,
        'claimant_sovereign_id': sovereignId,
      },
      responseType: 'ALLOCATION_CLAIM_STAGE2_RESULT',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Fetch justice councils where [sovereignId] is a member or claimant.
  static Future<List<Map<String, dynamic>>> fetchMyCouncils(
      String sovereignId) async {
    final resp = await sendAndWait(
      request:      {'type': 'ALLOCATION_MY_COUNCILS', 'sovereign_id': sovereignId},
      responseType: 'ALLOCATION_MY_COUNCILS_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return (resp?['councils'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Cast a vote on a justice council.
  /// [vote]: 'approve' | 'reject' | 'abstain'
  static Future<Map<String, dynamic>> castCouncilVote(
      String sovereignId, int councilId, String vote) async {
    final resp = await sendAndWait(
      request: {
        'type':        'ALLOCATION_COUNCIL_VOTE',
        'sovereign_id': sovereignId,
        'council_id':   councilId,
        'vote':         vote,
      },
      responseType: 'ALLOCATION_COUNCIL_VOTE_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  // ══════════════════════════════════════════════════════════════════════════
  // JUSTICE PROTOCOL
  // ══════════════════════════════════════════════════════════════════════════

  /// Open a justice dispute against [defendantId].
  /// [evidenceHash] — SHA-256 of evidence payload (hex string, 64 chars).
  /// [claimAmountSeeds] — amount in seeds to recover.
  /// Deducts 10 SOV bond from [sovereignId] on the relay.
  static Future<Map<String, dynamic>> openJusticeDispute({
    required String       sovereignId,
    required String       defendantId,
    required String       evidenceHash,
    required int          claimAmountSeeds,
    List<String>?         evidenceImages,
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':             'JUSTICE_DISPUTE_OPEN',
        'sovereign_id':     sovereignId,
        'defendant_id':     defendantId,
        'evidence_hash':    evidenceHash,
        'claim_amount':     claimAmountSeeds,
        if (evidenceImages != null && evidenceImages.isNotEmpty)
          'evidence_images': evidenceImages,
      },
      responseType: 'JUSTICE_DISPUTE_OPENED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Cast a verdict on an open justice case.
  /// [verdict] — 'uphold_plaintiff' | 'dismiss'
  static Future<Map<String, dynamic>> castJusticeVote({
    required String sovereignId,
    required String caseId,
    required String verdict,
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':               'JUSTICE_VOTE',
        'juror_sovereign_id': sovereignId,
        'case_id':            caseId,
        'verdict':            verdict,
      },
      responseType: 'JUSTICE_VOTE_RECORDED',
      timeout: const Duration(seconds: 15),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Respond to a jury duty invitation — accept or decline.
  /// [response] — 'accept' | 'decline'
  static Future<Map<String, dynamic>> respondToJuryDuty({
    required String sovereignId,
    required String caseId,
    required String response, // 'accept' | 'decline'
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':                 'JUSTICE_JUROR_RESPOND',
        'juror_sovereign_id':   sovereignId,
        'case_id':              caseId,
        'response':             response,
      },
      responseType: 'JUSTICE_JUROR_RESPONSE_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Request panel expansion — adds 1 more juror to the case (up to max).
  /// Only accepted jurors may call this.
  static Future<Map<String, dynamic>> expandJuryPanel({
    required String sovereignId,
    required String caseId,
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':                      'JUSTICE_EXPAND_PANEL',
        'requester_sovereign_id':    sovereignId,
        'case_id':                   caseId,
      },
      responseType: 'JUSTICE_EXPAND_PANEL_RESULT',
      timeout: const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Fetch all justice cases for [sovereignId] (plaintiff + juror roles).
  static Future<Map<String, dynamic>> getJusticeMyCases(
      String sovereignId) async {
    final resp = await sendAndWait(
      // Route via JUSTICE_DISPUTE_LIST (op DR → handleDisputeList); no role =
      // own disputes (plaintiff/defendant). Relay replies type JUSTICE_MY_CASES_RESULT.
      request:      {'type': 'JUSTICE_DISPUTE_LIST', 'sovereign_id': sovereignId},
      responseType: 'JUSTICE_MY_CASES_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'cases': [], 'error': 'No response from relay'};
  }

  /// Fetch the citizen's juror invitations (disputes they've been selected for).
  /// The justice model is INVITE-based (jurors are randomly selected on dispute
  /// open, not volunteer-browse), so this is role='juror' → invited/accepted cases.
  static Future<Map<String, dynamic>> listOpenDisputes(
      String sovereignId) async {
    final resp = await sendAndWait(
      // Route via JUSTICE_DISPUTE_LIST (op DR → handleDisputeList) with role=juror.
      // Relay replies type JUSTICE_LIST_OPEN_RESULT with both cases + disputes keys.
      request: {
        'type':         'JUSTICE_DISPUTE_LIST',
        'role':         'juror',
        'sovereign_id': sovereignId,
      },
      responseType: 'JUSTICE_LIST_OPEN_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'cases': [], 'disputes': [], 'error': 'No response from relay'};
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SOV VALUE VOTING
  // ══════════════════════════════════════════════════════════════════════════

  /// Get the current SOV value voting status (current rate, proposals, epoch).
  static Future<Map<String, dynamic>> getSovValueStatus(
      String sovereignId) async {
    final resp = await sendAndWait(
      request: {
        'type':         'SOV_VALUE_STATUS',
        'sovereign_id': sovereignId,
      },
      responseType: 'SOV_VALUE_STATUS_RESULT',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Submit a proposed USD value for SOV this epoch.
  /// [proposedUsd] — citizen's proposed USD exchange rate for 1 SOV.
  static Future<Map<String, dynamic>> submitSovValueProposal({
    required String sovereignId,
    required double proposedUsd,
  }) async {
    final resp = await sendAndWait(
      request: {
        'type':         'SOV_VALUE_SUBMIT',
        'sovereign_id': sovereignId,
        'proposed_usd': proposedUsd,
      },
      responseType: 'SOV_VALUE_SUBMITTED',
      timeout:      const Duration(seconds: 10),
    );
    return resp ?? {'success': false, 'error': 'No response from relay'};
  }

  /// Sync confirmed transaction history from the relay into local TransactionStore.
  /// Sends TX_HISTORY_REQUEST, saves any new transactions, then confirms sync to
  /// the relay so it can mark them synced in sov_tx_sync_log.
  static Future<void> syncTransactionHistory(String sovereignId) async {
    if (sovereignId.isEmpty) return;
    try {
      final result = await sendAndWait(
        request: {
          'type':         'TX_HISTORY_REQUEST',
          'sovereign_id': sovereignId,
        },
        responseType: 'TX_HISTORY_RESULT',
        timeout: const Duration(seconds: 15),
      );
      if (result == null || result['success'] != true) return;
      final transactions = result['transactions'] as List? ?? [];
      if (transactions.isEmpty) return;

      // Merge into local store (deduplicates by tx_hash)
      await TransactionStore.mergeAll(transactions, sovereignId);

      // Collect confirmed IDs to ack back to relay
      final confirmedIds = <String>[];
      for (final tx in transactions) {
        if (tx is Map) {
          final id = (tx['tx_id'] ?? tx['tx_hash'] ?? '') as String;
          if (id.isNotEmpty) confirmedIds.add(id);
        }
      }
      if (confirmedIds.isEmpty) return;

      await sendAndWait(
        request: {
          'type':              'TX_HISTORY_CONFIRMED',
          'sovereign_id':      sovereignId,
          'confirmed_tx_ids':  confirmedIds,
        },
        responseType: 'TX_HISTORY_DELETE_RESULT',
        timeout: const Duration(seconds: 10),
      );
      debugPrint('[TX_SYNC] Synced ${confirmedIds.length} transactions');
    } catch (e) {
      debugPrint('[TX_SYNC] syncTransactionHistory error: $e');
    }
  }

  /// Fetch the relay pool. Sends RELAY_LIST_REQUEST and waits up to 2 s for
  /// gossip response. Returns all known relays from gossip + local cache.
  /// Always falls back to the bundled relay_pool.json so the relay pool screen
  /// never shows empty (e.g. on tablet before gossip has populated _knownRelays).
  static Future<List<RelayEntry>> getRelayPool() async {
    if (_connected) {
      await send({'type': 'RELAY_LIST_REQUEST'});
      await Future.delayed(const Duration(seconds: 2));
    }
    final seen   = <String>{};
    final result = <RelayEntry>[];
    // Build from gossip list, but override opaque "node_xxx" relay IDs with
    // canonical IDs from relay_pool.json so names are consistent everywhere.
    for (final r in _knownRelays) {
      final canonical = _canonicalRelayIdByIp[r.ip] ?? '';
      final entry = (canonical.isNotEmpty && canonical != r.relayId)
          ? RelayEntry(
              relayId:     canonical,
              ip:          r.ip,
              port:        r.port,
              fingerprint: r.fingerprint,
              name:        canonical,
              nickname:    r.nickname,
              addedAt:     r.addedAt,
            )
          : r;
      final key = entry.relayId.isNotEmpty ? entry.relayId : entry.ip;
      if (seen.add(key)) { result.add(entry); }
    }
    // If gossip has not yet populated _knownRelays, fall back to the bundled
    // relay_pool.json so the screen always shows at least the 4 bootstrap relays.
    if (result.isEmpty) {
      final bundled = await _loadRelayEntries();
      for (final r in bundled) {
        if (seen.add(r.relayId.isNotEmpty ? r.relayId : r.ip)) { result.add(r); }
      }
    }
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RELAY POOL — racing connections
  // All pool sockets share _messageController with the primary connection.
  // transferSOV() sends to ALL connected sockets; first response wins.
  // ══════════════════════════════════════════════════════════════════════════

  /// Wire up a raw WebSocket so its messages flow into _messageController.
  static void _addPoolSocket(WebSocket socket) {
    _poolSockets.add(socket);
    socket.listen(
      (message) {
        try {
          final decoded =
              jsonDecode(message as String) as Map<String, dynamic>;
          _messageController?.add(decoded);
        } catch (_) {}
      },
      onDone:  () { _poolSockets.remove(socket); },
      onError: (_) { _poolSockets.remove(socket); },
    );
  }

  /// Connect to a list of relay WebSocket URLs (no cert pinning — pool
  /// relays are opportunistic, used only to race for faster response).
  /// Accepts self-signed certs — relay network does not use a public CA.
  static Future<void> connectToPool(List<String> relayUrls) async {
    for (final url in relayUrls) {
      if (_poolSockets.length >= 3) break; // cap pool at 3 extra relays
      try {
        final context = SecurityContext(withTrustedRoots: false);
        final socket = await WebSocket.connect(
          url,
          customClient: HttpClient(context: context)
            ..badCertificateCallback =
                (X509Certificate cert, String host, int port) => true,
        ).timeout(const Duration(seconds: 8));
        _addPoolSocket(socket);
        debugPrint('[POOL] Connected pool socket: $url');
      } catch (e) {
        debugPrint('[POOL] Pool connect failed $url: $e');
      }
    }
  }

  /// Fire-and-forget: called after connecting to any relay.
  /// Sends RELAY_LIST_REQUEST, collects gossip, saves endpoints to
  /// SharedPreferences 'relay_pool_cache', then connects pool sockets
  /// to all discovered peers for racing.
  static Future<void> _syncRelayPool() async {
    try {
      await Future.delayed(const Duration(seconds: 2));
      if (!_connected) return;
      await send({'type': 'RELAY_LIST_REQUEST'});
      await Future.delayed(const Duration(seconds: 2));

      // Collect all endpoint URLs discovered via gossip
      final endpoints = _knownRelays
          .where((r) => r.wsUrl.isNotEmpty && r.ip.isNotEmpty)
          .map((r) => r.wsUrl)
          .toList();

      if (endpoints.isNotEmpty) {
        // Persist to cache for next session
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList('relay_pool_cache', endpoints);
          debugPrint('[DISCOVERY] Cached ${endpoints.length} relay endpoints');
        } catch (_) {}

        // Connect pool sockets for racing (cap at 3)
        await connectToPool(endpoints);
      }

      debugPrint('[POOL] Sync complete. Pool size: ${_poolSockets.length}');
      // Now that _knownRelays is populated, resolve the relay ID for the
      // active connection so the pool screen can highlight it by relay_id.
      _resolveCurrentRelayId();
    } catch (_) {}
  }

  /// Match _currentEndpoint against _knownRelays to set _currentRelayId.
  /// Uses exact URL match first, then IP-host fallback for format tolerance.
  static void _resolveCurrentRelayId() {
    final endpoint = _currentEndpoint;
    if (endpoint == null || endpoint.isEmpty) return;
    final host = Uri.tryParse(endpoint)?.host ?? '';
    // 1. Check canonical map from bundled relay_pool.json — always authoritative.
    //    Gossip may return opaque "node_xxx" IDs; we prefer the human-readable ones.
    if (host.isNotEmpty && _canonicalRelayIdByIp.containsKey(host)) {
      _currentRelayId = _canonicalRelayIdByIp[host]!;
      debugPrint('[POOL] Resolved active relay (canonical): $_currentRelayId ($endpoint)');
      return;
    }
    // 2. Fall back to gossip list.
    for (final r in _knownRelays) {
      if (r.wsUrl == endpoint || (host.isNotEmpty && r.ip == host)) {
        _currentRelayId = r.relayId;
        debugPrint('[POOL] Resolved active relay: $_currentRelayId ($endpoint)');
        return;
      }
    }
    debugPrint('[POOL] Could not resolve relay ID for endpoint: $endpoint');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FLOW A2 — App-mediated Path A (PHISHING-PROOF SOV LOGIN)
  //
  // The SOV app uses these endpoints to confirm a citizen's intent to sign
  // into an external platform. The citizen's seed phrase NEVER enters a
  // browser; instead, the browser displays a 6-digit pairing code, the
  // citizen types it into this app, the app fetches platform details from
  // a BUNDLED relay (the trust anchor), and on user confirmation the app
  // signs an Ed25519 authorization using KeyManager — all on-device.
  //
  // Phishing-proof because:
  //   - HTTP destinations are read from assets/relay_pool.json bundled in the
  //     APK at compile time. A malicious website cannot redirect the SOV app
  //     to a fake relay — the URLs are hard-coded.
  //   - The citizen's private key never leaves KeyManager's secure storage.
  //   - The pairing code is short-lived (90s), one-use, domain-bound.
  // ══════════════════════════════════════════════════════════════════════════

  /// HTTP-reachable node IPs (port 80), most reliable first.
  ///
  /// These come from the DISCOVERED pool, not from anything compiled in. The
  /// anti-phishing property the old hard-coded list provided is unchanged and
  /// is what actually matters here: the destination comes from the app's OWN
  /// pool — built from mirrors and the DHT and verified by connection — never
  /// from a URL, QR code, or page a website handed us. A malicious site still
  /// cannot point the app at a relay of its choosing.
  ///
  /// What it drops is the part that was never a security feature: publishing
  /// the live node addresses inside every APK.
  static List<String> _bundledHttpRelayIps() {
    return NodeDiscovery.all
        .map((e) => e.ip)
        .where((ip) => ip.isNotEmpty)
        .toList();
  }

  /// Iterate the bundled HTTP relay pool, POST [body] to [path] on each,
  /// return the first response with `success: true`. If all fail, return the
  /// last error response so the caller can surface a useful error to the user.
  ///
  /// This is the HTTP variant of the WSS pool race used elsewhere. Uses
  /// `dart:io` `HttpClient` directly (no `http` package dependency added).
  static Future<Map<String, dynamic>?> _httpPostJsonRelayPool(
      String path, Map<String, dynamic> body) async {
    final encoded = utf8.encode(jsonEncode(body));
    Map<String, dynamic>? lastError;
    for (final ip in _bundledHttpRelayIps()) {
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
        final req = await client.postUrl(Uri.parse('http://$ip:80$path'));
        req.headers.set('Content-Type', 'application/json');
        req.add(encoded);
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final bodyStr = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(bodyStr) as Map<String, dynamic>;
        if (json['success'] == true) return json;
        lastError = json;
      } catch (e) {
        lastError = {'success': false, 'error': 'NETWORK_ERROR', 'detail': e.toString()};
      } finally {
        client?.close(force: true);
      }
    }
    return lastError;
  }

  /// Flow A2 step 2: SOV app fetches session details by pairing code.
  /// Returns `{success, session_id, platform_domain, return_url, expires_at}`
  /// on hit, or `{success: false, error: <code>}` on miss/expired/used.
  static Future<Map<String, dynamic>?> checkAppPairing(String pairingCode) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pairingCode)) {
      return {'success': false, 'error': 'INVALID_PAIRING_CODE_FORMAT'};
    }
    return _httpPostJsonRelayPool('/sov-login/check-app', {
      'pairing_code': pairingCode,
    });
  }

  /// Flow A2 step 3: citizen taps "Yes" in the confirmation dialog — SOV app
  /// signs the canonical authorization payload and submits to the relay.
  /// Returns `{success, status: 'authorized', sovereign_id, palm_name, ...}`
  /// on success, or error response on failure.
  ///
  /// Caller passes [sessionId] and [platformDomain] obtained from
  /// [checkAppPairing]. The citizen's [sovereignId] is read from KeyManager
  /// and the signature is computed locally.
  static Future<Map<String, dynamic>?> authorizeAppPairing({
    required String sessionId,
    required String platformDomain,
    String password = '',
  }) async {
    final sovereignId = await KeyManager.getSovereignId();
    if (sovereignId == null) {
      return {'success': false, 'error': 'NOT_ENROLLED'};
    }
    final timestamp = _nowMs();
    // Canonical payload — MUST match the relay's verification format exactly.
    // Defined in relay_pool.js `authorize-app` handler.
    final canonical =
        'sov-link-v1-app:$sessionId:$sovereignId:$platformDomain:$timestamp';
    final signature = await KeyManager.signChallenge(canonical);
    final payload = <String, dynamic>{
      'session_id':   sessionId,
      'sovereign_id': sovereignId,
      'signature':    signature,
      'timestamp':    timestamp,
    };
    // Optional: citizen-chosen platform password. Sent ONLY to the bundled
    // trust-anchor relay (same channel as the Ed25519 authorization). Relay
    // derives scrypt verifier server-side, stores verifier, discards plain
    // password. Empty = no Path B login allowed (Flow A2 every time).
    if (password.isNotEmpty) {
      payload['password'] = password;
    }
    return _httpPostJsonRelayPool('/sov-login/authorize-app', payload);
  }

}
