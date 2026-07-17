import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:nkpdfsign/src/cos/lexer.dart';
import 'package:nkpdfsign/src/cos/objects.dart';
import 'package:nkpdfsign/src/cos/parser.dart';
import 'package:nkpdfsign/src/exceptions.dart';
import 'package:nkpdfsign/src/pdf/document.dart';
import 'package:nkpdfsign/src/pdf/xref.dart';

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('lexer', () {
    test('name with #xx escape', () {
      final t = Lexer(_ascii('/Name#20x ')).nextToken();
      expect(t.type, TokenType.name);
      expect(t.value, 'Name x');
    });

    test('nested and escaped parens in literal string', () {
      final t = Lexer(_ascii(r'(a\(b (c) d)')).nextToken();
      expect(t.type, TokenType.string);
      expect(String.fromCharCodes(t.value as Uint8List), 'a(b (c) d');
    });

    test('octal and EOL escapes', () {
      final t = Lexer(_ascii('(\\101\\12x\\\n y)')).nextToken();
      expect(t.value, [0x41, 0x0a, 0x78, 0x20, 0x79]);
    });

    test('hex string with whitespace and odd digit count', () {
      final t = Lexer(_ascii('<AB C1 2>')).nextToken();
      expect(t.type, TokenType.hexString);
      expect(t.value, [0xab, 0xc1, 0x20]);
    });

    test('real number forms', () {
      expect(Lexer(_ascii('.5 ')).nextToken().value, 0.5);
      expect(Lexer(_ascii('-.7 ')).nextToken().value, -0.7);
      expect(Lexer(_ascii('4. ')).nextToken().value, 4.0);
      expect(Lexer(_ascii('123 ')).nextToken().value, 123);
    });

    test('comments are skipped', () {
      final lexer = Lexer(_ascii('% hello\n42 '));
      expect(lexer.nextToken().value, 42);
    });
  });

  group('parser', () {
    test('N G R vs numbers', () {
      final p = CosParser(_ascii('[1 0 R 2 3 4 0 R]'));
      final arr = p.parseValueAt(0) as CosArray;
      expect(arr.items, hasLength(4));
      expect(arr[0], const CosRef(1, 0));
      expect((arr[1] as CosNumber).asInt, 2);
      expect((arr[2] as CosNumber).asInt, 3);
      expect(arr[3], const CosRef(4, 0));
    });

    test('dict with nested values', () {
      final p =
          CosParser(_ascii('<</A /B /C [1 2] /D <</E (x)>> /F true /G null>>'));
      final d = p.parseValueAt(0) as CosDict;
      expect(d.nameOf('A'), 'B');
      expect((d['C'] as CosArray).length, 2);
      expect(((d['D'] as CosDict)['E'] as CosString).bytes, [0x78]);
      expect((d['F'] as CosBool).value, isTrue);
      expect(d['G'], isA<CosNull>());
    });

    test('stream with direct /Length', () {
      final src =
          _ascii('1 0 obj\n<</Length 5>>\nstream\nHELLO\nendstream\nendobj\n');
      final obj = CosParser(src).parseIndirectObjectAt(0);
      final s = obj.value as CosStream;
      expect(String.fromCharCodes(s.rawData), 'HELLO');
    });

    test('stream with wrong /Length falls back to endstream scan', () {
      final src =
          _ascii('1 0 obj\n<</Length 99>>\nstream\nHELLO\nendstream\nendobj\n');
      final obj = CosParser(src).parseIndirectObjectAt(0);
      final s = obj.value as CosStream;
      expect(String.fromCharCodes(s.rawData), 'HELLO');
    });
  });

  group('PdfDocument.load fixtures', () {
    for (final name in [
      'minimal_classic.pdf',
      'libreoffice_classic.pdf',
      'synthetic_xrefstream.pdf',
    ]) {
      test(name, () {
        final bytes = File('test/fixtures/$name').readAsBytesSync();
        final doc = PdfDocument.load(Uint8List.fromList(bytes));

        expect(doc.catalog.nameOf('Type'), 'Catalog');
        final (pageRef, page) = doc.firstPage();
        expect(page.nameOf('Type'), 'Page');
        expect(pageRef.objectNumber, greaterThan(0));
        expect(doc.maxObjectNumber, greaterThanOrEqualTo(pageRef.objectNumber));

        // Every non-free entry must resolve.
        for (final e in doc.entries.entries) {
          if (e.value.type == XrefEntryType.free) continue;
          final v = doc.resolve(CosRef(e.key));
          expect(v, isNotNull, reason: 'object ${e.key} did not resolve');
        }
      });
    }

    test('xrefstream fixture: catalog really lives in an ObjStm', () {
      final bytes =
          File('test/fixtures/synthetic_xrefstream.pdf').readAsBytesSync();
      final doc = PdfDocument.load(Uint8List.fromList(bytes));
      expect(doc.xrefStyle, XrefStyle.stream);
      final rootEntry = doc.entries[doc.catalogRef.objectNumber]!;
      expect(rootEntry.type, XrefEntryType.compressed);
    });

    test('libreoffice fixture uses classic tables', () {
      final bytes =
          File('test/fixtures/libreoffice_classic.pdf').readAsBytesSync();
      final doc = PdfDocument.load(Uint8List.fromList(bytes));
      expect(doc.xrefStyle, XrefStyle.table);
      expect(doc.trailer['ID'], isNotNull);
    });

    test('encrypted PDF is rejected', () {
      // Minimal classic fixture with /Encrypt spliced into the trailer.
      final src = latin1
          .decode(File('test/fixtures/minimal_classic.pdf').readAsBytesSync());
      final tampered =
          src.replaceFirst('/Root 1 0 R', '/Root 1 0 R /Encrypt 9 0 R');
      // The trailer moved; keep startxref valid by not shifting anything
      // before it — splice happens after the xref table, so offsets hold.
      expect(
        () => PdfDocument.load(Uint8List.fromList(latin1.encode(tampered))),
        throwsA(isA<EncryptedPdfException>()),
      );
    });

    test('junk before %PDF- header is tolerated', () {
      final bytes = File('test/fixtures/minimal_classic.pdf').readAsBytesSync();
      final junk = _ascii('JUNKJUNK\n');
      final shifted = Uint8List.fromList([...junk, ...bytes]);
      final doc = PdfDocument.load(shifted);
      expect(doc.headerDelta, junk.length);
      expect(doc.catalog.nameOf('Type'), 'Catalog');
    });

    test('not a PDF', () {
      expect(() => PdfDocument.load(_ascii('hello world')),
          throwsA(isA<PdfParseException>()));
    });
  });
}
