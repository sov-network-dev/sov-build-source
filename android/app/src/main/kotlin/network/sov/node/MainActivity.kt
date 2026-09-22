package network.sov.node

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val FILE_CHANNEL       = "network.sov.node/file_intent"
        private const val REQUEST_FILE_PICK  = 1001
    }

    // Native holding cell for file bytes.
    // Populated in onCreate (Open With cold start), onNewIntent (Open With
    // mid-session), and onActivityResult (in-app file picker — survives
    // process death because Android preserves the Activity result protocol).
    // Cleared when Dart calls getPendingFile().
    private var pendingFileBytes: ByteArray? = null

    // ── Activity lifecycle ────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        extractAndCache(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractAndCache(intent)
    }

    // Called after the native file picker returns — even when the process was
    // killed while the picker was open. Android recreates the Activity and
    // delivers the result here before onResume, so the bytes are ready when
    // the Flutter splash calls getPendingFile().
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data) // let Flutter plugins handle theirs
        if (requestCode == REQUEST_FILE_PICK && resultCode == Activity.RESULT_OK) {
            val uri = data?.data ?: return
            val bytes = readUri(uri)
            if (bytes != null) {
                android.util.Log.d("SOVNode", "onActivityResult: cached ${bytes.size} bytes")
                pendingFileBytes = bytes
            }
        }
    }

    // ── FlutterEngine config ──────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(SimInfoPlugin())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    // Dart polls for bytes — one-shot, clears after delivery
                    "getPendingFile" -> {
                        val bytes = pendingFileBytes
                        pendingFileBytes = null
                        result.success(bytes) // null if nothing pending
                    }

                    // Dart asks us to open the native file picker.
                    // We do it here in Kotlin so the result comes back via
                    // onActivityResult (native protocol) — survives LMK kill.
                    "openFilePicker" -> {
                        launchNativeFilePicker()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Launch the system file picker using the native Activity result protocol. */
    private fun launchNativeFilePicker() {
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "*/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            // Hint MIME types — file managers may ignore these but it nudges
            // them to surface relevant files
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/octet-stream", "application/json", "text/plain", "*/*")
            )
        }
        startActivityForResult(intent, REQUEST_FILE_PICK)
    }

    /** Extract and cache bytes from an ACTION_VIEW / ACTION_SEND intent, then
     *  neutralize the intent so Android cannot re-deliver stale data. */
    private fun extractAndCache(intent: Intent?) {
        val bytes = extractBytesFromIntent(intent) ?: return
        pendingFileBytes = bytes
        // Neutralize — prevents re-trigger on configuration changes (rotation)
        intent?.data = null
        intent?.removeExtra(Intent.EXTRA_STREAM)
        intent?.action = Intent.ACTION_MAIN
    }

    private fun extractBytesFromIntent(intent: Intent?): ByteArray? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> null
        }
        return uri?.let { readUri(it) }
    }

    /** Opens a ContentResolver stream and reads all bytes. Call while the URI
     *  permission grant is still active (i.e. inside onCreate/onNewIntent/onActivityResult). */
    private fun readUri(uri: Uri): ByteArray? {
        return try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            android.util.Log.e("SOVNode", "readUri failed: $e")
            null
        }
    }
}
