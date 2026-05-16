#!/usr/bin/env bash
# 01-init-master.sh
# Initialize the Kubernetes control plane on the master node.
# Run ONLY on the master, AFTER 00-prep-node.sh has run on this node.

set -euo pipefail

# Calico's default pod CIDR (matches manifests/custom-resources.yaml from Tigera)
POD_CIDR="192.168.0.0/16"

# Auto-detect the master's private IP — the IP workers will use to reach the API server
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MASTER_IP=$(ip -4 addr show dev "$DEFAULT_IFACE" | awk '/inet / {print $2; exit}' | cut -d/ -f1)

echo "==> Running kubeadm init"
echo "    Pod CIDR:        ${POD_CIDR}"
echo "    Advertise addr:  ${MASTER_IP}"
echo

sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address="${MASTER_IP}"

echo
echo "==> Setting up kubectl for $USER"
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo
echo "==> Generating worker join command (saved to /tmp/kubeadm-join.cmd):"
sudo kubeadm token create --print-join-command | sudo tee /tmp/kubeadm-join.cmd

echo
echo "==> Master initialized."
echo "    Next step: run 03-install-calico.sh on this node BEFORE joining workers."
echo "    Then on each worker: sudo ./02-join-worker.sh \"\$(cat /tmp/kubeadm-join.cmd)\""
