import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'key_manager.dart';
import 'wallet_engine.dart';

/// Wi-Fi Aware (NAN - Neighbour Awareness Networking)
/// Allows SOV nodes to discover and transact with
/// each other directly without any router or internet.
/// Requires Android API 26+ (Android 8.0 Oreo and above).

enum MeshStatus {
  unavailable,   // Device does not support Wi-Fi Aware
  idle,          // Supported but not scanning
  discovering,   // Actively scanning for nearby nodes
  connected,     // Connected to at least one peer
}

class WifiAwarePeer {
  final String sovereignId;
  final String publicKey;
  final double balance;
  final DateTime discoveredAt;
  final int signalStrength;

  WifiAwarePeer({
    required this.sovereignId,
    required this.publicKey,
    required this.balance,
    required this.discoveredAt,
    required this.signalStrength,
  });

  factory WifiAwarePeer.fromJson(Map<String, dynamic> json) {
    return WifiAwarePeer(
      sovereignId: json['sovereign_id'] as String,
      publicKey: json['public_key'] as String,
      balance: (json['balance'] as num).toDouble(),
      discoveredAt: DateTime.now(),
      signalStrength: (json['signal_strength'] as num?)?.toInt() ?? -70,
    );
  }

  Map<String, dynamic> toJson() => {
    'sovereign_id': sovereignId,
    'public_key': publicKey,
    'balance': balance,
    'signal_strength': signalStrength,
  };
}

class WifiAwareMesh {
  static const _channel = MethodChannel('network.sov.node/wifi_aware');
  static const _eventChannel = EventChannel('network.sov.node/wifi_aware_events');

  // Wi-Fi Aware (NAN) is Android-only proximity mesh. Desktop has no such
  // radio API — short-circuit so the unregistered channel never throws.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static MeshStatus _status = MeshStatus.idle;
  static final Map<String, WifiAwarePeer> _peers = {};
  static StreamController<List<WifiAwarePeer>>? _peerController;
  static StreamController<Map<String, dynamic>>? _messageController;
  static StreamSubscription? _eventSubscription;
  static Timer? _discoveryTimer;

  // ── Public getters ────────────────────────────────────────
  static MeshStatus get status => _status;
  static List<WifiAwarePeer> get nearbyPeers => _peers.values.toList();
  static Stream<List<WifiAwarePeer>>? get peerStream =>
      _peerController?.stream;
  static Stream<Map<String, dynamic>>? get messageStream =>
      _messageController?.stream;

  // ── Initialise ────────────────────────────────────────────
  static Future<void> initialise() async {
    _peerController ??=
    StreamController<List<WifiAwarePeer>>.broadcast();
    _messageController ??=
    StreamController<Map<String, dynamic>>.broadcast();

    final supported = await _isSupported();
    if (!supported) {
      _status = MeshStatus.unavailable;
      return;
    }
    _status = MeshStatus.idle;
  }

  // ── Check device support ──────────────────────────────────
  static Future<bool> _isSupported() async {
    if (_isDesktop) return false;
    try {
      final result =
      await _channel.invokeMethod<bool>('isWifiAwareSupported');
      return result ?? false;
    } on PlatformException {
      // Wi-Fi Aware not available — graceful fallback
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ── Start peer discovery ──────────────────────────────────
  static Future<void> startDiscovery() async {
    if (_status == MeshStatus.unavailable) return;

    final sovereignId = await KeyManager.getSovereignId();
    final publicKey = await KeyManager.getPublicKey();
    final balance = await WalletEngine.getBalance();

    // Build our node advertisement payload
    final advertisement = jsonEncode({
      'sovereign_id': sovereignId,
      'public_key': publicKey,
      'balance': balance,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    try {
      await _channel.invokeMethod('startDiscovery', {
        'service_name': 'sov_mesh',
        'advertisement': advertisement,
      });
      _status = MeshStatus.discovering;
      _listenForEvents();
      _startPeriodicRefresh();
    } on PlatformException {
      // Device supports Wi-Fi Aware but session failed
      // Fall through to Bluetooth mesh
      _status = MeshStatus.unavailable;
    }
  }

  // ── Stop discovery ────────────────────────────────────────
  static Future<void> stopDiscovery() async {
    _discoveryTimer?.cancel();
    _eventSubscription?.cancel();
    try {
      await _channel.invokeMethod('stopDiscovery');
    } on PlatformException {
      // Already stopped
    }
    _status = MeshStatus.idle;
    _peers.clear();
    _peerController?.add([]);
  }

  // ── Listen for peer events from native layer ──────────────
  static void _listenForEvents() {
    _eventSubscription?.cancel();
    _eventSubscription =
        _eventChannel.receiveBroadcastStream().listen((event) {
          try {
            final data = jsonDecode(event as String) as Map<String, dynamic>;
            final eventType = data['event'] as String;

            switch (eventType) {
              case 'PEER_DISCOVERED':
                _onPeerDiscovered(data);
                break;
              case 'PEER_LOST':
                _onPeerLost(data);
                break;
              case 'MESSAGE_RECEIVED':
                _onMessageReceived(data);
                break;
            }
          } catch (_) {}
        });
  }

  // ── Peer discovered ───────────────────────────────────────
  static void _onPeerDiscovered(Map<String, dynamic> data) {
    try {
      final peer = WifiAwarePeer.fromJson(
          data['peer'] as Map<String, dynamic>);
      _peers[peer.sovereignId] = peer;
      _status = MeshStatus.connected;
      _peerController?.add(nearbyPeers);
    } catch (_) {}
  }

  // ── Peer lost ─────────────────────────────────────────────
  static void _onPeerLost(Map<String, dynamic> data) {
    final sovereignId = data['sovereign_id'] as String?;
    if (sovereignId != null) {
      _peers.remove(sovereignId);
      if (_peers.isEmpty) _status = MeshStatus.discovering;
      _peerController?.add(nearbyPeers);
    }
  }

  // ── Message received from peer ────────────────────────────
  static void _onMessageReceived(Map<String, dynamic> data) {
    _messageController?.add(data);
  }

  // ── Send message to specific peer ────────────────────────
  static Future<bool> sendToPeer({
    required String sovereignId,
    required Map<String, dynamic> message,
  }) async {
    if (!_peers.containsKey(sovereignId)) return false;
    try {
      await _channel.invokeMethod('sendMessage', {
        'peer_id': sovereignId,
        'message': jsonEncode(message),
      });
      return true;
    } on PlatformException {
      return false;
    }
  }

  // ── Send SOV directly to nearby peer ─────────────────────
  static Future<bool> sendSOVToPeer({
    required String sovereignId,
    required double amount,
  }) async {
    try {
      final txHash = await WalletEngine.sendSOV(
        toId: sovereignId,
        amount: amount,
      );
      return await sendToPeer(
        sovereignId: sovereignId,
        message: {
          'type': 'SOV_TRANSFER',
          'tx_hash': txHash,
          'amount': amount,
          'from': await KeyManager.getSovereignId(),
        },
      );
    } catch (_) {
      return false;
    }
  }

  // ── Broadcast to all nearby peers ────────────────────────
  static Future<void> broadcast(Map<String, dynamic> message) async {
    for (final peer in _peers.values) {
      await sendToPeer(
        sovereignId: peer.sovereignId,
        message: message,
      );
    }
  }

  // ── Periodic peer list refresh ────────────────────────────
  static void _startPeriodicRefresh() {
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(
      const Duration(seconds: 30),
          (_) async {
        // Remove peers not seen in last 2 minutes
        final cutoff = DateTime.now().subtract(
          const Duration(minutes: 2),
        );
        _peers.removeWhere(
              (_, peer) => peer.discoveredAt.isBefore(cutoff),
        );
        _peerController?.add(nearbyPeers);
      },
    );
  }

  // ── Status label ──────────────────────────────────────────
  static String getStatusLabel() {
    switch (_status) {
      case MeshStatus.unavailable:
        return 'Mesh Unavailable';
      case MeshStatus.idle:
        return 'Mesh Idle';
      case MeshStatus.discovering:
        return 'Scanning for Nearby Citizens';
      case MeshStatus.connected:
        return '${_peers.length} Citizen(s) Nearby';
    }
  }
}