// docx_document.dart — Word .docx read + simple write, entirely inside SOV (v1.2.27).
//
// Parser and view drafted by Gemini (docs/security/GEMINI_DOCX_RESPONSE_2026-10-08.txt) and reviewed;
// the ZIP reader is our own because the draft trusted the sizes a file DECLARES: a forged header
// would still inflate everything into memory. Here an entry is inflated in streamed chunks and
// reading stops the moment the real output passes the cap, whatever the header says.
// A received file may come from a stranger, so every limit below is a refusal, never a hang.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

class DocxContent {
  final List<DocxBlock> blocks;
  DocxContent(this.blocks);
  String get plainText => blocks.map((b) => b.plainText).join('\n');
}

sealed class DocxBlock {
  String get plainText;
}

class DocxParagraph extends DocxBlock {
  final List<DocxRun> runs;
  final int headingLevel; // 0 = body, 1..6
  final bool isListItem;
  DocxParagraph({required this.runs, required this.headingLevel, required this.isListItem});
  @override
  String get plainText => runs.map((r) => r.text).join();
}

class DocxRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  DocxRun({required this.text, required this.bold, required this.italic, required this.underline});
}

class DocxTable extends DocxBlock {
  final List<List<String>> rows;
  DocxTable({required this.rows});
  @override
  String get plainText => rows.map((r) => r.join('\t')).join('\n');
}

class DocxDocument {
  static const int _maxFileBytes = 60 * 1024 * 1024;     // the .docx itself
  static const int _maxTotalBytes = 50 * 1024 * 1024;    // declared uncompressed total
  static const int _maxEntries = 2000;
  static const int _maxXmlBytes = 20 * 1024 * 1024;      // document.xml, enforced on REAL output

  static Future<DocxContent> read(File file) async {
    final len = await file.length();
    if (len > _maxFileBytes) throw const FormatException('This document is too large to open.');
    final bytes = await file.readAsBytes();
    final xmlBytes = _readZipEntry(bytes, 'word/document.xml');
    final xmlString = utf8.decode(xmlBytes, allowMalformed: true);
    // No DTDs or entities, ever (XXE / billion laughs). Word never writes them.
    if (xmlString.contains('<!DOCTYPE') || xmlString.contains('<!ENTITY')) {
      throw const FormatException('This document contains XML features SOV does not open.');
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlString);
    } catch (_) {
      throw const FormatException('This document is damaged.');
    }
    final body = doc.findAllElements('w:body').firstOrNull;
    if (body == null) throw const FormatException('This is not a Word document.');
    final blocks = <DocxBlock>[];
    void addBodyChildren(XmlElement parent) {
      for (final child in parent.childElements) {
        final loc = child.name.local;
        if (loc == 'p') {
          blocks.add(_parseParagraph(child));
        } else if (loc == 'tbl') {
          blocks.add(_parseTable(child));
        } else if (loc == 'sdt' || loc == 'sdtContent') {
          addBodyChildren(child); // content controls wrap ordinary paragraphs
        }
      }
    }
    addBodyChildren(body);
    return DocxContent(blocks);
  }

  /// Writes a minimal valid .docx: one paragraph per line, tabs kept, invalid XML characters dropped.
  static Future<void> writeFromText(File out, String text) async {
    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';
    const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';
    const docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>';

    final sb = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n')
      ..write('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>');
    for (final rawLine in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final line = rawLine.replaceAll(_invalidXmlChars, '');
      sb.write('<w:p><w:r>');
      final parts = line.split('\t');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) sb.write('<w:tab/>');
        if (parts[i].isNotEmpty) sb.write('<w:t xml:space="preserve">${_escapeXml(parts[i])}</w:t>');
      }
      sb.write('</w:r></w:p>');
    }
    sb.write('<w:sectPr/></w:body></w:document>');

    final archive = Archive()
      ..addFile(ArchiveFile.bytes('[Content_Types].xml', utf8.encode(contentTypes)))
      ..addFile(ArchiveFile.bytes('_rels/.rels', utf8.encode(rels)))
      ..addFile(ArchiveFile.bytes('word/_rels/document.xml.rels', utf8.encode(docRels)))
      ..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(sb.toString())));
    await out.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  }

  static final RegExp _invalidXmlChars = RegExp('[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]');

  // ── Bounded ZIP reader ────────────────────────────────────────────────────────────────────
  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static Uint8List _readZipEntry(Uint8List b, String wanted) {
    const bad = FormatException('This is not a valid Word document.');
    // End of central directory: within the last 22 + 65535 bytes.
    var eocd = -1;
    for (var i = b.length - 22; i >= 0 && i >= b.length - 22 - 65535; i--) {
      if (_u32(b, i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw bad;
    final count = _u16(b, eocd + 10);
    final cdOffset = _u32(b, eocd + 16);
    if (count == 0xFFFF || cdOffset == 0xFFFFFFFF) throw bad; // ZIP64: never needed for a document
    if (count > _maxEntries) throw const FormatException('This document has too many parts.');
    var p = cdOffset, total = 0;
    int? method, compSize, local;
    for (var n = 0; n < count; n++) {
      if (p + 46 > b.length || _u32(b, p) != 0x02014b50) throw bad;
      final m = _u16(b, p + 10), cs = _u32(b, p + 20), us = _u32(b, p + 24);
      final nl = _u16(b, p + 28), el = _u16(b, p + 30), cl = _u16(b, p + 32), lo = _u32(b, p + 42);
      if (p + 46 + nl > b.length) throw bad;
      total += us;
      if (total > _maxTotalBytes) throw const FormatException('This document is too large to open.');
      final name = utf8.decode(b.sublist(p + 46, p + 46 + nl), allowMalformed: true);
      if (name == wanted) { method = m; compSize = cs; local = lo; }
      p += 46 + nl + el + cl;
    }
    if (local == null || method == null || compSize == null) throw bad;
    if (local + 30 > b.length || _u32(b, local) != 0x04034b50) throw bad;
    final start = local + 30 + _u16(b, local + 26) + _u16(b, local + 28);
    if (start + compSize > b.length) throw bad;
    final data = Uint8List.sublistView(b, start, start + compSize);
    if (method == 0) {
      if (data.length > _maxXmlBytes) throw const FormatException('This document is too large to open.');
      return Uint8List.fromList(data);
    }
    if (method != 8) throw bad;
    // Inflate in chunks, counting REAL output, and stop at the cap.
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final out = BytesBuilder(copy: false);
    void drain({required bool end}) {
      List<int>? chunk;
      while ((chunk = filter.processed(flush: end, end: end)) != null) {
        out.add(chunk!);
        if (out.length > _maxXmlBytes) throw const FormatException('This document is too large to open.');
      }
    }
    const step = 64 * 1024;
    try {
      for (var o = 0; o < data.length; o += step) {
        filter.process(data, o, o + step > data.length ? data.length : o + step);
        drain(end: false);
      }
      drain(end: true);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('This document is damaged.');
    }
    return out.takeBytes();
  }

  // ── Parser (from the reviewed draft) ─────────────────────────────────────────────────────
  static DocxParagraph _parseParagraph(XmlElement p) {
    var headingLevel = 0;
    var isListItem = false;
    final pPr = p.childElements.where((e) => e.name.local == 'pPr').firstOrNull;
    if (pPr != null) {
      isListItem = pPr.childElements.any((e) => e.name.local == 'numPr');
      final pStyle = pPr.childElements.where((e) => e.name.local == 'pStyle').firstOrNull;
      if (pStyle != null) {
        final val = (_getAttr(pStyle, 'val') ?? '').toLowerCase();
        // Lists are often a STYLE (ListBullet, ListNumber) rather than inline numbering.
        if (val.startsWith('list')) isListItem = true;
        if (val == 'title') {
          headingLevel = 1;
        } else if (val.startsWith('heading')) {
          final digit = int.tryParse(val.replaceAll(RegExp(r'\D'), ''));
          if (digit != null && digit >= 1 && digit <= 6) headingLevel = digit;
        }
      }
    }
    final runs = <DocxRun>[];
    void walk(XmlElement node) {
      final loc = node.name.local;
      if (loc == 'del' || loc == 'pPr') return;
      if (loc == 'r') {
        final r = _parseRun(node);
        if (r != null) runs.add(r);
        return;
      }
      for (final child in node.childElements) {
        walk(child);
      }
    }
    walk(p);
    return DocxParagraph(runs: runs, headingLevel: headingLevel, isListItem: isListItem);
  }

  static DocxRun? _parseRun(XmlElement rNode) {
    final rPr = rNode.childElements.where((e) => e.name.local == 'rPr').firstOrNull;
    final sb = StringBuffer();
    for (final child in rNode.childElements) {
      switch (child.name.local) {
        case 't': sb.write(child.innerText);
        case 'tab': sb.write('\t');
        case 'br' || 'cr': sb.write('\n');
      }
    }
    final text = sb.toString();
    if (text.isEmpty) return null;
    return DocxRun(
      text: text,
      bold: rPr != null && _isFormatOn(rPr, 'b'),
      italic: rPr != null && _isFormatOn(rPr, 'i'),
      underline: rPr != null && _isFormatOn(rPr, 'u'),
    );
  }

  static DocxTable _parseTable(XmlElement tbl) {
    final rows = <List<String>>[];
    var maxCols = 0;
    for (final tr in tbl.childElements.where((e) => e.name.local == 'tr')) {
      final cells = <String>[];
      for (final tc in tr.childElements.where((e) => e.name.local == 'tc')) {
        final parts = <String>[];
        for (final c in tc.childElements) {
          if (c.name.local == 'p') parts.add(_parseParagraph(c).plainText);
          if (c.name.local == 'tbl') parts.add(_parseTable(c).plainText);
        }
        cells.add(parts.join('\n'));
      }
      if (cells.length > maxCols) maxCols = cells.length;
      rows.add(cells);
    }
    for (final row in rows) {
      while (row.length < maxCols) {
        row.add('');
      }
    }
    return DocxTable(rows: rows);
  }

  static bool _isFormatOn(XmlElement rPr, String tag) {
    final el = rPr.childElements.where((e) => e.name.local == tag).firstOrNull;
    if (el == null) return false;
    final val = _getAttr(el, 'val');
    return !(val == '0' || val == 'false' || val == 'none');
  }

  static String? _getAttr(XmlElement el, String localName) =>
      el.attributes.where((a) => a.name.local == localName).firstOrNull?.value;

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

class DocxView extends StatelessWidget {
  const DocxView({super.key, required this.content});
  final DocxContent content;

  @override
  Widget build(BuildContext context) {
    if (content.blocks.isEmpty) {
      return const Center(child: Text('This document has no text.', style: TextStyle(color: Colors.white70)));
    }
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: content.blocks.length,
        itemBuilder: (context, i) {
          final block = content.blocks[i];
          return switch (block) {
            DocxParagraph() => _paragraph(block),
            DocxTable() => _table(block),
          };
        },
      ),
    );
  }

  Widget _paragraph(DocxParagraph p) {
    final heading = p.headingLevel > 0;
    final size = heading ? 16.0 + (7 - p.headingLevel) * 3.0 : 16.0;
    final spans = <TextSpan>[
      for (final r in p.runs)
        TextSpan(
          text: r.text,
          style: TextStyle(
            color: Colors.white,
            fontSize: size,
            fontWeight: (r.bold || heading) ? FontWeight.bold : FontWeight.normal,
            fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
            decoration: r.underline ? TextDecoration.underline : null,
          ),
        ),
    ];
    if (spans.isEmpty) spans.add(const TextSpan(text: '​'));
    Widget child = Text.rich(TextSpan(children: spans));
    if (p.isListItem) {
      child = Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('•  ', style: TextStyle(color: Colors.white, fontSize: size)),
          Expanded(child: child),
        ]),
      );
    }
    return Padding(padding: EdgeInsets.symmetric(vertical: heading ? 8 : 4), child: child);
  }

  Widget _table(DocxTable t) {
    if (t.rows.isEmpty || t.rows.first.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: Colors.white54),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          children: [
            for (final row in t.rows)
              TableRow(children: [
                for (final cell in row)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(cell, style: const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
              ]),
          ],
        ),
      ),
    );
  }
}
