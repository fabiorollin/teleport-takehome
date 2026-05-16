#!/usr/bin/env bash
# 04-install-cert-manager.sh
# Install cert-manager via the official static release manifest.

set -euo pipefail

CM_VERSION="v1.15.0"

echo "==> Installing cert-manager ${CM_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml"

echo "==> Waiting for cert-manager pods to be Ready"
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=300s

echo
echo "==> cert-manager installed."
echo "    Next: kubectl apply -f manifests/cluster-issuer.yaml"
