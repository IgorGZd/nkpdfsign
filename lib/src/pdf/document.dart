// Loaded PDF document: merged cross-reference view, object resolution
// (including object streams), and the handful of structural lookups the
// signing flow needs.
import 'dart:typed_data';

import '../cos/lexer.dart';
import '../cos/objects.dart';
import '../cos/parser.dart';
import '../exceptions.dart';
import 'filters.dart';
import 'xref.dart';

class PdfDocument {
  PdfDocument._(this.bytes, this.entries, this.trailer, this.xrefStyle,
      this.startXrefOffset, this.headerDelta);

  final Uint8List bytes;

  /// Merged xref: newest section wins.
  final Map<int, XrefEntry> entries;

  /// Trailer dict of the newest section (holds /Root, /Info, /ID, /Size).
  final CosDict trailer;

  /// Style of the newest xref section — the incremental update must match it.
  final XrefStyle xrefStyle;

  /// Offset of the newest xref section (the incremental trailer's /Prev).
  final int startXrefOffset;

  /// Bytes of junk before "%PDF-" (offsets in broken files may need it).
  final int headerDelta;

  late final CosParser _parser = CosParser(bytes, resolver: _resolveRef);

  final Map<int, IndirectObject> _objectCache = {};
  final Map<int, List<CosObject?>> _objStmCache = {};

  static PdfDocument load(Uint8List bytes) {
    final headerDelta = _findHeader(bytes);
    final startXref = _findStartXref(bytes);

    // Walk the /Prev chain, newest first; first-seen entries win.
    final merged = <int, XrefEntry>{};
    CosDict? newestTrailer;
    XrefStyle? newestStyle;
    final seenOffsets = <int>{};
    final probeParser = CosParser(bytes);

    int? offset = startXref;
    var isNewest = true;
    while (offset != null) {
      var section = _readSectionWithDeltaRetry(
          bytes, offset, probeParser, headerDelta);
      if (!seenOffsets.add(offset)) {
        throw PdfParseException('cyclic /Prev chain in xref');
      }
      // Hybrid-reference: the /XRefStm entries take precedence over this
      // section's table entries, but not over newer sections.
      if (section.xrefStmOffset != null) {
        final hidden = _readSectionWithDeltaRetry(
            bytes, section.xrefStmOffset!, probeParser, headerDelta);
        for (final e in hidden.entries.entries) {
          merged.putIfAbsent(e.key, () => e.value);
        }
      }
      for (final e in section.entries.entries) {
        merged.putIfAbsent(e.key, () => e.value);
      }
      if (isNewest) {
        newestTrailer = section.trailer;
        newestStyle = section.style;
        isNewest = false;
      }
      offset = section.prev;
    }

    if (newestTrailer == null || newestStyle == null) {
      throw PdfParseException('no xref section found');
    }
    if (newestTrailer.has('Encrypt')) {
      throw EncryptedPdfException();
    }

    return PdfDocument._(
        bytes, merged, newestTrailer, newestStyle, startXref, headerDelta);
  }

  static XrefSection _readSectionWithDeltaRetry(
      Uint8List bytes, int offset, CosParser parser, int delta) {
    try {
      return readXrefSectionAt(bytes, offset, parser);
    } on PdfParseException {
      if (delta > 0) {
        return readXrefSectionAt(bytes, offset + delta, parser);
      }
      rethrow;
    }
  }

  static int _findHeader(Uint8List bytes) {
    const probe = [0x25, 0x50, 0x44, 0x46, 0x2d]; // %PDF-
    final limit = bytes.length - probe.length;
    for (var i = 0; i <= limit && i < 1024; i++) {
      var match = true;
      for (var j = 0; j < probe.length; j++) {
        if (bytes[i + j] != probe[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    throw PdfParseException('not a PDF: missing %PDF- header');
  }

  static int _findStartXref(Uint8List bytes) {
    const kw = 'startxref';
    final from = bytes.length > 2048 ? bytes.length - 2048 : 0;
    for (var i = bytes.length - kw.length; i >= from; i--) {
      var match = true;
      for (var j = 0; j < kw.length; j++) {
        if (bytes[i + j] != kw.codeUnitAt(j)) {
          match = false;
          break;
        }
      }
      if (match) {
        final lexer = Lexer(bytes, i + kw.length);
        final t = lexer.nextToken();
        if (t.type != TokenType.number) {
          throw PdfParseException('bad startxref value');
        }
        return t.asNum.toInt();
      }
    }
    throw PdfParseException('startxref not found');
  }

  /// Follows references until a non-reference value (or null) is reached.
  CosObject? resolve(CosObject? obj) {
    var current = obj;
    var hops = 0;
    while (current is CosRef) {
      if (++hops > 64) throw PdfParseException('reference loop');
      current = _resolveRef(current);
    }
    return current;
  }

  CosObject? _resolveRef(CosRef ref) {
    final cached = _objectCache[ref.objectNumber];
    if (cached != null) return cached.value;

    final entry = entries[ref.objectNumber];
    if (entry == null) return null;
    switch (entry.type) {
      case XrefEntryType.free:
        return null;
      case XrefEntryType.regular:
        final obj = _parseRegularAt(entry.offset, ref.objectNumber);
        if (obj == null) return null;
        _objectCache[ref.objectNumber] = obj;
        return obj.value;
      case XrefEntryType.compressed:
        final objects = _loadObjStm(entry.objStmNumber);
        if (entry.indexInObjStm >= objects.length) return null;
        return objects[entry.indexInObjStm];
    }
  }

  IndirectObject? _parseRegularAt(int offset, int expectedNumber) {
    IndirectObject obj;
    try {
      obj = _parser.parseIndirectObjectAt(offset);
    } on PdfParseException {
      if (headerDelta > 0) {
        obj = _parser.parseIndirectObjectAt(offset + headerDelta);
      } else {
        rethrow;
      }
    }
    if (obj.objectNumber != expectedNumber) {
      throw PdfParseException(
          'xref points to object ${obj.objectNumber}, expected $expectedNumber');
    }
    return obj;
  }

  /// Parses all objects inside object stream [objStmNumber] (cached).
  List<CosObject?> _loadObjStm(int objStmNumber) {
    final cached = _objStmCache[objStmNumber];
    if (cached != null) return cached;

    final entry = entries[objStmNumber];
    if (entry == null || entry.type != XrefEntryType.regular) {
      throw PdfParseException('object stream $objStmNumber not found in xref');
    }
    final stmObj = _parseRegularAt(entry.offset, objStmNumber);
    final value = stmObj?.value;
    if (value is! CosStream || value.dict.nameOf('Type') != 'ObjStm') {
      throw PdfParseException('object $objStmNumber is not an /ObjStm');
    }
    final n = value.dict.intOf('N') ??
        (throw PdfParseException('/ObjStm missing /N'));
    final first = value.dict.intOf('First') ??
        (throw PdfParseException('/ObjStm missing /First'));
    final data = decodeStream(value, resolve);

    final headerLexer = Lexer(data, 0);
    final innerParser = CosParser(data, resolver: _resolveRef);
    final objects = List<CosObject?>.filled(n, null);
    final numbers = List<int>.filled(n, 0);
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final numTok = headerLexer.nextToken();
      final offTok = headerLexer.nextToken();
      if (numTok.type != TokenType.number || offTok.type != TokenType.number) {
        throw PdfParseException('bad /ObjStm header');
      }
      numbers[i] = numTok.asNum.toInt();
      offsets[i] = offTok.asNum.toInt();
    }
    for (var i = 0; i < n; i++) {
      objects[i] = innerParser.parseValueAt(first + offsets[i]);
      // Cache by number too — but only when the current xref still maps the
      // number into THIS object stream (a newer revision may have replaced
      // the object with a regular one).
      final current = entries[numbers[i]];
      if (current != null &&
          current.type == XrefEntryType.compressed &&
          current.objStmNumber == objStmNumber) {
        _objectCache.putIfAbsent(
            numbers[i], () => IndirectObject(numbers[i], 0, objects[i]!));
      }
    }
    _objStmCache[objStmNumber] = objects;
    return objects;
  }

  // --- Structural lookups -------------------------------------------------

  CosRef get catalogRef {
    final root = trailer['Root'];
    if (root is! CosRef) throw PdfParseException('trailer /Root missing');
    return root;
  }

  CosDict get catalog {
    final c = resolve(catalogRef);
    if (c is! CosDict) throw PdfParseException('/Root is not a dictionary');
    return c;
  }

  /// Highest object number in use (new objects start at this + 1).
  int get maxObjectNumber {
    var max = trailer.intOf('Size') ?? 0;
    max -= 1;
    for (final k in entries.keys) {
      if (k > max) max = k;
    }
    return max < 0 ? 0 : max;
  }

  /// Finds the first page: (reference, dict). Walks /Pages /Kids depth-first.
  (CosRef, CosDict) firstPage() {
    final pagesRef = catalog['Pages'];
    if (pagesRef is! CosRef) {
      throw PdfParseException('catalog /Pages missing or direct');
    }
    return _firstPageUnder(pagesRef, 0);
  }

  (CosRef, CosDict) _firstPageUnder(CosRef nodeRef, int depth) {
    if (depth > 64) throw PdfParseException('pages tree too deep');
    final node = resolve(nodeRef);
    if (node is! CosDict) throw PdfParseException('bad pages tree node');
    final type = node.nameOf('Type');
    if (type == 'Page') return (nodeRef, node);
    final kids = resolve(node['Kids']);
    if (kids is! CosArray || kids.items.isEmpty) {
      throw PdfParseException('pages tree has no pages');
    }
    for (final kid in kids.items) {
      if (kid is CosRef) {
        try {
          return _firstPageUnder(kid, depth + 1);
        } on PdfParseException {
          continue; // tolerate an empty intermediate node
        }
      }
    }
    throw PdfParseException('pages tree has no pages');
  }
}
