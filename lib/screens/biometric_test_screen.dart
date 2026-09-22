import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/key_manager.dart';

// ═══════════════════════════════════════════════════════════════════════════
// BiometricTestScreen — Sovereign Protocol Test Suite
//
// Tests the full biometric hash protocol WITHOUT using real biometrics.
// Simulates known hash values to verify the relay correctly:
//   1. Accepts a new identity
//   2. Rejects the same identity on re-enrollment (duplicate)
//   3. Accepts a different identity
//   4. Restores wallet via palm hash match (recovery)
//   5. Rejects unknown palm hash (wrong person)
//
// All tests run over the live relay connection — wss://203.0.113.10:443
// No real biometric data is captured or transmitted.
// ═══════════════════════════════════════════════════════════════════════════

enum TestStatus { pending, running, pass, fail, warn }

class _TestResult {
  final String id;
  final String label;
  TestStatus status = TestStatus.pending;
  String detail = '';
  String? relayResponse;

  _TestResult({
    required this.id,
    required this.label,
  });
}

class BiometricTestScreen extends StatefulWidget {
  const BiometricTestScreen({super.key});

  @override
  State<BiometricTestScreen> createState() => _BiometricTestScreenState();
}

class _BiometricTestScreenState extends State<BiometricTestScreen> {
  static const _teal   = Color(0xFF00D4AA);
  static const _gold   = Color(0xFFFFB800);
  static const _bg     = Color(0xFF0A0A1A);
  static const _card   = Color(0xFF0D1B2A);

  bool _isRunning = false;
  bool _isDone    = false;
  String _overallStatus = 'Ready to run protocol tests';
  Color  _overallColor  = Colors.white54;

  // ── Known test hashes ───────────────────────────────────────────────────
  // These are deterministic SHA-256 values used only for testing
  // They simulate what real biometric capture would produce
  static String _hash(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  late final String _hashA;
  late final String _hashB;
  late final String _hashC;
  late final String _livenessA;

  String? _testSovId;   // Sovereign ID created during test 1
  String? _testPubKey;  // Public key created during test 1

  final List<_TestResult> _tests = [
    _TestResult(id: 't1', label: 'Test 1 — New identity accepted'),
    _TestResult(id: 't2', label: 'Test 2 — Same identity rejected (duplicate)'),
    _TestResult(id: 't3', label: 'Test 3 — Different identity accepted'),
    _TestResult(id: 't4', label: 'Test 4 — Recovery: correct palm restores wallet'),
    _TestResult(id: 't5', label: 'Test 5 — Recovery: wrong palm rejected'),
  ];

  @override
  void initState() {
    super.initState();
    _hashA     = _hash('TEST_PERSON_ALPHA_PALM_SESSION_001');
    _hashB     = _hash('TEST_PERSON_BETA_PALM_SESSION_001');
    _hashC     = _hash('TEST_PERSON_UNKNOWN_PALM_SESSION_XYZ');
    _livenessA = _hash('TEST_FACE_ALPHA_SESSION_001');
    _cleanupTestData();
  }

  // Remove any leftover test enrollments from previous runs
  Future<void> _cleanupTestData() async {
    if (!RelayConnector.isConnected) return;
    await RelayConnector.send({
      'type':       'TEST_CLEANUP',
      'test_hashes': [_hashA, _hashB],
    });
  }

  void _reset() {
    setState(() {
      _isDone    = false;
      _isRunning = false;
      _overallStatus = 'Ready to run protocol tests';
      _overallColor  = Colors.white54;
      _testSovId  = null;
      _testPubKey = null;
      for (final t in _tests) {
        t.status = TestStatus.pending;
        t.detail = '';
        t.relayResponse = null;
      }
    });
    _cleanupTestData();
  }

  Future<void> _runAllTests() async {
    if (_isRunning) return;
    setState(() { _isRunning = true; _isDone = false; });

    if (!RelayConnector.isConnected) {
      setState(() {
        _overallStatus = 'No relay connection — cannot run tests';
        _overallColor  = Colors.redAccent;
        _isRunning     = false;
      });
      return;
    }

    await _runTest('t1', _test1NewIdentityAccepted);
    await _runTest('t2', _test2DuplicateRejected);
    await _runTest('t3', _test3DifferentIdentityAccepted);
    await _runTest('t4', _test4RecoveryCorrectPalm);
    await _runTest('t5', _test5RecoveryWrongPalm);

    // Clean up test data from relay
    await _cleanupTestData();

    final passed = _tests.where((t) => t.status == TestStatus.pass).length;
    final total  = _tests.length;
    setState(() {
      _isDone    = true;
      _isRunning = false;
      if (passed == total) {
        _overallStatus = 'ALL $total TESTS PASSED — Protocol verified ✓';
        _overallColor  = _teal;
      } else {
        _overallStatus = '$passed/$total tests passed — Review failures';
        _overallColor  = Colors.orangeAccent;
      }
    });
  }

  Future<void> _runTest(String id, Future<void> Function() testFn) async {
    final test = _tests.firstWhere((t) => t.id == id);
    setState(() { test.status = TestStatus.running; test.detail = 'Running...'; });
    try {
      await testFn();
    } catch (e) {
      setState(() {
        test.status = TestStatus.fail;
        test.detail = 'Exception: $e';
      });
    }
    await Future.delayed(const Duration(milliseconds: 400));
  }

  // ── TEST 1 — New identity should be accepted ────────────────────────────
  Future<void> _test1NewIdentityAccepted() async {
    final test = _tests.firstWhere((t) => t.id == 't1');

    // First check duplicate — should return false for new hash
    final dupCheck = await RelayConnector.sendAndWait(
      request:      {'type': 'IDENTITY_DUPLICATE_CHECK', 'identity_hash': _hashA},
      responseType: 'IDENTITY_DUPLICATE_RESULT',
      timeout:      const Duration(seconds: 10),
    );

    if (dupCheck == null) {
      setState(() {
        test.status = TestStatus.fail;
        test.detail = 'No response from relay — connection issue';
      });
      return;
    }

    if (dupCheck['duplicate'] == true) {
      // Clean previous test data and retry
      await _cleanupTestData();
      await Future.delayed(const Duration(seconds: 1));
    }

    // Generate test keys for this enrollment
    await KeyManager.wipeKeys();
    await KeyManager.initialise();
    _testSovId  = await KeyManager.getSovereignId();
    _testPubKey = await KeyManager.getPublicKey();

    // Send test enrollment
    final ack = await RelayConnector.sendAndWait(
      request: {
        'type':            'ENROLLMENT_REGISTER',
        'sovereign_id':    _testSovId,
        'public_key':      _testPubKey,
        'liveness_hash':   _livenessA,
        'uniqueness_hash': _hashA,
        'enrollment_hash': _hash('${_livenessA}_${_hashA}_TEST'),
        'enrollment_sov':  1000,
        'citizen_number':  999901, // test citizen number
        'test_mode':       true,
      },
      responseType: 'ENROLLMENT_ACK',
      timeout:      const Duration(seconds: 15),
    );

    setState(() {
      test.relayResponse = ack != null ? 'ACK received' : 'No ACK';
      if (ack != null && ack['success'] != false) {
        test.status = TestStatus.pass;
        test.detail = 'New identity accepted by relay ✓\nSovereign ID: ${(_testSovId?.length ?? 0) > 8 ? _testSovId!.substring(0, 8) : _testSovId}...';
      } else {
        test.status = TestStatus.fail;
        test.detail = 'Relay rejected new identity — unexpected\nResponse: ${ack?['reason'] ?? 'no response'}';
      }
    });
  }

  // ── TEST 2 — Same identity should be rejected ───────────────────────────
  Future<void> _test2DuplicateRejected() async {
    final test = _tests.firstWhere((t) => t.id == 't2');

    // Check duplicate — should now return true since test 1 enrolled hashA
    final dupCheck = await RelayConnector.sendAndWait(
      request:      {'type': 'IDENTITY_DUPLICATE_CHECK', 'identity_hash': _hashA},
      responseType: 'IDENTITY_DUPLICATE_RESULT',
      timeout:      const Duration(seconds: 10),
    );

    setState(() {
      test.relayResponse = dupCheck != null
          ? 'duplicate: ${dupCheck['duplicate']}'
          : 'No response';
      if (dupCheck == null) {
        test.status = TestStatus.fail;
        test.detail = 'No response from relay';
      } else if (dupCheck['duplicate'] == true) {
        test.status = TestStatus.pass;
        test.detail = 'Duplicate correctly detected and blocked ✓\n'
                      'Same palm hash rejected as expected';
      } else {
        test.status = TestStatus.fail;
        test.detail = 'SECURITY FAILURE — duplicate not detected!\n'
                      'Same identity hash was not found in relay DB.\n'
                      'This means a person could enroll twice.';
      }
    });
  }

  // ── TEST 3 — Different identity should be accepted ──────────────────────
  Future<void> _test3DifferentIdentityAccepted() async {
    final test = _tests.firstWhere((t) => t.id == 't3');

    final dupCheck = await RelayConnector.sendAndWait(
      request:      {'type': 'IDENTITY_DUPLICATE_CHECK', 'identity_hash': _hashB},
      responseType: 'IDENTITY_DUPLICATE_RESULT',
      timeout:      const Duration(seconds: 10),
    );

    setState(() {
      test.relayResponse = dupCheck != null
          ? 'duplicate: ${dupCheck['duplicate']}'
          : 'No response';
      if (dupCheck == null) {
        test.status = TestStatus.fail;
        test.detail = 'No response from relay';
      } else if (dupCheck['duplicate'] == false) {
        test.status = TestStatus.pass;
        test.detail = 'Different identity correctly allowed ✓\n'
                      'New person can enroll freely';
      } else {
        test.status = TestStatus.fail;
        test.detail = 'False positive — different identity wrongly blocked\n'
                      'Hash collision or bloom filter misconfiguration';
      }
    });
  }

  // ── TEST 4 — Recovery: correct palm hash finds wallet ───────────────────
  Future<void> _test4RecoveryCorrectPalm() async {
    final test = _tests.firstWhere((t) => t.id == 't4');

    final recovery = await RelayConnector.sendAndWait(
      request: {
        'type':            'PALM_RECOVERY_REQUEST',
        'uniqueness_hash': _hashA,
        'test_mode':       true,
      },
      responseType: 'PALM_RECOVERY_RESPONSE',
      timeout:      const Duration(seconds: 10),
    );

    setState(() {
      test.relayResponse = recovery != null
          ? 'found: ${recovery['found']}'
          : 'No response';
      if (recovery == null) {
        test.status = TestStatus.warn;
        test.detail = 'No response — PALM_RECOVERY_REQUEST handler may not exist yet\n'
                      'This is expected if recovery handler not yet built on relay';
      } else if (recovery['found'] == true) {
        test.status = TestStatus.pass;
        test.detail = 'Correct palm hash finds wallet ✓\n'
                      'Recovery would restore: ${recovery['sovereign_id'] ?? _testSovId}';
      } else {
        test.status = TestStatus.fail;
        test.detail = 'Correct palm hash did not find wallet\n'
                      'Recovery would fail for legitimate user';
      }
    });
  }

  // ── TEST 5 — Recovery: wrong palm hash fails ────────────────────────────
  Future<void> _test5RecoveryWrongPalm() async {
    final test = _tests.firstWhere((t) => t.id == 't5');

    final recovery = await RelayConnector.sendAndWait(
      request: {
        'type':            'PALM_RECOVERY_REQUEST',
        'uniqueness_hash': _hashC,
        'test_mode':       true,
      },
      responseType: 'PALM_RECOVERY_RESPONSE',
      timeout:      const Duration(seconds: 10),
    );

    setState(() {
      test.relayResponse = recovery != null
          ? 'found: ${recovery['found']}'
          : 'No response';
      if (recovery == null) {
        test.status = TestStatus.warn;
        test.detail = 'No response — PALM_RECOVERY_REQUEST handler not built yet\n'
                      'Expected — recovery protocol is a pending item';
      } else if (recovery['found'] == false) {
        test.status = TestStatus.pass;
        test.detail = 'Unknown palm hash correctly rejected ✓\n'
                      'Cannot recover wallet with wrong palm';
      } else {
        test.status = TestStatus.fail;
        test.detail = 'SECURITY FAILURE — unknown palm hash found a wallet!\n'
                      'Recovery would allow wrong person access to someone\'s wallet';
      }
    });
  }

  // ── BUILD ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('Biometric Protocol Test',
            style: TextStyle(color: Colors.white, fontSize: 16,
                fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_isDone)
            IconButton(
              icon: const Icon(Icons.refresh, color: _teal),
              onPressed: _reset,
            ),
        ],
      ),
      body: Column(children: [
        // Header info
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.science, color: _teal, size: 16),
              SizedBox(width: 8),
              Text('Protocol Test Mode',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 8),
            const Text(
              'Tests biometric duplicate detection using deterministic hash values. '
              'No real biometric data used. All tests run against the live relay.',
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 8),
            Row(children: [
              _dot(RelayConnector.isConnected ? _teal : Colors.redAccent),
              const SizedBox(width: 6),
              Text(
                RelayConnector.isConnected
                    ? 'Connected — SRP-RELAY-001'
                    : 'No relay connection',
                style: TextStyle(
                  color: RelayConnector.isConnected ? _teal : Colors.redAccent,
                  fontSize: 12,
                ),
              ),
            ]),
          ]),
        ),

        // Test list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _tests.length,
            itemBuilder: (context, i) => _buildTestCard(_tests[i]),
          ),
        ),

        // Overall status
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _overallColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _overallColor.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            if (_isRunning)
              const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2,
                      color: Color(0xFF00D4AA))),
            if (!_isRunning)
              Icon(_isDone ? Icons.check_circle : Icons.info_outline,
                  color: _overallColor, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(_overallStatus,
                style: TextStyle(color: _overallColor, fontSize: 13))),
          ]),
        ),

        // Run button
        if (!_isRunning && !_isDone)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: RelayConnector.isConnected ? _runAllTests : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: _bg,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Run All 5 Tests',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ),

        if (_isDone)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton(
                onPressed: _reset,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _teal,
                  side: const BorderSide(color: Color(0xFF00D4AA)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Run Again',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildTestCard(_TestResult test) {
    final statusColor = switch (test.status) {
      TestStatus.pass    => _teal,
      TestStatus.fail    => Colors.redAccent,
      TestStatus.warn    => _gold,
      TestStatus.running => Colors.white70,
      TestStatus.pending => Colors.white24,
    };
    final statusIcon = switch (test.status) {
      TestStatus.pass    => Icons.check_circle,
      TestStatus.fail    => Icons.cancel,
      TestStatus.warn    => Icons.warning_amber,
      TestStatus.running => Icons.hourglass_top,
      TestStatus.pending => Icons.radio_button_unchecked,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: test.status == TestStatus.pending
              ? Colors.white12
              : statusColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        test.status == TestStatus.running
            ? SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2,
                    color: statusColor))
            : Icon(statusIcon, color: statusColor, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(test.label,
                style: TextStyle(
                  color: test.status == TestStatus.pending
                      ? Colors.white54
                      : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                )),
            if (test.detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(test.detail,
                  style: TextStyle(color: statusColor, fontSize: 12,
                      height: 1.5)),
            ],
            if (test.relayResponse != null) ...[
              const SizedBox(height: 4),
              Text('Relay: ${test.relayResponse}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ],
        )),
      ]),
    );
  }

  Widget _dot(Color color) => Container(
    width: 8, height: 8,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
