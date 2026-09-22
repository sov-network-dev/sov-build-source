// lib/screens/messages_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Messages Tab — three sub-tabs: SOV Speak · Contacts · SOV Enclave
//
// ARCHITECTURE (clean separation of concerns):
//
//   messages_screen   Owns the conversation LIST.
//                     Subscribes to incomingMessages broadcast stream.
//                     Reloads list and increments per-conversation unread count
//                     when a message arrives for a conversation that is NOT
//                     currently open in a thread.
//                     Does NOT save message content to the DB.
//                     Does NOT show message text.
//
//   main_shell        Saves every incoming message to ContactsDb.
//                     Shows banner notification.
//                     Manages the bottom-nav unread badge.
//
//   sov_link_screen   Thread view only.
//                     Appends incoming messages to the displayed list.
//                     Does NOT save to DB (main_shell already did).
//
// NAVIGATION:
//   Tap 1 — Messages tab → conversation list visible immediately.
//   Tap 2 — Conversation row → thread with message input visible immediately.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/message_events.dart';
import 'contacts_screen.dart';
import 'sov_link_screen.dart';
import 'group_channel_screen.dart';

class MessagesScreen extends StatefulWidget {
  final String sovereignId;
  const MessagesScreen({super.key, required this.sovereignId});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen>
    with SingleTickerProviderStateMixin {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  late TabController _tabCtrl;

  // SOV Speak — conversation list state
  List<Conversation>    _conversations = [];
  Map<String, Contact?> _contactCache  = {};

  // Palm name cache for display — filled asynchronously from relay.
  // Key = sovereign_id, value = resolved palm name (or empty if not yet fetched).
  // UI rebuilds via setState each time a new name arrives.
  final Map<String, String> _palmNames = {};

  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  StreamSubscription<void>?                 _sentSub;

  // Forum state — relay is the single source of truth.
  // The phone never decides locally whether the forum is active.
  // It always asks the relay and displays whatever it receives.
  bool   _enclaveActive  = false;
  bool   _forumLoading = false;
  List<Map<String, dynamic>> _enclavePosts = [];
  StreamSubscription<void>? _connectedSub;

  // Groups tab state
  List<Map<String, dynamic>> _groups        = [];
  bool                       _groupsLoading = false;
  StreamSubscription<Map<String, dynamic>>? _groupInviteSub;
  StreamSubscription<Map<String, dynamic>>? _groupMsgSub;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _tabCtrl.addListener(() {
      if (mounted) setState(() {});
      // Every time the user switches to the Forum tab, ask the relay fresh.
      if (_tabCtrl.index == 2 && !_forumLoading) _loadForum();
      // Every time user switches to Groups tab, reload group list.
      if (_tabCtrl.index == 3 && !_groupsLoading) _loadGroups();
    });
    _loadConversations();
    _incomingSub = RelayConnector.incomingMessages.listen(_onIncoming);
    _sentSub = MessageEvents.onConversationChanged.listen((_) {
      if (mounted) _loadConversations();
    });
    // Ask the relay for forum state every time we connect or reconnect.
    // This is the primary trigger — relay pushes truth, phone displays it.
    _connectedSub = RelayConnector.relayConnected.listen((_) {
      if (mounted) _loadForum();
    });
    // Also ask on startup in case we're already connected.
    _loadForum();
    _loadGroups();

    // Groups: reload list when invited to a new group or receive a group msg.
    _groupInviteSub = RelayConnector.groupInviteStream.listen((_) {
      if (mounted) _loadGroups();
    });
    _groupMsgSub = RelayConnector.groupMessageStream.listen((msg) {
      // Refresh the group list row to show latest message snippet.
      if (mounted) _loadGroups();
    });
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _sentSub?.cancel();
    _connectedSub?.cancel();
    _groupInviteSub?.cancel();
    _groupMsgSub?.cancel();
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Incoming message handler (list refresh) ─────────────────────────────────
  // Responsibility: refresh list + increment per-conversation unread count.
  // Does NOT save message content (main_shell does that).

  Future<void> _onIncoming(Map<String, dynamic> msg) async {
    final type = msg['type'] as String?;

    // ── SOV Speak live-push — insert new post/reply without full reload ────────
    if (type == 'ENCLAVE_NEW_POST') {
      final post = msg['post'] as Map<String, dynamic>?;
      if (post != null && mounted && _enclaveActive) {
        setState(() {
          // Only insert if not already in list (dedup by post_id)
          if (!_enclavePosts.any((p) => p['post_id'] == post['post_id'])) {
            _enclavePosts.insert(0, post);
          }
        });
        // Prefetch the author's palm name for this newly arrived post.
        final authorId = post['author_id'] as String? ?? '';
        if (authorId.isNotEmpty) _prefetchName(authorId);
      }
      return;
    }

    if (type == 'ENCLAVE_NEW_REPLY') {
      final reply = msg['reply'] as Map<String, dynamic>?;
      if (reply != null && mounted && _enclaveActive) {
        final postId = reply['post_id'] as String?;
        if (postId != null) {
          setState(() {
            final idx = _enclavePosts.indexWhere((p) => p['post_id'] == postId);
            if (idx >= 0) {
              final updated = Map<String, dynamic>.from(_enclavePosts[idx]);
              updated['reply_count'] =
                  ((updated['reply_count'] as num?)?.toInt() ?? 0) + 1;
              _enclavePosts[idx] = updated;
            }
          });
        }
      }
      return;
    }

    if (type != 'MESSAGE_INCOMING') return;

    final encryptedPayload = msg['encrypted_payload'] as String? ?? '';
    String fromId = '';
    try {
      final env = jsonDecode(encryptedPayload) as Map<String, dynamic>;
      fromId = env['from'] as String? ?? '';
    } catch (_) {}
    if (fromId.isEmpty) {
      fromId = msg['from_sovereign_id'] as String? ?? '';
    }
    if (fromId.isEmpty) return;

    // main_shell owns all DB writes (upsertConversation + incrementUnread).
    // Wait for main_shell to finish before querying so the row exists.
    await Future.delayed(const Duration(milliseconds: 250));

    if (mounted) _loadConversations();
  }

  // ── Conversation list ────────────────────────────────────────────────────────

  Future<void> _loadConversations() async {
    final convs  = await ContactsDb.getConversations();
    final cache  = <String, Contact?>{};
    for (final c in convs) {
      cache[c.participantId] = await ContactsDb.getContact(c.participantId);
    }
    if (mounted) setState(() { _conversations = convs; _contactCache = cache; });
    // Prefetch relay palm names for all conversation participants.
    for (final c in convs) {
      RelayConnector.prefetchPalmName(c.participantId, onResolved: () {
        if (mounted) { setState(() {
          _palmNames[c.participantId] =
              RelayConnector.cachedPalmNameFor(c.participantId);
        }); }
      });
    }
  }

  // ── Navigation to thread ─────────────────────────────────────────────────────

  void _openThread(String participantId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SovLinkScreen(
          mySovId:       widget.sovereignId,
          participantId: participantId,
        ),
      ),
    ).then((_) {
      // Refresh list when thread is closed so preview + unread count are current.
      _loadConversations();
    });
  }

  // ── New conversation sheet ───────────────────────────────────────────────────

  void _showNewConversationSheet() {
    final ctrl  = TextEditingController();
    final regex = RegExp(r'^SOV-[0-9A-F]{16}$');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Text('New Message',
                style: TextStyle(color: Colors.white,
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus:  true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white,
                  fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                hintText:  'SOV-XXXXXXXXXXXXXXXX',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                filled:    true,
                fillColor: _navy,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _gold, width: 1.5)),
              ),
            ),
            // Recent contacts list
            FutureBuilder<List<Contact>>(
              future: ContactsDb.getContacts(),
              builder: (ctx, snap) {
                if (!snap.hasData || snap.data!.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 4),
                      child: Text('Recent contacts',
                          style: TextStyle(color: Colors.white38, fontSize: 11)),
                    ),
                    ...snap.data!.take(5).map((c) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.displayName,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      subtitle: Text(_truncateId(c.sovereignId),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 10,
                              fontFamily: 'monospace')),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openThread(c.sovereignId);
                      },
                    )),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () {
                  final id = ctrl.text.trim().toUpperCase();
                  if (!regex.hasMatch(id)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:  Text('Enter a valid Sovereign ID: SOV-XXXXXXXXXXXXXXXX'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  _openThread(id);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Open Conversation',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _contactName(String participantId) {
    // System author — pre-seeded network topics
    if (participantId == 'SOV-ENCLAVE') return 'The Network';
    // 1. Relay-fetched palm name (best — human name from biometric)
    final palm = _palmNames[participantId] ??
        RelayConnector.cachedPalmNameFor(participantId);
    if (palm.isNotEmpty) return palm;
    // 2. Local contact label / nickname
    final c = _contactCache[participantId];
    if (c != null) return c.displayName;
    final nick = RelayConnector.getNickname(participantId);
    if (nick.isNotEmpty && nick != participantId) return nick;
    // 3. Truncated SOV-ID fallback
    return _truncateId(participantId);
  }

  /// Trigger palm name prefetch for [id] and call setState when it resolves.
  void _prefetchName(String id) {
    RelayConnector.prefetchPalmName(id, onResolved: () {
      if (mounted) { setState(() {
        _palmNames[id] = RelayConnector.cachedPalmNameFor(id);
      }); }
    });
  }

  String _truncateId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 12)}\u2026${id.substring(id.length - 6)}';
  }

  String _relativeTime(int? ms) {
    if (ms == null) return '';
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Messages',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor:        _gold,
          indicatorWeight:       2,
          labelColor:            _gold,
          unselectedLabelColor:  Colors.white38,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'SOV Speak'),
            Tab(text: 'Contacts'),
            Tab(text: 'SOV Enclave'),
            Tab(text: 'Groups'),
          ],
        ),
      ),
      // FAB — pencil on SOV Speak; compose on SOV Enclave (when active); group+ on Groups
      floatingActionButton: _tabCtrl.index == 0
          ? FloatingActionButton(
              heroTag: null,
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              onPressed: _showNewConversationSheet,
              child: const Icon(Icons.edit_rounded),
            )
          : (_tabCtrl.index == 2 && _enclaveActive)
              ? FloatingActionButton(
                  heroTag: null,
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  onPressed: _showNewPostSheet,
                  child: const Icon(Icons.add_rounded),
                )
              : _tabCtrl.index == 3
                  ? FloatingActionButton(
                      heroTag: null,
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      onPressed: _showNewGroupSheet,
                      child: const Icon(Icons.group_add_rounded),
                    )
                  : null,
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _buildSovSpeakTab(),
          ContactsScreen(sovereignId: widget.sovereignId),
          KeyedSubtree(
            key: const ValueKey('enclaveTab'),
            child: _buildForumTab(),
          ),
          _buildGroupsTab(),
        ],
      ),
    );
  }

  // ── SOV Speak tab ────────────────────────────────────────────────────────────

  Widget _buildSovSpeakTab() {
    if (_conversations.isEmpty) return _buildEmptyState();
    return ListView.builder(
      itemCount: _conversations.length,
      padding: const EdgeInsets.only(top: 8, bottom: 88),
      itemBuilder: (_, i) => _buildConversationTile(_conversations[i]),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76, height: 76,
              decoration: BoxDecoration(
                color:  _gold.withAlpha(18),
                shape:  BoxShape.circle,
                border: Border.all(color: _gold.withAlpha(50)),
              ),
              child: const Icon(Icons.forum_rounded, color: _gold, size: 36),
            ),
            const SizedBox(height: 20),
            const Text('No conversations yet',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Tap the pencil button to start\na secure conversation.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white38, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(Conversation conv) {
    final name      = _contactName(conv.participantId);
    final timeLabel = _relativeTime(conv.lastMessageAt);
    final unread    = conv.unreadCount;

    return InkWell(
      onTap: () => _openThread(conv.participantId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: Colors.white.withAlpha(8))),
        ),
        child: Row(
          children: [
            // Avatar circle with first letter
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color:  _teal.withAlpha(40),
                shape:  BoxShape.circle,
                border: Border.all(color: _teal.withAlpha(80)),
              ),
              child: Center(
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(
                      color: _teal, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: unread > 0
                                  ? FontWeight.bold
                                  : FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeLabel.isNotEmpty)
                        Text(timeLabel,
                            style: TextStyle(
                                color: unread > 0
                                    ? _gold
                                    : Colors.white38,
                                fontSize: 11,
                                fontWeight: unread > 0
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    conv.lastMessagePreview ?? '',
                    style: TextStyle(
                        color: unread > 0 ? Colors.white70 : Colors.white38,
                        fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Unread badge
            if (unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: const BoxDecoration(
                    color: _gold, shape: BoxShape.circle),
                child: Center(
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Groups ───────────────────────────────────────────────────────────────────

  Future<void> _loadGroups() async {
    if (_groupsLoading) return;
    if (mounted) setState(() => _groupsLoading = true);
    try {
      final groups = await RelayConnector.listGroups(widget.sovereignId);
      if (mounted) setState(() => _groups = groups);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _groupsLoading = false);
    }
  }

  void _showNewGroupSheet() {
    final nameCtrl    = TextEditingController();
    final memberCtrl  = TextEditingController();
    final members     = <String>[];
    bool  creating    = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx2).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('New Group',
                  style: TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 16),
              // Group name field
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Group name',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withAlpha(10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              // Member entry
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: memberCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13,
                        fontFamily: 'monospace'),
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'Add member SOV-XXXX…',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      filled: true,
                      fillColor: Colors.white.withAlpha(10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.person_add_outlined, color: _gold),
                  onPressed: () {
                    final id = memberCtrl.text.trim().toUpperCase();
                    final regex = RegExp(r'^SOV-[0-9A-F]{16}$');
                    if (!regex.hasMatch(id)) return;
                    if (!members.contains(id)) {
                      setSheet(() { members.add(id); memberCtrl.clear(); });
                    }
                  },
                ),
              ]),
              // Member chips
              if (members.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: members.map((m) => Chip(
                    backgroundColor: _teal.withAlpha(50),
                    label: Text(
                      '${m.substring(0, 8)}…',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    deleteIcon: const Icon(Icons.close, size: 14, color: Colors.white54),
                    onDeleted: () => setSheet(() => members.remove(m)),
                  )).toList(),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: creating ? null : () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    setSheet(() => creating = true);
                    try {
                      await RelayConnector.createGroup(
                        groupId:   'GRP-${DateTime.now().millisecondsSinceEpoch}',
                        name:      name,
                        createdBy: widget.sovereignId,
                        memberIds: members,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      _loadGroups();
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text('Failed: $e')));
                      }
                    } finally {
                      setSheet(() => creating = false);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                  child: creating
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : const Text('Create Group',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroupsTab() {
    if (_groupsLoading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadGroups,
        color: _gold,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(
                  children: [
                    Container(
                      width: 76, height: 76,
                      decoration: BoxDecoration(
                        color: _gold.withAlpha(18),
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold.withAlpha(50)),
                      ),
                      child: const Icon(Icons.group_rounded, color: _gold, size: 36),
                    ),
                    const SizedBox(height: 20),
                    const Text('No groups yet',
                        style: TextStyle(color: Colors.white,
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                      'Tap the + button to create\na group conversation.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadGroups,
      color: _gold,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 88),
        itemCount: _groups.length,
        itemBuilder: (_, i) => _buildGroupTile(_groups[i]),
      ),
    );
  }

  Widget _buildGroupTile(Map<String, dynamic> group) {
    final groupId     = group['group_id'] as String? ?? '';
    final name        = group['name'] as String? ?? 'Group';
    final memberCount = (group['member_count'] as num?)?.toInt() ?? 0;
    final lastMsg     = group['last_message'] as String? ?? '';
    final lastAt      = (group['last_message_at'] as num?)?.toInt();

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChannelScreen(
              sovereignId: widget.sovereignId,
              groupId:     groupId,
              groupName:   name,
              memberCount: memberCount,
            ),
          ),
        ).then((_) => _loadGroups());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white.withAlpha(8))),
        ),
        child: Row(
          children: [
            // Group avatar
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color: _gold.withAlpha(25),
                shape: BoxShape.circle,
                border: Border.all(color: _gold.withAlpha(70)),
              ),
              child: Center(
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : 'G',
                  style: const TextStyle(
                      color: _gold, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(color: Colors.white,
                              fontSize: 14, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (lastAt != null)
                      Text(_relativeTime(lastAt),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Icon(Icons.group_outlined, size: 12, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text('$memberCount member${memberCount == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    if (lastMsg.isNotEmpty) ...[
                      const Text('  ·  ',
                          style: TextStyle(color: Colors.white24, fontSize: 11)),
                      Expanded(
                        child: Text(lastMsg,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ]),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Forum ────────────────────────────────────────────────────────────────────

  Future<void> _loadForum() async {
    if (_forumLoading) return;
    if (mounted) setState(() => _forumLoading = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: { 'type': 'ENCLAVE_LIST', 'channel': 'general' },
        responseType: 'ENCLAVE_LIST_RESULT',
        timeout: const Duration(seconds: 8),
      );
      if (resp != null && mounted) {
        final posts = List<Map<String, dynamic>>.from(resp['posts'] ?? []);
        setState(() {
          _enclaveActive = resp['enclave_active'] == true;
          _enclavePosts  = posts;
        });
        // Prefetch palm names for all post authors so they show as real names.
        for (final p in posts) {
          final authorId = p['author_id'] as String? ?? '';
          if (authorId.isNotEmpty) _prefetchName(authorId);
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _forumLoading = false);
    }
  }

  void _showNewPostSheet() {
    final titleCtrl   = TextEditingController();
    final contentCtrl = TextEditingController();
    bool  posting     = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx2).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('New Enclave Post',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              const SizedBox(height: 16),
              TextField(
                controller: titleCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Title',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withAlpha(10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtrl,
                maxLines: 4,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'What\'s on your mind?',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.white.withAlpha(10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: posting ? null : () async {
                    final title   = titleCtrl.text.trim();
                    final content = contentCtrl.text.trim();
                    if (title.isEmpty || content.isEmpty) return;
                    setSheet(() => posting = true);
                    try {
                      final resp = await RelayConnector.sendAndWait(
                        request: {
                          'type':        'ENCLAVE_POST',
                          'sovereign_id': widget.sovereignId,
                          'channel':     'general',
                          'title':       title,
                          'content':     content,
                        },
                        responseType: 'ENCLAVE_POST_RESULT',
                        timeout: const Duration(seconds: 10),
                      );
                      if (resp?['success'] == true) {
                        if (ctx.mounted) Navigator.pop(ctx);
                        _loadForum();
                      } else {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(resp?['error'] ?? 'Post failed')));
                        }
                      }
                    } catch (_) {
                    } finally {
                      setSheet(() => posting = false);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                  child: posting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Text('Post',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForumTab() {
    if (_forumLoading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (!_enclaveActive) {
      // Pull-to-refresh works even on the locked state — relay is the authority.
      return RefreshIndicator(
        onRefresh: _loadForum,
        color: _gold,
        child: ListView(
          key: const ValueKey('enclaveLockedView'),
          children: [
            const SizedBox(height: 120),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 76, height: 76,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(8),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withAlpha(20)),
                      ),
                      child: const Icon(Icons.lock_outline_rounded,
                          color: Colors.white38, size: 34),
                    ),
                    const SizedBox(height: 20),
                    const Text('SOV Enclave',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    const Text(
                      'SOV Enclave is activated by citizen governance.\n'
                      'Visit the Constitution tab and vote to bring it live.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.55),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Only 2 citizens needed to activate.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _gold.withAlpha(200), fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: _loadForum,
                      icon: const Icon(Icons.refresh_rounded, size: 16, color: Colors.white38),
                      label: const Text('Pull down or tap to check relay',
                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_enclavePosts.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadForum,
        color: _gold,
        child: ListView(
          children: [
            const SizedBox(height: 100),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(
                  children: [
                    Container(
                      width: 76, height: 76,
                      decoration: BoxDecoration(
                        color: _gold.withAlpha(18),
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold.withAlpha(50)),
                      ),
                      child: const Icon(Icons.forum_rounded, color: _gold, size: 36),
                    ),
                    const SizedBox(height: 20),
                    const Text('SOV Enclave is live!',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text('No posts yet. Be the first citizen to open the Enclave.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white38, fontSize: 13, height: 1.5)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadForum,
      color: _gold,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
        itemCount: _enclavePosts.length,
        itemBuilder: (_, i) => _buildPostCard(_enclavePosts[i]),
      ),
    );
  }

  Widget _buildPostCard(Map<String, dynamic> post) {
    final title      = post['title'] as String? ?? '';
    final authorId   = post['author_id'] as String? ?? '';
    final replyCount = (post['reply_count'] as num?)?.toInt() ?? 0;
    final createdAt  = (post['created_at'] as num?)?.toInt();
    final timeLabel  = _relativeTime(createdAt);
    final authorName = _contactName(authorId);

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _ForumThreadPage(
              post:        post,
              mySovId:     widget.sovereignId,
              authorName:  authorName,
              onReplied:   _loadForum,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Row(children: [
              Container(
                width: 22, height: 22,
                decoration: BoxDecoration(
                    color: _teal.withAlpha(40),
                    shape: BoxShape.circle),
                child: Center(
                  child: Text(
                    authorName.isNotEmpty ? authorName[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: _teal, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(authorName,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ),
              if (timeLabel.isNotEmpty)
                Text(timeLabel,
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
            if (replyCount > 0) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.chat_bubble_outline_rounded,
                    color: Colors.white24, size: 13),
                const SizedBox(width: 4),
                Text('$replyCount ${replyCount == 1 ? 'reply' : 'replies'}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Forum Thread Page
// ─────────────────────────────────────────────────────────────────────────────
class _ForumThreadPage extends StatefulWidget {
  final Map<String, dynamic> post;
  final String               mySovId;
  final String               authorName;
  final VoidCallback         onReplied;

  const _ForumThreadPage({
    required this.post,
    required this.mySovId,
    required this.authorName,
    required this.onReplied,
  });

  @override
  State<_ForumThreadPage> createState() => _ForumThreadPageState();
}

class _ForumThreadPageState extends State<_ForumThreadPage> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  List<Map<String, dynamic>> _replies  = [];
  bool _loading   = true;
  bool _sending   = false;
  final _replyCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() => _loading = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: { 'type': 'ENCLAVE_GET', 'post_id': widget.post['post_id'] },
        responseType: 'ENCLAVE_REPLIES_RESULT',
        timeout: const Duration(seconds: 8),
      );
      if (resp != null && mounted) {
        setState(() {
          _replies = List<Map<String, dynamic>>.from(resp['replies'] ?? []);
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: {
          'type':         'ENCLAVE_REPLY',
          'sovereign_id': widget.mySovId,
          'post_id':      widget.post['post_id'],
          'content':      text,
        },
        responseType: 'ENCLAVE_REPLY_RESULT',
        timeout: const Duration(seconds: 10),
      );
      if (resp?['success'] == true) {
        _replyCtrl.clear();
        _loadReplies();
        widget.onReplied();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(resp?['error'] ?? 'Reply failed')));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _truncateId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 11)}…${id.substring(id.length - 5)}';
  }

  String _relTime(int? ms) {
    if (ms == null) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours   < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final title   = widget.post['title']   as String? ?? '';
    final content = widget.post['content'] as String? ?? '';
    final author  = widget.post['author_id'] as String? ?? '';
    final createdAt = (widget.post['created_at'] as num?)?.toInt();

    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _gold))
                : RefreshIndicator(
                    onRefresh: _loadReplies,
                    color: _gold,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      children: [
                        // Original post
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _cardBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _gold.withAlpha(50)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              Row(children: [
                                Container(
                                  width: 20, height: 20,
                                  decoration: BoxDecoration(
                                      color: _teal.withAlpha(40),
                                      shape: BoxShape.circle),
                                  child: Center(
                                    child: Text(
                                      widget.authorName.isNotEmpty
                                          ? widget.authorName[0].toUpperCase() : '?',
                                      style: const TextStyle(
                                          color: _teal, fontSize: 10,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    widget.authorName.isEmpty
                                        ? _truncateId(author) : widget.authorName,
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(_relTime(createdAt),
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 11)),
                              ]),
                              const SizedBox(height: 10),
                              const Divider(color: Colors.white12),
                              const SizedBox(height: 6),
                              Text(content,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                      height: 1.5)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (_replies.isEmpty)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('No replies yet. Start the conversation.',
                                  style: TextStyle(color: Colors.white38, fontSize: 13)),
                            ),
                          )
                        else ...[
                          Text('${_replies.length} ${_replies.length == 1 ? 'reply' : 'replies'}',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          ..._replies.map((r) {
                            final rAuthor = r['author_id'] as String? ?? '';
                            final rTime   = (r['created_at'] as num?)?.toInt();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: _cardBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white.withAlpha(8)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Container(
                                      width: 18, height: 18,
                                      decoration: BoxDecoration(
                                          color: _teal.withAlpha(30),
                                          shape: BoxShape.circle),
                                      child: Center(
                                        child: Text(
                                          rAuthor.length > 4 ? rAuthor[4].toUpperCase() : '?',
                                          style: const TextStyle(
                                              color: _teal, fontSize: 9,
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(_truncateId(rAuthor),
                                          style: const TextStyle(
                                              color: Colors.white54, fontSize: 11),
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                    Text(_relTime(rTime),
                                        style: const TextStyle(
                                            color: Colors.white38, fontSize: 10)),
                                  ]),
                                  const SizedBox(height: 8),
                                  Text(r['content'] as String? ?? '',
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          height: 1.4)),
                                ],
                              ),
                            );
                          }),
                        ],
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
          ),
          // Reply compose bar
          Container(
            color: _cardBg,
            padding: EdgeInsets.fromLTRB(
                12, 10, 12, MediaQuery.of(context).viewInsets.bottom + 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _replyCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Write a reply…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withAlpha(10),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendReply(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendReply,
                child: Container(
                  width: 42, height: 42,
                  decoration: const BoxDecoration(
                      color: _gold, shape: BoxShape.circle),
                  child: _sending
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2))
                      : const Icon(Icons.send_rounded,
                          color: Colors.black, size: 18),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
