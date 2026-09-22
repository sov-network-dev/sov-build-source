import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// SOV Network Native Protocol Client
///
/// Implements the SOV native binary framing protocol for direct TCP
/// relay-to-relay and phone-to-relay communication.
///
/// Frame format:
///   Magic(4) + Version(1) + MsgType(1) + PayloadLen(4) +
///   SovereignId(32) + Signature(32) + Payload(N)
///   Total header = 74 bytes
///
/// Phone-to-relay currently uses WebSocket (relay_connector.dart) as the
/// compatibility layer. This client demonstrates the native protocol and
/// is used for direct relay connections when available.
class SovNativeClient {
  static const List<int> _magic = [0x53, 0x4F, 0x56, 0x01];
  static const int headerSize = 74;
  static const int _version = 0x01;

  Socket? _socket;
  String? _endpoint;
  final List<int> _buffer = [];
  void Function(Map<String, dynamic>)? _onMessage;
  void Function()? _onDisconnect;

  // â”€â”€ Message type codes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  static const Map<String, int> msgTypes = {
    'HANDSHAKE':              0x01,
    'HANDSHAKE_ACK':          0x02,
    'PING':                   0x03,
    'PONG':                   0x04,
    'DISCONNECT':             0x05,
    'SOV_TRANSFER':           0x10,
    'SOV_TRANSFER_RESULT':    0x11,
    'SOV_BALANCE_QUERY':      0x12,
    'SOV_BALANCE_RESULT':     0x13,
    'ENROLLMENT_REGISTER':    0x20,
    'ENROLLMENT_ACK':         0x21,
    'PALM_EMBEDDING_REGISTER':0x22,
    'PALM_EMBEDDING_RESULT':  0x23,
    'PALM_DUPLICATE_CHECK':   0x24,
    'PALM_DUPLICATE_RESULT':  0x25,
    'PALM_HELPER_FETCH':      0x26,
    'PALM_HELPER_RESULT':     0x27,
    'DISC_DELTA_SYNC':        0x30,
    'RELAY_LIST_REQUEST':     0x31,
    'RELAY_LIST_RESULT':      0x32,
    'PENDING_TX_BROADCAST':   0x33,
    'TX_CONFIRMED_BROADCAST': 0x34,
    'LIVENESS_CHECK':         0x50,
    'LIVENESS_RESULT':        0x51,
    'DEADMAN_CONFIGURE':      0x52,
    'DEADMAN_CONFIGURED':     0x53,
    'DEADMAN_CLAIM':          0x54,
    'DEADMAN_CANCEL':         0x55,
    'PIONEER_REGISTER':       0x60,
    'PIONEER_REGISTERED':     0x61,
    'GUARDIAN_NOMINATE':      0x62,
    'GUARDIAN_NOMINATED':     0x63,
    'EXCHANGE_LIST_ORDER':    0x70,
    'EXCHANGE_ORDER_LISTED':  0x71,
    'EXCHANGE_VIEW_ORDERS':   0x72,
    'EXCHANGE_ORDERS_LIST':   0x73,
    'EXCHANGE_FILL_ORDER':    0x74,
    'EXCHANGE_ORDER_FILLED':  0x75,
    'POLL_CREATE':            0x80,
    'POLL_CREATED':           0x81,
    'POLL_VOTE':              0x82,
    'POLL_VOTE_RECORDED':     0x83,
    'POLL_RESULT':            0x84,
    'ERROR':                  0xFF,
  };

  static const Map<int, String> msgNames = {
    0x01: 'HANDSHAKE',
    0x02: 'HANDSHAKE_ACK',
    0x03: 'PING',
    0x04: 'PONG',
    0x11: 'SOV_TRANSFER_RESULT',
    0x13: 'SOV_BALANCE_RESULT',
    0x21: 'ENROLLMENT_ACK',
    0x23: 'PALM_EMBEDDING_RESULT',
    0x25: 'PALM_DUPLICATE_RESULT',
    0x32: 'RELAY_LIST_RESULT',
    0x51: 'LIVENESS_RESULT',
    0x53: 'DEADMAN_CONFIGURED',
    0x61: 'PIONEER_REGISTERED',
    0x63: 'GUARDIAN_NOMINATED',
    0x71: 'EXCHANGE_ORDER_LISTED',
    0x73: 'EXCHANGE_ORDERS_LIST',
    0x75: 'EXCHANGE_ORDER_FILLED',
    0x77: 'EXCHANGE_DELIVERY_CONFIRMED',
    0x81: 'POLL_CREATED',
    0x83: 'POLL_VOTE_RECORDED',
    0x85: 'POLL_RESULT',
    0xFF: 'ERROR',
  };

  // â”€â”€ Connection â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<bool> connect(
    String host,
    int port,
    void Function(Map<String, dynamic>) onMessage, {
    void Function()? onDisconnect,
  }) async {
    try {
      _onMessage    = onMessage;
      _onDisconnect = onDisconnect;
      _endpoint     = '$host:$port';

      debugPrint('[SOV-NET] Connecting to: $_endpoint');

      _socket = await Socket.connect(
        host, port,
        timeout: const Duration(seconds: 5));

      debugPrint('[SOV-NET] TCP connected: $_endpoint');

      _socket!.listen(
        _onData,
        onError: (Object e) {
          debugPrint('[SOV-NET] Socket error: $e');
          _onDisconnect?.call();
        },
        onDone: () {
          debugPrint('[SOV-NET] Disconnected: $_endpoint');
          _onDisconnect?.call();
        },
        cancelOnError: true,
      );

      return true;
    } catch (e) {
      debugPrint('[SOV-NET] Connect failed: $e');
      return false;
    }
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _processBuffer();
  }

  void _processBuffer() {
    while (_buffer.length >= headerSize) {
      // Verify magic
      if (_buffer[0] != _magic[0] ||
          _buffer[1] != _magic[1] ||
          _buffer[2] != _magic[2] ||
          _buffer[3] != _magic[3]) {
        // Re-sync: find next magic byte sequence
        _buffer.removeAt(0);
        continue;
      }

      // Read payload length at offset 6 (big-endian uint32)
      final payloadLen =
          (_buffer[6] << 24) |
          (_buffer[7] << 16) |
          (_buffer[8] << 8)  |
           _buffer[9];

      final totalLen = headerSize + payloadLen;

      if (_buffer.length < totalLen) break; // Incomplete frame â€” wait

      final msgType = _buffer[5];
      final msgName = msgNames[msgType] ??
          'UNKNOWN_0x${msgType.toRadixString(16).padLeft(2, '0')}';

      final payloadBytes = Uint8List.fromList(
          _buffer.sublist(headerSize, totalLen));
      _buffer.removeRange(0, totalLen);

      try {
        final payloadStr = utf8.decode(payloadBytes);
        final payload    = jsonDecode(payloadStr) as Map<String, dynamic>;

        // Ensure type field is set
        if (!payload.containsKey('type')) {
          payload['type'] = msgName;
        }

        debugPrint('[SOV-NET] Received: $msgName');
        _onMessage?.call(payload);
      } catch (e) {
        debugPrint('[SOV-NET] Frame decode error: $e');
      }
    }
  }

  // â”€â”€ Send â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void send(
    String msgTypeName,
    Map<String, dynamic> payload, {
    String? sovereignId,
  }) {
    if (_socket == null) {
      debugPrint('[SOV-NET] send() called but socket is null');
      return;
    }

    final msgType = msgTypes[msgTypeName] ?? 0xFF;

    // Ensure type field is present
    payload['type'] = msgTypeName;

    final payloadBytes = utf8.encode(jsonEncode(payload));
    final pLen         = payloadBytes.length;

    // Build header
    final header = Uint8List(headerSize);
    int offset   = 0;

    // Magic (4)
    header[offset++] = _magic[0];
    header[offset++] = _magic[1];
    header[offset++] = _magic[2];
    header[offset++] = _magic[3];

    // Version (1)
    header[offset++] = _version;

    // Message type (1)
    header[offset++] = msgType;

    // Payload length big-endian (4)
    header[offset++] = (pLen >> 24) & 0xFF;
    header[offset++] = (pLen >> 16) & 0xFF;
    header[offset++] = (pLen >> 8)  & 0xFF;
    header[offset++] =  pLen        & 0xFF;

    // Sovereign ID (32 bytes, zero-padded)
    if (sovereignId != null) {
      final hexStr = sovereignId
          .replaceAll('SOV-', '')
          .padLeft(32, '0');
      for (int i = 0; i < 16 && i * 2 + 1 < hexStr.length; i++) {
        header[offset + i] = int.parse(
            hexStr.substring(i * 2, i * 2 + 2),
            radix: 16);
      }
    }
    offset += 32;

    // Signature placeholder (32 bytes â€” zeroed for Phase 1)
    offset += 32; // already zero-initialized

    // Concatenate header + payload
    final frame = Uint8List(headerSize + pLen);
    frame.setAll(0, header);
    frame.setAll(headerSize, payloadBytes);

    try {
      _socket!.add(frame);
      debugPrint('[SOV-NET] Sent: $msgTypeName (${pLen}B payload)');
    } catch (e) {
      debugPrint('[SOV-NET] Send error: $e');
    }
  }

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void disconnect() {
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
    debugPrint('[SOV-NET] Disconnected from $_endpoint');
  }

  bool get isConnected => _socket != null;

  String? get endpoint => _endpoint;
}
