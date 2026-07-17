// Minimal DER encoder.
//
// Hand-rolled instead of pointycastle's ASN.1 object model because DER output
// must be byte-exact: pointycastle's ASN1Set does not implement the SET OF
// lexicographic sort required by X.690 §11.6, and implicit tagging of
// pre-encoded content is awkward there. Encoding TLVs directly keeps every
// byte under our control.
import 'dart:typed_data';

Uint8List derLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
  final bytes = <int>[];
  var v = length;
  while (v > 0) {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List derTlv(int tag, List<int> content) {
  final b = BytesBuilder();
  b.addByte(tag);
  b.add(derLength(content.length));
  b.add(content);
  return b.takeBytes();
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

Uint8List derSequence(List<List<int>> children) =>
    derTlv(0x30, _concat(children));

/// DER `SET OF`: children are sorted lexicographically by their encoded
/// bytes as required by X.690 §11.6 (shorter prefix sorts first).
Uint8List derSetOf(List<List<int>> children) {
  final sorted = List<List<int>>.of(children)..sort(_compareBytes);
  return derTlv(0x31, _concat(sorted));
}

/// DER `SET` with caller-determined order (e.g. a single-element set).
Uint8List derSet(List<List<int>> children) => derTlv(0x31, _concat(children));

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// Context-specific constructed tag `[n]` wrapping pre-encoded children
/// (IMPLICIT: the children keep their own tags, the wrapper replaces nothing).
Uint8List derContextConstructed(int n, List<List<int>> children) =>
    derTlv(0xa0 | n, _concat(children));

Uint8List derOctetString(List<int> bytes) => derTlv(0x04, bytes);

Uint8List derNull() => Uint8List.fromList([0x05, 0x00]);

Uint8List derInteger(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList([0x02, 0x01, 0x00]);
  if (value.isNegative) {
    throw ArgumentError('negative INTEGER not needed/supported');
  }
  final bytes = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v >>= 8;
  }
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0); // keep it positive
  return derTlv(0x02, bytes);
}

Uint8List derIntegerRaw(List<int> contentBytes) => derTlv(0x02, contentBytes);

Uint8List derSmallInt(int v) => derInteger(BigInt.from(v));

/// Encodes a dotted-decimal OID string.
Uint8List derOid(String oid) {
  final parts = oid.split('.').map(int.parse).toList();
  final content = <int>[parts[0] * 40 + parts[1]];
  for (final p in parts.skip(2)) {
    if (p < 0x80) {
      content.add(p);
    } else {
      final tmp = <int>[];
      var v = p;
      while (v > 0) {
        tmp.insert(0, (v & 0x7f) | 0x80);
        v >>= 7;
      }
      tmp[tmp.length - 1] &= 0x7f;
      content.addAll(tmp);
    }
  }
  return derTlv(0x06, content);
}
