# Design Document

## Goal

A 3-node Kubernetes cluster deployed via `kubeadm` on AWS EC2, demonstrating native Kubernetes authentication and authorization using the `CertificateSigningRequest` API. The cluster runs a TLS-secured Nginx application deployed by a non-admin user, with NetworkPolicy isolation and Flux-based GitOps reconciliation.

This exercise demonstrates not just that the stack *works*, but that the operator understands its **operational trade-offs at scale** — particularly around user lifecycle, certificate management, and audit. The pluses-and-minuses analysis (below) is the most important part of this document.

## Architecture

```
                ┌──────────────────────────────────────────┐
                │  Operator workstation                    │
                │  kubectl + per-user kubeconfig (X.509)   │
                └─────────────────────┬────────────────────┘
                                      │ TLS:6443
                                      ▼
       ┌──────────────────────────────────────────────────┐
       │                k8s-master (EC2)                  │
       │ • kube-apiserver  (issues + signs CSRs)          │
       │ • etcd, scheduler, controller-manager            │
       │ • kubelet, containerd                            │
       │ • Calico tigera-operator (CNI + NetworkPolicy)   │
       │ • NGINX Ingress (NodePort exposure)              │
       │ • cert-manager (self-signed ClusterIssuer)       │
       │ • Flux controllers (source, kustomize)           │
       └─────────────┬────────────────┬───────────────────┘
                     │ kubelet:10250  │ Calico VXLAN:8472
                     ▼                ▼
       ┌──────────────────────┐  ┌──────────────────────┐
       │ k8s-worker-1 (EC2)   │  │ k8s-worker-2 (EC2)   │
       │ • kubelet, containerd│  │ • kubelet, containerd│
       │ • Calico node        │  │ • Calico node        │
       │ • app pods           │  │ • app pods           │
       └──────────────────────┘  └──────────────────────┘

  Namespace: nginx-app                  Namespace: ingress-nginx
  ┌──────────────────────────┐          ┌──────────────────────────┐
  │ Deployment: nginx (x2)   │◄─port 80─┤ NGINX Ingress Controller │
  │ Service: nginx (ClusterIP)│          │ Service: NodePort :3xxxx │
  │ Ingress (TLS via cert-mgr)│          └──────────────────────────┘
  │ NetworkPolicies:         │
  │   • default-deny         │
  │   • allow-from-ingress   │
  │   • allow-dns            │
  └──────────────────────────┘
```

## Component choices and rationale

### Kubernetes installation: kubeadm

The take-home requires kubeadm — no wrappers. Beyond compliance: kubeadm produces an idiomatic cluster. Static control-plane pods live in `/etc/kubernetes/manifests/`, the PKI lives in `/etc/kubernetes/pki/`, the admin kubeconfig is at `/etc/kubernetes/admin.conf`. Anyone debugging this cluster finds what they expect.

### CNI: Calico (chosen over Flannel)

Both work. **Calico** was chosen because it natively supports NetworkPolicy enforcement; Flannel does not (it's a routing-only plugin). Layering Calico-on-Flannel ("Canal") is possible but adds operational complexity. Since this lab uses NetworkPolicy as a defense-in-depth signal, Calico's single-plugin approach is simpler.

Trade-off: Calico's data plane (Felix + BIRD or the eBPF variant) is heavier than Flannel's, but on `t3.medium` nodes the overhead is invisible.

Installed via the Tigera operator (`tigera-operator.yaml` + `custom-resources.yaml`). The operator pattern is the supported install method and makes upgrades cleaner.

### Ingress: NGINX Ingress Controller via NodePort

A bare-metal kubeadm cluster has no cloud-managed `LoadBalancer` service. Two real options:

- **MetalLB** — gives you actual `LoadBalancer` service types via L2 announcement
- **NodePort** — simpler, no extra component

**NodePort** was chosen for demo simplicity. The master's public IP plus the NodePort port = a reachable endpoint. In production, MetalLB or a cloud LB is the right answer.

### TLS issuance: cert-manager + self-signed `ClusterIssuer`

cert-manager is the requirement. For the issuer:

- **Self-signed `ClusterIssuer`** — works anywhere, no DNS dependency, reproducible from a fresh AWS account in <30 minutes. Cost: browser warnings (the CA isn't in any trust store).
- **Let's Encrypt via DNS-01** — produces publicly-trusted certs, but requires a real domain name + Route 53 IAM credentials in the cluster.

Self-signed was chosen to preserve **rebuild discipline**. Anyone validating this submission can do it without owning a domain. The Let's Encrypt path is documented in "What I'd add in production."

### RBAC: namespace-scoped Roles with CN-based subjects

Once CSR-signed certs are in play, the cert's **CN** becomes the user identity Kubernetes recognizes. Two Roles in the `nginx-app` namespace:

| Role | Permits |
|---|---|
| `nginx-viewer` | `get`, `list`, `watch` on pods, deployments, services, ingresses, configmaps, certificates |
| `nginx-admin` | viewer's verbs **plus** `create`, `update`, `patch`, `delete` on the same plus NetworkPolicies and pods/exec |

Both Roles use **explicit verb lists, no `*` wildcards**. Least privilege at the verb level.

Two demo users:

- `alice` (CN=`alice`) bound to `nginx-viewer`
- `bob` (CN=`bob`) bound to `nginx-admin`

RoleBindings live in `rbac/`. Credential generation (key + CSR + kubeconfig) lives in `scripts/create-user.sh`. **These are intentionally separated**: authentication is identity-issuance; authorization is policy. Mixing them in one script reads cleanly but blurs the abstraction.

### NetworkPolicy: default-deny + named allows

Three policies in `manifests/network-policies/`:

1. `default-deny.yaml` — denies all ingress and egress in `nginx-app`
2. `allow-ingress-from-nginx.yaml` — allows port 80 traffic from pods in the `ingress-nginx` namespace
3. `allow-dns-egress.yaml` — allows DNS egress to `kube-system` (UDP and TCP 53)

The third policy is non-obvious but essential — without it, the default-deny breaks all DNS resolution in `nginx-app`. This is the most common NetworkPolicy footgun, so it's surfaced explicitly.

### GitOps: Flux v2

Flux was chosen over ArgoCD because the author operates Flux in production at IPC Systems. The repo's `manifests/nginx-app/` directory is reconciled by Flux's `kustomize-controller`. `flux bootstrap github` installs the controllers and commits its config to `clusters/demo/`.

In Flux's model, **the repo is the source of truth**. Drift in the cluster is reverted on the next reconciliation. This is the same operating pattern used to manage hundreds of customer Kubernetes clusters at IPC.

## Security model

**Identity:**
- Users authenticate to the API server using X.509 client certificates
- The cluster's CA (auto-generated by `kubeadm init`, stored at `/etc/kubernetes/pki/ca.crt`) is the only trust anchor
- Certs are issued via `CertificateSigningRequest` resources signed by `kubernetes.io/kube-apiserver-client`
- 30-day TTL on user certs (`expirationSeconds: 2592000`)

**Authorization:**
- Two namespace-scoped Roles, explicit verbs, no wildcards
- All users are namespace-scoped — no ClusterRoleBindings outside the standard kubeadm defaults
- The `kubectl auth can-i` matrix is verified end-to-end by `scripts/test-rbac.sh`

**Network:**
- Default-deny ingress and egress in the application namespace
- Only the Ingress controller can reach app pods on port 80
- DNS egress is explicitly permitted; everything else is denied
- The cluster API server (port 6443) is only reachable from within the security group or from the operator's IP

**Secrets handling:**
- Generated user keys and kubeconfigs land in `out/` which is git-ignored
- The cluster CA cert is embedded into each user kubeconfig (so kubectl trusts the API server)
- No production secrets are committed to the repo

**Operator access:**
- The cluster admin's kubeconfig (`/etc/kubernetes/admin.conf`) is root-equivalent and lives only on the master node
- For day-to-day operation, an operator would create their own scoped user — not use admin.conf

## Pluses and minuses — operating native Kubernetes RBAC at scale

### Pluses

- **Standards-based** — X.509 client authentication is well-understood, widely tooled, and uses the cluster's own CA — no external dependencies
- **Strong cryptographic identity** — certificates cannot be forged without compromising the cluster CA
- **Works in air-gapped or offline environments** — no IdP reachability required
- **Audit log captures every API call** with the cert CN as the subject
- **Free** — built into Kubernetes, no extra software to deploy

### Minuses

| Pain | Why it matters in production | What an enterprise access-management platform adds |
|---|---|---|
| **Certificate lifecycle is manual** | When does Alice's cert expire? Who renews it? At scale, teams build cert-tracking systems — operational debt nobody asked for. | Short-lived certs auto-renewed per session |
| **No central revocation** | Bob leaves the company; his kubeconfig still works until expiry. Kubernetes has no CRL or OCSP. | Lock the user → access cuts instantly across all clusters |
| **Kubeconfig sprawl** | Files on laptops, in Slack, in backups, in dotfiles. A 30-day cert in 50 places is a 30-day window. | No kubeconfig stored on disk; cert ephemeral per session |
| **Manual approval workflow** | Every new user requires admin to run `kubectl certificate approve`, every cluster, every time. | SSO with claim-to-role mapping — joiners provisioned automatically |
| **No SSO integration** | Disconnected from the corporate IdP (Okta, Entra, AD FS). Joiner/mover/leaver is manual. | OIDC / SAML connector — identity flows from the IdP |
| **No MFA** | Possession of the kubeconfig file is sufficient authentication | Per-session MFA, WebAuthn, hardware key touch |
| **Audit shows cert CN, not human identity** | Logs say `user=bob`, but who is "bob"? Two engineers named Bob is not hypothetical. | Audit log carries human identity (email, employee ID) from SSO claims through every action |
| **No just-in-time elevation** | A user is either viewer or admin permanently. Privilege escalation requires a new RoleBinding. | Access Requests with TTL — request admin for 4h, auto-expire, full audit |
| **Per-cluster effort** | All of the above repeats for every cluster | One control plane fronts dozens of K8s clusters |
| **No session recording** | `kubectl exec` into a pod isn't captured for forensic review | Every exec is recorded and replayable |
| **No network-level isolation for the API server** | The API server must be reachable from operator networks. Either expose 6443 or run a VPN. | Proxy fronts everything — agents dial out, no inbound ports |

The native pattern shown in this lab is **the floor** of what's possible — table stakes for a small team on one cluster. Production-grade access management is the ceiling, and the gap between them is operational debt that compounds with cluster count and team size.

## What I'd add in production

If this cluster were leaving lab status:

1. **Real CA via Let's Encrypt + DNS-01** — public-trusted certs, no browser warnings. cert-manager already supports this; needs Route 53 IAM credentials in the cluster (or IRSA on EKS) and a real domain.

2. **OIDC connector to a corporate IdP** — replace per-user CSR generation with SSO. Map IdP groups to Kubernetes Groups, which RoleBindings reference. Joiner/mover/leaver becomes IdP-driven and automatic.

3. **MFA for cluster access** — either at the IdP layer (most common) or via a proxy in front of the API server (kube-oidc-proxy, Pinniped, or a commercial access platform).

4. **Audit log shipping** — enable `--audit-policy-file` and `--audit-log-path` on kube-apiserver → Fluent Bit DaemonSet → SIEM (Splunk, Datadog). Alerts on suspicious actions: CSR creation, ClusterRoleBinding changes, exec sessions on production namespaces.

5. **Session recording for `kubectl exec`** — not native to Kubernetes; requires a proxy. Critical for compliance environments (SOX, MiFID II, PCI).

6. **Just-in-time elevation** — a request-and-approval workflow for elevation to admin roles, with auto-expiry. Pairs with audit logging for "who was admin when."

7. **Cert expiry monitoring** — a CronJob listing CSRs by expiry, paging an operator when ≤30 days. (Or: short-lived certs at every login, which removes the problem class entirely.)

8. **Multi-master HA control plane** — 3 masters with stacked etcd, behind an internal load balancer. Survives single-master failure.

9. **Pod Security Admission** — enforce the `restricted` policy on `nginx-app` to block privilege escalation, host-namespace mounts, etc.

10. **Cilium with Hubble** — eBPF-based CNI with observability for policy enforcement and L7-aware policies. Calico is fine; Cilium is the modern choice for new deployments.

## Reproducibility

Fully scripted. See `README.md` for the step-by-step. Total build time from a clean AWS account: ~30 minutes.

The clean-rebuild test (which this submission was validated against):

1. Terminate all 3 EC2 instances
2. Provision 3 new ones with the same SG + SSH key
3. Run `scripts/00-prep-node.sh` on each
4. Run `scripts/01-init-master.sh` on master, capture join command
5. Run `scripts/02-join-worker.sh` on each worker
6. Run `scripts/03-install-calico.sh`, `04-install-cert-manager.sh`, `05-install-ingress-nginx.sh`
7. Apply `rbac/`, `manifests/cluster-issuer.yaml`, `manifests/nginx-app/`, `manifests/network-policies/`
8. Run `scripts/create-user.sh alice` and `scripts/create-user.sh bob`
9. Run `scripts/test-rbac.sh` — all PASS

## Known limitations (called out for honesty)

- **Self-signed TLS** — browsers warn unless the operator manually trusts the cert
- **Single-master control plane** — no HA; documented production path is 3-master stacked-etcd
- **NodePort exposure** — works for the demo, not for production traffic; MetalLB or a cloud LB is the production path
- **Audit logging not enabled in this lab** — discussed in the production-path list, not implemented (time-boxed exercise)
- **No active cert-expiry monitoring** — `kubectl get csr` shows issued certs but there's no alerting
- **No IdP integration** — by design (the exercise asks for CSR-based auth); production path documented

These are intentional trade-offs given the scope of the exercise. Each has a documented production answer.
