#!/usr/bin/env bash
# 02-join-worker.sh
# Join this node to the cluster as a worker.
# Run on EACH worker AFTER 00-prep-node.sh has run on this node.
#
# Usage:
#   sudo ./02-join-worker.sh "<full kubeadm join command from the master>"
#
# Get the join command on the master with:
#   sudo kubeadm token create --print-join-command
# (it's also written to /tmp/kubeadm-join.cmd by 01-init-master.sh)

set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat <<'EOF'
ERROR: missing join command.

Usage: sudo ./02-join-worker.sh "<kubeadm join command from master>"

To get the join command, run on the master:
  sudo kubeadm token create --print-join-command
or read it from /tmp/kubeadm-join.cmd if 01-init-master.sh saved it there.
EOF
  exit 1
fi

JOIN_CMD="$*"
echo "==> Joining cluster"
echo "    Command: ${JOIN_CMD}"
echo

sudo $JOIN_CMD

echo
echo "==> Worker joined."
echo "    Verify from the master with: kubectl get nodes"
