// Generates deterministic synthetic PDF fixtures for tests:
//  - minimal_classic.pdf   : PDF 1.4, classic xref table, uncompressed objects
//  - synthetic_xrefstream.pdf : PDF 1.5, xref stream (Flate + PNG Up predictor),
//    Catalog/Pages/Page stored inside an object stream (/Type /ObjStm)
//
// Run from the package root: dart run tool/gen_fixtures.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final fixtures = Directory('test/fixtures');

void main() {
  fixtures.createSync(recursive: true);
  genMinimalClassic();
  genXrefStream();
}

class _Builder {
  final BytesBuilder _buf = BytesBuilder();
  final Map<int, int> offsets = {};

  int get length => _buf.length;

  void add(List<int> bytes) => _buf.add(bytes);

  void addString(String s) => _buf.add(latin1.encode(s));

  void beginObj(int num) {
    offsets[num] = _buf.length;
    addString('$num 0 obj\n');
  }

  void endObj() => addString('endobj\n');

  Uint8List take() => _buf.takeBytes();
}

void genMinimalClassic() {
  final b = _Builder();
  b.addString('%PDF-1.4\n%âãÏÓ\n');

  b.beginObj(1);
  b.addString('<</Type /Catalog /Pages 2 0 R>>\n');
  b.endObj();

  b.beginObj(2);
  b.addString('<</Type /Pages /Kids [3 0 R] /Count 1>>\n');
  b.endObj();

  b.beginObj(3);
  b.addString(
      '<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R '
      '/Resources <</Font <</F1 5 0 R>>>>>>\n');
  b.endObj();

  const content = 'BT /F1 24 Tf 72 770 Td (nkpdfsign classic fixture) Tj ET';
  b.beginObj(4);
  b.addString('<</Length ${content.length}>>\nstream\n$content\nendstream\n');
  b.endObj();

  b.beginObj(5);
  b.addString('<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>\n');
  b.endObj();

  final xrefOffset = b.length;
  b.addString('xref\n0 6\n');
  b.addString('0000000000 65535 f \n');
  for (var i = 1; i <= 5; i++) {
    b.addString('${b.offsets[i]!.toString().padLeft(10, '0')} 00000 n \n');
  }
  b.addString(
      'trailer\n<</Size 6 /Root 1 0 R /ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]>>\n');
  b.addString('startxref\n$xrefOffset\n%%EOF\n');

  File('${fixtures.path}/minimal_classic.pdf').writeAsBytesSync(b.take());
  print('minimal_classic.pdf written');
}

/// Applies the PNG "Up" filter (predictor 12) to [rows] of width [columns],
/// then Flate-compresses.
Uint8List _flateWithUpPredictor(List<List<int>> rows, int columns) {
  final out = BytesBuilder();
  var prev = List<int>.filled(columns, 0);
  for (final row in rows) {
    assert(row.length == columns);
    out.addByte(2); // PNG Up filter tag
    for (var i = 0; i < columns; i++) {
      out.addByte((row[i] - prev[i]) & 0xff);
    }
    prev = row;
  }
  return Uint8List.fromList(zlib.encode(out.takeBytes()));
}

void genXrefStream() {
  final b = _Builder();
  b.addString('%PDF-1.5\n%âãÏÓ\n');

  // Objects 1 (Catalog), 2 (Pages), 3 (Page) live inside ObjStm number 5.
  // Object 4 is a regular content stream; object 6 is the xref stream.
  const inner1 = '<</Type /Catalog /Pages 2 0 R>>';
  const inner2 = '<</Type /Pages /Kids [3 0 R] /Count 1>>';
  const inner3 =
      '<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R>>';

  const content = 'BT 72 770 Td (nkpdfsign xrefstream fixture) Tj ET';
  b.beginObj(4);
  b.addString('<</Length ${content.length}>>\nstream\n$content\nendstream\n');
  b.endObj();

  // Build the object stream payload: "num offset" pairs, then objects.
  final off1 = 0;
  final off2 = off1 + inner1.length + 1;
  final off3 = off2 + inner2.length + 1;
  final header = '1 $off1 2 $off2 3 $off3 ';
  final payload = latin1.encode('$header$inner1\n$inner2\n$inner3');
  final first = header.length;
  final compressed = zlib.encode(payload);
  b.beginObj(5);
  b.addString(
      '<</Type /ObjStm /N 3 /First $first /Filter /FlateDecode /Length ${compressed.length}>>\nstream\n');
  b.add(compressed);
  b.addString('\nendstream\n');
  b.endObj();

  // Xref stream: /W [1 4 2], 7 entries (0..6).
  final xrefOffset = b.length;
  List<int> entry(int type, int a, int c) => [
        type,
        (a >> 24) & 0xff,
        (a >> 16) & 0xff,
        (a >> 8) & 0xff,
        a & 0xff,
        (c >> 8) & 0xff,
        c & 0xff,
      ];
  final rows = [
    entry(0, 0, 0xffff), // obj 0: free
    entry(2, 5, 0), // obj 1: in ObjStm 5, index 0
    entry(2, 5, 1), // obj 2: in ObjStm 5, index 1
    entry(2, 5, 2), // obj 3: in ObjStm 5, index 2
    entry(1, b.offsets[4]!, 0), // obj 4: regular
    entry(1, b.offsets[5]!, 0), // obj 5: regular (the ObjStm itself)
    entry(1, xrefOffset, 0), // obj 6: the xref stream
  ];
  final xrefData = _flateWithUpPredictor(rows, 7);
  b.beginObj(6);
  b.addString('<</Type /XRef /Size 7 /W [1 4 2] /Root 1 0 R '
      '/Filter /FlateDecode /DecodeParms <</Predictor 12 /Columns 7>> '
      '/ID [<AABBCCDDEEFF00112233445566778899> <AABBCCDDEEFF00112233445566778899>] '
      '/Length ${xrefData.length}>>\nstream\n');
  b.add(xrefData);
  b.addString('\nendstream\n');
  b.endObj();

  b.addString('startxref\n$xrefOffset\n%%EOF\n');

  File('${fixtures.path}/synthetic_xrefstream.pdf').writeAsBytesSync(b.take());
  print('synthetic_xrefstream.pdf written');
}
