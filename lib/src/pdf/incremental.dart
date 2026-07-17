// Incremental-update writer: appends new/updated objects plus a
// cross-reference section in the same style as the original file
// (table -> table, stream -> stream), per ISO 32000-1 §7.5.6.
import 'dart:typed_data';

import '../cos/objects.dart';
import '../cos/writer.dart';
import 'document.dart';
import 'xref.dart';

class IncrementalUpdater {
  IncrementalUpdater(this.document)
      : _nextNumber = document.maxObjectNumber + 1;

  final PdfDocument document;
  int _nextNumber;

  final Map<int, CosObject> _objects = {};
  final Map<int, int> _generations = {};

  /// Adds a brand-new object; returns its reference.
  CosRef addObject(CosObject value) {
    final number = _nextNumber++;
    _objects[number] = value;
    _generations[number] = 0;
    return CosRef(number);
  }

  /// Replaces an existing object (same number, same generation).
  void updateObject(CosRef ref, CosObject value) {
    _objects[ref.objectNumber] = value;
    final entry = document.entries[ref.objectNumber];
    _generations[ref.objectNumber] =
        (entry != null && entry.type == XrefEntryType.regular)
            ? entry.generation
            : ref.generation;
  }

  /// Serializes: original bytes + update section. [rawOffsets] receives the
  /// absolute offsets of every CosRaw placeholder written.
  Uint8List build({Map<CosRaw, int>? rawOffsets}) {
    final original = document.bytes;
    final buf = BytesBuilder();
    buf.add(original);
    // Guarantee the update starts on a fresh line.
    if (original.isNotEmpty && original.last != 0x0a) buf.add([0x0a]);

    final writer = CosWriter(buf, baseOffset: 0);

    final offsets = <int, int>{};
    final numbers = _objects.keys.toList()..sort();
    for (final number in numbers) {
      offsets[number] = writer.offset;
      writer.writeIndirectObject(
          number, _generations[number] ?? 0, _objects[number]!);
    }

    final newSize = _nextNumber;
    if (document.xrefStyle == XrefStyle.table) {
      _writeXrefTable(writer, offsets, newSize);
    } else {
      _writeXrefStream(writer, offsets, newSize);
    }

    rawOffsets?.addAll(writer.rawOffsets);
    return buf.takeBytes();
  }

  /// Contiguous runs of object numbers -> xref subsections.
  static List<(int, List<int>)> _subsections(List<int> numbers) {
    final result = <(int, List<int>)>[];
    List<int>? run;
    var runStart = 0;
    for (final n in numbers) {
      if (run != null && n == runStart + run.length) {
        run.add(n);
      } else {
        run = [n];
        runStart = n;
        result.add((runStart, run));
      }
    }
    return result;
  }

  CosDict _trailerEntries(int newSize) {
    final t = CosDict();
    t['Size'] = CosNumber(newSize);
    t['Root'] = document.trailer['Root']!;
    final info = document.trailer['Info'];
    if (info != null) t['Info'] = info;
    final id = document.trailer['ID'];
    if (id != null) t['ID'] = id;
    t['Prev'] = CosNumber(document.startXrefOffset);
    return t;
  }

  void _writeXrefTable(CosWriter writer, Map<int, int> offsets, int newSize) {
    final xrefStart = writer.offset;
    writer.writeString('xref\n');
    final numbers = offsets.keys.toList()..sort();
    for (final (start, run) in _subsections(numbers)) {
      writer.writeString('$start ${run.length}\n');
      for (final n in run) {
        final off = offsets[n]!.toString().padLeft(10, '0');
        final gen = (_generations[n] ?? 0).toString().padLeft(5, '0');
        writer.writeString('$off $gen n \n');
      }
    }
    writer.writeString('trailer\n');
    writer.writeValue(_trailerEntries(newSize));
    writer.writeString('\nstartxref\n$xrefStart\n%%EOF\n');
  }

  void _writeXrefStream(CosWriter writer, Map<int, int> offsets, int newSize) {
    // The xref stream is itself an object and lists itself.
    final xrefObjNumber = _nextNumber++;
    final xrefStart = writer.offset;

    final allOffsets = Map<int, int>.of(offsets)..[xrefObjNumber] = xrefStart;
    final numbers = allOffsets.keys.toList()..sort();

    final index = <CosObject>[];
    final data = BytesBuilder();
    for (final (start, run) in _subsections(numbers)) {
      index.add(CosNumber(start));
      index.add(CosNumber(run.length));
      for (final n in run) {
        final off = allOffsets[n]!;
        data.addByte(1);
        data.add([
          (off >> 24) & 0xff,
          (off >> 16) & 0xff,
          (off >> 8) & 0xff,
          off & 0xff
        ]);
        final gen = _generations[n] ?? 0;
        data.add([(gen >> 8) & 0xff, gen & 0xff]);
      }
    }

    final dict = _trailerEntries(xrefObjNumber + 1);
    dict['Type'] = const CosName('XRef');
    dict['W'] = CosArray([CosNumber(1), CosNumber(4), CosNumber(2)]);
    dict['Index'] = CosArray(index);
    final payload = data.takeBytes();
    dict['Length'] = CosNumber(payload.length);
    // Unfiltered on purpose: /Filter is optional (§7.5.8) and this keeps the
    // write path free of compression.

    writer.writeIndirectObject(xrefObjNumber, 0, CosStream(dict, payload));
    writer.writeString('startxref\n$xrefStart\n%%EOF\n');
  }
}
