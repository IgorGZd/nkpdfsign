// Minimal X.509 field extraction — just what CMS SignerInfo needs beyond what
// pkcs12_parser's X509CertificateDer already exposes (issuerDer).
//
// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
// TBSCertificate ::= SEQUENCE { version [0] EXPLICIT OPTIONAL, serialNumber
//   INTEGER, ... }
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';

import '../exceptions.dart';

/// Returns the raw content bytes of the certificate's serialNumber INTEGER
/// (sign-preserving, ready to re-emit via derIntegerRaw).
Uint8List extractSerialNumberDer(Uint8List certificateDer) {
  final ASN1Object top;
  try {
    top = ASN1Parser(certificateDer).nextObject();
  } catch (e) {
    throw SigningCredentialsException('cannot parse certificate DER: $e');
  }
  if (top is! ASN1Sequence || top.elements == null || top.elements!.isEmpty) {
    throw SigningCredentialsException('certificate is not a SEQUENCE');
  }
  final tbs = top.elements![0];
  if (tbs is! ASN1Sequence || tbs.elements == null || tbs.elements!.length < 2) {
    throw SigningCredentialsException('TBSCertificate is not a SEQUENCE');
  }
  final elements = tbs.elements!;
  final base = (elements[0].tag == 0xA0) ? 1 : 0;
  final serial = elements[base];
  if (serial is! ASN1Integer) {
    throw SigningCredentialsException('serialNumber is not an INTEGER');
  }
  return Uint8List.fromList(serial.valueBytes!);
}
