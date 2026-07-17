// CMS SignedData (RFC 5652) builder for a detached PDF signature
// (SubFilter /adbe.pkcs7.detached).
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart' show ASN1Parser, ASN1Sequence;
import 'package:pointycastle/export.dart';

import '../exceptions.dart';
import 'der.dart';
import 'oids.dart';
import 'x509_min.dart';

/// SHA-256 over a sequence of byte chunks (streaming, for large ByteRanges).
Uint8List sha256OfParts(Iterable<Uint8List> parts) {
  final digest = SHA256Digest();
  for (final part in parts) {
    digest.update(part, 0, part.length);
  }
  final out = Uint8List(digest.digestSize);
  digest.doFinal(out, 0);
  return out;
}

/// Builds the detached CMS structure for a PDF signature.
///
/// The caller hashes the PDF's ByteRange spans and passes the 32-byte SHA-256
/// digest; the signature itself is made over the DER-sorted signed attributes
/// (contentType + messageDigest), per RFC 5652 §5.4.
class CmsSigner {
  CmsSigner({
    required RSAPrivateKey privateKey,
    required Uint8List certificateDer,
    List<Uint8List> caChainDer = const [],
  })  : _privateKey = privateKey,
        _certificateDer = certificateDer,
        _caChainDer = caChainDer;

  final RSAPrivateKey _privateKey;
  final Uint8List _certificateDer;
  final List<Uint8List> _caChainDer;

  /// ContentInfo(signedData) DER for the given content digest.
  Uint8List buildDetached(Uint8List sha256ContentDigest) {
    if (sha256ContentDigest.length != 32) {
      throw ArgumentError('expected a 32-byte SHA-256 digest');
    }

    // AlgorithmIdentifier for sha256 — parameters absent (RFC 5754 §2).
    final algSha256 = derSequence([derOid(oidSha256)]);
    // rsaEncryption requires explicit NULL parameters (RFC 3370 §3.2).
    final algRsa = derSequence([derOid(oidRsaEncryption), derNull()]);

    // Signed attributes, DER-sorted as SET OF.
    final attrContentType = derSequence([
      derOid(oidAttrContentType),
      derSet([derOid(oidData)]),
    ]);
    final attrMessageDigest = derSequence([
      derOid(oidAttrMessageDigest),
      derSet([derOctetString(sha256ContentDigest)]),
    ]);
    final signedAttrsSet = derSetOf([attrContentType, attrMessageDigest]);

    // Sign the attributes with their real SET OF tag (0x31)...
    final signature = _signRsaSha256(signedAttrsSet);
    // ...but embed them IMPLICIT [0] (0xA0) inside SignerInfo.
    final signedAttrsImplicit = Uint8List.fromList(signedAttrsSet)..[0] = 0xa0;

    final issuerAndSerial = derSequence([
      _issuerDer(),
      derIntegerRaw(extractSerialNumberDer(_certificateDer)),
    ]);

    final signerInfo = derSequence([
      derSmallInt(1),
      issuerAndSerial,
      algSha256,
      signedAttrsImplicit,
      algRsa,
      derOctetString(signature),
    ]);

    final encapContentInfo = derSequence([derOid(oidData)]); // detached

    final certificates = derContextConstructed(0, [
      _certificateDer,
      ..._caChainDer,
    ]);

    final signedData = derSequence([
      derSmallInt(1),
      derSet([algSha256]),
      encapContentInfo,
      certificates,
      derSet([signerInfo]),
    ]);

    return derSequence([
      derOid(oidSignedData),
      derTlv(0xa0, signedData), // content [0] EXPLICIT
    ]);
  }

  Uint8List _issuerDer() {
    // TBSCertificate: [0] version (optional), serialNumber, signature, issuer.
    final top = ASN1Parser(_certificateDer).nextObject();
    if (top is! ASN1Sequence || top.elements == null || top.elements!.isEmpty) {
      throw SigningCredentialsException('certificate is not a SEQUENCE');
    }
    final tbs = top.elements![0];
    if (tbs is! ASN1Sequence || tbs.elements == null) {
      throw SigningCredentialsException('TBSCertificate is not a SEQUENCE');
    }
    final elements = tbs.elements!;
    final base = (elements[0].tag == 0xA0) ? 1 : 0;
    if (elements.length < base + 3) {
      throw SigningCredentialsException('TBSCertificate too short');
    }
    return Uint8List.fromList(elements[base + 2].encodedBytes!);
  }

  Uint8List _signRsaSha256(Uint8List data) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
    signer.init(true, PrivateKeyParameter<RSAPrivateKey>(_privateKey));
    return signer.generateSignature(data).bytes;
  }
}
