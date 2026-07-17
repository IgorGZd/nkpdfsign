import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nkpdfsign/nkpdfsign.dart';
import 'package:test/test.dart';

import 'package:nkpdfsign/src/cos/objects.dart';
import 'package:nkpdfsign/src/pdf/document.dart';
import 'package:nkpdfsign/src/pdf/xref.dart';

late NkPdfSigner signer;

void main() {
  setUpAll(() {
    final p12 = Pkcs12.load(
        File('test/fixtures/test_signer.p12').readAsBytesSync(), 'test1234');
    signer = NkPdfSigner(SigningCredentials.fromPkcs12(p12));
  });

  for (final name in [
    'minimal_classic.pdf',
    'libreoffice_classic.pdf',
    'synthetic_xrefstream.pdf',
  ]) {
    group('signing $name', () {
      late Uint8List original;
      late Uint8List signed;

      setUpAll(() {
        original = File('test/fixtures/$name').readAsBytesSync();
        signed = signer.sign(original,
            reason: 'Test', location: 'Zagreb', signerName: 'NK Test Signer');
      });

      test('original bytes are a strict prefix of the output', () {
        expect(signed.length, greaterThan(original.length));
        expect(Uint8List.sublistView(signed, 0, original.length), original);
      });

      test('output reopens with our own loader, xref style preserved', () {
        final before = PdfDocument.load(original);
        final doc = PdfDocument.load(signed);
        expect(doc.xrefStyle, before.xrefStyle);
        expect(doc.catalog.nameOf('Type'), 'Catalog');
        // Every non-free entry still resolves after the update.
        for (final e in doc.entries.entries) {
          if (e.value.type == XrefEntryType.free) continue;
          expect(doc.resolve(CosRef(e.key)), isNotNull,
              reason: 'object ${e.key} did not resolve');
        }
      });

      test('signature field is wired into AcroForm and page annots', () {
        final doc = PdfDocument.load(signed);
        final acro = doc.resolve(doc.catalog['AcroForm']) as CosDict;
        expect((doc.resolve(acro['SigFlags']) as CosNumber).asInt, 3);
        final fields = doc.resolve(acro['Fields']) as CosArray;
        expect(fields.length, greaterThanOrEqualTo(1));
        final field = doc.resolve(fields[fields.length - 1]) as CosDict;
        expect(field.nameOf('FT'), 'Sig');
        expect(latin1.decode((field['T'] as CosString).bytes), 'Signature1');

        final sig = doc.resolve(field['V']) as CosDict;
        expect(sig.nameOf('Type'), 'Sig');
        expect(sig.nameOf('SubFilter'), 'adbe.pkcs7.detached');

        final (_, page) = doc.firstPage();
        final annots = doc.resolve(page['Annots']) as CosArray;
        expect(annots.items, isNotEmpty);
      });

      test('ByteRange covers everything except the Contents hex', () {
        final doc = PdfDocument.load(signed);
        final sig = _findSigDict(doc);
        final br = doc.resolve(sig['ByteRange']) as CosArray;
        final v = [for (final e in br.items) (e as CosNumber).asInt];
        expect(v[0], 0);
        expect(v[1] + (v[2] - v[1]) + v[3], signed.length);
        // Span between v[1] and v[2] must be exactly <hex>.
        expect(signed[v[1]], 0x3c);
        expect(signed[v[2] - 1], 0x3e);
        expect(v[1] + v[3] + (v[2] - v[1]), signed.length);
      });

      test('openssl verifies the embedded CMS over the byte ranges', () {
        final openssl = _findOpenssl();
        if (openssl == null) {
          markTestSkipped('openssl not found');
          return;
        }
        final doc = PdfDocument.load(signed);
        final sig = _findSigDict(doc);
        final br = doc.resolve(sig['ByteRange']) as CosArray;
        final v = [for (final e in br.items) (e as CosNumber).asInt];
        final contents = doc.resolve(sig['Contents']) as CosString;
        // Trim zero-padding: DER length is encoded in the first bytes.
        final cms = _trimDer(contents.bytes);

        final dir = Directory.systemTemp.createTempSync('nkpdfsign_e2e');
        try {
          File('${dir.path}/sig.der').writeAsBytesSync(cms);
          final content = BytesBuilder()
            ..add(signed.sublist(v[0], v[0] + v[1]))
            ..add(signed.sublist(v[2], v[2] + v[3]));
          File('${dir.path}/content.bin').writeAsBytesSync(content.takeBytes());
          final result = Process.runSync(openssl, [
            'cms',
            '-verify',
            '-in',
            '${dir.path}/sig.der',
            '-inform',
            'DER',
            '-content',
            '${dir.path}/content.bin',
            '-binary',
            '-noverify',
            '-out',
            '${dir.path}/out.bin',
          ]);
          expect(result.exitCode, 0, reason: 'openssl: ${result.stderr}');
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    });
  }

  test('double signing keeps the first signature bytes intact', () {
    final original =
        File('test/fixtures/libreoffice_classic.pdf').readAsBytesSync();
    final once = signer.sign(original, signingTime: DateTime.utc(2026, 7, 17));
    final twice = signer.sign(once, signingTime: DateTime.utc(2026, 7, 18));

    expect(Uint8List.sublistView(twice, 0, once.length), once,
        reason: 'second signature must not touch the first revision');

    final doc = PdfDocument.load(twice);
    final acro = doc.resolve(doc.catalog['AcroForm']) as CosDict;
    final fields = doc.resolve(acro['Fields']) as CosArray;
    expect(fields.length, 2);
    final names = <String>{};
    for (final f in fields.items) {
      final field = doc.resolve(f) as CosDict;
      names.add(latin1.decode((field['T'] as CosString).bytes));
    }
    expect(names, {'Signature1', 'Signature2'});
  });

  test('too-small reservation throws SignatureTooLargeException', () {
    final original =
        File('test/fixtures/minimal_classic.pdf').readAsBytesSync();
    expect(
      () => signer.sign(original, signatureSizeEstimate: 100),
      throwsA(isA<SignatureTooLargeException>()),
    );
  });
}

CosDict _findSigDict(PdfDocument doc) {
  final acro = doc.resolve(doc.catalog['AcroForm']) as CosDict;
  final fields = doc.resolve(acro['Fields']) as CosArray;
  final field = doc.resolve(fields[fields.length - 1]) as CosDict;
  return doc.resolve(field['V']) as CosDict;
}

/// Cuts a DER TLV out of a zero-padded buffer using its encoded length.
Uint8List _trimDer(Uint8List padded) {
  if (padded.length < 2) return padded;
  var len = 0;
  var headerLen = 2;
  final l0 = padded[1];
  if (l0 < 0x80) {
    len = l0;
  } else {
    final n = l0 & 0x7f;
    headerLen = 2 + n;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | padded[2 + i];
    }
  }
  return Uint8List.sublistView(padded, 0, headerLen + len);
}

String? _findOpenssl() {
  const candidates = [
    'openssl',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
  ];
  for (final c in candidates) {
    try {
      final r = Process.runSync(c, ['version']);
      if (r.exitCode == 0) return c;
    } catch (_) {}
  }
  return null;
}
