// document_viewer_screen.dart — documents open INSIDE SOV (owner, 2026-10-08), so a file received
// end to end is never handed to another app just to be read.
//   PDF                      -> pdfrx (PDFium), zoom + page through, read-only
//   .txt .csv .md .json .log -> view + EDIT; CSV shows as a table, Markdown rendered
//   .docx                    -> docx_document.dart (text, headings, bold/italic, tables); edit as text
// An edited copy is saved next to the original and can be sent back to the chat (end to end, as
// any file). "Open in another app" stays available from the chat for anything else.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pdfrx/pdfrx.dart';

import '../sov_node_sdk/docx_document.dart';

const _navy = Color(0xFF0A1628);
const _gold = Color(0xFFD4AF37);

enum DocKind { pdf, text, csv, markdown, docx, unsupported }

DocKind docKindFor(String path) {
  final ext = path.toLowerCase().split('.').last;
  switch (ext) {
    case 'pdf': return DocKind.pdf;
    case 'csv': return DocKind.csv;
    case 'md': case 'markdown': return DocKind.markdown;
    case 'txt': case 'json': case 'log': case 'xml': case 'yaml': case 'yml': return DocKind.text;
    case 'docx': return DocKind.docx;
    default: return DocKind.unsupported;
  }
}

class DocumentViewerScreen extends StatefulWidget {
  final String path;
  /// Called with the path of an edited copy when the user taps "Send edited copy".
  final Future<void> Function(String editedPath)? onSendEdited;
  const DocumentViewerScreen({super.key, required this.path, this.onSendEdited});

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late final DocKind _kind = docKindFor(widget.path);
  String? _text;                 // text-like formats and the plain text of a .docx
  DocxContent? _docx;
  bool _editing = false;
  late final TextEditingController _edit = TextEditingController();
  String? _error;

  String get _name => widget.path.split(RegExp(r'[\\/]')).last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (_kind == DocKind.docx) {
        final d = await DocxDocument.read(File(widget.path));
        setState(() { _docx = d; _text = d.plainText; _edit.text = d.plainText; });
      } else if (_kind == DocKind.text || _kind == DocKind.csv || _kind == DocKind.markdown) {
        final t = await File(widget.path).readAsString();
        setState(() { _text = t; _edit.text = t; });
      }
    } catch (e) {
      setState(() => _error = 'This file could not be read: $e');
    }
  }

  @override
  void dispose() { _edit.dispose(); super.dispose(); }

  Future<String> _saveCopy() async {
    final dot = _name.lastIndexOf('.');
    final stem = dot > 0 ? _name.substring(0, dot) : _name;
    final ext = dot > 0 ? _name.substring(dot) : '';
    final dir = File(widget.path).parent.path;
    var out = File('$dir${Platform.pathSeparator}$stem (edited)$ext');
    for (var i = 2; out.existsSync(); i++) {
      out = File('$dir${Platform.pathSeparator}$stem (edited $i)$ext');
    }
    if (_kind == DocKind.docx) {
      await DocxDocument.writeFromText(out, _edit.text);
    } else {
      await out.writeAsString(_edit.text, flush: true);
    }
    return out.path;
  }

  bool get _canEdit => _kind == DocKind.text || _kind == DocKind.csv ||
      _kind == DocKind.markdown || _kind == DocKind.docx;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_canEdit && _error == null)
            IconButton(
              tooltip: _editing ? 'View' : 'Edit',
              icon: Icon(_editing ? Icons.visibility : Icons.edit, color: _gold),
              onPressed: () => setState(() => _editing = !_editing),
            ),
          if (_editing)
            IconButton(
              tooltip: 'Save a copy',
              icon: const Icon(Icons.save, color: _gold),
              onPressed: () async {
                final p = await _saveCopy();
                if (!context.mounted) return;
                final send = widget.onSendEdited;
                final again = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: _navy,
                    title: const Text('Saved', style: TextStyle(color: _gold)),
                    content: Text('Saved as ${p.split(RegExp(r'[\\/]')).last}.',
                        style: const TextStyle(color: Colors.white70)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Done')),
                      if (send != null)
                        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send edited copy')),
                    ],
                  ),
                );
                if (again == true && send != null) {
                  await send(p);
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.white70))));
    }
    if (_kind == DocKind.unsupported) {
      return const Center(child: Text('No built-in viewer for this file type.\nUse "Open in another app".',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)));
    }
    if (_kind == DocKind.pdf) {
      return Container(color: Colors.white, child: PdfViewer.file(widget.path));
    }
    if (_text == null) return const Center(child: CircularProgressIndicator(color: _gold));
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _edit, maxLines: null, expands: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14),
          decoration: InputDecoration(
            filled: true, fillColor: Colors.white.withAlpha(12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            helperText: _kind == DocKind.docx ? 'Editing the text. Formatting is simplified in the saved copy.' : null,
            helperStyle: const TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    switch (_kind) {
      case DocKind.markdown:
        return Markdown(data: _text!, styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context).copyWith(
            textTheme: Theme.of(context).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white))));
      case DocKind.csv:
        return _csvTable(_text!);
      case DocKind.docx:
        return DocxView(content: _docx!);
      default:
        return SingleChildScrollView(padding: const EdgeInsets.all(16),
            child: SelectableText(_text!, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14)));
    }
  }

  Widget _csvTable(String csv) {
    final rows = parseCsv(csv);
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: Colors.white24),
          children: [
            for (var i = 0; i < rows.length; i++)
              TableRow(
                decoration: BoxDecoration(color: i == 0 ? _gold.withAlpha(40) : null),
                children: [
                  for (var c = 0; c < cols; c++)
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(c < rows[i].length ? rows[i][c] : '',
                            style: TextStyle(color: Colors.white, fontWeight: i == 0 ? FontWeight.bold : FontWeight.normal))),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// RFC 4180 CSV: quoted fields, doubled quotes, commas and newlines inside quotes.
List<List<String>> parseCsv(String s) {
  final rows = <List<String>>[]; var row = <String>[]; final f = StringBuffer();
  var q = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (q) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') { f.write('"'); i++; } else { q = false; }
      } else { f.write(ch); }
    } else if (ch == '"') { q = true; }
    else if (ch == ',') { row.add(f.toString()); f.clear(); }
    else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      row.add(f.toString()); f.clear(); rows.add(row); row = <String>[];
    } else { f.write(ch); }
  }
  if (f.isNotEmpty || row.isNotEmpty) { row.add(f.toString()); rows.add(row); }
  return rows.where((r) => !(r.length == 1 && r[0].isEmpty)).toList();
}
