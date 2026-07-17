// Public API: NkPdfSigner orchestrates the whole pipeline —
// load -> reject unsupported -> placeholder -> incremental section ->
// ByteRange patch -> hash -> CMS -> splice.
import 'dart:typed_data';

import 'package:pkcs12_parser/pkcs12_parser.dart';

import 'cms/signed_data.dart';
import 'cos/objects.dart';
import 'exceptions.dart';
import 'pdf/document.dart';
import 'pdf/incremental.dart';
import 'sign/byterange.dart';
import 'sign/placeholder.dart';

/// Signing identity: private key + certificate chain. Decoupled from PKCS#12
/// so PEM/DER-sourced credentials work too.
class SigningCredentials {
  SigningCredentials({
    required PrivateKey privateKey,
    required this.certificateDer,
    this.caChainDer = const [],
  }) : privateKey = _requireRsa(privateKey);

  factory SigningCredentials.fromPkcs12(Pkcs12 p12) => SigningCredentials(
        privateKey: p12.privateKey,
        certificateDer: p12.certificate.der,
        caChainDer: [for (final c in p12.caChain) c.der],
      );

  final RSAPrivateKey privateKey;
  final Uint8List certificateDer;
  final List<Uint8List> caChainDer;

  static RSAPrivateKey _requireRsa(PrivateKey key) {
    if (key is RSAPrivateKey) return key;
    throw SigningCredentialsException(
        'only RSA keys are supported in this version '
        '(got ${key.runtimeType})');
  }
}

class NkPdfSigner {
  NkPdfSigner(this.credentials);

  final SigningCredentials credentials;

  /// Signs [pdfBytes] with an invisible PAdES-B-B signature
  /// (`/adbe.pkcs7.detached`) appended as an incremental update.
  /// Existing signatures remain valid; signing twice adds a second field.
  Uint8List sign(
    Uint8List pdfBytes, {
    String fieldName = 'Signature1',
    String? reason,
    String? location,
    String? contactInfo,
    String? signerName,
    DateTime? signingTime,
    int? signatureSizeEstimate,
  }) {
    final document = PdfDocument.load(pdfBytes);
    _checkDocMdp(document);

    final reserved = signatureSizeEstimate ?? _defaultReservation();

    final updater = IncrementalUpdater(document);
    final placeholder = addSignaturePlaceholder(
      document,
      updater,
      fieldName: fieldName,
      signatureSizeBytes: reserved,
      reason: reason,
      location: location,
      contactInfo: contactInfo,
      signerName: signerName,
      signingTime: signingTime,
    );

    final rawOffsets = <CosRaw, int>{};
    final bytes = updater.build(rawOffsets: rawOffsets);
    final slots = SignatureSlots.fromPlaceholder(placeholder, rawOffsets);

    patchByteRange(bytes, slots);
    final digest = sha256OfParts(byteRangeSpans(bytes, slots));

    final cms = CmsSigner(
      privateKey: credentials.privateKey,
      certificateDer: credentials.certificateDer,
      caChainDer: credentials.caChainDer,
    ).buildDetached(digest);

    spliceCms(bytes, slots, cms);
    return bytes;
  }

  int _defaultReservation() {
    var certsTotal = credentials.certificateDer.length;
    for (final c in credentials.caChainDer) {
      certsTotal += c.length;
    }
    final needed = 2048 + certsTotal;
    return ((needed + 1023) ~/ 1024) * 1024;
  }

  /// Rejects documents whose certification signature forbids all changes
  /// (DocMDP transform with P=1); P=2/3 permit form-fill/annotations, which
  /// covers adding a signature field.
  void _checkDocMdp(PdfDocument document) {
    final perms = document.resolve(document.catalog['Perms']);
    if (perms is! CosDict) return;
    final docMdpSig = document.resolve(perms['DocMDP']);
    if (docMdpSig is! CosDict) return;
    final references = document.resolve(docMdpSig['Reference']);
    if (references is! CosArray) return;
    for (final r in references.items) {
      final ref = document.resolve(r);
      if (ref is! CosDict) continue;
      if (ref.nameOf('TransformMethod') != 'DocMDP') continue;
      final params = document.resolve(ref['TransformParams']);
      final p = params is CosDict ? (params.intOf('P') ?? 2) : 2;
      if (p == 1) throw DocMdpViolationException();
    }
  }
}
