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
//   SovNode.exe --cli send --to <sovereign-id> --amount <sov> [--memo <text>]
//   SovNode.exe --cli history [--limit <n>]          Recent txs from local DB
//   SovNode.exe --cli contacts                       Local contact list
//   SovNode.exe --cli msg --to <id> "<text>"         Send a message
//   SovNode.exe --cli msg --list [--with <id>] [--limit <n>]   Local messages
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
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/node_discovery.dart';

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
      print('Wallet restored. Sovereign ID: $sovId');
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
    final sigData = await KeyManager.signMessage(msg);
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

  /// send --to <sovereign-id> --amount <sov> [--memo <text>]
  static Future<int> _cmdSend(Map<String, dynamic> opts, bool json) async {
    final to      = opts['to']     as String? ?? '';
    final amtStr  = opts['amount'] as String? ?? '';
    final memo    = opts['memo']   as String? ?? '';

    if (to.isEmpty || amtStr.isEmpty) {
      _err('Usage: --cli send --to <sovereign-id> --amount <sov>', json);
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

      // A Sovereign ID is the only address there is. SOV has no @handles by
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

    final txs = TransactionStore.getAll(prefs);
    final recent = txs.length > limit ? txs.sublist(txs.length - limit) : txs;

    if (json) {
      print(jsonEncode(recent.reversed.toList()));
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

    print('${'Sovereign ID'.padRight(28)} Name');
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

    // v1 JSON envelope — plain text (E2E encryption requires GUI or key exchange)
    final msgId   = _makeId();
    final envelope = jsonEncode({'v': 1, 'from': sovId, 'text': text});

    final payloadBase = <String, dynamic>{
      'type':              'MESSAGE_SEND',
      'from_sovereign_id': sovId,
      'to_sovereign_id':   to,
      'message_id':        msgId,
      'encrypted_payload': envelope,
      'message_type':      'text',
      'conversation_id':   ConversationUtils.conversationId(sovId, to),
    };

    // Up to 2 attempts, each on a FRESH signed handshake (msgsigfix 2026-06-16).
    // A cold-start race can ship an unsigned HELLO → legacyMode → SIGNATURE_REQUIRED,
    // or drop the handshake → no response. Re-handshaking clears both. msgId is fixed
    // so the retry is idempotent on the node (it dedups by message_id).
    String lastErr = 'No relay response — message state unknown.';
    for (var attempt = 0; attempt < 2; attempt++) {
      final conn = _CliWS();
      try {
        await conn.connect(nodeUrl, prefs);
        final payload = Map<String, dynamic>.from(payloadBase);
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

  static Future<int> _cmdMsgList(Map<String, dynamic> opts, bool json) async {
    final withId = opts['with'] as String?;
    final limit  = int.tryParse(opts['limit'] as String? ?? '20') ?? 20;
    final prefs  = await SharedPreferences.getInstance();
    final sovId  = prefs.getString('sovereign_id') ?? '';

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
          'preview': _msgPreview(m.decryptedContent ?? m.encryptedContent),
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
            '${_msgPreview(m.decryptedContent ?? m.encryptedContent)}');
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

        case 'chat': {
          if (orderId.isEmpty) { _err('exchange chat --order <id> [--buyer <sid>]', json); return 1; }
          final buyer = opts['buyer'] as String? ?? '';
          final resp = await conn.sendAndWait({
            'type': 'EXCHANGE_CHAT_LIST',
            'order_id': orderId,
            if (buyer.isNotEmpty) 'buyer_id': buyer,
          }, ['EXCHANGE_CHAT_LIST_RESULT', 'XK'], timeoutSecs: 12);
          final msgs = List<Map<String, dynamic>>.from(resp?['messages'] ?? []);
          if (json) { print(jsonEncode({'ok': true, 'messages': msgs})); return 0; }
          if (msgs.isEmpty) { print('no messages'); return 0; }
          for (final m in msgs) {
            print('[${m['from_id']}] ${m['content']}');
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
          final payload = <String, dynamic>{
            'type':     'EXCHANGE_CHAT_SEND',
            'order_id': orderId,
            'from_id':  sovId,
            'to_id':    to,
            'content':  text,
          };
          await _signInPlace(payload, prefs);
          final resp = await conn.sendAndWait(
              payload, ['EXCHANGE_CHAT_SEND_RESULT', 'XH'], timeoutSecs: 12);
          if (resp?['success'] == true) {
            if (json) { print(jsonEncode({'ok': true})); } else { print('sent'); }
            return 0;
          }
          _err('chat-send failed: ${resp?['error'] ?? 'no response'}', json);
          return 1;
        }

        case 'threads': {
          if (orderId.isEmpty) { _err('exchange threads --order <id>', json); return 1; }
          final resp = await conn.sendAndWait(
              {'type': 'EXCHANGE_CHAT_THREADS', 'order_id': orderId},
              ['EXCHANGE_CHAT_THREADS_RESULT', 'XT'], timeoutSecs: 12);
          final threads = List<Map<String, dynamic>>.from(resp?['threads'] ?? []);
          if (json) { print(jsonEncode({'ok': resp?['success'] == true, 'threads': threads})); return 0; }
          if (threads.isEmpty) { print('no threads'); return 0; }
          for (final t in threads) {
            print('${t['buyer_id']}  unread=${t['unread']}  last="${t['last_content']}"  '
                'rep=${t['reputation_score'] ?? '-'}');
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
  // cannot exceed them. Loosening a limit is delayed (cooldown) + alerted.
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
            'unless you run "automation cancel" from any device.');
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
             'per-tx','daily','allow','id','data','seed','seed-file'].contains(key)) {
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
  send --to <sovereign-id> --amount <n>  Send SOV  [--memo <text>]
  history      [--limit <n>]          Recent transactions (local cache, default 20)
  contacts                            Local contact list
  msg --to <id> "<text>"              Send a message
  msg --list   [--with <id>]          List conversations or messages  [--limit <n>]
  node                                Relay reachability probe

GLOBAL FLAGS
  --pin <code>      Supply PIN non-interactively (required if wallet PIN is on)
  --node <wss://…>  Override relay URL for this call
  --json            Machine-readable JSON output (for scripting)

EXAMPLES
  SovNode.exe --cli status --pin 1234
  SovNode.exe --cli balance --pin 1234
  SovNode.exe --cli send --to SOV-EC23457EB9695138 --amount 10 --pin 1234
  SovNode.exe --cli send --to @alice --amount 5 --memo "coffee" --pin 1234
  SovNode.exe --cli history --limit 5 --pin 1234
  SovNode.exe --cli msg --to SOV-EC23457EB9695138 "Hello from the CLI" --pin 1234
  SovNode.exe --cli msg --list --pin 1234
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
      onDone:  () {},
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
      'version': '1.0.0',
    });
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
