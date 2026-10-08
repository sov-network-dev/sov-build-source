// SOV Speak message extras — disappearing timer, reply quote, timer-change notices.
//
// Everything here travels INSIDE the end-to-end encrypted plaintext, so a node sees
// nothing new and keeps nothing (nodes never store messages). A plain message with no
// extras is still sent as bare text, exactly as before, so older apps keep reading it.
//
//   bare text                                  -> an ordinary message
//   {"sp":1,"text":..,"ttl":secs,"re":msgId}   -> a message with a timer and/or a reply
//   {"sp":1,"sys":"ttl","ttl":secs}            -> "disappearing messages set to ..." notice
//
// Media carries its caption and timer in its (encrypted) chunk header instead:
// see MediaTransfer ('cap', 'ttl').

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'contacts_db.dart';
import 'message_events.dart';

class SpeakPayload {
  final String text;
  final int ttl;          // seconds; 0 = never disappears
  final String? replyTo;  // id of the message this answers
  final String? sys;      // 'ttl' for a timer-change notice

  const SpeakPayload({required this.text, this.ttl = 0, this.replyTo, this.sys});

  static String encode(String text, {int ttl = 0, String? replyTo}) {
    if (ttl <= 0 && (replyTo == null || replyTo.isEmpty)) return text;
    return jsonEncode({
      'sp': 1, 'text': text,
      if (ttl > 0) 'ttl': ttl,
      if (replyTo != null && replyTo.isNotEmpty) 're': replyTo,
    });
  }

  static String encodeTimerNotice(int ttl) => jsonEncode({'sp': 1, 'sys': 'ttl', 'ttl': ttl});

  /// Read a decrypted plaintext. Anything that is not our JSON is ordinary text.
  static SpeakPayload parse(String plain) {
    final t = plain.trimLeft();
    if (!t.startsWith('{') || !t.contains('"sp"')) return SpeakPayload(text: plain);
    try {
      final m = jsonDecode(t) as Map<String, dynamic>;
      if (m['sp'] != 1) return SpeakPayload(text: plain);
      final ttl = (m['ttl'] as num?)?.toInt() ?? 0;
      final sys = m['sys'] as String?;
      return SpeakPayload(
        text: sys == 'ttl' ? DisappearingTimer.noticeText(ttl) : (m['text'] as String? ?? ''),
        ttl: ttl.clamp(0, DisappearingTimer.maxSeconds),
        replyTo: m['re'] as String?,
        sys: sys,
      );
    } catch (_) {
      return SpeakPayload(text: plain);
    }
  }
}

/// The per-conversation disappearing-messages setting. Kept on this device only.
class DisappearingTimer {
  static const int maxSeconds = 7 * 24 * 3600;

  /// The choices offered in the chat menu: label -> seconds.
  static const Map<String, int> choices = {
    'Off': 0,
    '5 minutes': 300,
    '1 hour': 3600,
    '1 day': 86400,
    '1 week': 604800,
  };

  static String _key(String conversationId) => 'sov_ttl_$conversationId';

  static Future<int> get(String conversationId) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getInt(_key(conversationId)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> set(String conversationId, int seconds) async {
    final p = await SharedPreferences.getInstance();
    if (seconds <= 0) {
      await p.remove(_key(conversationId));
    } else {
      await p.setInt(_key(conversationId), seconds.clamp(1, maxSeconds));
    }
  }

  static String label(int seconds) {
    for (final e in choices.entries) {
      if (e.value == seconds) return e.key;
    }
    if (seconds % 86400 == 0) return '${seconds ~/ 86400} days';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600} hours';
    if (seconds % 60 == 0) return '${seconds ~/ 60} minutes';
    return '$seconds seconds';
  }

  static String noticeText(int seconds) => seconds <= 0
      ? 'Disappearing messages turned off'
      : 'Disappearing messages: new messages vanish ${label(seconds)} after they arrive';

  /// "4m", "2h", "3d" — time left before a message disappears.
  static String shortLeft(int expiresAtMs) {
    final s = ((expiresAtMs - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    if (s <= 0) return '0s';
    if (s < 60) return '${s}s';
    if (s < 3600) return '${(s / 60).ceil()}m';
    if (s < 86400) return '${(s / 3600).ceil()}h';
    return '${(s / 86400).ceil()}d';
  }
}

/// Runs while the app is open: removes messages whose timer has run out, on every
/// platform, and tells open screens which ones went. Started once from MainShell.
class DisappearingSweeper {
  static Timer? _timer;
  static final _gone = StreamController<List<String>>.broadcast();

  /// Ids of messages that just disappeared.
  static Stream<List<String>> get removed => _gone.stream;

  static void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => sweep());
    sweep();
  }

  static Future<void> sweep() async {
    try {
      final ids = await ContactsDb.deleteExpired();
      if (ids.isEmpty) return;
      _gone.add(ids);
      MessageEvents.notifyConversationChanged();
    } catch (_) {}
  }
}
