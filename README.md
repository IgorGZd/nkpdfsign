# nkpdfsign

Pure Dart digital signing of **existing** PDF documents — PAdES-B-B level,
`/adbe.pkcs7.detached` (CMS/PKCS#7) with the full certificate chain embedded.
Runs server-side on the Dart VM (Windows/Linux/macOS) with **no Flutter, no
Java, no native dependencies**.

Companion package to [`pkcs12_parser`](https://pub.dev/packages/pkcs12_parser),
which supplies the signing identity from a `.p12`/`.pfx` file.

## Features

- Signs arbitrary existing PDFs — not just documents this library created.
- Reads classic xref tables **and** cross-reference streams (PDF 1.5+),
  `/Prev` chains, hybrid-reference files (`/XRefStm`), and object streams
  (`/ObjStm`).
- Appends a proper **incremental update** in the same xref style as the
  original file, so prior revisions — including existing signatures — stay
  byte-for-byte intact. Signing twice yields two valid signatures.
- CMS `SignedData` per RFC 5652: SHA-256, RSA PKCS#1 v1.5, DER-sorted signed
  attributes (`contentType`, `messageDigest`), certificate chain included,
  no `signingTime` attribute (PAdES uses the dictionary's `/M` instead).
- Invisible signature field (zero rect) wired into `/AcroForm` and the first
  page's `/Annots`.
- Typed exceptions — the library refuses to emit a plausibly-broken file
  (encrypted input, DocMDP P=1 certification, exotic filters, oversized CMS).

## Usage

```dart
import 'dart:io';
import 'package:nkpdfsign/nkpdfsign.dart';

void main() {
  final p12 = Pkcs12.load(File('identity.p12').readAsBytesSync(), 'password');
  final signer = NkPdfSigner(SigningCredentials.fromPkcs12(p12));

  final signed = signer.sign(
    File('document.pdf').readAsBytesSync(),
    reason: 'Approval',
    location: 'Zagreb',
    signerName: 'Jane Doe',
  );

  File('document-signed.pdf').writeAsBytesSync(signed);
}
```

Credentials can also be built directly from a pointycastle `RSAPrivateKey`
plus DER certificates via the `SigningCredentials` constructor.

### CLI

```
dart run nkpdfsign input.pdf identity.p12 password [output.pdf] \
    [--reason=...] [--location=...] [--contact=...] [--name=...]
```

## Scope and limitations (v1)

| Area | Status |
| --- | --- |
| Signature level | PAdES-B-B (no timestamp, no LTV) |
| SubFilter | `/adbe.pkcs7.detached` |
| Keys | RSA (2048+). EC planned. |
| Appearance | Invisible only (no visible signature block) |
| Encrypted PDFs | Rejected (`EncryptedPdfException`) |
| DocMDP P=1 certified docs | Rejected (`DocMdpViolationException`) |
| Stream filters on xref/ObjStm | FlateDecode (+ TIFF/PNG predictors) only |
| Linearized PDFs | Signed fine; output is no longer linearized (harmless) |

If the CMS exceeds the reserved `/Contents` space, a
`SignatureTooLargeException` tells you the exact `signatureSizeEstimate` to
pass.

## Verifying the output

- **Adobe Acrobat Reader**: open the signed file → signature panel →
  "Signature is valid, document has not been modified". (Trust for a test CA
  must be added manually.)
- **openssl**: extract `/Contents` and the two ByteRange spans, then
  `openssl cms -verify -inform DER -in sig.der -content spans.bin -binary -noverify`.
- **pyHanko**: `pyhanko sign validate signed.pdf`.

The test suite (`dart test`) does all of the structural checks and — when an
`openssl` binary is available — cryptographic cross-verification
automatically.
