// lib/sov_node_sdk/media_handler.dart
// ─────────────────────────────────────────────────────────────────────────────
// Media attachment utilities for SOV Speak.
//
// Handles: image pick (camera/gallery), video pick, file pick, voice notes.
// All relay delivery uses base64 for files ≤ 7 MB (relay WebSocket cap = 10 MB;
// base64 adds ~33% overhead so 7 MB raw → ~9.3 MB on wire, safely under cap).
// Files > 7 MB are stored locally and queued for P2P delivery.
//
// NOTE: video_thumbnail is intentionally omitted — video thumbnails show a
//       generic placeholder icon to avoid native build dependencies.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mime/mime.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class MediaResult {
  final File   file;
  final String contentType;   // 'image' | 'video' | 'audio' | 'voice' | 'file'
  final String mimeType;
  final int    sizeBytes;
  final int?   durationMs;
  final String? thumbnailBase64;

  const MediaResult({
    required this.file,
    required this.contentType,
    required this.mimeType,
    required this.sizeBytes,
    this.durationMs,
    this.thumbnailBase64,
  });
}

// ── Handler ───────────────────────────────────────────────────────────────────

class MediaHandler {
  static const int _maxRelayBytes = 7 * 1024 * 1024;   // 7 MB → ~9.3 MB base64, fits relay 10 MB cap

  // ── Image ─────────────────────────────────────────────────────────────────

  /// True on Windows/macOS/Linux desktop — there is no camera/gallery there, so
  /// media is chosen with a native file dialog (file_picker) instead of image_picker.
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Pick a single file of [type] via the desktop file dialog → MediaResult.
  static Future<MediaResult?> _pickDesktop(FileType type, String contentType,
      String fallbackMime) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: false, type: type);
    if (result == null || result.files.isEmpty) return null;
    final p = result.files.single.path;
    if (p == null) return null;
    final f = File(p);
    return MediaResult(
      file: f, contentType: contentType,
      mimeType: lookupMimeType(p) ?? fallbackMime,
      sizeBytes: await f.length(),
    );
  }

  /// Pick an image from the camera or gallery (mobile) or a file dialog (desktop).
  static Future<MediaResult?> pickImage({bool camera = false}) async {
    if (_isDesktop) return _pickDesktop(FileType.image, 'image', 'image/jpeg');
    final picker = ImagePicker();
    final XFile? xfile = camera
        ? await picker.pickImage(
            source:        ImageSource.camera,
            imageQuality:  80,
            maxWidth:      1920,
            maxHeight:     1080,
          )
        : await picker.pickImage(
            source:        ImageSource.gallery,
            imageQuality:  80,
            maxWidth:      1920,
            maxHeight:     1080,
          );

    if (xfile == null) return null;

    // Use xfile.readAsBytes() rather than File(xfile.path).readAsBytes().
    // On Android 12+ with scoped storage, image_picker may return a content
    // URI (content://media/picker/...) instead of a real file-system path.
    // File() cannot open content URIs directly, so file.readAsBytes() would
    // throw.  XFile.readAsBytes() routes through the platform channel and
    // handles content URIs correctly.
    final bytes = await xfile.readAsBytes();
    final size  = bytes.length;
    final mime  = lookupMimeType(xfile.path) ?? 'image/jpeg';

    // Write to a real temp file so that downstream File(path) usage
    // (fileToBase64, decryptedContent display, etc.) always succeeds.
    final dir     = await getTemporaryDirectory();
    final ext     = mime.contains('png') ? '.png' : '.jpg';
    final tmpFile = File(
        '${dir.path}/sov_img_${DateTime.now().millisecondsSinceEpoch}$ext');
    await tmpFile.writeAsBytes(bytes, flush: true);

    return MediaResult(
      file:        tmpFile,
      contentType: 'image',
      mimeType:    mime,
      sizeBytes:   size,
    );
  }

  // ── Video ─────────────────────────────────────────────────────────────────

  /// Pick a video from the camera or gallery.
  /// Thumbnail generation is skipped — a generic icon is shown instead.
  static Future<MediaResult?> pickVideo({bool camera = false}) async {
    if (_isDesktop) return _pickDesktop(FileType.video, 'video', 'video/mp4');
    final picker = ImagePicker();
    final XFile? xfile = camera
        ? await picker.pickVideo(
            source:      ImageSource.camera,
            maxDuration: const Duration(minutes: 10),
          )
        : await picker.pickVideo(source: ImageSource.gallery);

    if (xfile == null) return null;

    final ioFile = File(xfile.path);
    final size   = await ioFile.length();

    return MediaResult(
      file:        ioFile,
      contentType: 'video',
      mimeType:    'video/mp4',
      sizeBytes:   size,
      // thumbnailBase64 intentionally omitted — video_thumbnail not used
    );
  }

  // ── File ──────────────────────────────────────────────────────────────────

  /// Pick any file from the device storage.
  static Future<MediaResult?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type:          FileType.any,
    );

    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first;
    if (picked.path == null) return null;

    final ioFile = File(picked.path!);
    final size   = await ioFile.length();
    final mime   = lookupMimeType(picked.path!) ?? 'application/octet-stream';

    return MediaResult(
      file:        ioFile,
      contentType: 'file',
      mimeType:    mime,
      sizeBytes:   size,
    );
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Returns true if the file is small enough to route through the relay.
  static bool isRelayRoutable(int bytes) => bytes <= _maxRelayBytes;

  /// Format a byte count for human display.
  static String formatSize(int bytes) {
    if (bytes < 1024)            return '${bytes}B';
    if (bytes < 1024 * 1024)     return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  /// Encode a file to base64 for relay delivery.
  /// Only call this for files ≤ 25 MB (check [isRelayRoutable] first).
  static Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  /// Save received media (delivered as base64) to the local SOV Speak media
  /// directory and return the saved [File].
  static Future<File> saveReceivedMedia(
      String base64Data, String filename) async {
    try {
      final dir      = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${dir.path}/sov_speak_media');
      await mediaDir.create(recursive: true);
      final file  = File('${mediaDir.path}/$filename');
      final bytes = base64Decode(base64Data);
      await file.writeAsBytes(bytes);
      return file;
    } catch (e) {
      debugPrint('[MEDIA] saveReceivedMedia error: $e');
      rethrow;
    }
  }

  /// Return a suitable file extension for a MIME type.
  static String extensionForMime(String mimeType) {
    if (mimeType.contains('jpeg') || mimeType.contains('jpg')) return '.jpg';
    if (mimeType.contains('png'))  return '.png';
    if (mimeType.contains('gif'))  return '.gif';
    if (mimeType.contains('webp')) return '.webp';
    if (mimeType.contains('aac'))  return '.aac';
    if (mimeType.contains('mp3'))  return '.mp3';
    if (mimeType.contains('ogg'))  return '.ogg';
    if (mimeType.contains('mp4'))  return '.mp4';
    if (mimeType.contains('pdf'))  return '.pdf';
    return '';
  }
}
