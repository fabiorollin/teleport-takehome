# Kubernetes RBAC with CSR-Based User Onboarding

A reproducible Kubernetes lab demonstrating native K8s authentication and authorization using the `CertificateSigningRequest` API. Built on a 3-node `kubeadm` cluster on AWS EC2, with cert-manager TLS, NGINX Ingress, Calico CNI + NetworkPolicy isolation, and Flux GitOps reconciliation.

Submitted for the **Teleport Professional Services** take-home interview, May 2026.

## What this demonstrates

- **A working `kubeadm` cluster** — 1 master + 2 workers on EC2, Calico CNI
- **CSR-based user onboarding** — users get cluster-CA-signed X.509 certs; no shared admin kubeconfigs
- **Two RBAC roles** — `nginx-viewer` (read-only) and `nginx-admin` (full namespace control), both namespace-scoped
- **cert-manager** issuing TLS for the Nginx app via a self-signed `ClusterIssuer`
- **NetworkPolicy** — default-deny in the application namespace plus explicit allow rules
- **Flux GitOps** — application manifests reconciled from this repository

See `design.md` for component choices, security model, and the **pluses-and-minuses analysis** of operating Kubernetes RBAC this way at scale.

## Prerequisites

- AWS account with EC2 / VPC / SG permissions
- Local tools: `kubectl`, `ssh`, `git`, `openssl`, `bash`
- One SSH keypair imported to your AWS account

## End-to-end reproduction

The build is scripted by 6 numbered helpers in `scripts/`. Run them in order.

### 1. Provision 3 EC2 instances

In the AWS Console:

- 3 × `t3.medium` instances, **Ubuntu 22.04 LTS**, 20 GB gp3 root
- Same subnet, same SSH key, same security group
- Public IPs assigned
- Tag them `k8s-master`, `k8s-worker-1`, `k8s-worker-2`

Security group inbound rules:

| Source | Port | Reason |
|---|---|---|
| your IP | 22/TCP | SSH |
| within SG | 6443/TCP | Kubernetes API |
| within SG | 2379–2380/TCP | etcd |
| within SG | 10250/TCP | kubelet API |
| within SG | 10257, 10259/TCP | controller-manager, scheduler |
| within SG | 8472/UDP | Calico VXLAN |
| your IP | 30000–32767/TCP | NodePort range (for demo access) |
| your IP | 80, 443/TCP | Browser access |

### 2. Prep each node

SCP the prep script to each instance and run it:

```bash
for ip in <master-ip> <worker-1-ip> <worker-2-ip>; do
  scp scripts/00-prep-node.sh ubuntu@$ip:
  ssh ubuntu@$ip "chmod +x 00-prep-node.sh && ./00-prep-node.sh"
done
```

The script disables swap, loads kernel modules, sets sysctl, installs containerd + kubeadm/kubelet/kubectl pinned to v1.30.

### 3. Initialize the master

```bash
ssh ubuntu@<master-ip>
./01-init-master.sh
```

Captures the join command into `/tmp/kubeadm-join.cmd`.

### 4. Join the workers

Grab the join command from the master, then on each worker:

```bash
sudo ./02-join-worker.sh "<paste the full join command>"
```

### 5. Install Calico CNI

On the master:

```bash
./03-install-calico.sh
```

Wait for `kubectl get nodes` to show all 3 `Ready` (~2 minutes).

### 6. Install cert-manager and the NGINX Ingress Controller

```bash
./04-install-cert-manager.sh
./05-install-ingress-nginx.sh
```

### 7. Apply RBAC, the Nginx app, and NetworkPolicies

```bash
kubectl apply -f rbac/
kubectl apply -f manifests/cluster-issuer.yaml
kubectl apply -f manifests/nginx-app/
kubectl apply -f manifests/network-policies/
```

### 8. Onboard demo users

```bash
./scripts/create-user.sh alice
./scripts/create-user.sh bob
./scripts/test-rbac.sh
```

Expected output: `alice` passes viewer checks and fails admin ones; `bob` passes both. All users fail `kube-system` checks.

### 9. (Bonus) Bootstrap Flux

```bash
flux bootstrap github \
  --owner=<your-github-user> \
  --repository=<this-repo-name> \
  --branch=main \
  --path=clusters/demo \
  --personal
```

Then copy `flux/nginx-app-kustomization.yaml` into `clusters/demo/`, commit, and push. See `flux/README.md`.

## Validation checklist

After install, all of these should pass:

```bash
kubectl get nodes                                                        # 3 Ready
kubectl get pods -A | grep -v Running | grep -v Completed                # empty (besides headers)
kubectl --kubeconfig=out/bob.kubeconfig get pods -n nginx-app            # success
kubectl --kubeconfig=out/alice.kubeconfig create deployment foo \
  --image=nginx -n nginx-app                                             # Forbidden
```

For the Nginx app:

1. Find the HTTPS NodePort: `kubectl -n ingress-nginx get svc ingress-nginx-controller`
2. Add to your local `/etc/hosts` (or Windows `hosts` file): `<master-public-ip> nginx.demo.local`
3. Open `https://nginx.demo.local:<nodeport>` in a browser
4. Accept the self-signed cert warning → custom HTML loads

## Repository layout

```
.
├── README.md
├── design.md                           # Architecture, choices, pluses & minuses
├── .gitignore
├── scripts/
│   ├── 00-prep-node.sh                 # OS prep — run on all 3 nodes
│   ├── 01-init-master.sh               # kubeadm init — run on master
│   ├── 02-join-worker.sh               # kubeadm join — run on each worker
│   ├── 03-install-calico.sh            # Calico CNI via Tigera operator
│   ├── 04-install-cert-manager.sh
│   ├── 05-install-ingress-nginx.sh
│   ├── create-user.sh                  # CSR-based user onboarding
│   └── test-rbac.sh                    # Authorization matrix verification
├── rbac/
│   ├── namespace.yaml
│   ├── role-nginx-viewer.yaml
│   ├── role-nginx-admin.yaml
│   ├── rolebinding-alice-viewer.yaml
│   └── rolebinding-bob-admin.yaml
├── manifests/
│   ├── cluster-issuer.yaml             # cert-manager self-signed issuer
│   ├── nginx-app/                      # The Nginx workload
│   │   ├── configmap.yaml              # Custom HTML
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml                # TLS via cert-manager
│   └── network-policies/
│       ├── default-deny.yaml
│       ├── allow-ingress-from-nginx.yaml
│       └── allow-dns-egress.yaml
└── flux/
    ├── README.md
    └── nginx-app-kustomization.yaml    # Flux reconciles manifests/nginx-app
```

## Security notes

- `out/` is git-ignored. Generated user keys and kubeconfigs never leave the operator's machine.
- Roles use **no `*` wildcards** — every verb is explicit. Least privilege at the verb level.
- All user certificates are issued with a 30-day TTL (`expirationSeconds: 2592000`).
- NetworkPolicy enforces default-deny in `nginx-app`; only the Ingress controller can reach app pods on port 80.
- The self-signed `ClusterIssuer` is **intentional** for this lab — it keeps the rebuild test reproducible from any AWS account without a domain. Production design notes for Let's Encrypt + DNS-01 are in `design.md`.

## Total build time, fresh

~30 minutes from a clean AWS account to a working cluster with the Nginx app reachable via TLS.

## Author

**Fabio Rollin** — Teleport Professional Services take-home submission, May 2026.
