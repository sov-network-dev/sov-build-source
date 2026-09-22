// lib/screens/group_channel_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Group Channel Screen — SOV Speak multi-citizen chat room
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';

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

  StreamSubscription<Map<String, dynamic>>? _msgSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();

    // Live-push: new group message arrives
    _msgSub = RelayConnector.groupMessageStream.listen((msg) {
      if (!mounted) return;
      if ((msg['group_id'] as String?) != widget.groupId) return;
      final msgId = msg['msg_id'] as String? ?? '';
      // Dedup: check if already present
      final exists = _messages.any((m) => m['msg_id'] == msgId);
      if (!exists) {
        setState(() {
          _messages.add(msg);
        });
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final msgs = await RelayConnector.getGroupHistory(widget.groupId);
      // History is newest-first; reverse to show oldest-first in the list
      if (!mounted) return;
      setState(() {
        _messages = msgs.reversed.toList();
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

    final msgId = 'GM-${DateTime.now().millisecondsSinceEpoch}-${widget.sovereignId.substring(4, 8)}';
    final optimistic = {
      'msg_id':    msgId,
      'group_id':  widget.groupId,
      'sender_id': widget.sovereignId,
      'content':   text,
      'media_type':'text',
      'ts':        DateTime.now().millisecondsSinceEpoch,
      '_pending':  true,
    };
    setState(() { _messages.add(optimistic); });
    _scrollToBottom();

    try {
      final result = await RelayConnector.sendGroupMessage(
        msgId:    msgId,
        groupId:  widget.groupId,
        content:  text,
      );
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m['msg_id'] == msgId);
        if (idx >= 0) {
          _messages[idx] = {
            ...optimistic,
            '_pending': false,
            '_status': (result?['status'] as String? ?? 'sent'),
          };
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m['msg_id'] == msgId);
        if (idx >= 0) _messages[idx] = {...optimistic, '_error': true};
      });
    } finally {
      if (mounted) setState(() { _sending = false; });
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
