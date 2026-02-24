#!/bin/bash
# gen-certs.sh — Generate self-signed TLS certificates for Titan mTLS
# Output: certs/ca.pem, certs/server.pem, certs/server-key.pem, certs/client.pem, certs/client-key.pem

set -e

CERT_DIR="certs"
mkdir -p "$CERT_DIR"

DAYS=365
SUBJ_CA="/CN=Titan-CA"
SUBJ_SERVER="/CN=titan-manager"
SUBJ_CLIENT="/CN=titan-worker"

echo "→ Generating CA key and certificate..."
openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096 2>/dev/null
openssl req -new -x509 -days $DAYS -key "$CERT_DIR/ca-key.pem" \
  -out "$CERT_DIR/ca.pem" -subj "$SUBJ_CA" 2>/dev/null

echo "→ Generating Server key and CSR..."
openssl genrsa -out "$CERT_DIR/server-key.pem" 4096 2>/dev/null
openssl req -new -key "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server.csr" -subj "$SUBJ_SERVER" 2>/dev/null

# SAN extension for localhost + Docker service names
cat > "$CERT_DIR/server-ext.cnf" <<EOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = titan-manager
DNS.3 = *.titan-net
IP.1 = 127.0.0.1
IP.2 = 0.0.0.0
EOF

openssl x509 -req -days $DAYS -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -out "$CERT_DIR/server.pem" \
  -extfile "$CERT_DIR/server-ext.cnf" -extensions v3_req 2>/dev/null

echo "→ Generating Client key and certificate..."
openssl genrsa -out "$CERT_DIR/client-key.pem" 4096 2>/dev/null
openssl req -new -key "$CERT_DIR/client-key.pem" \
  -out "$CERT_DIR/client.csr" -subj "$SUBJ_CLIENT" 2>/dev/null
openssl x509 -req -days $DAYS -in "$CERT_DIR/client.csr" \
  -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" -CAcreateserial \
  -out "$CERT_DIR/client.pem" 2>/dev/null

# Clean up CSRs and serial
rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.srl "$CERT_DIR"/*.cnf

echo ""
echo "✓ Certificates generated in $CERT_DIR/"
echo "  CA:     $CERT_DIR/ca.pem"
echo "  Server: $CERT_DIR/server.pem + $CERT_DIR/server-key.pem"
echo "  Client: $CERT_DIR/client.pem + $CERT_DIR/client-key.pem"
echo ""
echo "Usage:"
echo "  Manager: --tls --tls-cert=certs/server.pem --tls-key=certs/server-key.pem --tls-ca=certs/ca.pem"
echo "  Worker:  --tls --tls-cert=certs/client.pem --tls-key=certs/client-key.pem --tls-ca=certs/ca.pem"
