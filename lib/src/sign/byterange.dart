// ByteRange mechanics: patch the placeholder with real offsets (byte length
// preserved), expose the two signed spans, and splice the CMS DER into
// /Contents as zero-padded hex.
import 'dart:convert';
import 'dart:typed_data';

import '../cos/objects.dart';
import '../exceptions.dart';
import '../sign/placeholder.dart';

class SignatureSlots {
  SignatureSlots({
    required this.byteRangeStart,
    required this.byteRangeLength,
    required this.contentsStart,
    required this.contentsEnd,
  });

  /// Reads marker positions recorded by the writer.
  factory SignatureSlots.fromPlaceholder(
      PlaceholderResult placeholder, Map<CosRaw, int> rawOffsets) {
    final brStart = rawOffsets[placeholder.byteRange];
    final cStart = rawOffsets[placeholder.contents];
    if (brStart == null || cStart == null) {
      throw StateError('placeholder markers were not written');
    }
    return SignatureSlots(
      byteRangeStart: brStart,
      byteRangeLength: placeholder.byteRange.bytes.length,
      contentsStart: cStart,
      contentsEnd: cStart + placeholder.contents.bytes.length,
    );
  }

  final int byteRangeStart; // offset of '['
  final int byteRangeLength;
  final int contentsStart; // offset of '<'
  final int contentsEnd; // offset just past '>'
}

/// Overwrites the ByteRange placeholder in place with the real values,
/// space-padded to the exact placeholder length.
void patchByteRange(Uint8List bytes, SignatureSlots slots) {
  final total = bytes.length;
  final values = [0, slots.contentsStart, slots.contentsEnd, total - slots.contentsEnd];
  var s = '[${values.join(' ')}';
  if (s.length > slots.byteRangeLength - 1) {
    throw StateError('ByteRange does not fit its placeholder');
  }
  s = '${s.padRight(slots.byteRangeLength - 1)}]';
  final encoded = latin1.encode(s);
  bytes.setRange(slots.byteRangeStart, slots.byteRangeStart + encoded.length, encoded);
}

/// The two spans covered by the signature: everything except `<...>`.
List<Uint8List> byteRangeSpans(Uint8List bytes, SignatureSlots slots) => [
      Uint8List.sublistView(bytes, 0, slots.contentsStart),
      Uint8List.sublistView(bytes, slots.contentsEnd),
    ];

/// Writes the CMS DER into /Contents as uppercase hex, zero-padded to the
/// reserved width. The signed spans are untouched.
void spliceCms(Uint8List bytes, SignatureSlots slots, Uint8List cmsDer) {
  final reservedBytes = (slots.contentsEnd - slots.contentsStart - 2) ~/ 2;
  if (cmsDer.length > reservedBytes) {
    throw SignatureTooLargeException(cmsDer.length, reservedBytes);
  }
  var p = slots.contentsStart + 1;
  for (final b in cmsDer) {
    final hex = b.toRadixString(16).padLeft(2, '0').toUpperCase();
    bytes[p++] = hex.codeUnitAt(0);
    bytes[p++] = hex.codeUnitAt(1);
  }
  // Remaining reserved area stays as ASCII zeros from the placeholder.
}
