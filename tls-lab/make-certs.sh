#!/usr/bin/env bash
# Builds a small PKI for the TLS lab: root CA -> intermediate -> leaf certs,
# plus three deliberately broken variants. Everything lands in ./certs.
#
# The chain is three tiers on purpose: with only a root you cannot reproduce the
# single most common real-world TLS fault, a server that forgets to send its
# intermediate.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf certs && mkdir -p certs/newcerts && cd certs
touch index.txt && echo 1000 > serial

# openssl ca needs a config; openssl x509 -req does not. We only use `ca` for the
# expired cert, because it is the only tool here that can backdate validity.
cat > ca.cnf <<'EOF'
[ca]
default_ca = CA_default
[CA_default]
dir              = .
database         = $dir/index.txt
serial           = $dir/serial
new_certs_dir    = $dir/newcerts
default_md       = sha256
policy           = policy_any
email_in_dn      = no
rand_serial      = no
unique_subject   = no
[policy_any]
commonName             = supplied
countryName            = optional
stateOrProvinceName    = optional
organizationName       = optional
organizationalUnitName = optional
emailAddress           = optional
EOF

# CA:TRUE + keyCertSign is what makes a cert able to sign others. pathlen:0 on the
# intermediate means "you may not create further CAs below you".
cat > ca.ext <<'EOF'
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage         = critical,digitalSignature,cRLSign,keyCertSign
EOF

# A leaf is identified by subjectAltName, NOT by CN -- every current client ignores
# CN. Only lab.local is listed, so connecting by any other name must fail.
cat > leaf.ext <<'EOF'
basicConstraints       = CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:lab.local
EOF

gen() { openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "$2" 2>/dev/null; }
sign() { # sign <csr-base> <issuer-base> <ext-file> <days>
  openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial \
    -out "$1.crt" -days "$4" -sha256 -extfile "$3" 2>/dev/null
}

# 1. Root CA -- self-signed, the only thing a client has to trust out of band.
openssl req -x509 -newkey rsa:2048 -nodes -keyout rootCA.key -out rootCA.crt -days 3650 \
  -subj "/CN=Lab Root CA/O=TLS Lab" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

# 2. Intermediate, signed by the root.
gen intermediate "/CN=Lab Intermediate CA/O=TLS Lab"
sign intermediate rootCA ca.ext 1825

# 3. Good leaf, signed by the intermediate.
gen server "/CN=lab.local/O=TLS Lab"
sign server intermediate leaf.ext 365

# 4. Expired leaf: same chain, validity entirely in the past. Backdating needs
#    `openssl ca`, hence the config above.
gen expired "/CN=lab.local/O=TLS Lab"
openssl ca -batch -config ca.cnf -notext \
  -cert intermediate.crt -keyfile intermediate.key \
  -in expired.csr -out expired.crt \
  -startdate 20200101000000Z -enddate 20200201000000Z \
  -extfile leaf.ext 2>/dev/null

# 5. Rogue CA and a leaf it signed: correct hostname, valid dates, wrong signer.
openssl req -x509 -newkey rsa:2048 -nodes -keyout rogueCA.key -out rogueCA.crt -days 3650 \
  -subj "/CN=Definitely Not The Lab CA/O=Elsewhere" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
gen rogue "/CN=lab.local/O=TLS Lab"
sign rogue rogueCA leaf.ext 365

# What the server sends: leaf first, then intermediate. The root is NOT included --
# sending it is pointless, the client either already trusts it or it proves nothing.
cat server.crt intermediate.crt > fullchain.crt
cat rogue.crt rogueCA.crt       > rogue-chain.crt
cat expired.crt intermediate.crt > expired-chain.crt

chmod 644 *.key   # lab only: nginx in the container runs as a different uid
rm -f *.csr
echo "certs built:"; ls -1 *.crt
