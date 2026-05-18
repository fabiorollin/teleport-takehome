#!/usr/bin/env bash
# test-rbac.sh
# Verify the authorization matrix for the demo users.
# Run after create-user.sh has produced alice.kubeconfig, bob.kubeconfig,
# and admin.kubeconfig (and their respective bindings have been applied
# from rbac/).
#
# Three tiers of access are exercised:
#   - alice (viewer)        : read-only in nginx-app, blocked elsewhere
#   - bob   (namespace-admin): full control of nginx-app, blocked elsewhere
#   - admin (cluster-admin)  : unrestricted, including cluster-scoped resources

set -uo pipefail

OUT_DIR="./out"
PASS=0
FAIL=0

# check <user> <verb> <resource> <scope> <expected>
#   scope = namespace name OR the literal string "cluster" for cluster-scoped resources
check() {
  local user=$1
  local verb=$2
  local resource=$3
  local scope=$4
  local expected=$5

  local kubeconfig="${OUT_DIR}/${user}.kubeconfig"
  if [[ ! -f "$kubeconfig" ]]; then
    printf "  [SKIP] %-7s %-7s %-16s  (no kubeconfig — run create-user.sh %s first)\n" \
      "$user" "$verb" "$resource" "$user"
    return
  fi

  local ns_args=()
  local scope_label="cluster"
  if [[ "$scope" != "cluster" ]]; then
    ns_args=("-n" "$scope")
    scope_label="$scope"
  fi

  local result
  result=$(kubectl --kubeconfig="$kubeconfig" auth can-i "$verb" "$resource" "${ns_args[@]}" 2>/dev/null || true)
  [[ -z "$result" ]] && result="no"

  local mark="FAIL"
  if [[ "$result" == "$expected" ]]; then
    mark="PASS"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi

  printf "  [%s] %-7s %-7s %-16s in %-12s -> %-3s (expected %s)\n" \
    "$mark" "$user" "$verb" "$resource" "$scope_label" "$result" "$expected"
}

echo "==> RBAC authorization matrix"
echo

echo "alice (viewer in nginx-app) — read-only, namespace-scoped:"
check alice get    pods             nginx-app   yes
check alice list   deployments      nginx-app   yes
check alice get    ingresses        nginx-app   yes
check alice create deployments      nginx-app   no
check alice create ingresses        nginx-app   no
check alice delete pods             nginx-app   no
echo

echo "bob (admin in nginx-app) — full control of one namespace:"
check bob   get    pods             nginx-app   yes
check bob   create deployments      nginx-app   yes
check bob   create ingresses        nginx-app   yes
check bob   delete pods             nginx-app   yes
check bob   create networkpolicies  nginx-app   yes
echo

echo "admin (cluster-admin) — unrestricted, cluster-scoped:"
check admin get    pods             nginx-app   yes
check admin get    pods             kube-system yes
check admin create deployments      default     yes
check admin list   nodes            cluster     yes
check admin create namespaces       cluster     yes
echo

echo "Cross-namespace probes — namespace-scoped users blocked outside nginx-app:"
check alice get    pods             kube-system no
check alice list   secrets          kube-system no
check bob   get    pods             kube-system no
check bob   list   secrets          kube-system no
echo

echo "==================================================="
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "Some checks failed. Verify Roles, RoleBindings, and the admin ClusterRoleBinding are applied."
  exit 1
fi
