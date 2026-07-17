// CLI: sign a PDF with a PKCS#12 (.p12/.pfx) identity.
//
//   dart run nkpdfsign <input.pdf> <certificate.p12> <password> [output.pdf]
//       [--reason=...] [--location=...] [--contact=...] [--name=...]
import 'dart:io';

import 'package:nkpdfsign/nkpdfsign.dart';

void main(List<String> args) {
  final positional = <String>[];
  final options = <String, String>{};
  for (final a in args) {
    if (a.startsWith('--')) {
      final eq = a.indexOf('=');
      if (eq < 0) {
        stderr.writeln('option "$a" needs =value');
        exit(2);
      }
      options[a.substring(2, eq)] = a.substring(eq + 1);
    } else {
      positional.add(a);
    }
  }

  if (positional.length < 3 || positional.length > 4) {
    stderr.writeln(
        'usage: nkpdfsign <input.pdf> <certificate.p12> <password> [output.pdf]\n'
        '       [--reason=...] [--location=...] [--contact=...] [--name=...]');
    exit(2);
  }

  final inputPath = positional[0];
  final p12Path = positional[1];
  final password = positional[2];
  final outputPath = positional.length == 4
      ? positional[3]
      : '${inputPath.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '')}-signed.pdf';

  try {
    final p12 = Pkcs12.load(File(p12Path).readAsBytesSync(), password);
    final signer = NkPdfSigner(SigningCredentials.fromPkcs12(p12));
    final signed = signer.sign(
      File(inputPath).readAsBytesSync(),
      reason: options['reason'],
      location: options['location'],
      contactInfo: options['contact'],
      signerName: options['name'],
    );
    File(outputPath).writeAsBytesSync(signed);
    stdout.writeln('signed: $outputPath (${signed.length} bytes)');
  } on NkPdfSignException catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  } on FileSystemException catch (e) {
    stderr.writeln('error: ${e.message}: ${e.path}');
    exit(1);
  }
}
