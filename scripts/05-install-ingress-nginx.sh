#!/usr/bin/env bash
# 05-install-ingress-nginx.sh
# Install the NGINX Ingress Controller in bare-metal mode (NodePort exposure).

set -euo pipefail

NGINX_VERSION="controller-v1.11.1"

echo "==> Installing ingress-nginx ${NGINX_VERSION} (bare-metal / NodePort)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

echo "==> Waiting for ingress-nginx controller Deployment to roll out"
kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=300s

echo
echo "==> NGINX Ingress installed. NodePorts:"
kubectl -n ingress-nginx get svc ingress-nginx-controller
echo
echo "    The HTTPS NodePort is what you'll hit in the browser:"
echo "    https://nginx.demo.local:<HTTPS-NodePort>"
echo "    (add an /etc/hosts entry mapping nginx.demo.local to your master's public IP)"
