import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'key_manager.dart';
import 'wallet_engine.dart';
import 'relay_connector.dart';
import 'dtn_store.dart';

/// NFC Tap-to-Pay Handler
/// The 3-second sovereign payment flow:
/// Step 1 — Phones tap (NFC exchanges credentials)
/// Step 2 — WiFi Direct channel opens automatically
/// Step 3 — Transaction completes peer-to-peer
/// No internet required. Works completely offline.
/// This is the fastest sovereign payment in existence.

enum NFCStatus {
  unavailable,  // Device has no NFC hardware
  idle,         // NFC ready, not listening
  listening,    // Waiting for a tap
  processing,   // Tap detected, processing payment
  success,      // Payment completed
  failed,       // Payment failed
}

class NFCPaymentRequest {
  final String fromId;
  final String fromPublicKey;
  final double requestedAmount;
  final String? memo;
  final int timestamp;
  final String sessionToken;

  NFCPaymentRequest({
    required this.fromId,
    required this.fromPublicKey,
    required this.requestedAmount,
    this.memo,
    required this.timestamp,
    required this.sessionToken,
  });

  factory NFCPaymentRequest.fromJson(Map<String, dynamic> json) {
    return NFCPaymentRequest(
      fromId: json['from_id'] as String,
      fromPublicKey: json['from_public_key'] as String,
      requestedAmount: (json['requested_amount'] as num).toDouble(),
      memo: json['memo'] as String?,
      timestamp: json['timestamp'] as int,
      sessionToken: json['session_token'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'from_id': fromId,
    'from_public_key': fromPublicKey,
    'requested_amount': requestedAmount,
    'memo': memo,
    'timestamp': timestamp,
    'session_token': sessionToken,
  };
}

class NFCPaymentResult {
  final bool success;
  final String? txHash;
  final String? error;
  final double? amount;
  final String? toId;
  final DateTime completedAt;

  NFCPaymentResult({
    required this.success,
    this.txHash,
    this.error,
    this.amount,
    this.toId,
    required this.completedAt,
  });
}

class NFCTapHandler {
  static const _channel = MethodChannel('network.sov.node/nfc');
  static const _eventChannel = EventChannel('network.sov.node/nfc_events');

  // NFC is a mobile-only contactless feature. Desktop (Windows/macOS/Linux)
  // has no NFC hardware path — short-circuit so an unregistered channel never
  // throws MissingPluginException.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static NFCStatus _status = NFCStatus.idle;
  static StreamController<NFCStatus>? _statusController;
  static StreamController<NFCPaymentResult>? _resultController;
  static StreamSubscription? _eventSubscription;
  static Timer? _timeoutTimer;

  // Payment session expires after 30 seconds
  static const _sessionTimeoutSeconds = 30;

  // ── Public getters ────────────────────────────────────────
  static NFCStatus get status => _status;
  static Stream<NFCStatus>? get statusStream =>
      _statusController?.stream;
  static Stream<NFCPaymentResult>? get resultStream =>
      _resultController?.stream;

  // ── Initialise ────────────────────────────────────────────
  static Future<void> initialise() async {
    _statusController ??=
    StreamController<NFCStatus>.broadcast();
    _resultController ??=
    StreamController<NFCPaymentResult>.broadcast();

    final supported = await _isSupported();
    if (!supported) {
      _status = NFCStatus.unavailable;
      _statusController?.add(_status);
      return;
    }
    _status = NFCStatus.idle;
    _statusController?.add(_status);
  }

  // ── Check NFC support ─────────────────────────────────────
  static Future<bool> _isSupported() async {
    if (_isDesktop) return false;
    try {
      final result =
      await _channel.invokeMethod<bool>('isNFCSupported');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ── SENDER SIDE — Start payment request ───────────────────
  // The person REQUESTING payment taps their phone first
  static Future<void> startPaymentRequest({
    required double amount,
    String? memo,
  }) async {
    if (_status == NFCStatus.unavailable) return;

    final sovereignId = await KeyManager.getSovereignId();
    final publicKey = await KeyManager.getPublicKey();
    final sessionToken = await KeyManager.signChallenge(
      '$sovereignId-$amount-${DateTime.now().millisecondsSinceEpoch}',
    );

    final request = NFCPaymentRequest(
      fromId: sovereignId!,
      fromPublicKey: publicKey!,
      requestedAmount: amount,
      memo: memo,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sessionToken: sessionToken,
    );

    try {
      await _channel.invokeMethod('startNFCBroadcast', {
        'payload': jsonEncode(request.toJson()),
      });
      _status = NFCStatus.listening;
      _statusController?.add(_status);
      _startTimeout();
      _listenForEvents();
    } on PlatformException catch (e) {
      _status = NFCStatus.failed;
      _statusController?.add(_status);
      _resultController?.add(NFCPaymentResult(
        success: false,
        error: e.message,
        completedAt: DateTime.now(),
      ));
    }
  }

  // ── RECEIVER SIDE — Listen for incoming tap ───────────────
  // The person SENDING payment holds their phone to receive
  static Future<void> listenForPaymentRequest() async {
    if (_status == NFCStatus.unavailable) return;

    try {
      await _channel.invokeMethod('startNFCListen');
      _status = NFCStatus.listening;
      _statusController?.add(_status);
      _startTimeout();
      _listenForEvents();
    } on PlatformException catch (e) {
      _status = NFCStatus.failed;
      _statusController?.add(_status);
      _resultController?.add(NFCPaymentResult(
        success: false,
        error: e.message,
        completedAt: DateTime.now(),
      ));
    }
  }

  // ── Process incoming NFC payment request ──────────────────
  static Future<void> _processPaymentRequest(
      Map<String, dynamic> data) async {
    _status = NFCStatus.processing;
    _statusController?.add(_status);
    _timeoutTimer?.cancel();

    try {
      final request = NFCPaymentRequest.fromJson(data);

      // Validate session is fresh (within 30 seconds)
      final age = DateTime.now().millisecondsSinceEpoch -
          request.timestamp;
      if (age > 30000) {
        throw Exception('Payment request expired');
      }

      // Check balance
      final balance = await WalletEngine.getBalance();
      if (balance < request.requestedAmount) {
        throw Exception('Insufficient balance');
      }

      // Execute the payment
      String txHash;

      if (RelayConnector.isConnected) {
        // Online — send via relay
        txHash = await WalletEngine.sendSOV(
          toId: request.fromId,
          amount: request.requestedAmount,
        );
        await RelayConnector.send({
          'type': 'SOV_TRANSFER',
          'tx_hash': txHash,
          'to_id': request.fromId,
          'amount': request.requestedAmount,
          'session_token': request.sessionToken,
        });
      } else {
        // Offline — store in DTN for later delivery
        final packetId = await DTNStore.storeTransaction(
          toId: request.fromId,
          amount: request.requestedAmount,
        );
        txHash = packetId;
      }

      // Confirm payment back via NFC
      await _channel.invokeMethod('sendNFCConfirmation', {
        'tx_hash': txHash,
        'amount': request.requestedAmount,
        'from_id': await KeyManager.getSovereignId(),
      });

      _status = NFCStatus.success;
      _statusController?.add(_status);
      _resultController?.add(NFCPaymentResult(
        success: true,
        txHash: txHash,
        amount: request.requestedAmount,
        toId: request.fromId,
        completedAt: DateTime.now(),
      ));
    } catch (e) {
      _status = NFCStatus.failed;
      _statusController?.add(_status);
      _resultController?.add(NFCPaymentResult(
        success: false,
        error: e.toString(),
        completedAt: DateTime.now(),
      ));
    }

    // Reset to idle after 3 seconds
    Timer(const Duration(seconds: 3), () {
      _status = NFCStatus.idle;
      _statusController?.add(_status);
    });
  }

  // ── Listen for NFC events from native layer ───────────────
  static void _listenForEvents() {
    _eventSubscription?.cancel();
    _eventSubscription =
        _eventChannel.receiveBroadcastStream().listen((event) {
          try {
            final data =
            jsonDecode(event as String) as Map<String, dynamic>;
            final eventType = data['event'] as String;

            switch (eventType) {
              case 'NFC_TAP_RECEIVED':
                _processPaymentRequest(
                    data['payload'] as Map<String, dynamic>);
                break;
              case 'NFC_CONFIRMATION_RECEIVED':
                _onPaymentConfirmed(data);
                break;
              case 'NFC_ERROR':
                _onNFCError(data);
                break;
            }
          } catch (_) {}
        });
  }

  // ── Payment confirmed by the other phone ──────────────────
  static void _onPaymentConfirmed(Map<String, dynamic> data) {
    _timeoutTimer?.cancel();
    _status = NFCStatus.success;
    _statusController?.add(_status);
    _resultController?.add(NFCPaymentResult(
      success: true,
      txHash: data['tx_hash'] as String?,
      amount: (data['amount'] as num?)?.toDouble(),
      toId: data['from_id'] as String?,
      completedAt: DateTime.now(),
    ));

    Timer(const Duration(seconds: 3), () {
      _status = NFCStatus.idle;
      _statusController?.add(_status);
    });
  }

  // ── NFC error ─────────────────────────────────────────────
  static void _onNFCError(Map<String, dynamic> data) {
    _timeoutTimer?.cancel();
    _status = NFCStatus.failed;
    _statusController?.add(_status);
    _resultController?.add(NFCPaymentResult(
      success: false,
      error: data['message'] as String?,
      completedAt: DateTime.now(),
    ));
  }

  // ── Session timeout ───────────────────────────────────────
  static void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(
      const Duration(seconds: _sessionTimeoutSeconds),
          () {
        if (_status == NFCStatus.listening) {
          _status = NFCStatus.idle;
          _statusController?.add(_status);
          stopListening();
        }
      },
    );
  }

  // ── Stop listening ────────────────────────────────────────
  static Future<void> stopListening() async {
    _timeoutTimer?.cancel();
    _eventSubscription?.cancel();
    try {
      await _channel.invokeMethod('stopNFC');
    } on PlatformException {
      // Already stopped
    }
    _status = NFCStatus.idle;
    _statusController?.add(_status);
  }

  // ── Status label ──────────────────────────────────────────
  static String getStatusLabel() {
    switch (_status) {
      case NFCStatus.unavailable:
        return 'NFC Not Available';
      case NFCStatus.idle:
        return 'Ready to Pay';
      case NFCStatus.listening:
        return 'Hold Phones Together...';
      case NFCStatus.processing:
        return 'Processing Payment...';
      case NFCStatus.success:
        return 'Payment Complete';
      case NFCStatus.failed:
        return 'Payment Failed';
    }
  }
}