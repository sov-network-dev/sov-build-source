// lib/sov_node_sdk/contacts_db.dart
// ─────────────────────────────────────────────────────────────────────────────
// Local SQLite store for SOV Speak contacts, conversations and messages.
//
// Architecture: message content NEVER leaves the sender device until the
// recipient is confirmed online. The relay stores only a watch-list entry —
// no message content, no sender identity.
//
// Tables:
//   contacts       — auto-saved from every successful interaction
//   conversations  — one row per unique participant, tracks last preview
//   messages       — full local message log (encrypted + decrypted content)
//   outbox         — messages queued for offline recipients
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'palm_name_engine.dart';
import 'sov_db_path.dart';

// ── Data models ──────────────────────────────────────────────────────────────

class Contact {
  final String sovereignId;
  final String nickname;
  final String? customLabel;
  final int firstContactAt;
  int lastContactAt;
  bool isFavourite;
  bool isBlocked;

  Contact({
    required this.sovereignId,
    required this.nickname,
    this.customLabel,
    required this.firstContactAt,
    required this.lastContactAt,
    this.isFavourite = false,
    this.isBlocked = false,
  });

  /// Best display name: custom_label → nickname → sovereignId
  /// Privacy model: names are local-only address book entries.
  /// No relay-synced names. No aliases. Sovereign ID is network identity.
  String get displayName => customLabel ?? nickname;

  Map<String, dynamic> toMap() => {
    'sovereign_id':    sovereignId,
    'nickname':        nickname,
    'custom_label':    customLabel,
    'first_contact_at': firstContactAt,
    'last_contact_at': lastContactAt,
    'is_favourite':    isFavourite ? 1 : 0,
    'is_blocked':      isBlocked   ? 1 : 0,
  };

  factory Contact.fromMap(Map<String, dynamic> m) => Contact(
    sovereignId:    m['sovereign_id']     as String,
    nickname:       m['nickname']         as String,
    customLabel:    m['custom_label']     as String?,
    firstContactAt: m['first_contact_at'] as int,
    lastContactAt:  m['last_contact_at']  as int,
    isFavourite:    (m['is_favourite'] as int? ?? 0) == 1,
    isBlocked:      (m['is_blocked']   as int? ?? 0) == 1,
  );
}

class LocalMessage {
  final String  id;
  final String  conversationId;
  final String  fromSovereignId;
  final String? toSovereignId;
  final String  contentType;
  final String  encryptedContent;
  String?       decryptedContent;
  String        status;
  final int     sentAt;
  int?          deliveredAt;
  int?          readAt;
  final String? replyToId;
  /// [S9] Emoji reactions — emoji → list of reactor sovereign IDs
  Map<String, List<String>> reactions;

  LocalMessage({
    required this.id,
    required this.conversationId,
    required this.fromSovereignId,
    this.toSovereignId,
    required this.contentType,
    required this.encryptedContent,
    this.decryptedContent,
    this.status = 'sending',
    required this.sentAt,
    this.deliveredAt,
    this.readAt,
    this.replyToId,
    Map<String, List<String>>? reactions,
  }) : reactions = reactions ?? {};

  /// Human-readable status for display under message bubble.
  ///
  /// Status lifecycle:
  ///   sending   → message is leaving the device right now
  ///   relayed   → relay accepted and forwarded to peer relay; delivery unconfirmed
  ///   delivered → relay confirmed the recipient's socket received it live
  ///   offline   → relay confirmed the recipient is not connected; message queued on relay
  ///   queued    → stored in device outbox (large file / timeout / no connection)
  ///   read      → recipient opened the message
  ///   failed    → permanent delivery failure
  ///
  /// NOTE: 'sent' is a legacy value kept for messages already stored in SQLite
  ///       from previous app versions.  It maps to 'Relayed' so old messages
  ///       stay readable without a DB migration.
  String get statusLabel {
    switch (status) {
      case 'sending':   return 'Sending…';
      case 'relayed':   return 'Sent';
      case 'sent':      return 'Sent';         // legacy — treated same as relayed
      case 'offline':   return 'Offline';
      case 'queued':    return 'Queued';
      case 'delivered': return 'Delivered';
      case 'read':      return 'Read';
      case 'failed':    return 'Failed';
      default:          return '';
    }
  }

  Map<String, dynamic> toMap() => {
    'id':                  id,
    'conversation_id':     conversationId,
    'from_sovereign_id':   fromSovereignId,
    'to_sovereign_id':     toSovereignId,
    'content_type':        contentType,
    'encrypted_content':   encryptedContent,
    'decrypted_content':   decryptedContent,
    'status':              status,
    'sent_at':             sentAt,
    'delivered_at':        deliveredAt,
    'read_at':             readAt,
    'reply_to_id':         replyToId,
    'reactions':           jsonEncode(reactions),
  };

  /// Parse the reactions JSON column: {"👍": ["SOV-A", "SOV-B"], ...}
  static Map<String, List<String>> _parseReactions(String? json) {
    if (json == null || json.isEmpty || json == '{}') return {};
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, List<String>.from(v as List)));
    } catch (_) { return {}; }
  }

  factory LocalMessage.fromMap(Map<String, dynamic> m) => LocalMessage(
    id:               m['id']                as String,
    conversationId:   m['conversation_id']   as String,
    fromSovereignId:  m['from_sovereign_id'] as String,
    toSovereignId:    m['to_sovereign_id']   as String?,
    contentType:      m['content_type']      as String,
    encryptedContent: m['encrypted_content'] as String,
    decryptedContent: m['decrypted_content'] as String?,
    status:           (m['status'] as String?) ?? 'sending',
    sentAt:           m['sent_at']            as int,
    deliveredAt:      m['delivered_at']       as int?,
    readAt:           m['read_at']            as int?,
    replyToId:        m['reply_to_id']        as String?,
    reactions:        LocalMessage._parseReactions(m['reactions'] as String?),
  );
}

class Conversation {
  final String  id;
  final String  participantId;
  final String? lastMessagePreview;
  final int?    lastMessageAt;
  int           unreadCount;

  Conversation({
    required this.id,
    required this.participantId,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount = 0,
  });

  factory Conversation.fromMap(Map<String, dynamic> m) => Conversation(
    id:                 m['id']                    as String,
    participantId:      m['participant_id']         as String,
    lastMessagePreview: m['last_message_preview']   as String?,
    lastMessageAt:      m['last_message_at']        as int?,
    unreadCount:        (m['unread_count'] as int?) ?? 0,
  );
}

// ── Database singleton ────────────────────────────────────────────────────────

class ContactsDb {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  /// Close the database singleton. Used before overwriting the file during restore.
  /// The next call to [db] will reopen the new file automatically.
  static Future<void> closeDb() async {
    await _db?.close();
    _db = null;
  }

  static Future<Database> _initDb() async {
    final dbPath = join(await sovDatabasesDir(), 'sov_contacts.db');
    return openDatabase(
      dbPath,
      version: 6,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE contacts ADD COLUMN is_blocked INTEGER DEFAULT 0');
        }
        if (oldVersion < 4) {
          // S4: relay-synced display name for each contact
          try {
            await db.execute(
              'ALTER TABLE contacts ADD COLUMN display_name TEXT DEFAULT \'\'');
          } catch (_) {} // column may already exist on fresh installs
        }
        if (oldVersion < 5) {
          // Dead column. The @handle registry was removed from the network: a
          // name a citizen picks is a name a citizen can leak, and SOV promises
          // to hold nothing that identifies you off the network. Nothing writes
          // or reads this any more.
          //
          // The migration itself stays. Version steps must remain contiguous or
          // a device upgrading from an older build lands on a schema the next
          // step does not expect. Removing a dead column is not worth breaking
          // every existing install for.
          try {
            await db.execute(
              'ALTER TABLE contacts ADD COLUMN alias TEXT DEFAULT \'\'');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          // S9: emoji reactions stored as JSON per message
          try {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN reactions TEXT DEFAULT \'{}\'');
          } catch (_) {}
        }
        if (oldVersion < 3) {
          // ── Deduplicate conversations ────────────────────────────────────
          // Old code could create multiple conversation rows per contact with
          // different IDs. Keep the most-recent row per participant_id and
          // re-point all messages from stale rows to it, then delete dupes.
          try {
            final allConvs = await db.rawQuery(
              'SELECT id, participant_id, last_message_at '
              'FROM conversations '
              'ORDER BY participant_id ASC, last_message_at DESC',
            );
            String? lastPid;
            String? keepId;
            for (final row in allConvs) {
              final pid = row['participant_id'] as String;
              final cid = row['id']             as String;
              if (pid != lastPid) {
                lastPid = pid;
                keepId  = cid; // first = most recent for this participant
              } else {
                // Duplicate — move its messages to the kept conversation
                await db.execute(
                  'UPDATE messages SET conversation_id = ? WHERE conversation_id = ?',
                  [keepId, cid],
                );
                await db.execute(
                  'DELETE FROM conversations WHERE id = ?', [cid]);
              }
            }
          } catch (_) {}
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            sovereign_id     TEXT PRIMARY KEY,
            nickname         TEXT NOT NULL,
            custom_label     TEXT,
            first_contact_at INTEGER NOT NULL,
            last_contact_at  INTEGER NOT NULL,
            is_favourite     INTEGER DEFAULT 0,
            is_blocked       INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE conversations (
            id                   TEXT PRIMARY KEY,
            participant_id       TEXT NOT NULL,
            last_message_preview TEXT,
            last_message_at      INTEGER,
            unread_count         INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE messages (
            id                TEXT PRIMARY KEY,
            conversation_id   TEXT NOT NULL,
            from_sovereign_id TEXT NOT NULL,
            to_sovereign_id   TEXT,
            content_type      TEXT NOT NULL,
            encrypted_content TEXT NOT NULL,
            decrypted_content TEXT,
            status            TEXT DEFAULT 'sending',
            sent_at           INTEGER NOT NULL,
            delivered_at      INTEGER,
            read_at           INTEGER,
            reply_to_id       TEXT,
            reactions         TEXT DEFAULT '{}'
          )
        ''');

        await db.execute('''
          CREATE TABLE outbox (
            id               TEXT PRIMARY KEY,
            to_sovereign_id  TEXT NOT NULL,
            encrypted_content TEXT NOT NULL,
            content_type     TEXT NOT NULL,
            queued_at        INTEGER NOT NULL,
            expires_at       INTEGER NOT NULL,
            retry_count      INTEGER DEFAULT 0,
            last_retry_at    INTEGER,
            status           TEXT DEFAULT 'queued'
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_msg_conv ON messages(conversation_id, sent_at)');
        await db.execute(
          'CREATE INDEX idx_outbox_to ON outbox(to_sovereign_id, status)');
      },
    );
  }

  // ── CONTACTS ──────────────────────────────────────────────────────────────

  /// Auto-save or refresh a contact after any successful interaction.
  static Future<void> recordInteraction({
    required String sovereignId,
    required String nickname,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await database.query(
      'contacts',
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (existing.isEmpty) {
      await database.insert('contacts', {
        'sovereign_id':    sovereignId,
        'nickname':        nickname,
        'first_contact_at': now,
        'last_contact_at': now,
      });
    } else {
      await database.update(
        'contacts',
        {'nickname': nickname, 'last_contact_at': now},
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
      );
    }
  }

  /// Returns non-blocked contacts. Pass [includeBlocked] = true to include all.
  static Future<List<Contact>> getContacts({
    String? query,
    bool includeBlocked = false,
  }) async {
    final database = await db;
    List<Map<String, dynamic>> rows;

    final blockedClause = includeBlocked ? '' : ' AND (is_blocked IS NULL OR is_blocked = 0)';

    if (query != null && query.isNotEmpty) {
      final q = '%$query%';
      rows = await database.query(
        'contacts',
        where: '(nickname LIKE ? OR custom_label LIKE ? OR sovereign_id LIKE ?)$blockedClause',
        whereArgs: [q, q, q],
        orderBy: 'is_favourite DESC, last_contact_at DESC',
      );
    } else {
      rows = await database.query(
        'contacts',
        where: includeBlocked ? null : '(is_blocked IS NULL OR is_blocked = 0)',
        orderBy: 'is_favourite DESC, last_contact_at DESC',
      );
    }
    return rows.map(Contact.fromMap).toList();
  }

  /// Returns only blocked contacts.
  static Future<List<Contact>> getBlockedContacts() async {
    final database = await db;
    final rows = await database.query(
      'contacts',
      where: 'is_blocked = 1',
      orderBy: 'last_contact_at DESC',
    );
    return rows.map(Contact.fromMap).toList();
  }

  static Future<void> blockContact(String sovereignId) async {
    final database = await db;
    await database.update(
      'contacts',
      {'is_blocked': 1, 'is_favourite': 0},
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
  }

  static Future<void> unblockContact(String sovereignId) async {
    final database = await db;
    await database.update(
      'contacts',
      {'is_blocked': 0},
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
  }

  static Future<bool> isContactBlocked(String sovereignId) async {
    final database = await db;
    final rows = await database.query(
      'contacts',
      columns: ['is_blocked'],
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (rows.isEmpty) return false;
    return (rows.first['is_blocked'] as int? ?? 0) == 1;
  }

  static Future<Contact?> getContact(String sovereignId) async {
    final database = await db;
    final rows = await database.query(
      'contacts',
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (rows.isEmpty) return null;
    return Contact.fromMap(rows.first);
  }

  static Future<void> updateContactLabel(
      String sovereignId, String? label) async {
    final database = await db;
    await database.update(
      'contacts',
      {'custom_label': label},
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
  }

  static Future<void> toggleFavourite(String sovereignId) async {
    final database = await db;
    final rows = await database.query(
      'contacts',
      columns: ['is_favourite'],
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (rows.isEmpty) return;
    final current = (rows.first['is_favourite'] as int? ?? 0);
    await database.update(
      'contacts',
      {'is_favourite': current == 1 ? 0 : 1},
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
  }

  static Future<void> removeContact(String sovereignId) async {
    final database = await db;
    await database.delete(
      'contacts', where: 'sovereign_id = ?', whereArgs: [sovereignId]);
  }

  /// Auto-add a contact on first interaction (incoming message OR outbound
  /// send) per `SOV_Network_Protocol_Book_v1.0` §17 line 741:
  ///   "When a citizen receives a message from an unknown Sovereign ID,
  ///    the app generates a deterministic human-readable nickname from
  ///    that ID..."
  ///
  /// Idempotent: if the contact already exists, only `last_contact_at`
  /// is updated. Citizens can rename later via [updateContactLabel].
  ///
  /// The deterministic nickname is produced by [PalmNameEngine.deriveName]
  /// — the same SHA-256-based adjective+noun pair used for relay nicknames.
  /// Two devices looking at the same SOV-ID will produce the same nickname.
  static Future<void> ensureContact(String sovereignId) async {
    if (sovereignId.isEmpty || !sovereignId.startsWith('SOV-')) return;
    // Never auto-add yourself.
    final selfId = (await SharedPreferences.getInstance())
        .getString('sovereign_id') ?? '';
    if (sovereignId == selfId) return;

    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await database.query(
      'contacts',
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (existing.isNotEmpty) {
      // Just bump last_contact_at; don't overwrite nickname or any user
      // customisation.
      await database.update(
        'contacts',
        {'last_contact_at': now},
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
      );
      return;
    }
    // First contact — derive deterministic nickname from the sovereign_id.
    final nickname = PalmNameEngine.deriveName([], sovereignId: sovereignId);
    await database.insert(
      'contacts',
      {
        'sovereign_id':     sovereignId,
        'nickname':         nickname,
        'custom_label':     null,
        'first_contact_at': now,
        'last_contact_at':  now,
        'is_favourite':     0,
        'is_blocked':       0,
      },
    );
  }

  // ── CONVERSATIONS ─────────────────────────────────────────────────────────

  static Future<List<Conversation>> getConversations() async {
    final database = await db;
    // Deduplicate by participant_id — return only the most-recent conversation
    // per contact so the list never shows the same person multiple times.
    // Exchange threads (xchg_) are excluded; they live in the Exchange screen.
    final rows = await database.rawQuery('''
      SELECT c.*
      FROM conversations c
      INNER JOIN (
        SELECT participant_id, MAX(last_message_at) AS max_at
        FROM conversations
        WHERE id NOT LIKE 'xchg_%'
        GROUP BY participant_id
      ) latest
        ON c.participant_id = latest.participant_id
       AND c.last_message_at = latest.max_at
      WHERE c.id NOT LIKE 'xchg_%'
      ORDER BY c.last_message_at DESC
    ''');
    return rows.map(Conversation.fromMap).toList();
  }

  static Future<void> upsertConversation({
    required String id,
    required String participantId,
    required String preview,
    required int lastMessageAt,
  }) async {
    final database = await db;
    // INSERT OR IGNORE creates the row with unread_count=0 only on first insert.
    // The subsequent UPDATE refreshes preview + timestamp without touching
    // unread_count, so banner badges and conversation counts are never reset.
    await database.rawInsert(
      'INSERT OR IGNORE INTO conversations '
      '(id, participant_id, last_message_preview, last_message_at, unread_count) '
      'VALUES (?, ?, ?, ?, 0)',
      [id, participantId, preview, lastMessageAt],
    );
    await database.rawUpdate(
      'UPDATE conversations '
      'SET participant_id = ?, last_message_preview = ?, last_message_at = ? '
      'WHERE id = ?',
      [participantId, preview, lastMessageAt, id],
    );
  }

  static Future<void> incrementUnread(String conversationId) async {
    final database = await db;
    await database.rawUpdate(
      'UPDATE conversations SET unread_count = unread_count + 1 WHERE id = ?',
      [conversationId],
    );
  }

  static Future<void> clearUnread(String conversationId) async {
    final database = await db;
    await database.update(
      'conversations',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  // ── MESSAGES ──────────────────────────────────────────────────────────────

  static Future<void> saveMessage(LocalMessage message) async {
    final database = await db;
    await database.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await upsertConversation(
      id:            message.conversationId,
      participantId: message.toSovereignId ?? message.fromSovereignId,
      preview:       message.decryptedContent ??
                     '[${message.contentType}]',
      lastMessageAt: message.sentAt,
    );
  }

  static Future<void> updateMessageStatus(
    String messageId,
    String status, {
    int? deliveredAt,
    int? readAt,
  }) async {
    final database = await db;
    final update = <String, dynamic>{'status': status};
    if (deliveredAt != null) update['delivered_at'] = deliveredAt;
    if (readAt      != null) update['read_at']      = readAt;
    await database.update(
      'messages', update,
      where: 'id = ?', whereArgs: [messageId],
    );
  }

  /// Persist a newly-decrypted plaintext for a message whose first delivery
  /// arrived before the sender's messaging key was available. Used by the
  /// re-decrypt retry so a "🔒 syncing…" placeholder resolves to real text.
  static Future<void> updateMessageDecrypted(
      String messageId, String decrypted) async {
    final database = await db;
    await database.update(
      'messages', {'decrypted_content': decrypted},
      where: 'id = ?', whereArgs: [messageId],
    );
  }

  /// [S9] Persist reactions JSON for a single message row.
  static Future<void> updateMessageReactions(
      String messageId, Map<String, List<String>> reactions) async {
    final database = await db;
    await database.update(
      'messages',
      {'reactions': jsonEncode(reactions)},
      where: 'id = ?', whereArgs: [messageId],
    );
  }

  static Future<List<LocalMessage>> getMessages(
      String conversationId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where:   'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'sent_at ASC',
    );
    return rows.map(LocalMessage.fromMap).toList();
  }

  // ── OUTBOX — messages queued locally for offline recipients ───────────────

  static Future<void> addToOutbox({
    required String messageId,
    required String toSovereignId,
    required String encryptedContent,
    required String contentType,
  }) async {
    final database = await db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.insert(
      'outbox',
      {
        'id':               messageId,
        'to_sovereign_id':  toSovereignId,
        'encrypted_content': encryptedContent,
        'content_type':     contentType,
        'queued_at':        now,
        'expires_at':       now + 7 * 24 * 3600 * 1000,
        'status':           'queued',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, dynamic>>> getOutboxForRecipient(
      String sovereignId) async {
    final database = await db;
    return database.query(
      'outbox',
      where:     'to_sovereign_id = ? AND status = ?',
      whereArgs: [sovereignId, 'queued'],
      orderBy:   'queued_at ASC',
    );
  }

  static Future<List<Map<String, dynamic>>> getAllOutboxQueued() async {
    final database = await db;
    return database.query(
      'outbox',
      where:   'status = ?',
      whereArgs: ['queued'],
      orderBy: 'queued_at ASC',
    );
  }

  static Future<void> updateOutboxContent(String messageId, String encryptedContent) async {
    final database = await db;
    await database.update(
      'outbox',
      {'encrypted_content': encryptedContent},
      where: 'id = ?', whereArgs: [messageId],
    );
  }

  static Future<void> markOutboxDelivered(String messageId) async {
    final database = await db;
    await database.update(
      'outbox',
      {'status': 'delivered'},
      where: 'id = ?', whereArgs: [messageId],
    );
  }

  static Future<void> removeFromOutbox(String messageId) async {
    final database = await db;
    await database.delete(
      'outbox', where: 'id = ?', whereArgs: [messageId]);
  }

  // ── BACKUP / RESTORE ──────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> exportAll() async {
    final contacts = await getContacts();
    return {
      'contacts':    contacts.map((c) => c.toMap()).toList(),
      'exported_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static Future<void> importAll(Map<String, dynamic> data) async {
    final database = await db;
    final contacts = data['contacts'] as List? ?? [];
    final batch = database.batch();
    for (final c in contacts) {
      batch.insert(
        'contacts',
        Map<String, dynamic>.from(c as Map),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }
}
