# Test fixtures

## Signing identity (throwaway, test-only)

`ca.crt`/`ca.key`, `leaf.crt`/`leaf.key` and `test_signer.p12` form a
synthetic signing identity (CN=NK Test Signer, issued by CN=NK Test CA),
generated **once** with `generate_fixtures.sh` (OpenSSL 3.x) and committed
to the repo. They secure nothing — the private keys and the container
password (`test1234`) are intentionally public.

To regenerate (Git Bash on Windows works; the script disables MSYS path
mangling itself):

```sh
sh test/fixtures/generate_fixtures.sh
```

## PDF corpus

| Fixture | Covers |
|---|---|
| `minimal_classic.pdf` | PDF 1.4, classic xref table, uncompressed objects |
| `synthetic_xrefstream.pdf` | PDF 1.5, xref stream (Flate + PNG Up predictor), Catalog/Pages/Page inside an `/ObjStm` |
| `libreoffice_classic.pdf` | Real-world file exported from LibreOffice Writer (classic xref) |

The two synthetic PDFs are deterministic and regenerable with:

```sh
dart run tool/gen_fixtures.dart
```
