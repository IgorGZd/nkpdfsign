// COS serializer for the incremental-update section. Existing streams are
// never re-encoded — only dictionaries/arrays we build or rewrite plus raw
// stream bytes we produced ourselves.
import 'dart:convert';
import 'dart:typed_data';

import 'lexer.dart' show isDelimiter, isWhitespace;
import 'objects.dart';

class CosWriter {
  CosWriter(this._buf, {int baseOffset = 0}) : _base = baseOffset;

  final BytesBuilder _buf;
  final int _base;

  /// Absolute start offset of every [CosRaw] written (identity-keyed).
  final Map<CosRaw, int> rawOffsets = {};

  int get offset => _base + _buf.length;

  void writeBytes(List<int> bytes) => _buf.add(bytes);

  void writeString(String s) => _buf.add(latin1.encode(s));

  void writeIndirectObject(int number, int generation, CosObject value) {
    writeString('$number $generation obj\n');
    writeValue(value);
    writeString('\nendobj\n');
  }

  void writeValue(CosObject value) {
    switch (value) {
      case CosRaw():
        rawOffsets[value] = offset;
        _buf.add(value.bytes);
      case CosNull():
        writeString('null');
      case CosBool():
        writeString(value.value ? 'true' : 'false');
      case CosNumber():
        writeString(_formatNumber(value));
      case CosName():
        writeString(_formatName(value.name));
      case CosString():
        _writeCosString(value);
      case CosRef():
        writeString('${value.objectNumber} ${value.generation} R');
      case CosArray():
        writeString('[');
        for (var i = 0; i < value.items.length; i++) {
          if (i > 0) writeString(' ');
          writeValue(value.items[i]);
        }
        writeString(']');
      case CosDict():
        _writeDict(value);
      case CosStream():
        _writeDict(value.dict);
        writeString('\nstream\n');
        _buf.add(value.rawData);
        writeString('\nendstream');
    }
  }

  void _writeDict(CosDict dict) {
    writeString('<<');
    var first = true;
    for (final e in dict.entries.entries) {
      if (!first) writeString(' ');
      first = false;
      writeString(_formatName(e.key));
      // A delimiter-starting value needs no separating space, but one never
      // hurts and keeps parsing unambiguous.
      writeString(' ');
      writeValue(e.value);
    }
    writeString('>>');
  }

  void _writeCosString(CosString s) {
    if (s.isHex) {
      final sb = StringBuffer('<');
      for (final b in s.bytes) {
        sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
      sb.write('>');
      writeString(sb.toString());
      return;
    }
    _buf.addByte(0x28); // (
    for (final b in s.bytes) {
      if (b == 0x28 || b == 0x29 || b == 0x5c) {
        _buf.addByte(0x5c);
        _buf.addByte(b);
      } else if (b == 0x0d) {
        _buf.add([0x5c, 0x72]); // \r would be normalized by readers
      } else {
        _buf.addByte(b);
      }
    }
    _buf.addByte(0x29); // )
  }

  static String _formatNumber(CosNumber n) {
    if (n.isInteger) return n.value.toInt().toString();
    final d = n.value.toDouble();
    if (d == d.roundToDouble()) return d.toInt().toString();
    var s = d.toStringAsFixed(6);
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _formatName(String name) {
    final sb = StringBuffer('/');
    for (final b in latin1.encode(name)) {
      final needsEscape = b < 0x21 ||
          b > 0x7e ||
          b == 0x23 ||
          isDelimiter(b) ||
          isWhitespace(b);
      if (needsEscape) {
        sb.write('#${b.toRadixString(16).padLeft(2, '0').toUpperCase()}');
      } else {
        sb.writeCharCode(b);
      }
    }
    return sb.toString();
  }
}
