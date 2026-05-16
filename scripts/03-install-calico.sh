#!/usr/bin/env bash
# 03-install-calico.sh
# Install Calico CNI via the Tigera operator.
# Run on the MASTER (any node with a working kubectl pointing at the cluster).

set -euo pipefail

CALICO_VERSION="v3.28.0"

echo "==> Installing Tigera operator (Calico ${CALICO_VERSION})"
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

echo "==> Waiting for the operator to be ready"
kubectl -n tigera-operator wait --for=condition=Available deployment/tigera-operator --timeout=180s

echo "==> Installing Calico custom resources (pod CIDR 192.168.0.0/16)"
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

echo "==> Waiting for Calico to roll out (may take 2-3 minutes)"
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s
kubectl -n calico-system rollout status deployment/calico-kube-controllers --timeout=300s

echo
echo "==> Calico installed."
echo
kubectl get nodes
echo
echo "==> Next: join workers (sudo ./02-join-worker.sh on each), then verify all 3 nodes Ready."
