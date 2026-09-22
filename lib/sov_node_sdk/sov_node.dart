import 'dart:async';
import 'relay_connector.dart';
import 'key_manager.dart';
import 'wallet_engine.dart';
import 'wifi_aware_mesh.dart';
import 'dtn_store.dart';
import 'nfc_tap_handler.dart';

/// SOV Node — Master Entry Point
/// This is the single class the app calls on launch.
/// It boots all 6 SDK components in the correct order
/// and provides a unified status stream for the UI.

enum NodeState {
  booting,      // Node is starting up
  ready,        // Fully initialised and connected
  degraded,     // Running but with limited connectivity
  offline,      // No connection — DTN mode active
  error,        // Critical failure
}

class NodeStatus {
  final NodeState state;
  final bool keysReady;
  final bool walletReady;
  final bool relayConnected;
  final bool meshActive;
  final bool nfcAvailable;
  final int pendingDTNPackets;
  final String connectionLabel;
  final String? sovereignId;
  final double? balance;

  NodeStatus({
    required this.state,
    required this.keysReady,
    required this.walletReady,
    required this.relayConnected,
    required this.meshActive,
    required this.nfcAvailable,
    required this.pendingDTNPackets,
    required this.connectionLabel,
    this.sovereignId,
    this.balance,
  });

  // Convenience getters
  bool get isFullyOperational =>
      keysReady && walletReady && relayConnected;
  bool get canTransact => keysReady && walletReady;
  bool get canMeshTransact => keysReady && walletReady && meshActive;
}

class SOVNode {
  static NodeState _state = NodeState.booting;
  static bool _keysReady = false;
  static bool _walletReady = false;
  static bool _meshActive = false;
  static bool _nfcAvailable = false;
  static int _pendingDTN = 0;

  static StreamController<NodeStatus>? _statusController;
  static Timer? _statusTimer;

  // ── Public stream ─────────────────────────────────────────
  static Stream<NodeStatus>? get statusStream =>
      _statusController?.stream;
  static NodeState get state => _state;

  // ── Boot sequence ─────────────────────────────────────────
  // Called once from main.dart when the app launches
  static Future<void> boot() async {
    _statusController ??=
    StreamController<NodeStatus>.broadcast();

    _state = NodeState.booting;
    _emitStatus();

    try {
      // Step 1 — Keys (must be first — everything needs identity)
      await KeyManager.initialise();
      _keysReady = true;
      _emitStatus();

      // Step 2 — Wallet (needs keys)
      await WalletEngine.initialise();
      _walletReady = true;
      _emitStatus();

      // Step 3 — Relay connection (needs identity)
      final connected = await RelayConnector.connect();
      if (connected) {
        await RelayConnector.registerNode();
      }
      _emitStatus();

      // Step 4 — Wi-Fi Aware mesh (independent)
      await WifiAwareMesh.initialise();
      await WifiAwareMesh.startDiscovery();
      _meshActive =
          WifiAwareMesh.status != MeshStatus.unavailable;
      _emitStatus();

      // Step 5 — NFC (independent)
      await NFCTapHandler.initialise();
      _nfcAvailable =
          NFCTapHandler.status != NFCStatus.unavailable;
      _emitStatus();

      // Step 6 — DTN auto-forward (needs relay + wallet)
      DTNStore.startAutoForward();
      _pendingDTN = await DTNStore.getPendingCount();
      _emitStatus();

      // Step 7 — Listen for incoming mesh transactions
      _listenForMeshMessages();

      // Step 8 — Listen for relay messages
      _listenForRelayMessages();

      // Determine final state
      if (RelayConnector.isConnected) {
        _state = NodeState.ready;
      } else if (_keysReady && _walletReady) {
        _state = NodeState.degraded;
      } else {
        _state = NodeState.offline;
      }

      _emitStatus();

      // Start periodic status updates every 30 seconds
      _startStatusTimer();
    } catch (e) {
      _state = NodeState.error;
      _emitStatus();
    }
  }

  // ── Listen for relay messages ─────────────────────────────
  static void _listenForRelayMessages() {
    RelayConnector.messageStream?.listen((message) async {
      final type = message['type'] as String?;
      switch (type) {
        case 'SOV_TRANSFER':
        // Incoming payment from relay
          await WalletEngine.receiveSOV(
            txHash: message['tx_hash'] as String,
            fromId: message['from_id'] as String,
            amount: (message['amount'] as num).toDouble(),
            signedPayload:
            message['signed_payload'] as String? ?? '',
          );
          break;

        case 'DTN_PACKET':
        // A packet being carried through our node
          await DTNStore.receiveCarriedPacket(message);
          // Immediately try to forward it
          await DTNStore.forwardPending();
          break;

        case 'WITNESS_REQUEST':
        // Another node asking us to witness a transaction
          await _handleWitnessRequest(message);
          break;

        case 'NODE_PING':
        // Relay checking if we are alive
          await RelayConnector.send({
            'type': 'NODE_PONG',
            'sovereign_id':
            await KeyManager.getSovereignId(),
          });
          break;
      }
    });
  }

  // ── Listen for mesh messages ──────────────────────────────
  static void _listenForMeshMessages() {
    WifiAwareMesh.messageStream?.listen((message) async {
      final type = message['type'] as String?;
      switch (type) {
        case 'SOV_TRANSFER':
        // Direct peer-to-peer payment via mesh
          await WalletEngine.receiveSOV(
            txHash: message['tx_hash'] as String,
            fromId: message['from'] as String,
            amount: (message['amount'] as num).toDouble(),
            signedPayload: '',
          );
          break;

        case 'DTN_PACKET':
        // A node is handing us a packet to carry
          await DTNStore.receiveCarriedPacket(message);
          break;
      }
    });
  }

  // ── Witness a transaction ─────────────────────────────────
  // Our node confirms another citizen's transaction
  // This is the 5-of-7 consensus in action
  static Future<void> _handleWitnessRequest(
      Map<String, dynamic> message) async {
    try {
      final txHash = message['tx_hash'] as String;
      final fromId = message['from_id'] as String;
      final toId = message['to_id'] as String;
      final amount = (message['amount'] as num).toDouble();
      final signedPayload =
      message['signed_payload'] as String;

      // Basic validation — check signature is present
      if (txHash.isEmpty ||
          fromId.isEmpty ||
          signedPayload.isEmpty) { return; }

      // Sign our witness confirmation
      final witnessSignature =
      await KeyManager.signChallenge(txHash);
      final sovereignId = await KeyManager.getSovereignId();

      // Send witness confirmation back to relay
      await RelayConnector.send({
        'type': 'WITNESS_CONFIRM',
        'tx_hash': txHash,
        'from_id': fromId,
        'to_id': toId,
        'amount': amount,
        'witness_id': sovereignId,
        'witness_signature': witnessSignature,
      });
    } catch (_) {}
  }

  // ── Get current node status ───────────────────────────────
  static Future<NodeStatus> getStatus() async {
    String? sovereignId;
    double? balance;

    try {
      sovereignId = await KeyManager.getSovereignId();
      balance = await WalletEngine.getBalance();
      _pendingDTN = await DTNStore.getPendingCount();
    } catch (_) {}

    return NodeStatus(
      state: _state,
      keysReady: _keysReady,
      walletReady: _walletReady,
      relayConnected: RelayConnector.isConnected,
      meshActive: _meshActive,
      nfcAvailable: _nfcAvailable,
      pendingDTNPackets: _pendingDTN,
      connectionLabel: RelayConnector.getConnectionLabel(),
      sovereignId: sovereignId,
      balance: balance,
    );
  }

  // ── Emit current status to stream ────────────────────────
  static void _emitStatus() async {
    final nodeStatus = await getStatus();
    _statusController?.add(nodeStatus);
  }

  // ── Periodic status refresh ───────────────────────────────
  static void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 30),
          (_) async {
        // Update relay connection state
        if (!RelayConnector.isConnected) {
          _state = _keysReady && _walletReady
              ? NodeState.degraded
              : NodeState.offline;
        } else {
          _state = NodeState.ready;
        }

        // Update mesh peer count
        _meshActive =
            WifiAwareMesh.status != MeshStatus.unavailable &&
                WifiAwareMesh.nearbyPeers.isNotEmpty;

        _pendingDTN = await DTNStore.getPendingCount();
        _emitStatus();
      },
    );
  }

  // ── Shutdown ──────────────────────────────────────────────
  static Future<void> shutdown() async {
    _statusTimer?.cancel();
    DTNStore.stopAutoForward();
    await WifiAwareMesh.stopDiscovery();
    await NFCTapHandler.stopListening();
    await RelayConnector.disconnect();
    _state = NodeState.offline;
    _emitStatus();
  }
}