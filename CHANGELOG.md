# Changelog

## 0.1.1

- `dart format` applied to the whole codebase (no functional changes).
- Added GitHub Actions CI (analyze, format check, tests on Linux/Windows).

## 0.1.0

- Initial release: PAdES-B-B (`/adbe.pkcs7.detached`) signing of existing
  PDFs as an incremental update, pure Dart (pointycastle + pkcs12_parser).
- Reads classic xref tables, xref streams, `/Prev` chains, hybrid
  `/XRefStm`, and object streams; writes the update xref in the original's
  style.
- RSA + SHA-256, DER-sorted signed attributes, certificate chain embedded,
  invisible signature field, multiple-signature support.
- Typed error taxonomy (encrypted input, DocMDP P=1, unsupported filters,
  oversized CMS).
