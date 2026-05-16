#!/usr/bin/env bash
# 00-prep-node.sh
# Prepares an Ubuntu 22.04 LTS node for kubeadm.
# Run on EACH of the 3 nodes (master + 2 workers) as a sudo-capable user.
# Idempotent — safe to re-run.

set -euo pipefail

K8S_VERSION="1.30"

echo "==> [1/7] Disabling swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "==> [2/7] Loading kernel modules (overlay, br_netfilter)"
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "==> [3/7] Setting sysctl params"
sudo tee /etc/sysctl.d/k8s.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "==> [4/7] Installing containerd"
sudo apt-get update -qq
sudo apt-get install -y -qq containerd

echo "==> [5/7] Configuring containerd for SystemdCgroup"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "==> [6/7] Adding the Kubernetes apt repository (v${K8S_VERSION})"
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "==> [7/7] Installing kubeadm, kubelet, kubectl + holding versions"
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo
echo "==> Done. Node ready for kubeadm init/join."
echo "    kubeadm version: $(kubeadm version -o short)"
echo "    containerd version: $(containerd --version | awk '{print $3}')"
