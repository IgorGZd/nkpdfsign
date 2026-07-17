// Cross-reference reading: classic tables (§7.5.4) and xref streams (§7.5.8),
// including hybrid-reference files (/XRefStm).
import 'dart:typed_data';

import '../cos/lexer.dart';
import '../cos/objects.dart';
import '../cos/parser.dart';
import '../exceptions.dart';
import 'filters.dart';

enum XrefEntryType { free, regular, compressed }

class XrefEntry {
  const XrefEntry.free(this.nextFreeOrOffset, this.generation)
      : type = XrefEntryType.free,
        objStmNumber = 0,
        indexInObjStm = 0;
  const XrefEntry.regular(this.nextFreeOrOffset, this.generation)
      : type = XrefEntryType.regular,
        objStmNumber = 0,
        indexInObjStm = 0;
  const XrefEntry.compressed(this.objStmNumber, this.indexInObjStm)
      : type = XrefEntryType.compressed,
        nextFreeOrOffset = 0,
        generation = 0;

  final XrefEntryType type;
  final int nextFreeOrOffset; // byte offset for regular entries
  final int generation;
  final int objStmNumber;
  final int indexInObjStm;

  int get offset => nextFreeOrOffset;
}

enum XrefStyle { table, stream }

/// One cross-reference section (one xref table/stream + its trailer dict).
class XrefSection {
  XrefSection(this.entries, this.trailer, this.style);
  final Map<int, XrefEntry> entries;
  final CosDict trailer;
  final XrefStyle style;

  int? get prev => trailer.intOf('Prev');
  int? get xrefStmOffset => trailer.intOf('XRefStm');
}

/// Reads the section starting at [offset]: dispatches between a classic
/// table ("xref" keyword) and an xref stream (an indirect object).
XrefSection readXrefSectionAt(Uint8List bytes, int offset, CosParser parser) {
  if (offset < 0 || offset >= bytes.length) {
    throw PdfParseException('xref offset $offset out of range');
  }
  final lexer = Lexer(bytes, offset);
  final save = lexer.pos;
  final t = lexer.nextToken();
  if (t.type == TokenType.keyword && t.value == 'xref') {
    return _readClassicTable(bytes, lexer);
  }
  lexer.pos = save;
  return _readXrefStream(bytes, offset, parser);
}

XrefSection _readClassicTable(Uint8List bytes, Lexer lexer) {
  final entries = <int, XrefEntry>{};
  while (true) {
    final t = lexer.nextToken();
    if (t.type == TokenType.keyword && t.value == 'trailer') {
      final parser = CosParser(bytes);
      final trailerObj = parser.parseValueAt(lexer.pos);
      if (trailerObj is! CosDict) {
        throw PdfParseException('trailer is not a dictionary');
      }
      return XrefSection(entries, trailerObj, XrefStyle.table);
    }
    if (t.type != TokenType.number) {
      throw PdfParseException(
          'expected subsection start or "trailer" at offset ${t.start}');
    }
    final start = t.asNum.toInt();
    final countTok = lexer.nextToken();
    if (countTok.type != TokenType.number) {
      throw PdfParseException('expected subsection count at ${countTok.start}');
    }
    final count = countTok.asNum.toInt();
    for (var i = 0; i < count; i++) {
      // Entries are nominally fixed-width 20 bytes; parse tolerantly by token.
      final offTok = lexer.nextToken();
      final genTok = lexer.nextToken();
      final kindTok = lexer.nextToken();
      if (offTok.type != TokenType.number ||
          genTok.type != TokenType.number ||
          kindTok.type != TokenType.keyword) {
        throw PdfParseException('bad xref entry at offset ${offTok.start}');
      }
      final objNum = start + i;
      final off = offTok.asNum.toInt();
      final gen = genTok.asNum.toInt();
      final entry = switch (kindTok.value) {
        'n' => XrefEntry.regular(off, gen),
        'f' => XrefEntry.free(off, gen),
        _ => throw PdfParseException(
            'bad xref entry kind "${kindTok.value}" at ${kindTok.start}'),
      };
      entries.putIfAbsent(objNum, () => entry);
    }
  }
}

XrefSection _readXrefStream(Uint8List bytes, int offset, CosParser parser) {
  final obj = parser.parseIndirectObjectAt(offset);
  final value = obj.value;
  if (value is! CosStream) {
    throw PdfParseException('object at xref offset $offset is not a stream');
  }
  final dict = value.dict;
  if (dict.nameOf('Type') != 'XRef') {
    throw PdfParseException('xref stream missing /Type /XRef');
  }
  final data = decodeStream(value, (o) => o); // xref stream dicts are direct

  final w = dict['W'];
  if (w is! CosArray || w.length < 3) {
    throw PdfParseException('xref stream missing /W');
  }
  final widths = [
    for (final e in w.items)
      e is CosNumber ? e.asInt : (throw PdfParseException('bad /W entry'))
  ];
  final size = dict.intOf('Size') ??
      (throw PdfParseException('xref stream missing /Size'));

  final index = <int>[];
  final indexObj = dict['Index'];
  if (indexObj is CosArray) {
    for (final e in indexObj.items) {
      if (e is! CosNumber) throw PdfParseException('bad /Index entry');
      index.add(e.asInt);
    }
  } else {
    index.addAll([0, size]);
  }

  final rowLen = widths.fold<int>(0, (a, b) => a + b);
  if (rowLen == 0) throw PdfParseException('zero-width xref stream rows');

  final entries = <int, XrefEntry>{};
  var p = 0;
  for (var pair = 0; pair + 1 < index.length; pair += 2) {
    final start = index[pair];
    final count = index[pair + 1];
    for (var i = 0; i < count; i++) {
      if (p + rowLen > data.length) {
        throw PdfParseException('xref stream data truncated');
      }
      var fieldPos = p;
      int readField(int width, int defaultValue) {
        if (width == 0) return defaultValue;
        var v = 0;
        for (var k = 0; k < width; k++) {
          v = (v << 8) | data[fieldPos + k];
        }
        fieldPos += width;
        return v;
      }

      final type = readField(widths[0], 1); // absent type field defaults to 1
      final f2 = readField(widths[1], 0);
      final f3 = readField(widths[2], 0);
      p += rowLen;

      final objNum = start + i;
      final entry = switch (type) {
        0 => XrefEntry.free(f2, f3),
        1 => XrefEntry.regular(f2, f3),
        2 => XrefEntry.compressed(f2, f3),
        _ => null, // unknown types must be treated as null references
      };
      if (entry != null) entries.putIfAbsent(objNum, () => entry);
    }
  }
  return XrefSection(entries, dict, XrefStyle.stream);
}
