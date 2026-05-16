#!/usr/bin/env bash
# create-user.sh
# Onboard a Kubernetes user using the CertificateSigningRequest API.
#
# Generates a private key + CSR, submits the CSR to the cluster CA for signing,
# approves the request, extracts the signed certificate, and writes a per-user
# kubeconfig.
#
# This script does NOT manage RBAC bindings. Bindings are static YAMLs in
# rbac/ — the user's CN must match a Subject in some RoleBinding for the cert
# to grant any access. This is intentional separation of authentication
# (identity issuance) from authorization (policy).
#
# Usage:
#   ./create-user.sh <username>
#
# Output:
#   out/<username>.key          (RSA 2048 private key, mode 0600)
#   out/<username>.csr          (PEM-encoded CSR)
#   out/<username>.crt          (PEM-encoded signed certificate)
#   out/<username>.kubeconfig   (kubeconfig pinned to namespace nginx-app)

set -euo pipefail

if [[ $# -ne 1 ]]; then
  cat <<'EOF'
Usage: ./create-user.sh <username>

Example:
  ./create-user.sh alice

Note: This script issues credentials only. The user's CN must be referenced
in a RoleBinding (see rbac/) for the credentials to grant any access.
EOF
  exit 1
fi

USERNAME="$1"
NS="${TARGET_NAMESPACE:-nginx-app}"
OUT_DIR="./out"

mkdir -p "$OUT_DIR"
KEY_FILE="$OUT_DIR/${USERNAME}.key"
CSR_FILE="$OUT_DIR/${USERNAME}.csr"
CRT_FILE="$OUT_DIR/${USERNAME}.crt"
KUBECONFIG_FILE="$OUT_DIR/${USERNAME}.kubeconfig"

echo "==> [1/6] Generating 2048-bit RSA private key"
openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
chmod 600 "$KEY_FILE"

echo "==> [2/6] Generating CSR with CN=${USERNAME}"
openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" \
  -subj "/CN=${USERNAME}/O=nginx-app-users" 2>/dev/null

echo "==> [3/6] Submitting CertificateSigningRequest"
CSR_NAME="user-${USERNAME}-$(date +%s)"
CSR_B64=$(base64 -w0 < "$CSR_FILE")

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 2592000   # 30 days
  usages:
    - client auth
EOF
echo "    CSR resource: ${CSR_NAME}"

echo "==> [4/6] Approving the CSR (kubectl certificate approve)"
kubectl certificate approve "$CSR_NAME" >/dev/null

echo "==> [5/6] Extracting signed certificate from CSR status"
CERT=""
for _ in {1..10}; do
  CERT=$(kubectl get csr "$CSR_NAME" -o jsonpath='{.status.certificate}' 2>/dev/null || echo "")
  if [[ -n "$CERT" ]]; then break; fi
  sleep 1
done
if [[ -z "$CERT" ]]; then
  echo "ERROR: signed certificate did not appear in CSR status after 10s" >&2
  exit 1
fi
echo "$CERT" | base64 -d > "$CRT_FILE"

echo "==> [6/6] Building kubeconfig"
CA_DATA=$(kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER=$(kubectl config view --minify \
  -o jsonpath='{.clusters[0].name}')
CLIENT_CERT_B64=$(base64 -w0 < "$CRT_FILE")
CLIENT_KEY_B64=$(base64 -w0 < "$KEY_FILE")

cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_DATA}
users:
  - name: ${USERNAME}
    user:
      client-certificate-data: ${CLIENT_CERT_B64}
      client-key-data: ${CLIENT_KEY_B64}
contexts:
  - name: ${USERNAME}@${CLUSTER}
    context:
      cluster: ${CLUSTER}
      user: ${USERNAME}
      namespace: ${NS}
current-context: ${USERNAME}@${CLUSTER}
EOF
chmod 600 "$KUBECONFIG_FILE"

echo
echo "==> Done. User '${USERNAME}' onboarded."
echo "    Kubeconfig: ${KUBECONFIG_FILE}"
echo "    Cert TTL:   30 days"
echo
echo "    Test the credentials:"
echo "      kubectl --kubeconfig=${KUBECONFIG_FILE} auth can-i get pods -n ${NS}"
echo
echo "    Note: access is governed by RoleBindings in rbac/."
echo "    If '${USERNAME}' is not referenced in a RoleBinding, every check returns 'no'."
