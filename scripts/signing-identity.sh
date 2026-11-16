#!/bin/zsh
# Creates (once) a local self-signed code-signing identity so rebuilt apps keep the same
# signature. macOS ties Accessibility permission to the signature; with ad-hoc signing every
# rebuild would silently lose the permission. The identity lives in its own keychain and
# never leaves this Mac. Prints the identity name on success, nothing otherwise.
set -euo pipefail
name="SuperCopy Local Signing"
keychain="$HOME/Library/Keychains/supercopy-signing.keychain-db"
password="supercopy-local"
if [[ ! -f "$keychain" ]]; then
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  cat > "$work/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.conf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "pass:$password" >/dev/null 2>&1 ||
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "pass:$password" >/dev/null 2>&1
  security create-keychain -p "$password" "$keychain" >/dev/null
  security set-keychain-settings "$keychain" >/dev/null
  security unlock-keychain -p "$password" "$keychain" >/dev/null
  security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null 2>&1
fi
security unlock-keychain -p "$password" "$keychain" >/dev/null 2>&1 || exit 0
# codesign only finds identities in the search list.
current=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
if (( ! ${current[(Ie)$keychain]} )); then security list-keychains -d user -s "${current[@]}" "$keychain" >/dev/null; fi
security find-certificate -c "$name" "$keychain" >/dev/null 2>&1 && print -- "$name"
