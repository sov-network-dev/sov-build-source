// lib/sov_node_sdk/sov_voice_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Optional spoken notifications. When enabled (Settings → Voice notifications,
// OFF by default), the app speaks short brand-voice lines on key events —
// "You have a new message in your inbox", "Your exchange order has been filled",
// etc. Clips are pre-rendered MP3s in assets/voice/ (en-GB-RyanNeural brand voice)
// so there's no runtime TTS / network / cost. Plays even while the PIN-lock
// overlay is up, because the relay event streams fire underneath it.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SovVoice {
  message,
  exchangeOrder,
  exchangeFilled,
  transferReceived,
  paymentRequest,
  operatorPayout,
  governanceVote,
  groupMessage,
  enclave,
  contactOnline,
  nodeServing,
}

class SovVoiceService {
  SovVoiceService._();

  static const prefKey = 'voice_notifications_enabled';
  static bool _enabled = false;
  static final AudioPlayer _player = AudioPlayer();

  /// Opt-in: off until the citizen/operator turns it on in Settings.
  static bool get enabled => _enabled;

  static const Map<SovVoice, String> _clip = {
    SovVoice.message:          'msg_inbox',
    SovVoice.exchangeOrder:    'exchange_order',
    SovVoice.exchangeFilled:   'exchange_filled',
    SovVoice.transferReceived: 'transfer_received',
    SovVoice.paymentRequest:   'payment_request',
    SovVoice.operatorPayout:   'operator_payout',
    SovVoice.governanceVote:   'governance_vote',
    SovVoice.groupMessage:     'group_message',
    SovVoice.enclave:          'enclave',
    SovVoice.contactOnline:    'contact_online',
    SovVoice.nodeServing:      'node_serving',
  };

  /// Load the saved preference (call once at startup).
  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(prefKey) ?? false;
    } catch (_) {/* default off */}
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefKey, value);
    } catch (_) {}
    if (value) play(SovVoice.message); // preview so the user hears the voice
  }

  /// Speak the line for [event] — no-op when disabled.
  static Future<void> play(SovVoice event) async {
    if (!_enabled) return;
    final name = _clip[event];
    if (name == null) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('voice/$name.mp3'));
    } catch (_) {/* audio unavailable — silent fail */}
  }
}
