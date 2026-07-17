/// Pure Dart digital signing of existing PDF documents (PAdES-B-B,
/// `/adbe.pkcs7.detached`) via incremental updates.
///
/// ```dart
/// final p12 = Pkcs12.load(p12Bytes, 'password');
/// final signer = NkPdfSigner(SigningCredentials.fromPkcs12(p12));
/// final signed = signer.sign(pdfBytes, reason: 'Approval');
/// ```
library;

export 'package:pkcs12_parser/pkcs12_parser.dart' show Pkcs12;

export 'src/exceptions.dart';
export 'src/signer.dart' show NkPdfSigner, SigningCredentials;
