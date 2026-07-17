// COS (Carousel Object System) object model — the PDF file format's
// primitive values. Deliberately minimal: just what parsing and an
// incremental update need.
import 'dart:typed_data';

sealed class CosObject {
  const CosObject();
}

class CosNull extends CosObject {
  const CosNull();
}

class CosBool extends CosObject {
  const CosBool(this.value);
  final bool value;
}

/// Integer or real. PDF distinguishes them syntactically; we keep [isInteger]
/// so round-tripped values serialize in their original flavor.
class CosNumber extends CosObject {
  const CosNumber(this.value, {this.isInteger = true});
  final num value;
  final bool isInteger;

  int get asInt => value.toInt();
}

/// A string, kept as raw bytes (PDF strings are byte strings, not text).
class CosString extends CosObject {
  const CosString(this.bytes, {this.isHex = false});
  final Uint8List bytes;

  /// Whether the source used hex `<...>` form (kept for faithful rewriting).
  final bool isHex;
}

class CosName extends CosObject {
  const CosName(this.name);

  /// Decoded name without the leading slash (`#xx` escapes resolved).
  final String name;

  @override
  bool operator ==(Object other) => other is CosName && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

class CosArray extends CosObject {
  CosArray([List<CosObject>? items]) : items = items ?? [];
  final List<CosObject> items;

  int get length => items.length;
  CosObject operator [](int i) => items[i];
}

class CosDict extends CosObject {
  CosDict([Map<String, CosObject>? entries]) : entries = entries ?? {};

  /// Keyed by decoded name without the leading slash.
  final Map<String, CosObject> entries;

  CosObject? operator [](String key) => entries[key];
  void operator []=(String key, CosObject value) => entries[key] = value;

  bool has(String key) => entries.containsKey(key);

  String? nameOf(String key) {
    final v = entries[key];
    return v is CosName ? v.name : null;
  }

  int? intOf(String key) {
    final v = entries[key];
    return v is CosNumber ? v.asInt : null;
  }
}

/// A stream: its dictionary plus the raw (still-encoded) data bytes.
class CosStream extends CosObject {
  CosStream(this.dict, this.rawData);
  final CosDict dict;
  final Uint8List rawData;
}

/// Pre-rendered bytes emitted verbatim by the writer. Used for the
/// /Contents and /ByteRange placeholders whose byte positions must be known
/// exactly: the writer records each instance's absolute start offset.
class CosRaw extends CosObject {
  CosRaw(this.bytes);
  final Uint8List bytes;
}

/// An indirect reference `N G R`.
class CosRef extends CosObject {
  const CosRef(this.objectNumber, [this.generation = 0]);
  final int objectNumber;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is CosRef &&
      other.objectNumber == objectNumber &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(objectNumber, generation);

  @override
  String toString() => '$objectNumber $generation R';
}

/// A parsed indirect object: `N G obj ... endobj`.
class IndirectObject {
  IndirectObject(this.objectNumber, this.generation, this.value);
  final int objectNumber;
  final int generation;
  final CosObject value;

  CosRef get ref => CosRef(objectNumber, generation);
}
