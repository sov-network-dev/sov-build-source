// lib/screens/group_channel_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Group Channel Screen — SOV Speak multi-citizen chat room
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/material.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/secure_channels.dart';

class GroupChannelScreen extends StatefulWidget {
  final String sovereignId;
  final String groupId;
  final String groupName;
  final int    memberCount;

  const GroupChannelScreen({
    super.key,
    required this.sovereignId,
    required this.groupId,
    required this.groupName,
    required this.memberCount,
  });

  @override
  State<GroupChannelScreen> createState() => _GroupChannelScreenState();
}

class _GroupChannelScreenState extends State<GroupChannelScreen> {

  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  final _ctrl   = TextEditingController();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  bool   _loading  = true;
  bool   _sending  = false;
  String _error    = '';

  StreamSubscription<String>? _msgSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // Messages are kept on THIS device (SecureChannels) — the node keeps none. Reload
    // whenever this group's local copy changes (an arrival, or a send's final status).
    _msgSub = SecureChannels.changes.listen((conv) {
      if (conv == SecureChannels.groupConv(widget.groupId)) _loadHistory(quiet: true);
    });
  }

  Map<String, dynamic> _asBubble(LocalMessage m) => {
        'msg_id':    m.id,
        'group_id':  widget.groupId,
        'sender_id': m.fromSovereignId,
        'content':   m.decryptedContent ?? "🔒 Encrypted — waiting for the sender's key",
        'media_type': m.contentType,
        'ts':        m.sentAt,
        '_pending':  m.status == 'sending',
        '_queued':   m.status == 'queued' || m.status == 'partial',
        '_error':    m.status == 'failed',
      };

  @override
  void dispose() {
    _msgSub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory({bool quiet = false}) async {
    if (!quiet) setState(() { _loading = true; _error = ''; });
    try {
      final msgs = await SecureChannels.groupHistory(widget.groupId);
      if (!mounted) return;
      setState(() {
        _messages = msgs.map(_asBubble).toList();
        _loading  = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not load messages'; });
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() { _sending = true; });
    _ctrl.clear();
    try {
      final m = await SecureChannels.sendGroup(groupId: widget.groupId, text: text);
      if (!mounted) return;
      if (m.status == 'failed') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(SecureChannels.lastError == 'GROUP_PLAINTEXT_REFUSED'
              ? 'The network refused an unencrypted message.'
              : 'Not sent: ${SecureChannels.lastError}'),
          backgroundColor: Colors.red[800]));
      } else if (m.status != 'delivered') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Kept on this phone for members who are offline — '
              'it is delivered when they come online.'),
          duration: Duration(seconds: 3), backgroundColor: Color(0xFF1A4A2A)));
      }
    } finally {
      if (mounted) setState(() { _sending = false; });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve:    Curves.easeOut,
        );
      }
    });
  }

  bool _isOwnMessage(Map<String, dynamic> msg) =>
      (msg['sender_id'] as String?) == widget.sovereignId;

  String _shortenId(String id) =>
      id.length > 8 ? '${id.substring(0, 4)}…${id.substring(id.length - 4)}' : id;

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts as int);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ── Add member dialog ───────────────────────────────────────────────────
  Future<void> _showAddMemberDialog() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _navy,
        title: const Text('Add Member', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'SOV-XXXX…',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add', style: TextStyle(color: Color(0xFFB8960C))),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      await RelayConnector.addGroupMember(
        groupId:     widget.groupId,
        newMemberId: result.toUpperCase(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Member added'), backgroundColor: Color(0xFF006B5E)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red[800]),
        );
      }
    }
  }

  Future<void> _confirmLeave() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _navy,
        title: const Text('Leave Group?', style: TextStyle(color: Colors.white)),
        content: Text(
          'You will leave "${widget.groupName}" and no longer receive messages.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await RelayConnector.leaveGroup(widget.groupId);
    if (mounted) Navigator.pop(context);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.groupName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('${widget.memberCount} members', style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined, color: Colors.white70),
            tooltip: 'Add member',
            onPressed: _showAddMemberDialog,
          ),
          PopupMenuButton<String>(
            color: _cardBg,
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            onSelected: (v) {
              if (v == 'leave') _confirmLeave();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'leave', child: Text('Leave group', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Message list ────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFB8960C)))
                : _error.isNotEmpty
                    ? Center(child: Text(_error, style: const TextStyle(color: Colors.white54)))
                    : _messages.isEmpty
                        ? const Center(
                            child: Text(
                              'No messages yet.\nSay hello to the group!',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white38, height: 1.5),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) => _buildBubble(_messages[i]),
                          ),
          ),
          // ── Compose bar ─────────────────────────────────────────────────
          _buildComposeBar(),
        ],
      ),
    );
  }

  Widget _buildBubble(Map<String, dynamic> msg) {
    final own     = _isOwnMessage(msg);
    final content = (msg['content'] as String?) ?? '';
    final sender  = (msg['sender_id'] as String?) ?? '';
    final pending = msg['_pending'] as bool? ?? false;
    final queued  = msg['_queued']  as bool? ?? false;
    final hasErr  = msg['_error']   as bool? ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: own ? _teal : _cardBg,
              borderRadius: BorderRadius.circular(12).copyWith(
                bottomRight: own   ? const Radius.circular(2) : null,
                bottomLeft:  !own  ? const Radius.circular(2) : null,
              ),
            ),
            child: Column(
              crossAxisAlignment: own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!own)
                  Text(
                    _shortenId(sender),
                    style: const TextStyle(
                      color:    _gold,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (!own) const SizedBox(height: 2),
                Text(content, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4)),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(msg['ts']),
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                    if (own) ...[
                      const SizedBox(width: 4),
                      Icon(
                        hasErr  ? Icons.error_outline
                        : pending ? Icons.access_time
                        : queued  ? Icons.schedule_send_outlined
                        : Icons.done,
                        size: 12,
                        color: hasErr ? Colors.red[300] : Colors.white38,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildComposeBar() {
    return Container(
      color: _cardBg,
      padding: EdgeInsets.only(
        left: 12, right: 8,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: const TextStyle(color: Colors.white),
              maxLines:  null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText:  'Message ${widget.groupName}…',
                hintStyle: const TextStyle(color: Colors.white38),
                border:    InputBorder.none,
                isDense:   true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          _sending
              ? const SizedBox(
                  width: 36, height: 36,
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFB8960C)),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.send_rounded),
                  color: _gold,
                  onPressed: _send,
                ),
        ],
      ),
    );
  }
}
