// Tokenizer for COS syntax (ISO 32000-1 §7.2, §7.3).
import 'dart:typed_data';

import '../exceptions.dart';

enum TokenType {
  number,
  name, // value: decoded name without slash
  string, // value: Uint8List (literal form)
  hexString, // value: Uint8List
  dictOpen, // <<
  dictClose, // >>
  arrayOpen, // [
  arrayClose, // ]
  keyword, // obj endobj stream endstream R true false null xref trailer startxref n f
  eof,
}

class Token {
  Token(this.type, this.start, this.end, [this.value, this.isInteger = true]);
  final TokenType type;
  final int start;
  final int end;
  final Object? value;

  /// For number tokens: whether the source spelled an integer (no dot).
  final bool isInteger;

  num get asNum => value as num;
  String get asString => value as String;

  @override
  String toString() => '$type($value)@$start';
}

bool isWhitespace(int b) =>
    b == 0x00 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d || b == 0x20;

bool isDelimiter(int b) =>
    b == 0x28 ||
    b == 0x29 || // ( )
    b == 0x3c ||
    b == 0x3e || // < >
    b == 0x5b ||
    b == 0x5d || // [ ]
    b == 0x7b ||
    b == 0x7d || // { }
    b == 0x2f ||
    b == 0x25; // / %

bool _isRegular(int b) => !isWhitespace(b) && !isDelimiter(b);

int _hexVal(int b) {
  if (b >= 0x30 && b <= 0x39) return b - 0x30;
  if (b >= 0x41 && b <= 0x46) return b - 0x41 + 10;
  if (b >= 0x61 && b <= 0x66) return b - 0x61 + 10;
  return -1;
}

class Lexer {
  Lexer(this.bytes, [this.pos = 0]);

  final Uint8List bytes;
  int pos;

  int? get _peek => pos < bytes.length ? bytes[pos] : null;

  void skipWhitespaceAndComments() {
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (isWhitespace(b)) {
        pos++;
      } else if (b == 0x25) {
        // % comment to end of line
        while (pos < bytes.length && bytes[pos] != 0x0a && bytes[pos] != 0x0d) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  /// Consumes a single end-of-line marker (CRLF, CR, or LF) if present.
  void skipEol() {
    if (pos < bytes.length && bytes[pos] == 0x0d) pos++;
    if (pos < bytes.length && bytes[pos] == 0x0a) pos++;
  }

  Token nextToken() {
    skipWhitespaceAndComments();
    final start = pos;
    final b = _peek;
    if (b == null) return Token(TokenType.eof, start, start);

    switch (b) {
      case 0x5b: // [
        pos++;
        return Token(TokenType.arrayOpen, start, pos);
      case 0x5d: // ]
        pos++;
        return Token(TokenType.arrayClose, start, pos);
      case 0x3c: // < or <<
        if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3c) {
          pos += 2;
          return Token(TokenType.dictOpen, start, pos);
        }
        return _hexString();
      case 0x3e: // >>
        if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3e) {
          pos += 2;
          return Token(TokenType.dictClose, start, pos);
        }
        throw PdfParseException('unexpected ">" at offset $pos');
      case 0x28: // (
        return _literalString();
      case 0x2f: // /
        return _name();
      case 0x7b: // { — postfix function syntax, not valid in body objects
      case 0x7d:
        throw PdfParseException('unexpected byte ${bytes[pos]} at offset $pos');
    }

    // Number: digits, +, -, .
    if ((b >= 0x30 && b <= 0x39) || b == 0x2b || b == 0x2d || b == 0x2e) {
      return _number();
    }

    // Keyword: run of regular characters
    if (_isRegular(b)) {
      final sb = StringBuffer();
      while (pos < bytes.length && _isRegular(bytes[pos])) {
        sb.writeCharCode(bytes[pos]);
        pos++;
      }
      return Token(TokenType.keyword, start, pos, sb.toString());
    }

    throw PdfParseException('unexpected byte $b at offset $pos');
  }

  Token _number() {
    final start = pos;
    var isInt = true;
    final sb = StringBuffer();
    while (pos < bytes.length) {
      final b = bytes[pos];
      if ((b >= 0x30 && b <= 0x39) || b == 0x2b || b == 0x2d) {
        sb.writeCharCode(b);
        pos++;
      } else if (b == 0x2e) {
        isInt = false;
        sb.writeCharCode(b);
        pos++;
      } else {
        break;
      }
    }
    final s = sb.toString();
    final num value;
    if (isInt) {
      value = int.tryParse(s) ??
          (throw PdfParseException('bad number "$s" at $start'));
    } else {
      // Accept forms like ".5", "4.", "-.7"
      value = double.tryParse(s.startsWith('.')
              ? '0$s'
              : s.startsWith('-.')
                  ? '-0${s.substring(1)}'
                  : s.endsWith('.')
                      ? '${s}0'
                      : s) ??
          (throw PdfParseException('bad number "$s" at $start'));
    }
    return Token(TokenType.number, start, pos, value, isInt);
  }

  Token _name() {
    final start = pos;
    pos++; // skip /
    final sb = StringBuffer();
    while (pos < bytes.length && _isRegular(bytes[pos])) {
      var b = bytes[pos];
      if (b == 0x23 && pos + 2 < bytes.length) {
        final h1 = _hexVal(bytes[pos + 1]);
        final h2 = _hexVal(bytes[pos + 2]);
        if (h1 >= 0 && h2 >= 0) {
          b = (h1 << 4) | h2;
          pos += 2;
        }
      }
      sb.writeCharCode(b);
      pos++;
    }
    return Token(TokenType.name, start, pos, sb.toString());
  }

  Token _literalString() {
    final start = pos;
    pos++; // skip (
    final out = BytesBuilder();
    var depth = 1;
    while (pos < bytes.length) {
      var b = bytes[pos];
      if (b == 0x5c) {
        // backslash escape
        pos++;
        if (pos >= bytes.length) break;
        b = bytes[pos];
        switch (b) {
          case 0x6e:
            out.addByte(0x0a);
            pos++;
            break; // \n
          case 0x72:
            out.addByte(0x0d);
            pos++;
            break; // \r
          case 0x74:
            out.addByte(0x09);
            pos++;
            break; // \t
          case 0x62:
            out.addByte(0x08);
            pos++;
            break; // \b
          case 0x66:
            out.addByte(0x0c);
            pos++;
            break; // \f
          case 0x28:
            out.addByte(0x28);
            pos++;
            break; // \(
          case 0x29:
            out.addByte(0x29);
            pos++;
            break; // \)
          case 0x5c:
            out.addByte(0x5c);
            pos++;
            break; // \\
          case 0x0d: // line continuation
            pos++;
            if (pos < bytes.length && bytes[pos] == 0x0a) pos++;
            break;
          case 0x0a:
            pos++;
            break;
          default:
            if (b >= 0x30 && b <= 0x37) {
              // 1-3 octal digits
              var v = 0;
              var n = 0;
              while (n < 3 &&
                  pos < bytes.length &&
                  bytes[pos] >= 0x30 &&
                  bytes[pos] <= 0x37) {
                v = (v << 3) | (bytes[pos] - 0x30);
                pos++;
                n++;
              }
              out.addByte(v & 0xff);
            } else {
              out.addByte(b); // unknown escape: emit as-is
              pos++;
            }
        }
      } else if (b == 0x28) {
        depth++;
        out.addByte(b);
        pos++;
      } else if (b == 0x29) {
        depth--;
        pos++;
        if (depth == 0) {
          return Token(TokenType.string, start, pos, out.takeBytes());
        }
        out.addByte(b);
      } else {
        out.addByte(b);
        pos++;
      }
    }
    throw PdfParseException('unterminated string starting at offset $start');
  }

  Token _hexString() {
    final start = pos;
    pos++; // skip <
    final out = BytesBuilder();
    int? pending;
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (b == 0x3e) {
        pos++;
        if (pending != null) out.addByte(pending << 4); // odd count: pad 0
        return Token(TokenType.hexString, start, pos, out.takeBytes());
      }
      final h = _hexVal(b);
      if (h >= 0) {
        if (pending == null) {
          pending = h;
        } else {
          out.addByte((pending << 4) | h);
          pending = null;
        }
      } else if (!isWhitespace(b)) {
        throw PdfParseException('bad hex string char at offset $pos');
      }
      pos++;
    }
    throw PdfParseException(
        'unterminated hex string starting at offset $start');
  }
}
