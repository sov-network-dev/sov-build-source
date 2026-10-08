// media_transfer.dart — SOV Speak media (photos, voice notes, video, files), end to end, in chunks.
//
// WHY (audit D34, 2026-10-08): the old media path sent the file as PLAIN JSON
// ({from, contentType, data: base64}) in one MESSAGE_SEND. Since node 1.4.81 a node refuses anything
// that is not a v2 ciphertext envelope (PLAINTEXT_REFUSED), and it caps one message at 256 KB, while
// the app still assumed the retired relay's 10 MB cap. Every photo, voice note and file failed.
//
// NOW: the file is cut into chunks of CHUNK_BYTES; each chunk is its own v2 envelope (X25519 + AES-GCM,
// exactly as text) carrying {"mc":2, mid, i, n, ct, mime, size, d}. Each goes as an ordinary
// MESSAGE_SEND with message_id "<mid>_<i>" and message_type = the content type. Nodes see only
// ciphertext and keep nothing; the receiving app decrypts each chunk and assembles the file. If the
// recipient is offline the SENDER keeps the file and resends when they come online (nodes never
// queue messages — king's rule).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contacts_db.dart';
import 'conversation_utils.dart';
import 'media_handler.dart';
import 'message_encryptor.dart';
import 'message_events.dart';
import 'message_key_manager.dart';
import 'outbox_manager.dart';
import 'relay_connector.dart';
import 'sov_db_path.dart';
import 'speak_payload.dart';

enum MediaSendOutcome { delivered, relayed, offline, noKey, tooLarge, failed }

class MediaTransfer {
  /// Raw bytes per chunk. base64 (x4/3) + JSON + hex ciphertext (x2) keeps one envelope
  /// near 220 KB, under the node's 256 KB per-message limit (message_engine.js).
  static const int chunkBytes = 80 * 1024;
  /// Largest file the network will carry this way (200 chunks).
  static const int maxBytes = 16 * 1024 * 1024;
  /// Photos larger than this are re-encoded (JPEG, longest side 1600 px) before sending.
  static const int _imageShrinkAbove = 1536 * 1024;
  static const _pendingKey = 'sov_media_pending_v1';

  static final _assembledCtrl = StreamController<LocalMessage>.broadcast();
  /// A received media message, fully assembled and saved (open threads append it).
  static Stream<LocalMessage> get assembled => _assembledCtrl.stream;

  static final Map<String, Map<int, String>> _parts = {};
  static final Map<String, int> _partsStarted = {};
  static final Map<String, Map<String, Object>> _meta = {};
  static final Set<String> _done = {};
  static StreamSubscription<String>? _onlineSub;

  static bool isMediaType(String t) => t.isNotEmpty && t != 'text';

  /// A file name that is safe to write and to show: letters, digits, space, dot, dash, underscore.
  static String safeName(String raw) {
    var n = raw.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_').trim();
    if (n.startsWith('.')) n = '_$n';
    return n.isEmpty ? 'file' : (n.length > 80 ? n.substring(n.length - 80) : n);
  }

  /// Start resending pending media when a recipient comes online. Idempotent.
  static void init() {
    _onlineSub ??= OutboxManager.citizenOnlineStream.listen(_resendPendingFor);
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  static Future<Uint8List> _prepareBytes(File file, String contentType) async {
    final bytes = await file.readAsBytes();
    if (contentType != 'image' || bytes.length <= _imageShrinkAbove) return bytes;
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
      final scaled = longest > 1600
          ? img.copyResize(decoded,
              width: decoded.width >= decoded.height ? 1600 : null,
              height: decoded.height > decoded.width ? 1600 : null)
          : decoded;
      final jpg = Uint8List.fromList(img.encodeJpg(scaled, quality: 82));
      return jpg.length < bytes.length ? jpg : bytes;
    } catch (_) {
      return bytes;
    }
  }

  /// Send [file] to [toId] as message [messageId]. Never sends anything unencrypted.
  static Future<MediaSendOutcome> send({
    required String toId,
    required String messageId,
    required File file,
    required String contentType,
    required String mimeType,
    String caption = '',
    int ttl = 0,
  }) async {
    final bytes = await _prepareBytes(file, contentType);
    if (bytes.length > maxBytes) return MediaSendOutcome.tooLarge;
    final key = await RelayConnector.lookupMessagingKey(toId);
    final priv = await MessageKeyManager.getPrivateKeyBytes();
    if (key == null || priv == null) return MediaSendOutcome.noKey;
    final n = (bytes.length / chunkBytes).ceil().clamp(1, 1 << 30);
    var allDelivered = true;
    for (var i = 0; i < n; i++) {
      final part = bytes.sublist(i * chunkBytes, ((i + 1) * chunkBytes).clamp(0, bytes.length));
      final plain = jsonEncode({
        'mc': 2, 'mid': messageId, 'i': i, 'n': n, 'ct': contentType, 'mime': mimeType,
        'size': bytes.length, 'name': safeName(file.path.split(RegExp(r'[\\/]')).last),
        // 1.2.28: caption and disappearing timer ride inside the encrypted chunk.
        if (caption.isNotEmpty) 'cap': caption,
        if (ttl > 0) 'ttl': ttl,
        'd': base64Encode(part),
      });
      final env = await MessageEncryptor.encrypt(
          plaintext: plain, recipientPubKeyHex: key, myPrivKeyBytes: priv);
      if (env == null) return MediaSendOutcome.failed;
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final chunkId = '${messageId}_$i';
      final r = await RelayConnector.sendAndWait(
        request: {
          'type': 'MESSAGE_SEND', 'to_sovereign_id': toId, 'encrypted_payload': env,
          'message_type': contentType, 'message_id': chunkId,
        },
        responseType: 'MESSAGE_SEND_RESULT',
        timeout: const Duration(seconds: 20),
        matchField: 'message_id',
        matchValue: chunkId,
      );
      if (r == null) return MediaSendOutcome.failed;
      if (r['success'] != true) {
        final err = (r['error'] ?? '').toString();
        if (err == 'RECIPIENT_OFFLINE' || err.contains('OFFLINE')) return MediaSendOutcome.offline;
        debugPrint('[MEDIA] chunk $i/$n refused: $err');
        return MediaSendOutcome.failed;
      }
      if (r['status'] != 'delivered') allDelivered = false;
    }
    return allDelivered ? MediaSendOutcome.delivered : MediaSendOutcome.relayed;
  }

  /// Keep [file] on THIS device and resend it when [toId] comes online.
  static Future<void> keepPending({
    required String toId, required String messageId, required String path,
    required String contentType, required String mimeType,
    String caption = '', int ttl = 0,
  }) async {
    final p = await SharedPreferences.getInstance();
    final list = (p.getStringList(_pendingKey) ?? [])
      ..removeWhere((s) => (jsonDecode(s) as Map)['mid'] == messageId)
      ..add(jsonEncode({'to': toId, 'mid': messageId, 'path': path, 'ct': contentType, 'mime': mimeType,
          'cap': caption, 'ttl': ttl}));
    await p.setStringList(_pendingKey, list);
    await OutboxManager.watch(toId);
  }

  static Future<void> _resendPendingFor(String toId) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_pendingKey) ?? [];
    final keep = <String>[];
    for (final s in list) {
      final e = jsonDecode(s) as Map<String, dynamic>;
      if (e['to'] != toId) { keep.add(s); continue; }
      final f = File(e['path'] as String);
      if (!await f.exists()) continue;
      final out = await send(toId: toId, messageId: e['mid'] as String, file: f,
          contentType: e['ct'] as String, mimeType: e['mime'] as String,
          caption: e['cap'] as String? ?? '', ttl: (e['ttl'] as num?)?.toInt() ?? 0);
      if (out == MediaSendOutcome.delivered || out == MediaSendOutcome.relayed) {
        await ContactsDb.updateMessageStatus(e['mid'] as String,
            out == MediaSendOutcome.delivered ? 'delivered' : 'relayed',
            deliveredAt: DateTime.now().millisecondsSinceEpoch);
        MessageEvents.notifyConversationChanged();
      } else {
        keep.add(s);
      }
    }
    await p.setStringList(_pendingKey, keep);
  }

  // ── Receiving ──────────────────────────────────────────────────────────────

  /// Handle one incoming media MESSAGE_INCOMING. Returns the assembled, SAVED message when this
  /// chunk completes the file; null while chunks are still missing (or if it cannot be read).
  static Future<LocalMessage?> acceptChunk(Map<String, dynamic> msg, String mySovId) async {
    final fromId = msg['from_sovereign_id'] as String? ?? '';
    final payload = msg['encrypted_payload'] as String? ?? '';
    if (fromId.isEmpty || !MessageEncryptor.isEncryptedEnvelope(payload)) return null;
    String? plain;
    for (var attempt = 0; attempt < 3 && plain == null; attempt++) {
      if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 2));
      final key = await RelayConnector.lookupMessagingKey(fromId);
      final priv = await MessageKeyManager.getPrivateKeyBytes();
      if (key == null || priv == null) continue;
      plain = await MessageEncryptor.decryptEnvelope(
          envelope: payload, senderPubKeyHex: key, myPrivKeyBytes: priv);
    }
    if (plain == null) return null;
    Map<String, dynamic> c;
    try { c = jsonDecode(plain) as Map<String, dynamic>; } catch (_) { return null; }
    if (c['mc'] != 2) return null;
    final mid = c['mid'] as String? ?? '';
    final i = (c['i'] as num?)?.toInt() ?? -1;
    final n = (c['n'] as num?)?.toInt() ?? 0;
    if (mid.isEmpty || i < 0 || n <= 0 || n > maxBytes ~/ chunkBytes + 1 || i >= n) return null;
    final slot = '$fromId:$mid';
    if (_done.contains(slot)) return null;
    _evictStale();
    _partsStarted.putIfAbsent(slot, () => DateTime.now().millisecondsSinceEpoch);
    (_parts[slot] ??= {})[i] = c['d'] as String? ?? '';
    if (c['cap'] is String || c['ttl'] is num) {
      _meta[slot] = {'cap': c['cap'] is String ? c['cap'] as String : '', 'ttl': (c['ttl'] as num?)?.toInt() ?? 0};
    }
    if (_parts[slot]!.length < n) return null;
    _done.add(slot);
    final parts = _parts.remove(slot)!; _partsStarted.remove(slot);
    final meta = _meta.remove(slot) ?? const {'cap': '', 'ttl': 0};
    final ttl = ((meta['ttl'] as int?) ?? 0).clamp(0, DisappearingTimer.maxSeconds);
    var caption = (meta['cap'] as String?) ?? '';
    if (caption.length > 2000) caption = caption.substring(0, 2000);
    final b = BytesBuilder(copy: false);
    for (var k = 0; k < n; k++) {
      final d = parts[k];
      if (d == null) return null;
      b.add(base64Decode(d));
    }
    final ct = c['ct'] as String? ?? 'file';
    final mime = c['mime'] as String? ?? '';
    final name = c['name'] is String && (c['name'] as String).isNotEmpty
        ? safeName(c['name'] as String)
        : '$mid${MediaHandler.extensionForMime(mime)}';
    final dir = Directory('${(await sovMediaDir()).path}/$mid');   // D51: private app folder on desktop   // one folder per message: names never collide
    await dir.create(recursive: true);
    final saved = File('${dir.path}/$name');
    await saved.writeAsBytes(b.takeBytes(), flush: true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final m = LocalMessage(
      id: mid, conversationId: ConversationUtils.conversationId(fromId, mySovId),
      fromSovereignId: fromId, toSovereignId: mySovId, contentType: ct,
      encryptedContent: '', decryptedContent: saved.path,
      status: 'delivered', sentAt: (msg['sent_at'] as num?)?.toInt() ?? now, deliveredAt: now,
      caption: caption, expiresAt: ttl > 0 ? now + ttl * 1000 : null,
    );
    await ContactsDb.saveMessage(m);
    _assembledCtrl.add(m);
    return m;
  }

  static void _evictStale() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 15 * 60 * 1000;
    for (final k in _partsStarted.keys.where((k) => _partsStarted[k]! < cutoff).toList()) {
      _parts.remove(k); _partsStarted.remove(k); _meta.remove(k);
    }
  }
}
