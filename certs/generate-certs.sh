#!/usr/bin/env bash
#
# mTLS JakeBx Certificate Generation Script
# Generates CA, server, and client certificates for mTLS
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}"
DAYS_CA=3650        # 10 years for CA
DAYS_CERT=365       # 1 year for server/client certs
KEY_SIZE=4096
ENCRYPTED_KEY_PASSPHRASE="changeit"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    log_error "OpenSSL is not installed or not in PATH"
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Check if certificates already exist (idempotency check)
_EXPECTED_FILES=(
    "${OUTPUT_DIR}/ca.crt"
    "${OUTPUT_DIR}/ca.key"
    "${OUTPUT_DIR}/server.crt"
    "${OUTPUT_DIR}/server.key"
    "${OUTPUT_DIR}/client.crt"
    "${OUTPUT_DIR}/client.key"
    "${OUTPUT_DIR}/client-encrypted.crt"
    "${OUTPUT_DIR}/client-encrypted.key"
)

if [ "${1:-}" != "--force" ]; then
    _ALL_EXIST=true
    _ANY_EXIST=false
    for _f in "${_EXPECTED_FILES[@]}"; do
        if [ -f "${_f}" ]; then
            _ANY_EXIST=true
        else
            _ALL_EXIST=false
        fi
    done

    if [ "${_ALL_EXIST}" = "true" ]; then
        log_warn "All certificates already exist in ${OUTPUT_DIR}"
        log_warn "Use --force to regenerate"
        exit 0
    elif [ "${_ANY_EXIST}" = "true" ]; then
        log_warn "Some certificates already exist in ${OUTPUT_DIR} but not all."
        log_warn "Use --force to regenerate all certificates."
    fi
fi

log_info "Generating mTLS JakeBx certificates..."
log_info "Output directory: ${OUTPUT_DIR}"

# ============================================================
# 1. Generate CA Certificate
# ============================================================
log_info "1/4 Generating Certificate Authority (CA)..."

# CA private key
openssl genrsa -out "${OUTPUT_DIR}/ca.key" ${KEY_SIZE} 2>/dev/null

# CA certificate (self-signed) with proper key usage for Python 3.13+ compatibility
openssl req -new -x509 \
    -key "${OUTPUT_DIR}/ca.key" \
    -out "${OUTPUT_DIR}/ca.crt" \
    -days ${DAYS_CA} \
    -subj "/C=AU/ST=NSW/L=Sydney/O=JakeBx/OU=Certificate Authority/CN=JakeBx CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

log_info "  CA certificate: ${OUTPUT_DIR}/ca.crt"
log_info "  CA private key: ${OUTPUT_DIR}/ca.key"

# ============================================================
# 2. Generate Server Certificate (for nginx/ollama-proxy)
# ============================================================
log_info "2/4 Generating Server certificate (ollama-proxy)..."

# Create server certificate extensions config
cat > "${OUTPUT_DIR}/server-ext.cnf" << 'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = AU
ST = NSW
L = Sydney
O = JakeBx
OU = Model Server
CN = ollama-proxy

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ollama-proxy
DNS.2 = localhost
DNS.3 = *.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

# Server private key
openssl genrsa -out "${OUTPUT_DIR}/server.key" ${KEY_SIZE} 2>/dev/null

# Server CSR
openssl req -new \
    -key "${OUTPUT_DIR}/server.key" \
    -out "${OUTPUT_DIR}/server.csr" \
    -config "${OUTPUT_DIR}/server-ext.cnf"

# Sign server certificate with CA
openssl x509 -req \
    -in "${OUTPUT_DIR}/server.csr" \
    -CA "${OUTPUT_DIR}/ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/server.crt" \
    -days ${DAYS_CERT} \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/server-ext.cnf" \
    2>/dev/null

log_info "  Server certificate: ${OUTPUT_DIR}/server.crt"
log_info "  Server private key: ${OUTPUT_DIR}/server.key"

# ============================================================
# 3. Generate Client Certificate (for garak mTLS nodes)
# ============================================================
log_info "3/4 Generating Client certificate (garak-client)..."

# Create client certificate extensions config
cat > "${OUTPUT_DIR}/client-ext.cnf" << 'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = AU
ST = NSW
L = Sydney
O = JakeBx
OU = Garak
CN = garak-client

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

# Client private key
openssl genrsa -out "${OUTPUT_DIR}/client.key" ${KEY_SIZE} 2>/dev/null

# Client CSR
openssl req -new \
    -key "${OUTPUT_DIR}/client.key" \
    -out "${OUTPUT_DIR}/client.csr" \
    -config "${OUTPUT_DIR}/client-ext.cnf"

# Sign client certificate with CA
openssl x509 -req \
    -in "${OUTPUT_DIR}/client.csr" \
    -CA "${OUTPUT_DIR}/ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/client.crt" \
    -days ${DAYS_CERT} \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/client-ext.cnf" \
    2>/dev/null

log_info "  Client certificate: ${OUTPUT_DIR}/client.crt"
log_info "  Client private key: ${OUTPUT_DIR}/client.key"

# ============================================================
# 4. Generate Encrypted Client Certificate (passphrase-protected)
# ============================================================
log_info "4/4 Generating Encrypted Client certificate (garak-client-encrypted)..."

# Create encrypted client certificate extensions config
cat > "${OUTPUT_DIR}/client-encrypted-ext.cnf" << 'EOF'
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = AU
ST = NSW
L = Sydney
O = JakeBx
OU = Garak
CN = garak-client-encrypted

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

# Encrypted client private key (AES-256, passphrase-protected)
openssl genrsa \
    -aes256 \
    -passout "pass:${ENCRYPTED_KEY_PASSPHRASE}" \
    -out "${OUTPUT_DIR}/client-encrypted.key" \
    ${KEY_SIZE} 2>/dev/null

# Encrypted client CSR
openssl req -new \
    -key "${OUTPUT_DIR}/client-encrypted.key" \
    -passin "pass:${ENCRYPTED_KEY_PASSPHRASE}" \
    -out "${OUTPUT_DIR}/client-encrypted.csr" \
    -config "${OUTPUT_DIR}/client-encrypted-ext.cnf"

# Sign encrypted client certificate with CA
openssl x509 -req \
    -in "${OUTPUT_DIR}/client-encrypted.csr" \
    -CA "${OUTPUT_DIR}/ca.crt" \
    -CAkey "${OUTPUT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/client-encrypted.crt" \
    -days ${DAYS_CERT} \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/client-encrypted-ext.cnf" \
    2>/dev/null

log_info "  Encrypted client certificate: ${OUTPUT_DIR}/client-encrypted.crt"
log_info "  Encrypted client private key: ${OUTPUT_DIR}/client-encrypted.key"

# ============================================================
# Verify the certificate chain
# ============================================================
log_info "Verifying certificate chain..."

echo ""
if openssl verify -CAfile "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/server.crt" 2>/dev/null; then
    log_info "  ✓ Server certificate verified against CA"
else
    log_error "  ✗ Server certificate verification failed!"
    exit 1
fi

if openssl verify -CAfile "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/client.crt" 2>/dev/null; then
    log_info "  ✓ Client certificate verified against CA"
else
    log_error "  ✗ Client certificate verification failed!"
    exit 1
fi

if openssl verify -CAfile "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/client-encrypted.crt" 2>/dev/null; then
    log_info "  ✓ Encrypted client certificate verified against CA"
else
    log_error "  ✗ Encrypted client certificate verification failed!"
    exit 1
fi

# ============================================================
# Cleanup temporary files
# ============================================================
rm -f "${OUTPUT_DIR}/server.csr" "${OUTPUT_DIR}/client.csr" "${OUTPUT_DIR}/client-encrypted.csr"
rm -f "${OUTPUT_DIR}/server-ext.cnf" "${OUTPUT_DIR}/client-ext.cnf" "${OUTPUT_DIR}/client-encrypted-ext.cnf"
rm -f "${OUTPUT_DIR}/ca.srl"

# ============================================================
# Set appropriate permissions
# ============================================================
chmod 644 "${OUTPUT_DIR}/ca.crt" "${OUTPUT_DIR}/server.crt" "${OUTPUT_DIR}/client.crt" "${OUTPUT_DIR}/client-encrypted.crt"
chmod 600 "${OUTPUT_DIR}/ca.key" "${OUTPUT_DIR}/server.key" "${OUTPUT_DIR}/client.key" "${OUTPUT_DIR}/client-encrypted.key"

# ============================================================
# Summary
# ============================================================
echo ""
log_info "========================================="
log_info "Certificate generation complete!"
log_info "========================================="
echo ""
echo "Files generated in ${OUTPUT_DIR}:"
echo ""
echo "  CA:"
echo "    ca.crt  - CA certificate (distribute to both sides)"
echo "    ca.key  - CA private key (keep secure!)"
echo ""
echo "  Server (install on nginx/ollama-proxy):"
echo "    server.crt - Server certificate"
echo "    server.key - Server private key"
echo ""
echo "  Client (configure in garak mTLS credential):"
echo "    client.crt - Client certificate"
echo "    client.key - Client private key"
echo ""
echo "  Client Encrypted (passphrase-protected, passphrase: ${ENCRYPTED_KEY_PASSPHRASE}):"
echo "    client-encrypted.crt - Encrypted client certificate"
echo "    client-encrypted.key - Encrypted client private key"
echo ""
echo "  For garak SSL Certificate credential, paste contents of:"
echo "    CA Certificate:     cat ${OUTPUT_DIR}/ca.crt"
echo "    Client Certificate: cat ${OUTPUT_DIR}/client.crt"
echo "    Client Key:         cat ${OUTPUT_DIR}/client.key"
echo ""
