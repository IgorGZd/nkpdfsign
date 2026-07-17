// Dev tool: structural + openssl verification of a signed PDF.
//   dart run tool/verify_signed.dart <signed.pdf>
import 'dart:io';
import 'dart:typed_data';

import 'package:nkpdfsign/src/cos/objects.dart';
import 'package:nkpdfsign/src/pdf/document.dart';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final doc = PdfDocument.load(bytes);
  print('xref style: ${doc.xrefStyle}');

  final acro = doc.resolve(doc.catalog['AcroForm']) as CosDict;
  final fields = doc.resolve(acro['Fields']) as CosArray;
  print('fields: ${fields.length}');
  final field = doc.resolve(fields[fields.length - 1]) as CosDict;
  final sig = doc.resolve(field['V']) as CosDict;
  print('subfilter: ${sig.nameOf('SubFilter')}');

  final br = doc.resolve(sig['ByteRange']) as CosArray;
  final v = [for (final e in br.items) (e as CosNumber).asInt];
  print('byteRange: $v (file: ${bytes.length})');
  if (v[2] + v[3] != bytes.length) {
    stderr.writeln('FAIL: ByteRange does not span the file');
    exit(1);
  }

  final contents = doc.resolve(sig['Contents']) as CosString;
  final cms = _trimDer(contents.bytes);
  print('cms: ${cms.length} bytes DER');

  final dir = Directory.systemTemp.createTempSync('nkverify');
  try {
    File('${dir.path}/sig.der').writeAsBytesSync(cms);
    final content = BytesBuilder()
      ..add(bytes.sublist(v[0], v[0] + v[1]))
      ..add(bytes.sublist(v[2], v[2] + v[3]));
    File('${dir.path}/content.bin').writeAsBytesSync(content.takeBytes());
    final openssl = _findOpenssl();
    if (openssl == null) {
      stderr.writeln('openssl not found; skipping cryptographic check');
      exit(0);
    }
    final r = Process.runSync(openssl, [
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
    print(r.exitCode == 0
        ? 'openssl: signature VALID'
        : 'openssl FAILED: ${r.stderr}');
    exit(r.exitCode == 0 ? 0 : 1);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

String? _findOpenssl() {
  const candidates = [
    'openssl',
    r'C:\Program Files\Git\mingw64\bin\openssl.exe',
    r'C:\Program Files\Git\usr\bin\openssl.exe',
  ];
  for (final c in candidates) {
    try {
      if (Process.runSync(c, ['version']).exitCode == 0) return c;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}

Uint8List _trimDer(Uint8List padded) {
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
