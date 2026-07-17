// COS object parser (ISO 32000-1 §7.3): values, indirect objects, streams.
import 'dart:typed_data';

import '../exceptions.dart';
import 'lexer.dart';
import 'objects.dart';

/// Resolves an indirect reference during parsing (needed for indirect
/// `/Length` on streams). May return null when unavailable.
typedef RefResolver = CosObject? Function(CosRef ref);

class CosParser {
  CosParser(this.bytes, {this.resolver});

  final Uint8List bytes;
  final RefResolver? resolver;

  /// Parses `N G obj ... endobj` at [offset].
  IndirectObject parseIndirectObjectAt(int offset) {
    final lexer = Lexer(bytes, offset);
    final numTok = lexer.nextToken();
    final genTok = lexer.nextToken();
    final objTok = lexer.nextToken();
    if (numTok.type != TokenType.number ||
        genTok.type != TokenType.number ||
        objTok.type != TokenType.keyword ||
        objTok.value != 'obj') {
      throw PdfParseException('expected "N G obj" at offset $offset');
    }
    final value = _parseValue(lexer, allowStream: true);
    // Trailing "endobj" is not strictly enforced (some producers omit it).
    return IndirectObject(numTok.asNum.toInt(), genTok.asNum.toInt(), value);
  }

  /// Parses a bare value starting at [offset] (used for ObjStm entries).
  CosObject parseValueAt(int offset) =>
      _parseValue(Lexer(bytes, offset), allowStream: false);

  CosObject _parseValue(Lexer lexer, {required bool allowStream}) {
    final token = lexer.nextToken();
    return _parseValueFromToken(lexer, token, allowStream: allowStream);
  }

  CosObject _parseValueFromToken(Lexer lexer, Token token,
      {required bool allowStream}) {
    switch (token.type) {
      case TokenType.number:
        return _numberOrRef(lexer, token);
      case TokenType.name:
        return CosName(token.asString);
      case TokenType.string:
        return CosString(token.value as Uint8List);
      case TokenType.hexString:
        return CosString(token.value as Uint8List, isHex: true);
      case TokenType.arrayOpen:
        final items = <CosObject>[];
        while (true) {
          final t = lexer.nextToken();
          if (t.type == TokenType.arrayClose) break;
          if (t.type == TokenType.eof) {
            throw PdfParseException('unterminated array at ${token.start}');
          }
          items.add(_parseValueFromToken(lexer, t, allowStream: false));
        }
        return CosArray(items);
      case TokenType.dictOpen:
        final dict = _parseDictBody(lexer, token.start);
        if (allowStream) return _maybeStream(lexer, dict);
        return dict;
      case TokenType.keyword:
        switch (token.value) {
          case 'true':
            return const CosBool(true);
          case 'false':
            return const CosBool(false);
          case 'null':
            return const CosNull();
        }
        throw PdfParseException(
            'unexpected keyword "${token.value}" at offset ${token.start}');
      default:
        throw PdfParseException(
            'unexpected token $token at offset ${token.start}');
    }
  }

  CosDict _parseDictBody(Lexer lexer, int start) {
    final dict = CosDict();
    while (true) {
      final keyTok = lexer.nextToken();
      if (keyTok.type == TokenType.dictClose) return dict;
      if (keyTok.type != TokenType.name) {
        throw PdfParseException(
            'expected name key in dict at offset ${keyTok.start}');
      }
      dict[keyTok.asString] = _parseValue(lexer, allowStream: false);
    }
  }

  /// After a dict, checks for the `stream` keyword and reads raw data.
  CosObject _maybeStream(Lexer lexer, CosDict dict) {
    final save = lexer.pos;
    final t = lexer.nextToken();
    if (t.type != TokenType.keyword || t.value != 'stream') {
      lexer.pos = save;
      return dict;
    }
    // After "stream": CRLF or LF (a lone CR is tolerated).
    var p = lexer.pos;
    if (p < bytes.length && bytes[p] == 0x0d) p++;
    if (p < bytes.length && bytes[p] == 0x0a) p++;

    var length = _resolveLength(dict);
    if (length != null &&
        p + length <= bytes.length &&
        _endstreamFollows(p + length)) {
      return CosStream(dict, Uint8List.sublistView(bytes, p, p + length));
    }
    // /Length missing or wrong: scan for "endstream".
    final end = _scanForEndstream(p);
    if (end == null) {
      throw PdfParseException('unterminated stream at offset ${t.start}');
    }
    return CosStream(dict, Uint8List.sublistView(bytes, p, end));
  }

  int? _resolveLength(CosDict dict) {
    final v = dict['Length'];
    if (v is CosNumber) return v.asInt;
    if (v is CosRef && resolver != null) {
      final r = resolver!(v);
      if (r is CosNumber) return r.asInt;
    }
    return null;
  }

  bool _endstreamFollows(int p) {
    // Optional EOL, then "endstream".
    if (p < bytes.length && bytes[p] == 0x0d) p++;
    if (p < bytes.length && bytes[p] == 0x0a) p++;
    const kw = [0x65, 0x6e, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d];
    if (p + kw.length > bytes.length) return false;
    for (var i = 0; i < kw.length; i++) {
      if (bytes[p + i] != kw[i]) return false;
    }
    return true;
  }

  int? _scanForEndstream(int from) {
    const kw = 'endstream';
    for (var i = from; i + kw.length <= bytes.length; i++) {
      var match = true;
      for (var j = 0; j < kw.length; j++) {
        if (bytes[i + j] != kw.codeUnitAt(j)) {
          match = false;
          break;
        }
      }
      if (match) {
        var end = i;
        // Trim one EOL that belongs to the keyword, not the data.
        if (end > from && bytes[end - 1] == 0x0a) end--;
        if (end > from && bytes[end - 1] == 0x0d) end--;
        return end;
      }
    }
    return null;
  }

  /// Integer token: could be a plain number or the start of `N G R`.
  CosObject _numberOrRef(Lexer lexer, Token first) {
    if (!first.isInteger || first.asNum < 0) {
      return CosNumber(first.asNum, isInteger: first.isInteger);
    }
    final save = lexer.pos;
    final second = lexer.nextToken();
    if (second.type == TokenType.number &&
        second.isInteger &&
        second.asNum >= 0) {
      final third = lexer.nextToken();
      if (third.type == TokenType.keyword && third.value == 'R') {
        return CosRef(first.asNum.toInt(), second.asNum.toInt());
      }
    }
    lexer.pos = save;
    return CosNumber(first.asNum, isInteger: first.isInteger);
  }
}
