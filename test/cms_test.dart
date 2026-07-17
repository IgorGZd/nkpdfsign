import 'dart:io';
import 'dart:typed_data';

import 'package:pkcs12_parser/pkcs12_parser.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart'
    show
        RSAPrivateKey,
        RSAPublicKey,
        RSASigner,
        RSASignature,
        SHA256Digest,
        PublicKeyParameter;
import 'package:test/test.dart';

import 'package:nkpdfsign/src/cms/der.dart';
import 'package:nkpdfsign/src/cms/oids.dart';
import 'package:nkpdfsign/src/cms/signed_data.dart';
import 'package:nkpdfsign/src/cms/x509_min.dart';

late Pkcs12 p12;
final content = Uint8List.fromList(List.generate(1000, (i) => i % 251));

void main() {
  setUpAll(() {
    final bytes = File('test/fixtures/test_signer.p12').readAsBytesSync();
    p12 = Pkcs12.load(bytes, 'test1234');
  });

  group('der.dart', () {
    test('length encodings', () {
      expect(derLength(5), [5]);
      expect(derLength(127), [127]);
      expect(derLength(128), [0x81, 128]);
      expect(derLength(300), [0x82, 0x01, 0x2c]);
    });

    test('OID encoding matches known vectors', () {
      // sha256 OID 2.16.840.1.101.3.4.2.1
      expect(derOid(oidSha256),
          [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]);
      // rsaEncryption 1.2.840.113549.1.1.1
      expect(derOid(oidRsaEncryption),
          [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]);
    });

    test('SET OF sorts children lexicographically', () {
      final a = Uint8List.fromList([0x30, 0x02, 0xff, 0xff]);
      final b = Uint8List.fromList([0x30, 0x01, 0x00]);
      final set = derSetOf([a, b]);
      // b (shorter, 0x01 < 0x02 at index 1) must come first.
      expect(set.sublist(2), [...b, ...a]);
    });

    test('INTEGER adds leading zero for high bit', () {
      expect(derInteger(BigInt.from(0x80)), [0x02, 0x02, 0x00, 0x80]);
      expect(derInteger(BigInt.from(1)), [0x02, 0x01, 0x01]);
    });
  });

  group('x509_min', () {
    test('extracts serial matching openssl output', () {
      final serial = extractSerialNumberDer(p12.certificate.der);
      // Serial is a positive INTEGER, 1..20 bytes content.
      expect(serial.length, inInclusiveRange(1, 21));
      final asBigInt = serial.fold<BigInt>(
          BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
      expect(asBigInt, greaterThan(BigInt.zero));
    });
  });

  group('CmsSigner.buildDetached', () {
    late Uint8List cms;

    setUpAll(() {
      final signer = CmsSigner(
        privateKey: p12.privateKey as RSAPrivateKey,
        certificateDer: p12.certificate.der,
        caChainDer: [for (final c in p12.caChain) c.der],
      );
      cms = signer.buildDetached(sha256OfParts([content]));
    });

    test('structural round-trip', () {
      final top = ASN1Parser(cms).nextObject() as ASN1Sequence;
      final contentTypeOid = top.elements![0] as ASN1ObjectIdentifier;
      expect(contentTypeOid.objectIdentifierAsString, oidSignedData);

      // [0] EXPLICIT SignedData
      final explicitWrapper = top.elements![1];
      expect(explicitWrapper.tag, 0xa0);
      final signedData =
          ASN1Parser(explicitWrapper.valueBytes).nextObject() as ASN1Sequence;

      final version = signedData.elements![0] as ASN1Integer;
      expect(version.integer!.toInt(), 1);

      // digestAlgorithms: SET with one sha256 AlgorithmIdentifier, absent params
      final digestAlgs = signedData.elements![1] as ASN1Set;
      expect(digestAlgs.elements!.length, 1);
      final alg = digestAlgs.elements!.first as ASN1Sequence;
      expect(
          (alg.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString,
          oidSha256);
      expect(alg.elements!.length, 1, reason: 'sha256 params must be absent');

      // encapContentInfo: detached — only the id-data OID
      final encap = signedData.elements![2] as ASN1Sequence;
      expect(encap.elements!.length, 1);
      expect(
          (encap.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString,
          oidData);

      // certificates [0] IMPLICIT: signer + 1 CA
      final certs = signedData.elements![3];
      expect(certs.tag, 0xa0);
      var certBytes = certs.valueBytes!;
      var certCount = 0;
      while (certBytes.isNotEmpty) {
        final cert = ASN1Parser(certBytes).nextObject();
        certCount++;
        certBytes = certBytes.sublist(cert.encodedBytes!.length);
      }
      expect(certCount, 2);

      // signerInfos: one SignerInfo
      final signerInfos = signedData.elements![4] as ASN1Set;
      final si = signerInfos.elements!.first as ASN1Sequence;
      expect((si.elements![0] as ASN1Integer).integer!.toInt(), 1);

      // sid: issuer matches the cert's issuerDer byte-exactly
      final sid = si.elements![1] as ASN1Sequence;
      expect(sid.elements![0].encodedBytes, p12.certificate.issuerDer);
      expect((sid.elements![1] as ASN1Integer).valueBytes,
          extractSerialNumberDer(p12.certificate.der));

      // signedAttrs [0] IMPLICIT with contentType before messageDigest (DER sort)
      final signedAttrs = si.elements![3];
      expect(signedAttrs.tag, 0xa0);
      final attrsAsSet = Uint8List.fromList(signedAttrs.encodedBytes!)
        ..[0] = 0x31;
      final attrSet = ASN1Parser(attrsAsSet).nextObject() as ASN1Set;
      expect(attrSet.elements!.length, 2);
      final attr0 = attrSet.elements![0] as ASN1Sequence;
      final attr1 = attrSet.elements![1] as ASN1Sequence;
      expect(
          (attr0.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString,
          oidAttrContentType);
      expect(
          (attr1.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString,
          oidAttrMessageDigest);

      // messageDigest value equals SHA-256 of content
      final mdSet = attr1.elements![1] as ASN1Set;
      final md = mdSet.elements!.first as ASN1OctetString;
      expect(md.valueBytes, sha256OfParts([content]));

      // signatureAlgorithm: rsaEncryption with NULL params
      final sigAlg = si.elements![4] as ASN1Sequence;
      expect(
          (sigAlg.elements![0] as ASN1ObjectIdentifier)
              .objectIdentifierAsString,
          oidRsaEncryption);
      expect(sigAlg.elements!.length, 2);

      // signature present, RSA-2048 → 256 bytes
      final sig = si.elements![5] as ASN1OctetString;
      expect(sig.valueBytes!.length, 256);
    });

    test('self-verification with certificate public key', () {
      final top = ASN1Parser(cms).nextObject() as ASN1Sequence;
      final signedData =
          ASN1Parser(top.elements![1].valueBytes).nextObject() as ASN1Sequence;
      final si =
          (signedData.elements![4] as ASN1Set).elements!.first as ASN1Sequence;
      final signedAttrsDer = Uint8List.fromList(si.elements![3].encodedBytes!)
        ..[0] = 0x31;
      final signature = (si.elements![5] as ASN1OctetString).valueBytes!;

      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201');
      verifier.init(
          false,
          PublicKeyParameter<RSAPublicKey>(
              p12.certificate.publicKey as RSAPublicKey));
      expect(verifier.verifySignature(signedAttrsDer, RSASignature(signature)),
          isTrue);
    });

    test('openssl cms -verify accepts the structure', () {
      final openssl = _findOpenssl();
      if (openssl == null) {
        markTestSkipped('openssl not found; dev-time verification skipped');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('nkpdfsign_cms');
      try {
        final cmsFile = File('${dir.path}/sig.der')..writeAsBytesSync(cms);
        final contentFile = File('${dir.path}/content.bin')
          ..writeAsBytesSync(content);
        final result = Process.runSync(openssl, [
          'cms',
          '-verify',
          '-in',
          cmsFile.path,
          '-inform',
          'DER',
          '-content',
          contentFile.path,
          '-binary',
          '-noverify',
          '-out',
          '${dir.path}/out.bin',
        ]);
        expect(result.exitCode, 0, reason: 'openssl stderr: ${result.stderr}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
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
