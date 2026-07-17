import 'dart:io';

import 'package:nkpdfsign/nkpdfsign.dart';

void main() {
  // Load the signing identity from a PKCS#12 (.p12/.pfx) file.
  final p12 = Pkcs12.load(
    File('test/fixtures/test_signer.p12').readAsBytesSync(),
    'test1234',
  );

  final signer = NkPdfSigner(SigningCredentials.fromPkcs12(p12));

  final signed = signer.sign(
    File('test/fixtures/libreoffice_classic.pdf').readAsBytesSync(),
    reason: 'Approval',
    location: 'Zagreb',
    signerName: 'NK Test Signer',
  );

  File('signed_sample.pdf').writeAsBytesSync(signed);
  print('wrote signed_sample.pdf (${signed.length} bytes)');
}
