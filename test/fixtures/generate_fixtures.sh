#!/bin/sh
# One-time generation of the test signing identity (requires OpenSSL 3.x).
# The generated certificates, keys and .p12 are committed to the repo;
# OpenSSL is NOT a runtime dependency of this package (tests only use it
# opportunistically for cross-verification when a binary is found).
#
# The PDF fixtures (minimal_classic.pdf, synthetic_xrefstream.pdf) are
# generated separately: dart run tool/gen_fixtures.dart
set -eu
cd "$(dirname "$0")"

# Prevent Git Bash / MSYS from rewriting "/CN=..." into a Windows path.
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

P=test1234

# Self-signed test CA (RSA-2048, SHA-256, ~20 years).
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout ca.key -out ca.crt \
  -subj "/CN=NK Test CA/O=NKTest/C=HR" \
  -addext "basicConstraints=critical,CA:TRUE"

# Leaf signing certificate issued by the CA.
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
  -subj "/CN=NK Test Signer/O=NKTest/C=HR"
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -sha256 -days 7300 -out leaf.crt \
  -extfile - <<EOF
keyUsage = critical, digitalSignature, nonRepudiation
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
EOF

# PKCS#12 container with the full chain (OpenSSL 3.x defaults:
# PBES2 / PBKDF2-hmacSHA256 / AES-256-CBC, SHA-256 MAC).
openssl pkcs12 -export -in leaf.crt -inkey leaf.key -certfile ca.crt \
  -out test_signer.p12 -passout pass:$P

rm -f leaf.csr ca.srl

echo "Fixtures generated."
