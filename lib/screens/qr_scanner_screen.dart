// lib/screens/qr_scanner_screen.dart
// QR code scanner for SOV payment requests and plain Sovereign IDs.
//
// Supports two modes:
//   1. LIVE CAMERA  — point camera at QR code on another screen (face-to-face)
//   2. IMAGE PICKER — select a QR code image from gallery/files (received via
//                     SOV Speak, WhatsApp, email, screenshot, etc.)
//
// Usage:
//   final result = await Navigator.push<String>(
//     context,
//     MaterialPageRoute(builder: (_) => const QrScannerScreen()),
//   );
//   // result is the raw scanned string (sovreq:// URI or SOV-XXX ID), or null.
//
// The caller (SendSovScreen) parses the result and fills the form.

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../sov_node_sdk/relay_connector.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  static const _navy = Color(0xFF0A1628);
  static const _gold = Color(0xFFD4AF37);

  // Desktop (Windows/macOS/Linux) has no live-camera path for mobile_scanner —
  // instantiating the controller there throws. On desktop we skip the camera
  // entirely and offer a paste-the-code fallback instead.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  late final MobileScannerController? _controller = _isDesktop
      ? null
      : MobileScannerController(
          detectionSpeed: DetectionSpeed.normal,
          facing: CameraFacing.back,
        );

  final TextEditingController _manualCtrl = TextEditingController();

  bool _scanned    = false;   // prevents double-pop on rapid detections
  bool _torchOn    = false;
  bool _analyzing  = false;   // true while decoding a gallery image

  @override
  void dispose() {
    _controller?.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  bool _isSovCode(String raw) =>
      raw.startsWith('sovreq://') ||
      raw.startsWith('sovlogin://') ||
      raw.startsWith('SOV-');

  void _submitManual() {
    final raw = _manualCtrl.text.trim();
    if (raw.isEmpty) return;
    if (!_isSovCode(raw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not a recognised SOV code (expects SOV-…, sovreq:// or sovlogin://)'),
          backgroundColor: Color(0xFF1A3A5C),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _scanned = true;
    Navigator.pop(context, raw);
  }

  // ── Gallery / image-based QR decode ─────────────────────────────────────
  // When the QR code was received as an image (SOV Speak, WhatsApp, email,
  // screenshot), the citizen picks the image from their gallery.
  // mobile_scanner's analyzeImage() runs ML Kit / ZXing on the static image
  // and returns the same BarcodeCapture as the live camera path.
  Future<void> _pickFromGallery() async {
    if (_scanned || _analyzing) return;

    RelayConnector.externalActivityOpen = true;
    final picker = ImagePicker();
    final file   = await picker.pickImage(source: ImageSource.gallery);
    RelayConnector.externalActivityOpen = false;

    if (file == null || !mounted) return;

    setState(() => _analyzing = true);
    try {
      final capture = await _controller?.analyzeImage(file.path);
      if (!mounted) return;

      if (capture == null || capture.barcodes.isEmpty) {
        setState(() => _analyzing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No QR code found in that image'),
            backgroundColor: Color(0xFF1A3A5C),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final raw = capture.barcodes.first.rawValue ?? '';
      if (raw.isEmpty ||
          (!raw.startsWith('sovreq://') &&
           !raw.startsWith('sovlogin://') &&
           !raw.startsWith('SOV-'))) {
        setState(() => _analyzing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('QR code is not a recognised SOV code'),
            backgroundColor: Color(0xFF1A3A5C),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      _scanned = true;
      Navigator.pop(context, raw);
    } catch (e) {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  // ── Desktop fallback — paste the SOV code (no camera) ───────────────────
  Widget _buildDesktopFallback(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Enter SOV Code',
            style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.qr_code_2_rounded, color: _gold, size: 64),
            const SizedBox(height: 16),
            const Text(
              'On desktop there is no camera to scan a QR code.\n'
              'Paste the SOV ID or payment link the other citizen shared.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _manualCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              onSubmitted: (_) => _submitManual(),
              decoration: InputDecoration(
                hintText: 'SOV-…  /  sovreq://…  /  sovlogin://…',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.black26,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _gold),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _submitManual,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: _navy,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Continue',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    final raw = barcode?.rawValue ?? '';
    if (raw.isEmpty) return;

    // Only accept sovreq://, sovlogin:// links or SOV- IDs
    if (!raw.startsWith('sovreq://') && !raw.startsWith('sovlogin://') &&
        !raw.startsWith('SOV-')) { return; }

    _scanned = true;
    _controller?.stop();
    Navigator.pop(context, raw);
  }

  @override
  Widget build(BuildContext context) {
    if (_isDesktop) return _buildDesktopFallback(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera viewfinder ─────────────────────────────────────────────
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // ── Darkened overlay with transparent cut-out ─────────────────────
          CustomPaint(
            painter: _ScanOverlayPainter(),
            child: const SizedBox.expand(),
          ),

          // ── Top bar ───────────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Back button
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white, size: 20),
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'Scan QR Code',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // Torch toggle
                  GestureDetector(
                    onTap: () {
                      _controller?.toggleTorch();
                      setState(() => _torchOn = !_torchOn);
                    },
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: _torchOn
                            ? _gold.withAlpha(200)
                            : Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _torchOn
                            ? Icons.flashlight_on_rounded
                            : Icons.flashlight_off_rounded,
                        color: _torchOn ? Colors.black : Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Scan frame corners ────────────────────────────────────────────
          const Center(
            child: _ScanFrameCorners(),
          ),

          // ── Bottom instruction + gallery button ───────────────────────────
          Positioned(
            bottom: 0,
            left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Instruction pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(160),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        children: [
                          Text(
                            'Point camera at a SOV payment QR code',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'The form will fill automatically',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Gallery / image picker button
                    GestureDetector(
                      onTap: _pickFromGallery,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          color: _analyzing
                              ? _gold.withAlpha(180)
                              : _navy.withAlpha(220),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _gold.withAlpha(180),
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_analyzing) ...[
                              const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Scanning image…',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                            ] else ...[
                              const Icon(Icons.photo_library_rounded,
                                  color: Color(0xFFD4AF37), size: 20),
                              const SizedBox(width: 10),
                              const Text(
                                'Choose from Gallery',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),
                    const Text(
                      'Received a QR via SOV Speak, WhatsApp or email? Pick the image.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Overlay painter: darkens everything outside the scan square ─────────────

class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const side   = 260.0;
    final cx     = size.width  / 2;
    final cy     = size.height / 2 - 30;   // slightly above centre
    final rect   = Rect.fromCenter(center: Offset(cx, cy),
                                   width: side, height: side);

    final paint = Paint()..color = Colors.black.withAlpha(140);

    // Draw four dark rectangles leaving the centre square transparent
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), paint);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), paint);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), paint);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), paint);

    // Thin gold border around the cut-out
    final borderPaint = Paint()
      ..color  = const Color(0xFFD4AF37).withAlpha(180)
      ..strokeWidth = 1.5
      ..style  = PaintingStyle.stroke;
    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─── Corner bracket decorations ──────────────────────────────────────────────

class _ScanFrameCorners extends StatelessWidget {
  const _ScanFrameCorners();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 260,
      height: 260,
      child: Stack(
        children: [
          // Top-left
          Positioned(top: -1, left: -1,    child: _Corner(flipH: false, flipV: false)),
          // Top-right
          Positioned(top: -1, right: -1,   child: _Corner(flipH: true,  flipV: false)),
          // Bottom-left
          Positioned(bottom: -1, left: -1, child: _Corner(flipH: false, flipV: true)),
          // Bottom-right
          Positioned(bottom: -1, right: -1,child: _Corner(flipH: true,  flipV: true)),
        ],
      ),
    );
  }
}

class _Corner extends StatelessWidget {
  final bool flipH;
  final bool flipV;
  const _Corner({required this.flipH, required this.flipV});

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
          flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0, 1.0),
      child: CustomPaint(
        size: const Size(28, 28),
        painter: _CornerPainter(),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = const Color(0xFFD4AF37)
      ..strokeWidth = 3.5
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round;

    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
