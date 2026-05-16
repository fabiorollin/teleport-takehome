#!/usr/bin/env bash
# test-rbac.sh
# Verify the authorization matrix for the demo users.
# Run after create-user.sh has produced alice.kubeconfig and bob.kubeconfig.

set -uo pipefail

OUT_DIR="./out"
PASS=0
FAIL=0

check() {
  local user=$1
  local verb=$2
  local resource=$3
  local namespace=$4
  local expected=$5

  local kubeconfig="${OUT_DIR}/${user}.kubeconfig"
  if [[ ! -f "$kubeconfig" ]]; then
    printf "  [SKIP] %-8s %-7s %-14s in %-10s  (no kubeconfig — run create-user.sh %s)\n" \
      "$user" "$verb" "$resource" "$namespace" "$user"
    return
  fi

  local result
  result=$(kubectl --kubeconfig="$kubeconfig" auth can-i "$verb" "$resource" -n "$namespace" 2>/dev/null || true)
  [[ -z "$result" ]] && result="no"

  local mark="FAIL"
  if [[ "$result" == "$expected" ]]; then
    mark="PASS"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi

  printf "  [%s] %-8s %-7s %-14s in %-12s -> %-3s (expected %s)\n" \
    "$mark" "$user" "$verb" "$resource" "$namespace" "$result" "$expected"
}

echo "==> RBAC authorization matrix"
echo

echo "alice (viewer) in nginx-app — should be able to read but not write:"
check alice get    pods         nginx-app yes
check alice list   deployments  nginx-app yes
check alice get    ingresses    nginx-app yes
check alice create deployments  nginx-app no
check alice create ingresses    nginx-app no
check alice delete pods         nginx-app no
echo

echo "bob (admin) in nginx-app — should be able to do everything in this namespace:"
check bob get    pods         nginx-app yes
check bob create deployments  nginx-app yes
check bob create ingresses    nginx-app yes
check bob delete pods         nginx-app yes
check bob create networkpolicies nginx-app yes
echo

echo "alice (viewer) in kube-system — should be forbidden everywhere:"
check alice get    pods nginx-app yes   # control: alice in her own ns
check alice get    pods kube-system no
check alice list   secrets kube-system no
echo

echo "bob (admin) in kube-system — should be forbidden (Role is namespace-scoped):"
check bob get    pods kube-system no
check bob list   secrets kube-system no
echo

echo "==================================================="
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "Some checks failed. Verify Roles + RoleBindings are applied."
  exit 1
fi
