// lib/sov_node_sdk/sov_db_path.dart
// Stable, per-user database directory for all SOV local SQLite stores.
//
// WHY: on desktop, sqflite_common_ffi's getDatabasesPath() defaults to
// `.dart_tool/sqflite_common_ffi/databases` RELATIVE TO THE WORKING DIRECTORY.
// For the single-file portable that working directory is the per-build extract
// folder (%LOCALAPPDATA%\SovNode\<build_id>\), so every update would land the
// wallet/contacts/message databases in a NEW folder and the old data would be
// orphaned (apparent data loss on every update), sitting in an unprotected,
// non-standard location.
//
// FIX: anchor all databases to getApplicationSupportDirectory() — the SAME
// stable location flutter_secure_storage + SharedPreferences already use
// (%APPDATA%\Roaming\network.sov\SOV Node\databases on Windows). Data then
// persists across updates and lives beside the other protected user data.
//
// Mobile (Android/iOS) keeps its platform default, which is already a stable
// app-private path.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

/// Returns the directory SOV SQLite databases should live in. Stable across
/// app updates on every platform. Creates the directory if needed (desktop).
Future<String> sovDatabasesDir() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final support = await getApplicationSupportDirectory(); // %APPDATA%\...\SOV Node
    final dir = Directory(p.join(support.path, 'databases'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
  // Android/iOS: the default is already an app-private, stable location.
  return getDatabasesPath();
}
