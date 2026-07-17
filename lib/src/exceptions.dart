/// Exception hierarchy for nkpdfsign.
///
/// The library never emits a plausibly-broken signed file: any condition it
/// cannot handle correctly raises a typed [NkPdfSignException] instead.
sealed class NkPdfSignException implements Exception {
  NkPdfSignException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The input PDF could not be parsed (broken xref, malformed objects, ...).
class PdfParseException extends NkPdfSignException {
  PdfParseException(super.message);
}

/// The input PDF is encrypted (`/Encrypt` in the trailer). Signing encrypted
/// documents requires crypt-filter support and is out of scope.
class EncryptedPdfException extends NkPdfSignException {
  EncryptedPdfException([String? message])
      : super(message ?? 'PDF is encrypted; signing encrypted documents is not supported');
}

/// The PDF uses a feature this library does not support (e.g. an exotic
/// stream filter on the xref or object stream).
class UnsupportedPdfException extends NkPdfSignException {
  UnsupportedPdfException(super.message);
}

/// An existing certification signature forbids any further changes
/// (DocMDP permission P=1); adding a signature would invalidate it.
class DocMdpViolationException extends NkPdfSignException {
  DocMdpViolationException([String? message])
      : super(message ??
            'Document has a certification signature that forbids changes (DocMDP P=1)');
}

/// The produced CMS structure is larger than the space reserved in
/// `/Contents`. Retry with a larger `signatureSizeEstimate`.
class SignatureTooLargeException extends NkPdfSignException {
  SignatureTooLargeException(this.neededBytes, this.reservedBytes)
      : super('CMS signature needs $neededBytes bytes but only '
            '$reservedBytes were reserved; pass signatureSizeEstimate: $neededBytes or more');

  final int neededBytes;
  final int reservedBytes;
}

/// The signing credentials are unusable (unsupported key type, missing
/// certificate, ...).
class SigningCredentialsException extends NkPdfSignException {
  SigningCredentialsException(super.message);
}
