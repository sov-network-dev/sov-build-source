// lib/sov_cli/cli_runner.dart
//
// Headless CLI mode for SovNode.exe.
// Invoked when SovNode.exe is launched with --cli as the first argument.
// Shares the same identity, keys, and local database as the GUI — no separate
// import or configuration. The CLI reads from the same SharedPreferences,
// flutter_secure_storage (Windows Credential Manager), and SQLite DB that the
// GUI writes. No GUI window is opened in CLI mode.
//
// Usage:
//   SovNode.exe --cli status                         Identity + relay + balance
//   SovNode.exe --cli balance                        Print SOV balance (plain, scriptable)
//   SovNode.exe --cli send --to <sov-id> --amount <sov> [--memo <text>]
//   SovNode.exe --cli history [--limit <n>]          Recent txs from local DB
//   SovNode.exe --cli contacts                       Local contact list
//   SovNode.exe --cli msg --to <id> "<text>"         Send a message
//   SovNode.exe --cli msg --list [--with <id>] [--limit <n>] [--offline]   Fetch + list messages
//   SovNode.exe --cli node                           Relay reachability probe
//
// Global flags (any command):
//   --pin <code>    Provide PIN non-interactively (for scripting)
//   --node <wss>    Override the relay URL for this invocation
//   --json          Machine-readable JSON output

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/conversation_utils.dart';
import '../sov_node_sdk/bip39.dart';
import '../sov_node_sdk/key_manager.dart';
import '../sov_node_sdk/message_encryptor.dart';
import '../sov_node_sdk/message_key_manager.dart';
import '../sov_node_sdk/secure_channels.dart' show SecureChannels;
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/node_discovery.dart';
import '../sov_node_sdk/pin_manager.dart';
import '../sov_node_sdk/relay_connector.dart' show RelayConnector;

// 1 SOV == 1 000 000 seeds (integer micro-unit on the wire)
const int _kSeedsPerSov = 1000000;

// Which node to talk to, resolved rather than compiled in.
//
// This used to be a constant holding a live VPS address. That published a real
// node address inside every build, and pinned the CLI to one machine that will
// not be there forever. Order of preference:
//
//   1. --node on the command line
//   2. custom_node in prefs (an operator's own node)
//   3. DISCOVERY — the cached pool, the pointer mirrors, then the public DHT
//
// Returns '' when nothing can be found, which is the honest answer before the
// first node of the network exists.
Future<String> _resolveNodeUrl(
    Map<String, dynamic> opts, SharedPreferences prefs) async {
  final explicit =
      (opts['node'] as String?) ?? prefs.getString('custom_node');
  if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();

  await NodeDiscovery.init();
  var pool = NodeDiscovery.all;
  if (pool.isEmpty) pool = await NodeDiscovery.refresh();
  if (pool.isEmpty) return '';
  return pool.first.wsUrl;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point — called from main() when --cli is detected.
// Returns a process exit code (0 = success, non-zero = error).
// ─────────────────────────────────────────────────────────────────────────────

class SovCLI {
  static Future<int> run(List<String> args) async {
    if (args.isEmpty || args[0] == '-h' || args[0] == '--help' || args[0] == 'help') {
      _printHelp();
      return 0;
    }

    final opts = _parseGlobal(args);
    final command = opts['_command'] as String? ?? '';
    final wantsJson = opts.containsKey('json');

    // ── Headless wallet restore from seed (creates the wallet; runs before the
    //    PIN/Spend-Lock gates, which assume a wallet already exists) ───────────
    if (command == 'restore') {
      try {
        return await _cmdRestore(opts, wantsJson);
      } catch (e) {
        _err('Restore failed: $e', wantsJson);
        return 1;
      }
    }

    // ── PIN gate ─────────────────────────────────────────────────────────────
    final pinOk = await _checkPin(opts['pin'] as String?);
    if (!pinOk) {
      _err('PIN verification failed.', wantsJson);
      return 1;
    }

    // ── Spend-Lock: if the key is PIN-encrypted, unlock this process's session
    //    before any signed op (HELLO, transfers, messages). The PIN decrypts the
    //    Argon2id-wrapped key cryptographically — wrong PIN simply can't sign.
    if (command != 'help' && command != 'spendlock' && command != 'hwlock' &&
        await KeyManager.isSpendLockEnabled()) {
      final pin = opts['pin'] as String?;
      final unlocked = pin != null && pin.isNotEmpty &&
          await KeyManager.unlockSession(pin, ttl: const Duration(hours: 1));
      if (!unlocked) {
        _err('Wallet is Spend-Locked — pass --pin <code> to unlock the encrypted key.',
            wantsJson);
        return 1;
      }
    }
    // ── Hardware-Lock: unseal the seed via the TPM (no PIN — the machine IS the key). ──
    if (command != 'help' && command != 'hwlock' && command != 'spendlock' &&
        await KeyManager.isHardwareLockEnabled()) {
      final unlocked = await KeyManager.unlockHardwareSession(ttl: const Duration(hours: 1));
      if (!unlocked) {
        _err('Wallet is Hardware-Locked but the TPM could not unseal it on this machine.',
            wantsJson);
        return 1;
      }
    }

    // ── Command dispatch ─────────────────────────────────────────────────────
    try {
      switch (command) {
        case 'status':   return await _cmdStatus(opts, wantsJson);
        case 'balance':  return await _cmdBalance(opts, wantsJson);
        case 'send':     return await _cmdSend(opts, wantsJson);
        case 'history':  return await _cmdHistory(opts, wantsJson);
        case 'contacts': return await _cmdContacts(opts, wantsJson);
        case 'msg':      return await _cmdMsg(opts, wantsJson);
        case 'node':     return await _cmdNode(opts, wantsJson);
        case 'exchange': return await _cmdExchange(opts, wantsJson);
        case 'spendlock':return await _cmdSpendLock(opts, wantsJson);
        case 'hwlock':   return await _cmdHwLock(opts, wantsJson);
        case 'automation':return await _cmdAutomation(opts, wantsJson);
        default:
          _err('Unknown command "$command". Run SovNode.exe --cli --help for usage.', wantsJson);
          return 1;
      }
    } catch (e) {
      _err('Unexpected error: $e', wantsJson);
      return 1;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // COMMANDS
  // ───────────────────────────────────────────────────────────────────────────

  /// Headless wallet restore from a BIP39 seed phrase — no GUI needed. Mirrors
  /// recovery_screen: 16-byte entropy -> sha256 -> 32-byte Ed25519 seed; Sovereign
  /// ID from the phrase; PIN-encrypt (required on Linux, no plaintext at rest).
  static Future<int> _cmdRestore(Map<String, dynamic> opts, bool json) async {
    // Seed source, most-secure first: a file, then piped stdin, then --seed on
    // the command line (discouraged — it is visible in the process arguments and
    // the shell history, so the phrase can leak to anything that lists processes).
    String raw = '';
    final seedFile = opts['seed-file'];
    final seedArg  = opts['seed'];
    if (seedFile is String && seedFile.isNotEmpty) {
      try {
        raw = File(seedFile).readAsStringSync();
      } catch (e) {
        _err('Could not read --seed-file "$seedFile": $e', json);
        return 1;
      }
    } else if (seedArg is String && seedArg.isNotEmpty) {
      raw = seedArg;
      stderr.writeln('[warning] --seed is visible in process args and shell '
          'history. Prefer --seed-file <path> or piping the phrase via stdin.');
    } else {
      // Piped:  echo "word1 … word12" | sov_node --cli restore --pin <code>
      try {
        if (!stdin.hasTerminal) raw = stdin.readLineSync(encoding: utf8) ?? '';
      } catch (_) {/* no readable stdin */}
    }
    raw = raw.trim();
    if (raw.isEmpty) {
      _err('Provide the seed phrase via --seed-file <path>, stdin '
          '(echo "<12 words>" | … restore --pin <code>), or --seed "<12 words>".', json);
      return 1;
    }
    final words = raw
        .split(RegExp(r'[\s,]+'))
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();
    if (!Bip39.validateMnemonic(words)) {
      _err('Invalid seed phrase — expected 12 valid BIP39 words.', json);
      return 1;
    }
    final entropy = Bip39.mnemonicToEntropyBytes(words);
    if (entropy == null) {
      _err('Could not derive entropy from the seed phrase.', json);
      return 1;
    }
    final seedHex = sha256.convert(entropy).toString();
    final sovId = Bip39.mnemonicToSovereignId(words);
    await KeyManager.storeRestoredKeys(privateKeyHex: seedHex, sovereignId: sovId);

    final pin = opts['pin'] as String?;
    if (KeyManager.requiresPinToPersist) {
      if (pin == null || pin.isEmpty) {
        _err('This platform requires --pin <code> to persist the restored key.', json);
        return 1;
      }
      if (!await KeyManager.enableSpendLock(pin)) {
        _err('Restore failed to persist the encrypted key.', json);
        return 1;
      }
    } else if (pin != null && pin.isNotEmpty) {
      await KeyManager.enableSpendLock(pin);
    }
    // Mirror the GUI restore's SharedPreferences state so every other command
    // recognises the wallet (they read 'sovereign_id' from prefs, not keys.json).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sovereign_id', sovId);
    await prefs.setBool('enrollment_complete', true);
    await prefs.setInt('enrolled_at', DateTime.now().millisecondsSinceEpoch);
    if (json) {
      print(jsonEncode({'ok': true, 'sovereign_id': sovId}));
    } else {
      print('Wallet restored. SOV ID: $sovId');
    }
    return 0;
  }

  /// Connect, authenticate, and query the balance — with a retry so a single
  /// raced reconnect handshake (no HELLO_ACK / no balance frame) doesn't report
  /// a spurious 0. Mirrors the GUI's balance-query-resilient-to-reconnect fix.
  /// Returns (balance_seeds, relay_node_id, reached).
  static Future<({int seeds, String nodeId, bool reached})> _fetchBalance(
    String sovId,
    String nodeUrl,
    SharedPreferences prefs, {
    int attempts = 2,
  }) async {
    Object? lastErr;
    for (int i = 0; i < attempts; i++) {
      final conn = _CliWS();
      try {
        await conn.connect(nodeUrl, prefs);
        final balResp = await conn.sendAndWait(
          {'type': 'BALANCE_QUERY', 'sovereign_id': sovId},
          ['SOV_BALANCE_RESULT', 'BALANCE_RESULT'],
        );
        // A valid handshake yields a node_id; a valid balance frame yields a
        // numeric field. If neither arrived, the handshake raced — retry once.
        final hasBal = balResp != null &&
            (balResp['balance_seeds'] is num || balResp['balance'] is num);
        if (conn.connectedNodeId.isNotEmpty && hasBal) {
          final seeds = (balResp['balance_seeds'] as num?)?.toInt() ??
                        (balResp['balance']       as num?)?.toInt() ?? 0;
          return (seeds: seeds, nodeId: conn.connectedNodeId, reached: true);
        }
        // Partial: keep the node_id we got but treat balance as unconfirmed.
        if (i == attempts - 1 && conn.connectedNodeId.isNotEmpty) {
          final seeds = (balResp?['balance_seeds'] as num?)?.toInt() ??
                        (balResp?['balance']       as num?)?.toInt() ?? 0;
          return (seeds: seeds, nodeId: conn.connectedNodeId, reached: true);
        }
      } catch (e) {
        lastErr = e;
      } finally {
        await conn.close();
      }
      if (i < attempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    if (lastErr != null) throw lastErr;
    return (seeds: 0, nodeId: '', reached: false);
  }

  /// Sign an outgoing command in place, exactly like RelayConnector.send():
  /// set node_id + timestamp, then attach nonce + signature via KeyManager.
  /// Required for MESSAGE_SEND / SOV_TRANSFER (relay rejects them otherwise with
  /// SIGNATURE_REQUIRED). Exempt query types work without it.
  static Future<void> _signInPlace(
      Map<String, dynamic> msg, SharedPreferences prefs) async {
    String sovereignId = prefs.getString('sovereign_id') ?? '';
    if (sovereignId.isEmpty) {
      sovereignId = (await KeyManager.getSovereignId()) ?? '';
    }
    msg['node_id']   = sovereignId;
    msg['timestamp'] = DateTime.now().millisecondsSinceEpoch;
    // The 2-char op code, and the English `type` removed, BEFORE signing - in the
    // same order as RelayConnector.send(). This used to be skipped: the CLI signed a
    // message carrying `type`, the node's gateway then ADDED `op`, and the signature
    // covered a shape the node never sees, so every CLI transfer logged
    // [TX-SIG] INVALID SIGNATURE_MISMATCH (measured live 2026-10-02) and would be
    // refused the day tx_signature_enforce is set to reject. It also sent the
    // operation name in clear on the wire, which the dictionary exists to prevent.
    RelayConnector.addOpCode(msg);
    // Sign as the id just claimed above. This mirrored RelayConnector.send(),
    // which is how it inherited the same defect: node_id came from prefs while
    // the signature was made with the raw Keystore id, so on a wallet whose
    // Keystore holds a stale AS-2026-* id the two disagreed and the signature
    // could never verify.
    final sigData =
        await KeyManager.signMessage(msg, asSovereignId: sovereignId);
    msg['nonce']     = sigData['nonce'];
    msg['signature'] = sigData['signature'];
  }

  /// status — identity + relay + balance
  static Future<int> _cmdStatus(Map<String, dynamic> opts, bool json) async {
    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final name    = prefs.getString('palm_name') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);

    if (sovId.isEmpty) {
      _err('Wallet not set up — import your 12-word phrase via the GUI first.', json);
      return 1;
    }

    // Connect to relay for balance + node info (retry-resilient)
    String relayNode = '';
    int balSeeds = 0;
    try {
      final r = await _fetchBalance(sovId, nodeUrl, prefs);
      relayNode = r.nodeId;
      balSeeds  = r.seeds;
    } catch (e) {
      if (!json) stderr.writeln('warning: relay unreachable ($e) — balance unavailable');
    }

    final balSov = balSeeds / _kSeedsPerSov;

    if (json) {
      print(jsonEncode({
        'sovereign_id': sovId,
        'name':         name,
        'balance_sov':  balSov,
        'balance_seeds': balSeeds,
        'relay':        nodeUrl,
        'relay_node_id': relayNode,
      }));
    } else {
      print('sovereign_id : $sovId');
      if (name.isNotEmpty) print('name         : $name');
      print('balance      : ${_fmtSov(balSeeds)} SOV');
      print('relay        : $nodeUrl');
      if (relayNode.isNotEmpty) print('node_id      : ${relayNode.substring(0, 16)}…');
    }
    return 0;
  }

  /// balance — print raw SOV number (scriptable)
  static Future<int> _cmdBalance(Map<String, dynamic> opts, bool json) async {
    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);

    if (sovId.isEmpty) {
      _err('Wallet not set up.', json);
      return 1;
    }

    try {
      final r = await _fetchBalance(sovId, nodeUrl, prefs);
      if (json) {
        print(jsonEncode({'balance_sov': r.seeds / _kSeedsPerSov, 'balance_seeds': r.seeds}));
      } else {
        print(_fmtSov(r.seeds));
      }
      return 0;
    } catch (e) {
      _err('Could not reach relay: $e', json);
      return 1;
    }
  }

  /// send --to <sov-id> --amount <sov> [--memo <text>]
  static Future<int> _cmdSend(Map<String, dynamic> opts, bool json) async {
    final to      = opts['to']     as String? ?? '';
    final amtStr  = opts['amount'] as String? ?? '';
    final memo    = opts['memo']   as String? ?? '';

    if (to.isEmpty || amtStr.isEmpty) {
      _err('Usage: --cli send --to <sov-id> --amount <sov>', json);
      return 1;
    }

    final double? amtSov = double.tryParse(amtStr);
    if (amtSov == null || amtSov <= 0) {
      _err('Invalid amount "$amtStr" — must be a positive number.', json);
      return 1;
    }
    final int amtSeeds = (amtSov * _kSeedsPerSov).round();

    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);

    if (sovId.isEmpty) {
      _err('Wallet not set up.', json);
      return 1;
    }

    final conn = _CliWS();
    try {
      await conn.connect(nodeUrl, prefs);

      // A SOV ID is the only address there is. SOV has no @handles by
      // design: a name a citizen picks is a name a citizen can leak, and this
      // network's whole promise is that it never holds anything that identifies
      // you off it.
      final String toId = to;

      // tx_nonce is a MONOTONIC sequence counter the node checks as
      // strict (disc.nonce + 1) — NOT a timestamp. Start from the locally
      // cached value and, if the node reports a different expected_nonce
      // (e.g. first send from this machine, or after syncing a fresh node),
      // retry once with the exact value the node wants. Matches send_sov_screen.
      int txNonce = (prefs.getInt('tx_nonce') ?? 0) + 1;

      Future<Map<String, dynamic>?> attempt(int n) async {
        final txId = _makeId();
        final payload = <String, dynamic>{
          'type':              'SOV_TRANSFER',
          'from_sovereign_id': sovId,
          'to_sovereign_id':   toId,
          'amount_seeds':      amtSeeds,
          'tx_id':             txId,
          'tx_nonce':          n,
          if (memo.isNotEmpty) 'memo': memo,
        };
        await _signInPlace(payload, prefs); // adds node_id + timestamp + signature
        final r = await conn.sendAndWait(payload, ['SOV_TRANSFER_RESULT', 'SR'], timeoutSecs: 15);
        if (r != null) r['_tx_id'] = txId;
        return r;
      }

      var resp = await attempt(txNonce);
      // Self-correct to the node's expected nonce (works on any node, incl. a
      // freshly-synced home node whose nonce differs from our cached value).
      if (resp != null && resp['success'] != true) {
        final err = resp['error'] as String?;
        final exp = (resp['expected_nonce'] as num?)?.toInt();
        if (exp != null && (err == 'NONCE_FUTURE' || err == 'NONCE_ALREADY_USED')) {
          txNonce = exp;
          resp = await attempt(txNonce);
        }
      }

      if (resp == null) {
        _err('No response from relay — transfer state unknown.', json);
        return 1;
      }
      if (resp['success'] == true) {
        await prefs.setInt('tx_nonce', txNonce); // persist last-used nonce
        final txId  = resp['_tx_id'] as String? ?? '';
        final feeSv = ((resp['fee_seeds'] as num?)?.toInt() ?? 0) / _kSeedsPerSov;
        if (json) {
          print(jsonEncode({'ok': true, 'tx_id': txId, 'amount_sov': amtSov, 'fee_sov': feeSv, 'to': toId}));
        } else {
          print('ok  tx=${txId.isNotEmpty ? txId.substring(0, 12) : "?"}  amount=${_fmtSov(amtSeeds)} SOV  fee=$feeSv SOV  to=$toId');
        }
        return 0;
      } else {
        final err = resp['error'] as String? ?? 'UNKNOWN';
        _err('Transfer rejected: $err', json);
        return 1;
      }
    } catch (e) {
      _err('Send failed: $e', json);
      return 1;
    } finally {
      await conn.close();
    }
  }

  /// history [--limit <n>] — recent transactions from local SharedPreferences cache
  static Future<int> _cmdHistory(Map<String, dynamic> opts, bool json) async {
    final limit = int.tryParse(opts['limit'] as String? ?? '20') ?? 20;
    final prefs  = await SharedPreferences.getInstance();
    final sovId  = prefs.getString('sovereign_id') ?? '';

    // D25 (1.2.27): take the NEWEST `limit` regardless of how the store is ordered (it is newest-first,
    // so the old `sublist(length - limit)` returned the OLDEST entries).
    int ts(Map<String, dynamic> t) => (t['created_at'] as int?) ?? (t['timestamp'] as int?) ?? 0;
    final txs = [...TransactionStore.getAll(prefs)]..sort((a, b) => ts(b).compareTo(ts(a)));
    final newest = txs.length > limit ? txs.sublist(0, limit) : txs;
    final recent = newest.reversed.toList();   // oldest -> newest, for the table below

    if (json) {
      print(jsonEncode(newest));                // newest first
      return 0;
    }

    if (recent.isEmpty) {
      print('No transaction history cached locally. Connect the wallet to sync.');
      return 0;
    }

    print('${'Date'.padRight(22)} ${'Dir'.padRight(5)} ${'Amount (SOV)'.padRight(16)} Party');
    print('─' * 72);
    for (final tx in recent.reversed) {
      final ts     = tx['created_at'] as int? ?? tx['timestamp'] as int? ?? 0;
      final dtStr  = ts > 0
          ? DateTime.fromMillisecondsSinceEpoch(ts).toLocal().toString().substring(0, 19)
          : '?';
      final from   = tx['from_sovereign_id'] as String? ?? tx['from_id'] as String? ?? '';
      final amt    = (tx['amount_seeds'] as num?)?.toInt() ?? 0;
      final dir    = from == sovId ? 'OUT' : 'IN ';
      final party  = from == sovId
          ? (tx['to_sovereign_id'] as String? ?? tx['to_id'] as String? ?? '?')
          : from;
      print('${dtStr.padRight(22)} $dir   ${_fmtSov(amt).padRight(16)} $party');
    }
    return 0;
  }

  /// contacts — list local contacts
  static Future<int> _cmdContacts(Map<String, dynamic> opts, bool json) async {
    final contacts = await ContactsDb.getContacts();

    if (json) {
      print(jsonEncode(contacts.map((c) => {
        'sovereign_id': c.sovereignId,
        'name':         c.nickname,
        'favourite':    c.isFavourite,
      }).toList()));
      return 0;
    }

    if (contacts.isEmpty) {
      print('No contacts yet.');
      return 0;
    }

    print('${'SOV ID'.padRight(28)} Name');
    print('─' * 50);
    for (final c in contacts) {
      final star = c.isFavourite ? '★ ' : '  ';
      print('$star${c.sovereignId.padRight(26)} ${c.nickname}');
    }
    return 0;
  }

  /// msg --to <id> "<text>"   — send a message
  /// msg --list [--with <id>] [--limit <n>]  — list local messages
  static Future<int> _cmdMsg(Map<String, dynamic> opts, bool json) async {
    final to      = opts['to']     as String?;
    final withId  = opts['with']   as String?;
    final isList  = opts.containsKey('list') || (to == null && withId == null);
    final text    = opts['_msg_text'] as String?;

    if (opts.containsKey('listen')) {
      return _cmdMsgListen(opts, json);
    }
    if (isList) {
      return _cmdMsgList(opts, json);
    }

    // Send mode
    if (to == null || to.isEmpty) {
      _err('Usage: --cli msg --to <sovereign_id> "<message text>"', json);
      return 1;
    }
    if (text == null || text.isEmpty) {
      _err('No message text provided. Usage: --cli msg --to <id> "<text>"', json);
      return 1;
    }

    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);

    if (sovId.isEmpty) {
      _err('Wallet not set up.', json);
      return 1;
    }

    // E2E like the app (v2: X25519 + AES-256-GCM). The CLI used to send a v1
    // PLAINTEXT envelope, which every node on the path could read — the app has
    // refused plaintext since 2026-05-21, and the CLI now does too.
    final myPriv = await MessageKeyManager.getPrivateKeyBytes().catchError((_) => null);
    if (myPriv == null) {
      _err('This wallet has no messaging key yet.', json);
      return 1;
    }
    final msgId = _makeId();
    final convId = ConversationUtils.conversationId(sovId, to);

    // Up to 2 attempts, each on a FRESH signed handshake (msgsigfix 2026-06-16).
    // A cold-start race can ship an unsigned HELLO → legacyMode → SIGNATURE_REQUIRED,
    // or drop the handshake → no response. Re-handshaking clears both. msgId is fixed
    // so the retry is idempotent on the node (it dedups by message_id).
    String lastErr = 'No relay response — message state unknown.';
    String? envelope;
    for (var attempt = 0; attempt < 2; attempt++) {
      final conn = _CliWS();
      try {
        await conn.connect(nodeUrl, prefs);
        if (envelope == null) {
          final recipientKey = await conn.messagingKeyOf(to);
          if (recipientKey == null) {
            _err('$to has not published a messaging key yet, so a message to them '
                'cannot be encrypted. It was NOT sent. They publish one the first time '
                'they open the SOV app (or run any CLI command) on their device.', json);
            return 1;
          }
          envelope = await MessageEncryptor.encrypt(
            plaintext: text, recipientPubKeyHex: recipientKey, myPrivKeyBytes: myPriv);
          if (envelope == null) {
            _err('Encryption failed. Message not sent.', json);
            return 1;
          }
        }
        final payload = <String, dynamic>{
          'type':              'MESSAGE_SEND',
          'from_sovereign_id': sovId,
          'to_sovereign_id':   to,
          'message_id':        msgId,
          'encrypted_payload': envelope,
          'message_type':      'text',
          'conversation_id':   convId,
        };
        await _signInPlace(payload, prefs);
        final resp = await conn.sendAndWait(
          payload,
          ['MESSAGE_SEND_RESULT', 'MA', 'MESSAGE_ACK'],
          timeoutSecs: 15,
        );
        if (resp == null) {
          lastErr = 'No relay response — message state unknown.';
        } else {
          final status = resp['status'] as String? ?? '';
          if (resp['success'] == true || status == 'delivered' || status == 'queued') {
            final now = DateTime.now().millisecondsSinceEpoch;
            try {
              await ContactsDb.saveMessage(LocalMessage(
                id: msgId, conversationId: convId, fromSovereignId: sovId,
                toSovereignId: to, contentType: 'text', encryptedContent: envelope,
                decryptedContent: text, status: status.isEmpty ? 'sent' : status,
                sentAt: now));
              await ContactsDb.upsertConversation(
                id: convId, participantId: to, preview: text, lastMessageAt: now);
            } catch (_) {}
            if (json) {
              print(jsonEncode({'ok': true, 'message_id': msgId, 'status': status}));
            } else {
              print('ok  message_id=${msgId.substring(0, 12)}  status=$status  to=$to');
            }
            return 0;
          }
          lastErr = 'Message rejected: ${resp['error'] as String? ?? status}';
        }
      } catch (e) {
        lastErr = 'Send failed: $e';
      } finally {
        await conn.close();
      }
      if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _err(lastErr, json);
    return 1;
  }

  /// msg --listen [--seconds <n>] — stay connected and print messages as they
  /// arrive (until Ctrl-C, or for n seconds). While connected this wallet shows as
  /// online, so senders whose devices are holding messages for it deliver them.
  static Future<int> _cmdMsgListen(Map<String, dynamic> opts, bool json) async {
    final prefs = await SharedPreferences.getInstance();
    final sovId = prefs.getString('sovereign_id') ?? '';
    if (sovId.isEmpty) { _err('Wallet not set up.', json); return 1; }
    final secs  = int.tryParse(opts['seconds'] as String? ?? '');
    final conn  = _CliWS();
    conn.onKept = (from, text, sentAt) {
      if (json) {
        print(jsonEncode({'from': from, 'text': text, 'sent_at': sentAt}));
      } else {
        final dt = DateTime.fromMillisecondsSinceEpoch(sentAt).toLocal().toString().substring(0, 16);
        print('$dt  $from  ${text ?? '[encrypted - sender key not yet available]'}');
      }
    };
    try {
      await conn.connect(await _resolveNodeUrl(opts, prefs), prefs);
      if (!json) {
        stderr.writeln('listening as $sovId via node ${conn.connectedNodeId.isEmpty ? '?' : conn.connectedNodeId.substring(0, min(8, conn.connectedNodeId.length))}'
            '${secs == null ? ' — Ctrl-C to stop' : ' for ${secs}s'}');
      }
      final until = secs == null ? null : DateTime.now().add(Duration(seconds: secs));
      while (until == null || DateTime.now().isBefore(until)) {
        await conn.keepIncoming();
        if (!conn.isOpen) { _err('Connection to the node closed.', json); return 1; }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      _err('Listen failed: $e', json);
      return 1;
    } finally {
      await conn.close();
    }
    return 0;
  }

  static Future<int> _cmdMsgList(Map<String, dynamic> opts, bool json) async {
    final withId = opts['with'] as String?;
    final limit  = int.tryParse(opts['limit'] as String? ?? '20') ?? 20;
    final prefs  = await SharedPreferences.getInstance();
    final sovId  = prefs.getString('sovereign_id') ?? '';

    // Fetch first: connecting is what makes the node hand over messages queued
    // while this wallet was away. `--offline` lists only what is already here.
    var fetched = 0;
    String? fetchErr;
    if (!opts.containsKey('offline') && sovId.isNotEmpty) {
      final conn = _CliWS();
      try {
        await conn.connect(await _resolveNodeUrl(opts, prefs), prefs);
        // The node's queue arrives right after HELLO_ACK. Most messages, though, are
        // held by the SENDER's device and retried when this wallet's presence goes
        // online — so stay connected long enough for those retries to land.
        final wait = int.tryParse(opts['wait'] as String? ?? '') ?? 8;
        final until = DateTime.now().add(Duration(seconds: wait.clamp(0, 120)));
        while (DateTime.now().isBefore(until)) {
          await conn.keepIncoming();
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        await conn.keepIncoming();
        // Messages that arrived before their sender's key was published.
        for (final c in await ContactsDb.getConversations()) {
          for (final m in await ContactsDb.getMessages(c.id)) {
            if (m.decryptedContent == null && m.fromSovereignId != sovId &&
                MessageEncryptor.isEncryptedEnvelope(m.encryptedContent)) {
              final t = await conn.decryptFrom(m.fromSovereignId, m.encryptedContent);
              if (t != null) await ContactsDb.updateMessageDecrypted(m.id, t);
            }
          }
        }
      } catch (e) {
        fetchErr = 'could not reach the node ($e) — showing local messages only';
      } finally {
        await conn.close();
        fetched = conn.keptIncoming;
      }
    }
    if (!json) {
      if (fetchErr != null) {
        stderr.writeln('note: $fetchErr');
      } else if (fetched > 0) {
        print('$fetched new message${fetched == 1 ? '' : 's'} received\n');
      }
    }

    if (withId != null && withId.isNotEmpty) {
      // List messages in a specific conversation
      final convId = ConversationUtils.conversationId(sovId, withId);
      final msgs   = await ContactsDb.getMessages(convId);
      final recent = msgs.length > limit ? msgs.sublist(msgs.length - limit) : msgs;

      if (json) {
        print(jsonEncode(recent.map((m) => {
          'id':      m.id,
          'from':    m.fromSovereignId,
          'status':  m.status,
          'sent_at': m.sentAt,
          'preview': _msgPreview(m.decryptedContent ?? (MessageEncryptor.isEncryptedEnvelope(m.encryptedContent) ? "[encrypted - sender key not yet available]" : m.encryptedContent)),
        }).toList()));
        return 0;
      }

      if (recent.isEmpty) { print('No messages with $withId'); return 0; }
      print('${'Date'.padRight(20)} ${'From'.padRight(10)} ${'Status'.padRight(12)} Preview');
      print('─' * 72);
      for (final m in recent) {
        final dt  = DateTime.fromMillisecondsSinceEpoch(m.sentAt).toLocal()
            .toString().substring(0, 16);
        final who = m.fromSovereignId == sovId ? 'me' : m.fromSovereignId.substring(4, 12);
        print('${dt.padRight(20)} ${who.padRight(10)} ${m.status.padRight(12)} '
            '${_msgPreview(m.decryptedContent ?? (MessageEncryptor.isEncryptedEnvelope(m.encryptedContent) ? "[encrypted - sender key not yet available]" : m.encryptedContent))}');
      }
    } else {
      // List all conversations
      final convs = await ContactsDb.getConversations();

      if (json) {
        print(jsonEncode(convs.map((c) => {
          'conversation_id': c.id,
          'participant':     c.participantId,
          'unread':          c.unreadCount,
          'last_message_at': c.lastMessageAt,
          'preview':         c.lastMessagePreview,
        }).toList()));
        return 0;
      }

      if (convs.isEmpty) { print('No conversations yet.'); return 0; }
      print('${'Participant'.padRight(28)} ${'Unread'.padRight(8)} Preview');
      print('─' * 72);
      for (final c in convs) {
        final unread = c.unreadCount > 0 ? '(${c.unreadCount})' : '';
        print('${c.participantId.padRight(28)} ${unread.padRight(8)} ${c.lastMessagePreview ?? ''}');
      }
    }
    return 0;
  }

  /// node — relay reachability probe
  static Future<int> _cmdNode(Map<String, dynamic> opts, bool json) async {
    final rest = (opts['_rest'] as List<String>? ?? const <String>[]);
    final sub  = rest.isNotEmpty ? rest[0] : 'status';
    switch (sub) {
      case 'on':
      case 'start':  return await _cmdNodeOn(opts, json);
      case 'off':
      case 'stop':   return await _cmdNodeOff(opts, json);
      case 'status': return await _cmdNodeStatus(opts, json);
      default:
        _err('Usage: node <status|on|off>', json);
        return 1;
    }
  }

  /// Locate the bundled node runtime (node.exe + sov-node/src/index.js) beside
  /// the running executable — mirrors NodeController._locate().
  static (String, String)? _locateBundledNode() {
    final exeDir   = File(Platform.resolvedExecutable).parent.path;
    final nodeName = Platform.isWindows ? 'node.exe' : 'node';
    // Dev fallback via SOV_DEV_NODE_DIR — no private folder layout baked in.
    final roots = <String>[
      exeDir,
      '$exeDir/data/flutter_assets',
      if ((Platform.environment['SOV_DEV_NODE_DIR'] ?? '').isNotEmpty)
        Platform.environment['SOV_DEV_NODE_DIR']!,
    ];
    for (final root in roots) {
      final entry = '$root/sov-node/src/index.js';
      if (!File(entry).existsSync()) continue;
      final bundled = '$root/node/$nodeName';
      if (File(bundled).existsSync()) return (bundled, entry);
    }
    return null;
  }

  /// True if a local node's dashboard is answering on :8080 (ANY HTTP reply,
  /// incl. the 302 to /dashboard/login — a listener there IS the node).
  static Future<bool> _localNodeAlive() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      final r = await (await c.getUrl(Uri.parse('http://127.0.0.1:8080/node-info'))).close();
      await r.drain();
      c.close();
      return r.statusCode > 0;
    } catch (_) { return false; }
  }

  static Future<int> _cmdNodeStatus(Map<String, dynamic> opts, bool json) async {
    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    // Default to the LOCAL node so `node status` reports THIS machine's node.
    final nodeUrl = opts['node'] as String? ?? 'wss://127.0.0.1:443';
    final localUp = await _localNodeAlive();

    final conn = _CliWS();
    Map<String, dynamic>? stats;
    bool reached = false;
    try {
      await conn.connect(nodeUrl, prefs);
      reached = true;
      stats = await conn.sendAndWait(
        {'type': 'NETWORK_STATS', 'sovereign_id': sovId},
        ['NODE_STATS_RESULT', 'ZR'], timeoutSecs: 10);
    } catch (_) {}
    await conn.close();

    if (json) {
      print(jsonEncode({'local_node_running': localUp, 'reachable': reached, 'url': nodeUrl, 'stats': stats}));
      return reached ? 0 : 1;
    }
    print('local full node : ${localUp ? "RUNNING (dashboard :8080 up)" : "not running"}');
    print('queried         : $nodeUrl  (${reached ? "reachable" : "UNREACHABLE"})');
    if (stats != null) {
      String n(dynamic v) => v == null ? '—' : '$v';
      final up = (stats['uptime_sec'] as num?)?.toInt();
      print('node id         : ${n(stats['node_id']).toString().substring(0, stats['node_id'] != null ? 16 : 0)}…');
      print('version         : ${n(stats['version'])}');
      print('connected clients: ${n(stats['connected_citizens'])}   <-- citizens served right now');
      print('peer nodes      : ${n(stats['peer_count'])}');
      print('enrolled citizens: ${n(stats['enrolled_citizens'])}');
      print('uptime          : ${up == null ? '—' : '${up ~/ 3600}h ${(up % 3600) ~/ 60}m ${up % 60}s'}');
      print('SOV circulation : ${_fmtSov((stats['total_sov_seeds'] as num?)?.toInt() ?? 0)} SOV');
      print('transfers 24h   : ${n(stats['transfers_24h'])}');
      print('operator id     : ${n(stats['operator_id'])}');
    }
    return reached ? 0 : 1;
  }

  static Future<int> _cmdNodeOn(Map<String, dynamic> opts, bool json) async {
    if (await _localNodeAlive()) {
      if (json) { print(jsonEncode({'ok': true, 'already_running': true})); }
      else { print('Full node already running (dashboard :8080).'); }
      return 0;
    }
    final loc = _locateBundledNode();
    if (loc == null) { _err('Bundled node runtime not found next to this executable.', json); return 1; }
    final (nodeBin, entry) = loc;
    final prefs = await SharedPreferences.getInstance();
    final sovId = prefs.getString('sovereign_id') ?? '';
    final dataDir = opts['data'] as String? ?? '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}/.sov-node';

    final env = Map<String, String>.from(Platform.environment)
      ..['OPERATOR_SOVEREIGN_ID'] = sovId
      ..['SOV_NO_TRAY'] = '1'
      ..['SOV_DATA_DIR'] = dataDir;
    try {
      final proc = await Process.start(nodeBin, [entry],
          environment: env,
          workingDirectory: File(entry).parent.parent.path,
          mode: ProcessStartMode.detached);
      // Give it a moment, then confirm it bound the dashboard.
      await Future.delayed(const Duration(seconds: 6));
      final up = await _localNodeAlive();
      if (json) { print(jsonEncode({'ok': up, 'pid': proc.pid, 'serving': up})); }
      else {
        print(up ? 'Full node started (pid ${proc.pid}) — serving on :443/:7771/:8080.'
                 : 'Node launched (pid ${proc.pid}) but dashboard not up yet — check `node status` shortly.');
      }
      return up ? 0 : 1;
    } catch (e) {
      _err('Could not start node: $e', json);
      return 1;
    }
  }

  static Future<int> _cmdNodeOff(Map<String, dynamic> opts, bool json) async {
    if (!Platform.isWindows) {
      _err('node off is Windows-only in the CLI (use the app toggle elsewhere).', json);
      return 1;
    }
    // Kill exactly the process(es) owning the SOV node ports — not every node.exe.
    final script = r'''
$ports = 443,7771,8080
$pids = @()
foreach ($p in $ports) {
  try { $pids += (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction Stop).OwningProcess } catch {}
}
$pids = $pids | Sort-Object -Unique
foreach ($id in $pids) {
  try { $pr = Get-Process -Id $id -ErrorAction Stop; if ($pr.Name -eq 'node') { Stop-Process -Id $id -Force; Write-Output "killed $id" } } catch {}
}
''';
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-Command', script]);
      final killed = (r.stdout as String).trim();
      final ok = killed.contains('killed');
      if (json) { print(jsonEncode({'ok': ok, 'detail': killed})); }
      else { print(ok ? 'Full node stopped ($killed).' : 'No SOV node process was holding the ports.'); }
      return 0;
    } catch (e) {
      _err('Could not stop node: $e', json);
      return 1;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // EXCHANGE — headless driving of the P2P SOV⇄fiat marketplace.
  // Mirrors the GUI's RelayConnector wire shapes exactly (exchange_screen.dart),
  // so a CLI trade exercises the same node paths as a citizen tapping the app.
  //
  //   exchange orders                              open order book
  //   exchange mine                                my listings (any status)
  //   exchange create --amount <sov> --memo "<text>" [--days 7]
  //                   [--payment "<how fiat is paid>"]
  //                   [--price <fiat/SOV> --currency NGN]     (omit = OTC)
  //   exchange chat --order <id> [--buyer <sid>]   thread messages (seller passes --buyer)
  //   exchange chat-send --order <id> --to <sid> "<text>"
  //   exchange threads --order <id>                seller negotiation inbox
  //   exchange fill --order <id> [--agreed <fiat/SOV>]
  //   exchange confirm --order <id>                seller confirms fiat received
  //   exchange cancel --order <id>
  // ───────────────────────────────────────────────────────────────────────────

  static Future<int> _cmdExchange(Map<String, dynamic> opts, bool json) async {
    final rest = (opts['_rest'] as List<String>? ?? const <String>[]);
    final sub  = rest.isNotEmpty ? rest[0] : '';

    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);
    if (sovId.isEmpty) {
      _err('Wallet not set up.', json);
      return 1;
    }

    final orderId = opts['order'] as String? ?? '';
    final conn = _CliWS();
    try {
      await conn.connect(nodeUrl, prefs);

      switch (sub) {
        case 'orders': {
          final resp = await conn.sendAndWait(
              {'type': 'EXCHANGE_VIEW_ORDERS'},
              ['EXCHANGE_ORDERS_LIST', 'XV'], timeoutSecs: 12);
          final orders = List<Map<String, dynamic>>.from(resp?['orders'] ?? []);
          if (json) { print(jsonEncode({'ok': true, 'orders': orders})); return 0; }
          if (orders.isEmpty) { print('no open orders'); return 0; }
          for (final o in orders) {
            final amt = _fmtSov((o['sov_amount'] as num?)?.toInt() ?? 0);
            print('${o['order_id']}  ${amt} SOV  price=${o['price_per_sov'] ?? 0} '
                '${o['currency_code'] ?? ''}  seller=${o['seller_sovereign_id'] ?? o['sovereign_id'] ?? '?'}  '
                'pay="${o['payment_method'] ?? ''}"  memo="${o['memo'] ?? ''}"');
          }
          return 0;
        }

        case 'mine': {
          final resp = await conn.sendAndWait(
              {'type': 'EXCHANGE_VIEW_MY_LISTINGS', 'sovereign_id': sovId},
              ['EXCHANGE_MY_LISTINGS_LIST', 'XY'], timeoutSecs: 12);
          final orders = List<Map<String, dynamic>>.from(resp?['orders'] ?? []);
          if (json) { print(jsonEncode({'ok': true, 'orders': orders})); return 0; }
          if (orders.isEmpty) { print('no listings'); return 0; }
          for (final o in orders) {
            print('${o['order_id']}  ${_fmtSov((o['sov_amount'] as num?)?.toInt() ?? 0)} SOV  '
                'status=${o['status']}  filled_by=${o['filled_by'] ?? '-'}');
          }
          return 0;
        }

        case 'create': {
          final amtStr = opts['amount'] as String? ?? '';
          final amt    = double.tryParse(amtStr);
          if (amt == null || amt <= 0) {
            _err('Usage: exchange create --amount <sov> --memo "<text>" [--payment "..."] [--price N --currency XXX]', json);
            return 1;
          }
          final priceStr = opts['price'] as String? ?? '0';
          final price    = double.tryParse(priceStr) ?? 0;
          final days     = int.tryParse(opts['days'] as String? ?? '7') ?? 7;
          final newId    = 'ORD-${DateTime.now().millisecondsSinceEpoch}-cli';
          final payload = <String, dynamic>{
            'type':             'EXCHANGE_LIST_ORDER',
            'sovereign_id':     sovId,
            'order_id':         newId,
            'sov_amount':       (amt * _kSeedsPerSov).round(),
            'price_per_sov':    price,
            'memo':             opts['memo'] as String? ?? '',
            'expires_in_hours': days * 24,
            'currency_code':    price > 0 ? (opts['currency'] as String? ?? 'USD') : 'OTC',
            'payment_method':   opts['payment'] as String? ?? '',
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_ORDER_LISTED', 'XL'], timeoutSecs: 15);
          if (resp?['success'] == true) {
            if (json) { print(jsonEncode({'ok': true, 'order_id': newId})); }
            else      { print('ok  order=$newId  escrowed=${amtStr} SOV'); }
            return 0;
          }
          _err('create failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        // Trade chat is end-to-end and kept only on the two devices (nodes keep none,
        // 2026-10-03). `chat` shows this device's copy of the thread; `chat-send`
        // encrypts to the counterparty; `threads` is the seller's inbox built here.
        case 'chat': {
          if (orderId.isEmpty) { _err('exchange chat --order <id> [--buyer <sid>]', json); return 1; }
          final buyer = (opts['buyer'] as String? ?? '').isNotEmpty ? opts['buyer'] as String : sovId;
          await Future<void>.delayed(const Duration(seconds: 2));   // let pushed messages land
          await conn.keepIncoming();
          final msgs = <Map<String, dynamic>>[];
          for (final m in await ContactsDb.getMessages(SecureChannels.tradeConv(orderId, buyer))) {
            var text = m.decryptedContent;
            if (text == null && MessageEncryptor.isEncryptedEnvelope(m.encryptedContent)) {
              text = await conn.decryptFrom(m.fromSovereignId, m.encryptedContent);
              if (text != null) await ContactsDb.updateMessageDecrypted(m.id, text);
            }
            msgs.add({'msg_id': m.id, 'from_id': m.fromSovereignId, 'content': text, 'status': m.status, 'ts': m.sentAt});
          }
          if (json) { print(jsonEncode({'ok': true, 'messages': msgs})); return 0; }
          if (msgs.isEmpty) { print('no messages on this device for that thread'); return 0; }
          for (final m in msgs) {
            print('[${m['from_id'] == sovId ? 'me' : m['from_id']}] ${m['content'] ?? '[encrypted - sender key not yet available]'}');
          }
          return 0;
        }

        case 'chat-send': {
          final to   = opts['to'] as String? ?? '';
          final text = rest.length > 1 ? rest.sublist(1).join(' ') : '';
          if (orderId.isEmpty || to.isEmpty || text.isEmpty) {
            _err('exchange chat-send --order <id> --to <sid> "<text>"', json);
            return 1;
          }
          final myPriv = await MessageKeyManager.getPrivateKeyBytes();
          final key = await conn.messagingKeyOf(to);
          if (key == null || myPriv == null) {
            _err('$to has not published a messaging key yet, so the message cannot be '
                'encrypted. It was NOT sent.', json);
            return 1;
          }
          final env = await MessageEncryptor.encrypt(plaintext: text, recipientPubKeyHex: key, myPrivKeyBytes: myPriv);
          if (env == null) { _err('Encryption failed. Message not sent.', json); return 1; }
          final msgId = 'XC-${_makeId()}';
          final payload = <String, dynamic>{
            'type':     'EXCHANGE_CHAT_SEND',
            'order_id': orderId,
            'from_id':  sovId,
            'to_id':    to,
            'content':  env,
            'msg_id':   msgId,
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_CHAT_SEND_RESULT', 'XH'], timeoutSecs: 12);
          if (resp?['success'] == true) {
            final buyer = (resp?['buyer_id'] as String?) ?? sovId;
            final delivered = resp?['status'] == 'delivered';
            await ContactsDb.saveChannelMessage(LocalMessage(
              id: msgId, conversationId: SecureChannels.tradeConv(orderId, buyer), fromSovereignId: sovId,
              toSovereignId: to, contentType: 'text', encryptedContent: env, decryptedContent: text,
              status: delivered ? 'delivered' : 'queued', sentAt: DateTime.now().millisecondsSinceEpoch));
            if (!delivered) {
              // Kept on THIS device; the desktop app on this machine retries it when they
              // come online. The node keeps nothing.
              await ContactsDb.addToOutbox(messageId: '$msgId@$to', toSovereignId: to,
                  encryptedContent: env, contentType: 'text', channel: 'xchg:$orderId');
            }
            if (json) { print(jsonEncode({'ok': true, 'status': delivered ? 'delivered' : 'queued'})); }
            else { print(delivered ? 'delivered' : 'recipient offline - kept on this device, delivered when they come online'); }
            return 0;
          }
          _err('chat-send failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        case 'threads': {
          if (orderId.isEmpty) { _err('exchange threads --order <id>', json); return 1; }
          await Future<void>.delayed(const Duration(seconds: 2));
          await conn.keepIncoming();
          final threads = await SecureChannels.tradeThreads(orderId);
          if (json) { print(jsonEncode({'ok': true, 'threads': threads})); return 0; }
          if (threads.isEmpty) { print('no threads on this device'); return 0; }
          for (final t in threads) {
            print('${t['buyer_id']}  messages=${t['message_count']}  unread=${t['unread']}  last="${t['last_content']}"');
          }
          return 0;
        }

        case 'fill': {
          if (orderId.isEmpty) { _err('exchange fill --order <id> [--agreed <fiat/SOV>]', json); return 1; }
          final agreed = double.tryParse(opts['agreed'] as String? ?? '0') ?? 0;
          final payload = <String, dynamic>{
            'type':               'EXCHANGE_FILL_ORDER',
            'buyer_sovereign_id': sovId,
            'order_id':           orderId,
            if (agreed > 0) 'agreed_price_per_sov': agreed,
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_ORDER_FILLED', 'XF'], timeoutSecs: 15);
          if (resp?['success'] == true) {
            if (json) { print(jsonEncode({'ok': true, 'resp': resp})); }
            else      { print('ok  filled $orderId  release_deadline=${resp?['release_deadline'] ?? '-'}'); }
            return 0;
          }
          _err('fill failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        case 'confirm': {
          if (orderId.isEmpty) { _err('exchange confirm --order <id>', json); return 1; }
          final payload = <String, dynamic>{
            'type':                    'EXCHANGE_CONFIRM_DELIVERY',
            'confirming_sovereign_id': sovId,
            'order_id':                orderId,
            'confirmation_type':       'SELLER_CONFIRMS_PAYMENT_RECEIVED',
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_DELIVERY_CONFIRMED', 'XC'], timeoutSecs: 15);
          if (resp?['success'] == true) {
            if (json) { print(jsonEncode({'ok': true})); } else { print('ok  confirmed — escrow released'); }
            return 0;
          }
          _err('confirm failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        case 'cancel': {
          if (orderId.isEmpty) { _err('exchange cancel --order <id>', json); return 1; }
          final payload = <String, dynamic>{
            'type':         'EXCHANGE_CANCEL_ORDER',
            'sovereign_id': sovId,
            'order_id':     orderId,
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_ORDER_CANCELLED', 'XX'], timeoutSecs: 15);
          if (resp?['success'] == true) {
            if (json) { print(jsonEncode({'ok': true})); } else { print('ok  cancelled'); }
            return 0;
          }
          _err('cancel failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        default:
          _err('Unknown exchange subcommand "$sub". '
               'Use: orders|mine|create|chat|chat-send|threads|fill|confirm|cancel', json);
          return 1;
      }
    } finally {
      await conn.close();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // SPEND-LOCK — enable/disable/status the PIN-encrypted key
  // ───────────────────────────────────────────────────────────────────────────
  static Future<int> _cmdSpendLock(Map<String, dynamic> opts, bool json) async {
    final rest = (opts['_rest'] as List<String>? ?? const <String>[]);
    final sub  = rest.isNotEmpty ? rest[0] : 'status';
    final pin  = opts['pin'] as String?;
    final on  = await KeyManager.isSpendLockEnabled();

    if (sub == 'status') {
      if (json) { print(jsonEncode({'spend_lock': on})); }
      else { print('spend-lock : ${on ? "ON (key is PIN-encrypted)" : "off (key stored in the clear)"}'); }
      return 0;
    }
    if (pin == null || pin.isEmpty) {
      _err('Spend-Lock $sub requires --pin <code>.', json); return 1;
    }
    if (sub == 'enable') {
      if (on) { _err('Spend-Lock already ON.', json); return 1; }
      final ok = await KeyManager.enableSpendLock(pin);
      if (!ok) { _err('Could not enable Spend-Lock (no key, or verify failed — nothing changed).', json); return 1; }
      if (json) { print(jsonEncode({'spend_lock': true})); }
      else { print('Spend-Lock ENABLED. Your key is now Argon2id-encrypted; every spend needs --pin.'); }
      return 0;
    }
    if (sub == 'disable') {
      final ok = await KeyManager.disableSpendLock(pin);
      if (!ok) { _err('Wrong PIN — Spend-Lock unchanged.', json); return 1; }
      if (json) { print(jsonEncode({'spend_lock': false})); }
      else { print('Spend-Lock disabled. Key restored to secure storage.'); }
      return 0;
    }
    _err('Usage: --cli spendlock <status|enable|disable> [--pin <code>]', json);
    return 1;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // HARDWARE-LOCK (Tier A) — TPM-sealed key at rest (Windows). No PIN: the TPM
  // itself is the key. A copied wallet blob is useless on any other machine.
  // ───────────────────────────────────────────────────────────────────────────
  static Future<int> _cmdHwLock(Map<String, dynamic> opts, bool json) async {
    final rest = (opts['_rest'] as List<String>? ?? const <String>[]);
    final sub  = rest.isNotEmpty ? rest[0] : 'status';
    final on   = await KeyManager.isHardwareLockEnabled();

    if (sub == 'status') {
      final avail = await KeyManager.isHardwareLockAvailable();
      final prov  = avail ? await KeyManager.hardwareBackingProvider() : 'none';
      final hello = on && await KeyManager.isHardwareLockHello();
      if (json) { print(jsonEncode({'hardware_lock': on, 'require_hello': hello, 'available': avail, 'provider': prov})); }
      else {
        print('hardware-lock : ${on ? "ON (key sealed in the TPM)" : "off"}');
        print('windows hello : ${hello ? "required each unlock" : "not required"}');
        print('secure element: ${avail ? prov : "not available on this machine"}');
      }
      return 0;
    }
    if (sub == 'enable') {
      if (on) { _err('Hardware-Lock already ON.', json); return 1; }
      if (await KeyManager.isSpendLockEnabled()) {
        _err('Disable Spend-Lock first (they are mutually exclusive).', json); return 1;
      }
      if (!await KeyManager.isHardwareLockAvailable()) {
        _err('No secure element (TPM/CNG) available on this machine — cannot enable.', json); return 1;
      }
      final hello = opts['hello'] == true;
      if (hello && !json) {
        print('Windows Hello required — approve the prompt when it appears (this is interactive).');
      }
      final ok = await KeyManager.enableHardwareLock(requireHello: hello);
      if (!ok) {
        _err(hello
            ? 'Could not enable Hardware-Lock+Hello (prompt cancelled/timed out — nothing changed).'
            : 'Could not enable Hardware-Lock (seal/verify failed — nothing changed).', json);
        return 1;
      }
      if (json) { print(jsonEncode({'hardware_lock': true, 'require_hello': hello})); }
      else {
        print(hello
            ? 'Hardware-Lock ENABLED with Windows Hello — every unlock now needs your Hello gesture.'
            : 'Hardware-Lock ENABLED. Your key is now sealed in the TPM — a copied wallet is useless off this machine.');
      }
      return 0;
    }
    if (sub == 'disable') {
      final ok = await KeyManager.disableHardwareLock();
      if (!ok) { _err('TPM could not unseal the key on this machine — Hardware-Lock unchanged.', json); return 1; }
      if (json) { print(jsonEncode({'hardware_lock': false})); }
      else { print('Hardware-Lock disabled. Key restored to secure storage.'); }
      return 0;
    }
    _err('Usage: --cli hwlock <status|enable|disable>', json);
    return 1;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // AUTOMATION POLICY — network-enforced spend caps + allowlist for a bot wallet
  // The NODES enforce these limits, so a compromised PC that holds the key still
  // cannot exceed them. Loosening a limit is delayed (cooldown); only this CLI can see or cancel it.
  // ───────────────────────────────────────────────────────────────────────────
  static Future<int> _cmdAutomation(Map<String, dynamic> opts, bool json) async {
    final rest = (opts['_rest'] as List<String>? ?? const <String>[]);
    final sub  = rest.isNotEmpty ? rest[0] : 'status';

    final prefs   = await SharedPreferences.getInstance();
    final sovId   = prefs.getString('sovereign_id') ?? '';
    final nodeUrl = await _resolveNodeUrl(opts, prefs);
    if (sovId.isEmpty) { _err('Wallet not set up.', json); return 1; }

    final conn = _CliWS();
    try {
      await conn.connect(nodeUrl, prefs);

      // Always read current policy first (needed for status + read-modify-write).
      Future<Map<String, dynamic>?> getState() => conn.sendAndWait(
          {'type': 'AUTOMATION_POLICY_GET'},
          ['AUTOMATION_POLICY_STATE', 'AS'], timeoutSecs: 12);
      Future<Map<String, dynamic>?> setPolicy(Map<String, dynamic> p) => conn.sendAndWait(
          {'type': 'AUTOMATION_POLICY_SET', ...p},
          ['AUTOMATION_POLICY_STATE', 'AS'], timeoutSecs: 12);

      final cur  = await getState();
      final pol  = (cur?['policy'] as Map?)?.cast<String, dynamic>() ?? const {};
      final curAllow = List<String>.from(pol['allowlist'] ?? const []);
      final curPerTx = (pol['per_tx_cap'] as num?)?.toInt() ?? 0;
      final curDaily = (pol['daily_cap']  as num?)?.toInt() ?? 0;
      final enabled  = pol['enabled'] == true;

      switch (sub) {
        case 'status': {
          final spent = (cur?['spent_24h_seeds'] as num?)?.toInt() ?? 0;
          final pend  = pol['pending'];
          final cool  = (cur?['cooldown_hours'] as num?)?.toInt() ?? 48;
          if (json) { print(jsonEncode({'ok': true, 'policy': pol, 'spent_24h_seeds': spent, 'cooldown_hours': cool})); return 0; }
          print('automated-wallet policy : ${enabled ? "ENABLED" : "off"}');
          print('  per-tx cap   : ${curPerTx == 0 ? "(none)" : "${_fmtSov(curPerTx)} SOV"}');
          print('  daily cap    : ${curDaily == 0 ? "(none)" : "${_fmtSov(curDaily)} SOV"}   spent 24h: ${_fmtSov(spent)} SOV');
          print('  allowlist    : ${curAllow.isEmpty ? "(any destination)" : curAllow.join(", ")}');
          if (pend != null) {
            final at = (pol['pending_at'] as num?)?.toInt() ?? 0;
            print('  PENDING relaxation takes effect: ${DateTime.fromMillisecondsSinceEpoch(at)} (cooldown ${cool}h) — "automation cancel" to stop it');
          }
          return 0;
        }

        case 'set': {
          // Full policy set (enables protection). Caps in SOV; 0 = unlimited.
          final perTx = double.tryParse(opts['per-tx'] as String? ?? '') ?? (curPerTx / _kSeedsPerSov);
          final daily = double.tryParse(opts['daily']  as String? ?? '') ?? (curDaily / _kSeedsPerSov);
          final allowArg = opts['allow'] as String?;
          final allow = allowArg != null
              ? allowArg.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
              : curAllow;
          final resp = await setPolicy({
            'enabled': true,
            'per_tx_cap': (perTx * _kSeedsPerSov).round(),
            'daily_cap':  (daily * _kSeedsPerSov).round(),
            'allowlist':  allow,
          });
          return _printSetResult(resp, json);
        }

        case 'allow': {
          final id = rest.length > 1 ? rest[1] : (opts['id'] as String? ?? '');
          if (id.isEmpty) { _err('Usage: automation allow <sovereign_id>', json); return 1; }
          final next = {...curAllow.toSet(), id}.toList();
          final resp = await setPolicy({'enabled': true, 'per_tx_cap': curPerTx, 'daily_cap': curDaily, 'allowlist': next});
          return _printSetResult(resp, json);
        }

        case 'deny': {
          final id = rest.length > 1 ? rest[1] : (opts['id'] as String? ?? '');
          if (id.isEmpty) { _err('Usage: automation deny <sovereign_id>', json); return 1; }
          final next = curAllow.where((x) => x != id).toList();
          final resp = await setPolicy({'enabled': true, 'per_tx_cap': curPerTx, 'daily_cap': curDaily, 'allowlist': next});
          return _printSetResult(resp, json);
        }

        case 'off': {
          final resp = await setPolicy({'enabled': false, 'per_tx_cap': 0, 'daily_cap': 0, 'allowlist': const []});
          return _printSetResult(resp, json);
        }

        case 'cancel': {
          final resp = await conn.sendAndWait(
              {'type': 'AUTOMATION_POLICY_CANCEL'},
              ['AUTOMATION_POLICY_STATE', 'AS'], timeoutSecs: 12);
          if (json) { print(jsonEncode({'ok': resp?['success'] == true, 'cancelled': resp?['cancelled'] == true})); return 0; }
          print(resp?['cancelled'] == true ? 'Pending relaxation cancelled.' : 'Nothing pending to cancel.');
          return 0;
        }

        default:
          _err('Usage: automation <status|set|allow <id>|deny <id>|off|cancel>\n'
               '  set --per-tx <sov> --daily <sov> --allow id1,id2', json);
          return 1;
      }
    } catch (e) {
      _err('automation: $e', json);
      return 1;
    } finally {
      conn.close();
    }
  }

  static int _printSetResult(Map<String, dynamic>? resp, bool json) {
    final ok = resp?['success'] == true;
    final applied = resp?['applied'] == true;
    if (json) { print(jsonEncode({'ok': ok, 'applied': applied, 'pending': resp?['pending'], 'pending_at': resp?['pending_at']})); return ok ? 0 : 1; }
    if (!ok) { print('failed: ${resp?['error'] ?? 'unknown'}'); return 1; }
    if (applied) { print('Policy applied.'); }
    else {
      final cool = (resp?['cooldown_hours'] as num?)?.toInt() ?? 48;
      print('Loosening a limit is delayed ${cool}h for safety. It takes effect after the cooldown '
            'unless you run "automation cancel" from this desktop CLI (on any desktop where this wallet is restored).');
    }
    return 0;
  }

  // PIN GATE
  // ───────────────────────────────────────────────────────────────────────────

  static Future<bool> _checkPin(String? pinArg) async {
    final prefs      = await SharedPreferences.getInstance();
    final pinEnabled = prefs.getBool('pin_enabled') ?? true;
    if (!pinEnabled) return true;

    final storedHash = prefs.getString('pin_hash') ?? '';
    if (storedHash.isEmpty) return true; // no PIN stored, allow

    final pin = pinArg ?? _promptPin();
    if (pin == null || pin.isEmpty) return false;

    // The app stores PinManager.hashPin (salted, device-bound) at enrolment, PIN setup
    // and restore; only the old settings screen stored plain sha256(pin). Accept both,
    // or the CLI refuses every wallet set up through the app (audit D24, 2026-10-08).
    final sovId = prefs.getString('sovereign_id') ?? '';
    if (await PinManager.verifyPin(pin, storedHash, sovId)) return true;
    final entered = sha256.convert(utf8.encode(pin)).toString();
    return entered == storedHash;
  }

  static String? _promptPin() {
    stderr.write('PIN: ');
    // Read without echo is not available in pure Dart; stdin reads plain.
    // For production use --pin flag in scripts to avoid interactive prompt.
    try {
      stdin.echoMode = false;
    } catch (_) {}
    final line = stdin.readLineSync();
    try {
      stdin.echoMode = true;
      stderr.writeln();
    } catch (_) {}
    return line;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // ARG PARSER
  // ───────────────────────────────────────────────────────────────────────────

  static Map<String, dynamic> _parseGlobal(List<String> args) {
    final result = <String, dynamic>{};
    String? pendingKey;
    String? command;
    final positional = <String>[];

    for (int i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('--')) {
        final key = a.substring(2);
        if (pendingKey != null) {
          result[pendingKey] = '';
          pendingKey = null;
        }
        // Flags that take a value
        if (['pin','node','to','amount','memo','with','limit',
             'order','buyer','payment','price','currency','days','agreed',
             'per-tx','daily','allow','id','data','seed','seed-file','seconds','wait'].contains(key)) {
          pendingKey = key;
        } else {
          result[key] = true; // boolean flag (e.g. --list, --json)
        }
      } else if (pendingKey != null) {
        result[pendingKey] = a;
        pendingKey = null;
      } else {
        positional.add(a);
      }
    }
    if (pendingKey != null) result[pendingKey] = '';

    // First positional = command; remaining are extra positionals (e.g. message text)
    if (positional.isNotEmpty) {
      command = positional[0];
      if (positional.length > 1) {
        // The trailing positional is the message text for `msg --to <id> "text"`
        result['_msg_text'] = positional.sublist(1).join(' ');
      }
    }

    result['_command'] = command ?? '';
    result['_rest']    = positional.isNotEmpty ? positional.sublist(1) : <String>[];
    return result;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ───────────────────────────────────────────────────────────────────────────

  static String _fmtSov(int seeds) {
    final sov = seeds / _kSeedsPerSov;
    return sov == sov.truncateToDouble() ? sov.toStringAsFixed(0) : sov.toStringAsFixed(6);
  }

  static String _msgPreview(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final env = jsonDecode(raw) as Map<String, dynamic>;
      return (env['text'] as String? ?? raw).replaceAll('\n', ' ').substring(0, min(60, (env['text'] as String? ?? raw).length));
    } catch (_) {
      return raw.replaceAll('\n', ' ').substring(0, min(60, raw.length));
    }
  }

  static String _makeId() {
    final rng = Random.secure();
    final ts  = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final rnd = List.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$ts-$rnd';
  }

  static void _err(String msg, bool json) {
    if (json) {
      print(jsonEncode({'ok': false, 'error': msg}));
    } else {
      stderr.writeln('error: $msg');
    }
  }

  static void _printHelp() {
    print('''
SOV Wallet CLI — runs inside SovNode.exe, shares your restored wallet.

USAGE
  SovNode.exe --cli <command> [options]

COMMANDS
  restore --seed-file <path>          Restore a wallet from a 12-word phrase (headless).
                                        Or pipe it:  echo "<12 words>" | … restore --pin <n>
                                        Needs --pin to encrypt the key at rest.
  status                              Wallet identity, relay, and balance
  balance                             Print balance in SOV (plain — for scripts)
  send --to <sov-id> --amount <n>  Send SOV  [--memo <text>]
  history      [--limit <n>]          Recent transactions (local cache, default 20)
  contacts                            Local contact list
  msg --to <id> "<text>"              Send an end-to-end encrypted message
  msg --list   [--with <id>]          Fetch new messages, then list conversations or messages
                                        [--limit <n>] [--wait <s>, default 8] [--offline: no fetch]
  msg --listen [--seconds <n>]        Stay online and print messages as they arrive
  node status|on|off                  This PC's full node: check it, start it, stop it
                                        (off is Windows only)
  exchange orders|mine                Open orders / your own orders and fills
  exchange create --amount <n> --memo "<terms>"   List SOV (held in escrow)
  exchange chat|chat-send|threads     Private trade chat  [--order <id> --to <id>]
  exchange fill|confirm|cancel --order <id>   Fill an order / confirm payment / cancel
  automation status                   Show the spending limits the NETWORK enforces
  automation set --per-tx <n> --daily <n> [--allow id1,id2]
                                        Tightening applies at once; loosening waits
                                        48 h and can be cancelled meanwhile
  automation allow|deny <id>          Add/remove a permitted recipient (turns limits on)
  automation off|cancel               Remove limits (delayed) / cancel a pending loosening
  spendlock status|enable|disable     Encrypt the signing key with your PIN (Argon2id)
  hwlock status|enable|disable        Seal the signing key in this PC's TPM [--hello]

GLOBAL FLAGS
  --pin <code>      Supply PIN non-interactively (required if wallet PIN is on)
  --node <wss://…>  Override relay URL for this call
  --json            Machine-readable JSON output (for scripting)

EXAMPLES
  SovNode.exe --cli status --pin 1234
  SovNode.exe --cli balance --pin 1234
  SovNode.exe --cli send --to SOV-EC23457EB9695138 --amount 10 --pin 1234
  SovNode.exe --cli send --to SOV-EC23457EB9695138 --amount 5 --memo "coffee" --pin 1234
  SovNode.exe --cli history --limit 5 --pin 1234
  SovNode.exe --cli msg --to SOV-EC23457EB9695138 "Hello from the CLI" --pin 1234
  SovNode.exe --cli msg --list --pin 1234
  SovNode.exe --cli msg --listen --pin 1234
  SovNode.exe --cli msg --list --with SOV-EC23457EB9695138 --limit 10 --pin 1234
  SovNode.exe --cli contacts --json --pin 1234
  SovNode.exe --cli node

EXCHANGE (P2P SOV⇄fiat marketplace)
  SovNode.exe --cli exchange orders                          Open order book
  SovNode.exe --cli exchange mine                            My listings (any status)
  SovNode.exe --cli exchange create --amount 5 --memo "OTC" --payment "Bank transfer"
  SovNode.exe --cli exchange chat --order ORD-… [--buyer SOV-…]
  SovNode.exe --cli exchange chat-send --order ORD-… --to SOV-… "message"
  SovNode.exe --cli exchange threads --order ORD-…           Seller inbox
  SovNode.exe --cli exchange fill --order ORD-… [--agreed 120]
  SovNode.exe --cli exchange confirm --order ORD-…           Seller: fiat received
  SovNode.exe --cli exchange cancel --order ORD-…

SCRIPTING (PowerShell)
  \$bal = (SovNode.exe --cli balance --pin 1234).Trim()
  Write-Host "Balance: \$bal SOV"
''');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lightweight WebSocket client — does NOT use relay_connector streams.
// Uses dart:io WebSocket directly so no Flutter UI binding is required beyond
// WidgetsFlutterBinding.ensureInitialized().
// ─────────────────────────────────────────────────────────────────────────────

class _CliWS {
  WebSocket? _ws;
  StreamSubscription? _sub;
  final List<Map<String, dynamic>> _inbox = [];
  String connectedNodeId = '';
  String _mySovId = '';
  bool _closed = false;
  bool get isOpen => _ws != null && !_closed;

  /// Messages kept by [keepIncoming] over this connection's life.
  int keptIncoming = 0;

  /// Called for each SOV Speak message kept: (from, text-or-null, sentAt).
  void Function(String from, String? text, int sentAt)? onKept;

  // The node flushes a citizen's queue straight after HELLO_ACK and deletes it as
  // it sends — there is no ACK. A direct message is normally held by the SENDER's
  // device, not the node, but one forwarded from another node that lands after the
  // recipient left IS queued there (message_engine _handleMsgForward). Any command
  // this CLI runs may therefore carry the only copy of such a message. Before
  // 1.2.17 the CLI closed without reading it and it was lost; now close() keeps it
  // first (E2E run 2026-10-03, finding 1). Group messages are not kept: the CLI has
  // no group support.
  static const _incomingTypes = {'MESSAGE_INCOMING', 'MI'};
  static const _tradeTypes    = {'EXCHANGE_CHAT_INCOMING', 'XI'};
  static const _groupTypes    = {'GROUP_MESSAGE_INCOMING', 'GM'};

  Future<void> connect(String url, SharedPreferences prefs) async {
    final orig = HttpOverrides.current;
    HttpOverrides.global = _TrustAll();
    try {
      _ws = await WebSocket.connect(url).timeout(const Duration(seconds: 10));
    } finally {
      HttpOverrides.global = orig;
    }

    // Buffer all incoming frames into _inbox
    _sub = _ws!.listen(
      (raw) {
        if (raw is String) {
          try {
            _inbox.add(jsonDecode(raw) as Map<String, dynamic>);
          } catch (_) {}
        }
      },
      onDone:  () { _closed = true; },
      onError: (_) {},
      cancelOnError: false,
    );

    // Wait for RELAY_HELLO (node greeting)
    await _waitFor(['RELAY_HELLO', 'RH'], timeoutSecs: 8);

    // Send signed HELLO
    await _sendHello(prefs);

    // Capture node_id from the first HELLO_ACK
    final ack = await _waitFor(['HELLO_ACK', 'HA'], timeoutSecs: 8);
    connectedNodeId = ack?['node_id'] as String? ?? '';
  }

  Future<void> _sendHello(SharedPreferences prefs) async {
    String sovId  = prefs.getString('sovereign_id') ?? '';
    String pubKey = prefs.getString('public_key_hex') ??
                    prefs.getString('ed25519_public_key_hex') ?? '';
    // Fall back to the KeyManager (Windows Credential Manager) when prefs is
    // empty — same as RelayConnector._sendHello. Without a public key the HELLO
    // ships UNSIGNED → relay flags the session legacyMode → signed ops like
    // MESSAGE_SEND are rejected with SIGNATURE_REQUIRED.
    if (sovId.isEmpty)  sovId  = (await KeyManager.getSovereignId()) ?? '';
    if (pubKey.isEmpty) pubKey = (await KeyManager.getPublicKey()) ?? '';
    _mySovId = sovId;
    final msgKey = await _messagingPublicKey();
    final ts = DateTime.now().millisecondsSinceEpoch;

    String? sig;
    if (pubKey.isNotEmpty) {
      // Retry once on a cold Credential-Manager read (msgsigfix 2026-06-16). Each CLI
      // invocation is a fresh process, so the first secure-storage read can race and
      // throw; an unsigned HELLO then flags the session legacyMode and the node rejects
      // MESSAGE_SEND with SIGNATURE_REQUIRED.
      for (var a = 0; a < 2 && sig == null; a++) {
        try {
          sig = await KeyManager.signChallenge('$sovId:$ts');
        } catch (_) {
          // enrollment flow / cold read — fall back to unsigned only after a retry
          if (a == 0) await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    }

    _send({
      'type':           'HELLO',
      'sovereign_id':   sovId,
      'public_key':     pubKey.isEmpty ? '0' * 64 : pubKey,
      'public_key_hex': pubKey.isEmpty ? '0' * 64 : pubKey,
      if (sig != null) 'signature': sig,
      if (sig != null) 'timestamp': ts,
      // Publish this wallet's messaging key, as the app does, so others can send
      // to it. Without it the app refuses to send ("no encryption key on file").
      if (msgKey.isNotEmpty) 'messaging_public_key': msgKey,
      'version': '1.0.0',
    });
  }

  /// This wallet's X25519 messaging key — the same store the desktop app uses on
  /// this machine, so the CLI and the app share one messaging identity.
  static Future<String> _messagingPublicKey() async {
    try {
      await MessageKeyManager.initialise();
      return await MessageKeyManager.getPublicKeyHex();
    } catch (_) {
      return '';
    }
  }

  /// A citizen's published messaging key, or null if they have none.
  Future<String?> messagingKeyOf(String sovereignId) async {
    if (sovereignId.isEmpty) return null;
    final cached = MessageEncryptor.getCachedKey(sovereignId);
    if (cached != null) return cached;
    // The gateway routes this query ONLY by its op code ('PK'): 'PUBLIC_KEY_QUERY'
    // is not in its legacy name map, so a name-only frame is silently dropped and
    // every lookup times out as "no key". Encode it as the app does.
    final req = <String, dynamic>{
        'type': 'PUBLIC_KEY_QUERY', 'target_id': sovereignId, 'target_sovereign_id': sovereignId};
    RelayConnector.addOpCode(req);
    final resp = await sendAndWait(
      req,
      ['PUBLIC_KEY_RESULT', 'KR'],
      timeoutSecs: 8,
    );
    final key = resp?['x25519_public_key_hex'] as String? ?? '';
    if (key.isEmpty) return null;
    MessageEncryptor.cacheKey(sovereignId, key);
    return key;
  }

  /// Decrypt a v2 envelope from [fromId]; null if it cannot be decrypted yet.
  Future<String?> decryptFrom(String fromId, String envelope) async {
    final senderKey = await messagingKeyOf(fromId);
    final myPriv    = await MessageKeyManager.getPrivateKeyBytes();
    if (senderKey == null || myPriv == null) return null;
    return MessageEncryptor.decryptEnvelope(
      envelope: envelope, senderPubKeyHex: senderKey, myPrivKeyBytes: myPriv);
  }

  /// Store every message the node has pushed on this connection, exactly as the
  /// app's main shell does: SOV Speak into its conversation (decrypted when the
  /// sender's key is available), exchange trade chat under `xchg_<order>`, blocked
  /// senders dropped. Returns how many were kept.
  Future<int> keepIncoming() async {
    var n = 0;
    for (var i = 0; i < _inbox.length;) {
      final m = _inbox[i];
      final t = m['type'] as String? ?? m['op'] as String? ?? '';
      final kind = _incomingTypes.contains(t) ? 0 : _tradeTypes.contains(t) ? 1 : _groupTypes.contains(t) ? 2 : -1;
      if (kind < 0) { i++; continue; }
      _inbox.removeAt(i);
      try {
        if (await (kind == 0 ? _storeIncoming(m) : kind == 1 ? _storeTrade(m) : _storeGroup(m))) n++;
      } catch (_) {}
    }
    keptIncoming += n;
    return n;
  }

  Future<bool> _storeIncoming(Map<String, dynamic> msg) async {
    final payload     = msg['encrypted_payload'] as String? ?? '';
    final messageId   = msg['message_id']        as String? ?? '';
    final contentType = msg['message_type']      as String? ?? 'text';
    final sentAt      = (msg['sent_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final encrypted   = MessageEncryptor.isEncryptedEnvelope(payload);

    var fromId = msg['from_sovereign_id'] as String? ?? '';
    String? text;
    var orderId = msg['exchange_order_id'] as String? ?? '';
    if (encrypted) {
      text = await decryptFrom(fromId, payload);
    } else {
      try {
        final env = jsonDecode(payload) as Map<String, dynamic>;
        if (fromId.isEmpty) fromId = env['from'] as String? ?? '';
        text = env['text'] as String?;
        if (orderId.isEmpty) orderId = env['exchange_order_id'] as String? ?? '';
      } catch (_) {
        text = payload;
      }
    }
    if (fromId.isEmpty || messageId.isEmpty || _mySovId.isEmpty) return false;
    if (await ContactsDb.isContactBlocked(fromId)) return false;

    final now = DateTime.now().millisecondsSinceEpoch;
    final convId = orderId.isNotEmpty
        ? 'xchg_$orderId'
        : ConversationUtils.conversationId(fromId, _mySovId);
    await ContactsDb.saveMessage(LocalMessage(
      id:               messageId,
      conversationId:   convId,
      fromSovereignId:  fromId,
      toSovereignId:    _mySovId,
      contentType:      contentType,
      encryptedContent: payload,
      decryptedContent: contentType == 'text' ? text : null,
      status:           'delivered',
      sentAt:           sentAt,
      deliveredAt:      now,
    ));
    if (orderId.isNotEmpty) return true; // trade chat is not a SOV Speak conversation
    onKept?.call(fromId, contentType == 'text' ? text : '[$contentType]', sentAt);
    try { await ContactsDb.ensureContact(fromId); } catch (_) {}
    await ContactsDb.upsertConversation(
      id:            convId,
      participantId: fromId,
      preview:       text ?? (encrypted ? '[Encrypted message]' : '[$contentType]'),
      lastMessageAt: sentAt,
    );
    await ContactsDb.incrementUnread(convId);
    return true;
  }

  // Trade chat / group messages: kept exactly as the app's SecureChannels keeps them
  // (same conversation ids), decrypted over THIS connection. Plain text is never kept.
  Future<bool> _storeTrade(Map<String, dynamic> m) async {
    final orderId = m['order_id'] as String? ?? '', from = m['from_id'] as String? ?? '';
    final id = m['msg_id'] as String? ?? '', env = m['content'] as String? ?? '';
    if (orderId.isEmpty || from.isEmpty || id.isEmpty || !MessageEncryptor.isEncryptedEnvelope(env)) return false;
    if (await ContactsDb.isContactBlocked(from)) return false;
    final buyer = (m['buyer_id'] as String?)?.isNotEmpty == true ? m['buyer_id'] as String : from;
    await ContactsDb.saveChannelMessage(LocalMessage(
      id: id, conversationId: SecureChannels.tradeConv(orderId, buyer), fromSovereignId: from,
      toSovereignId: _mySovId, contentType: 'text', encryptedContent: env,
      decryptedContent: await decryptFrom(from, env), status: 'delivered',
      sentAt: (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      deliveredAt: DateTime.now().millisecondsSinceEpoch));
    return true;
  }

  Future<bool> _storeGroup(Map<String, dynamic> m) async {
    final groupId = m['group_id'] as String? ?? '', from = m['sender_id'] as String? ?? '';
    final id = m['msg_id'] as String? ?? '', env = m['content'] as String? ?? '';
    if (groupId.isEmpty || from.isEmpty || id.isEmpty || !MessageEncryptor.isEncryptedEnvelope(env)) return false;
    if (await ContactsDb.isContactBlocked(from)) return false;
    await ContactsDb.saveChannelMessage(LocalMessage(
      id: id, conversationId: SecureChannels.groupConv(groupId), fromSovereignId: from,
      toSovereignId: _mySovId, contentType: (m['media_type'] as String?) ?? 'text', encryptedContent: env,
      decryptedContent: await decryptFrom(from, env), status: 'delivered',
      sentAt: (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      deliveredAt: DateTime.now().millisecondsSinceEpoch));
    return true;
  }

  void _send(Map<String, dynamic> msg) {
    _ws?.add(jsonEncode(msg));
  }

  /// Send [request] and wait for a frame whose 'type' or 'op' is in [responseTypes].
  Future<Map<String, dynamic>?> sendAndWait(
    Map<String, dynamic> request,
    List<String> responseTypes, {
    int timeoutSecs = 10,
  }) async {
    _send(request);
    return _waitFor(responseTypes, timeoutSecs: timeoutSecs);
  }

  Future<Map<String, dynamic>?> _waitFor(
    List<String> types, {
    int timeoutSecs = 10,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSecs));
    while (DateTime.now().isBefore(deadline)) {
      for (int i = 0; i < _inbox.length; i++) {
        final msg = _inbox[i];
        final t   = msg['type'] as String? ?? msg['op'] as String? ?? '';
        if (types.contains(t)) {
          _inbox.removeAt(i);
          return msg;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  Future<void> close() async {
    // Keep anything the node pushed before the socket goes (see _incomingTypes).
    if (_ws != null) {
      try { await keepIncoming(); } catch (_) {}
    }
    await _sub?.cancel();
    await _ws?.close();
    _ws  = null;
    _sub = null;
  }
}

/// Bypasses TLS certificate checks so the CLI can connect to nodes with
/// self-signed certificates (same as the GUI's behaviour).
class _TrustAll extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}
