# Teleport take-home — kubeadm cluster with CSR-based RBAC

My submission for the Teleport Professional Services take-home, May 2026. Three EC2 nodes, kubeadm-built Kubernetes, with a non-admin user (`bob`) deploying an Nginx app through X.509 client certs signed by the cluster CA via the CertificateSigningRequest API. cert-manager handles TLS, Calico does the CNI and NetworkPolicy enforcement, Flux reconciles the app from this repo.

The repo is documented for the team to rebuild it from scratch in about 30 minutes. The design doc (design.md) covers the architecture decisions and where this kind of native-RBAC setup hits its limits at scale.

## What's in the repo

```
scripts/        Numbered bash scripts that build the cluster end to end.
                Run them in order on the right nodes (master vs workers).
rbac/           Namespace, two Roles (viewer, admin), and the matching
                RoleBindings for the demo users alice and bob.
manifests/      The Nginx app + the self-signed cert-manager ClusterIssuer
                + three NetworkPolicies that lock down the namespace.
flux/           The Flux Kustomization that reconciles manifests/nginx-app/
                from this repo.
clusters/demo/  Created by `flux bootstrap` — contains Flux's own config
                (gotk-components, gotk-sync, kustomization).
design.md       Architecture, why I picked each piece, the pluses-and-minuses
                analysis, and known limitations.
README.md       This file.
```

## Prerequisites

- AWS account with permissions to create EC2 instances, VPC groups, security groups
- An SSH keypair on your local machine, imported to AWS
- `kubectl`, `ssh`, `git`, `openssl`, `bash` locally

## End-to-end build, top to bottom


### 1. Provision three EC2 instances

Three `t3.medium` Ubuntu 24.04 LTS instances, 20 GiB root volume. Tag them `k8s-master`, `k8s-worker-1`, `k8s-worker-2`.

The security group needs to allow:

- **22/TCP from your IP** so you can SSH in
- **6443/TCP within the SG** — the Kubernetes API server runs here, kubelets on the workers need to reach it
- **2379–2380/TCP within the SG** — etcd, the cluster's source of truth. Only the master's API server talks to etcd, but it's good practice to scope it to the SG.
- **10250/TCP within the SG** — the kubelet API on each node. The control plane reaches into the kubelets here for `kubectl logs`, `kubectl exec`, metrics scraping, etc.
- **10257, 10259/TCP within the SG** — the controller-manager and scheduler health endpoints
- **8472/UDP within the SG** — VXLAN for Calico. This is the one most people forget. If Calico can't VXLAN between nodes, pod-to-pod traffic across nodes breaks silently. (Note: in same-subnet deployments Calico will route natively without VXLAN — see step 5 about the AWS source/dest check, which is the other half of that story.)
- **30000–32767/TCP from your IP** — NodePort range, so you can browser-hit the Nginx demo
- **80, 443 from your IP** — only if you want to use those ports directly; not required for the demo since we'll go through NodePort

The "within the SG" rules use the SG itself as the source, anything tagged with this security group can talk to anything else tagged with it on those ports.

### 2. Prep each node (`00-prep-node.sh`)

The script is the same on all three nodes. It does the usual kubeadm preflight setup:

- **Disables swap.** kubelet refuses to start if swap is on. There's a long history of memory-management interaction issues; the project decided to require swap off.
- **Loads `overlay` and `br_netfilter` kernel modules.** containerd needs overlay for its filesystem, and br_netfilter lets iptables see traffic going through Linux bridges (which Kubernetes Services rely on).
- **Sets `net.ipv4.ip_forward=1` and the two bridge sysctls.** Without IP forwarding, packets between pods on the same node don't get routed properly.
- **Installs containerd and configures `SystemdCgroup = true`.** kubelet and containerd have to agree on which cgroup driver to use; systemd is the modern default and what Ubuntu uses for everything else.
- **Installs kubeadm, kubelet, kubectl pinned to v1.30** and holds the packages so unattended-upgrades doesn't surprise you.

Copy it to each node and run:

```bash
for ip in <master-ip> <worker-1-ip> <worker-2-ip>; do
  scp scripts/00-prep-node.sh ubuntu@$ip:
  ssh ubuntu@$ip "chmod +x 00-prep-node.sh && sudo ./00-prep-node.sh"
done
```

You can run all three in parallel from three terminal tabs if you're impatient.

### 3. Initialize the master (`01-init-master.sh`)

On the master only:

```bash
./01-init-master.sh
```

What `kubeadm init` is doing under the hood:

- Generates the cluster PKI in `/etc/kubernetes/pki/` — including the cluster CA we'll use later to sign user certificates
- Writes static pod manifests for the control plane (apiserver, controller-manager, scheduler, etcd) into `/etc/kubernetes/manifests/`. kubelet watches that directory and runs whatever's in it.
- Sets up the admin kubeconfig at `/etc/kubernetes/admin.conf` (the script copies this into your `~/.kube/config`)
- Creates a bootstrap token for workers to join

The script also writes the worker join command into `/tmp/kubeadm-join.cmd` so you don't have to scroll the terminal history to find it.

Pod CIDR is pinned to `192.168.0.0/16` because that's what the Calico operator manifest defaults to. If you change one, change the other.

### 4. Join the workers

When `kubeadm init` ran on the master, it created a bootstrap token and printed the join command. That command tells each worker's kubelet: *"go to the master's API server at this address, present this token to prove you're allowed to join, download the cluster CA and the kubelet kubeconfig, then start participating."*

The join command is saved on the master at `/tmp/kubeadm-join.cmd`. Get it:

```bash
cat /tmp/kubeadm-join.cmd
```

SSH into each worker and run that command with sudo. The `02-join-worker.sh` script is just a thin wrapper that takes the command as an argument — you can use it or paste the kubeadm command directly:

```bash
# On each worker:
sudo kubeadm join 172.31.16.94:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Once both workers join, `kubectl get nodes` from the master shows all three as `Ready` within about 30 seconds — assuming Calico is already installed (step 5).

### 5. Install Calico (`03-install-calico.sh`)

On the master:

```bash
./03-install-calico.sh
```

This installs the Tigera operator first, then applies the Calico custom resources. The operator pattern means upgrades later are CR edits, not manifest re-applies.

A couple of things worth knowing here:

**Why install Calico before joining workers?** Until a CNI is installed, CoreDNS pods stay `Pending` (they have no network namespace to live in) and worker `kubelet`s can't bring pods up either. If you join workers before installing Calico, they show `NotReady` and you sit there confused. The order is: init master → install CNI → join workers.

**The AWS source/destination check gotcha.** This bit me on the first build. cert-manager's validating webhook was timing out when called from the apiserver across nodes. The root cause: AWS drops packets where the source IP doesn't match the ENI's IP. Calico in same-subnet mode uses native routing — so pod IPs (192.168.x.x) are the source IPs on packets leaving the node, but the ENI has a 172.31.x.x IP. AWS drops them.

The fix is to disable source/dest check on all three EC2 instances:

- EC2 Console → each instance → Actions → Networking → **Change source/destination check** → uncheck Stop
- Or via CLI: `aws ec2 modify-instance-attribute --instance-id <id> --no-source-dest-check`

After disabling, cross-node pod traffic works immediately. (Alternative: configure Calico to use VXLAN-always instead of VXLANCrossSubnet. That sidesteps the AWS issue at the CNI layer at a small encapsulation overhead.)

**Verify before proceeding.** Wait for `kubectl get pods -n calico-system` to show all `Running` (~2-3 minutes the first time), then `kubectl get nodes` should show the master as `Ready`. If you've already joined workers, they'll go `Ready` too.

### 6. Install cert-manager and NGINX Ingress (`04-...` and `05-...`)

Two scripts, sequentially. They're both thin wrappers around `kubectl apply` against the official upstream manifests, plus a `kubectl wait` to make sure the components are actually Ready before the script returns.

**cert-manager** (`04-install-cert-manager.sh`):

```bash
CM_VERSION="v1.15.0"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=300s
```

That one big YAML file deploys three components into the `cert-manager` namespace: the main controller, the CA injector (which patches the cluster's webhook configurations with the right CA bundle), and the webhook itself. It also installs a bunch of CRDs (`Issuer`, `ClusterIssuer`, `Certificate`, `CertificateRequest`, `Order`, `Challenge`).

The `wait` matters because the ClusterIssuer we apply in step 7 needs cert-manager's webhook to be Ready, otherwise the apply fails with a webhook timeout. The wait blocks until the deployments report Available, which means the webhook is registered and serving.

**NGINX Ingress** (`05-install-ingress-nginx.sh`):

```bash
NGINX_VERSION="controller-v1.11.1"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/${NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=300s
```

The key word in that URL is `baremetal`. ingress-nginx ships several "provider" variants — `cloud`, `aws`, `gce`, `baremetal`. They mostly differ in how the controller's Service is exposed: `cloud` provisions a LoadBalancer (depends on a cloud controller), `baremetal` uses NodePort. Since kubeadm doesn't bring a cloud-controller manager along, NodePort is what works.

After install, the controller's Service has two NodePorts — one for HTTP (80 → 3xxxx) and one for HTTPS (443 → 3yyyy):

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

The HTTPS NodePort is what you'll hit in the browser — it's randomly assigned at install time and different on every fresh cluster. Save the number.

**Why self-signed ClusterIssuer instead of Let's Encrypt?** Reproducibility. A self-signed issuer needs nothing external and cert-manager generates its own CA and signs certs with it. Let's Encrypt would require owning a real domain and giving cert-manager Route 53 IAM credentials so it can complete the DNS-01 challenge. For a take-home that anyone should be able to rebuild from a fresh AWS account, self-signed wins. The production path with Let's Encrypt is documented in `design.md`.

### 7. Apply RBAC and the cert-manager issuer (as cluster admin)

This is the step where the cluster admin lays down the **safety rails** — the namespace, the Roles that define what users can do, the bindings between users and Roles, and the cluster-wide cert-manager issuer that the app's Ingress will later reference. Nothing in this step deploys the actual application; that comes in step 9 and is deliberately done as a non-admin user.

```bash
kubectl apply -f rbac/
kubectl apply -f manifests/cluster-issuer.yaml
```

#### What's in `rbac/`

- **`namespace.yaml`** — creates the `nginx-app` namespace. Everything else in this take-home lives inside it. The namespace has a `kubernetes.io/metadata.name=nginx-app` label which the NetworkPolicies will match on later.

- **`role-nginx-viewer.yaml`** — a namespace-scoped `Role` granting `get`/`list`/`watch` on pods, deployments, services, ingresses, configmaps, certificates. Read-only. 

- **`role-nginx-admin.yaml`** — same resource list as viewer plus `create`, `update`, `patch`, `delete`. Also grants the same verbs on `NetworkPolicy` and cert-manager `Certificate` resources, so the admin user can manage TLS and traffic rules. 

- **`rolebinding-alice-viewer.yaml`** — binds the *user* `alice` to the `nginx-viewer` Role. The subject is `kind: User, name: alice`.  The string `alice` is what the API server pulls from the CN of an authenticated client certificate. Whoever presents a cert with `CN=alice` *is* alice as far as RBAC is concerned.

- **`rolebinding-bob-admin.yaml`** — same shape, binds `bob` to `nginx-admin`.

This separation between authentication (the cert) and authorization (the RoleBinding) is deliberate. It matches the production pattern of "create the policy first, then issue credentials that grant access under that policy"

#### What's in `manifests/cluster-issuer.yaml`

A single `ClusterIssuer` resource named `selfsigned-cluster-issuer` of type `SelfSigned`. Three things to know about it:

- It's **cluster-scoped** (`ClusterIssuer` not `Issuer`), so a Certificate resource in any namespace can reference it. The Ingress in step 9 will, by way of a cert-manager annotation.
- The `selfSigned: {}` spec means cert-manager doesn't need to talk to any external CA. When a Certificate references this issuer, cert-manager generates a fresh CA key, signs the cert with it, and stores both in the target Secret. No DNS challenge, no ACME, no external dependency.

#### Verify the issuer is Ready

```bash
kubectl get clusterissuer
```

Expected output:

```
NAME                         READY   AGE
selfsigned-cluster-issuer    True    5s
```

If `READY=False`, cert-manager's webhook isn't responding. Most often that's a cross-node networking issue see the AWS source/dest check note in step 5.

#### What's intentionally NOT applied yet

The Nginx app (`manifests/nginx-app/`) and the NetworkPolicies (`manifests/network-policies/`) are not applied here. They get applied in step 9 using `bob`'s kubeconfig — the whole demo point of this exercise is that a non-admin user, authenticated via a CSR-signed cert, can deploy a real workload end to end. Doing that work as cluster admin would defeat the purpose.

### 8. Onboard the demo users via CSR

The script `create-user.sh` generates credentials for a Kubernetes user using the cluster's own CA with no external IdP, no shared password.

Run it twice, once per user:

```bash
./scripts/create-user.sh alice
./scripts/create-user.sh bob
./scripts/test-rbac.sh
```

What the script does in 6 steps:

1. Generates a 2048-bit RSA private key for the user
2. Generates a Certificate Signing Request (CSR) with `CN=<username>` 
3. Submits the CSR as a Kubernetes `CertificateSigningRequest` resource (`certificates.k8s.io/v1`), with `signerName: kubernetes.io/kube-apiserver-client`
4. Approves the CSR with `kubectl certificate approve`. 
5. Pulls the signed certificate out of `.status.certificate` on the CSR resource
6. Builds a kubeconfig that combines the cluster CA cert, the user's private key, and the signed cert. The kubeconfig defaults to the `nginx-app` namespace context.

After this runs, the user kubeconfig is in `out/<username>.kubeconfig`. Authentication (this script) and authorization (RoleBindings) are deliberately separate.

`test-rbac.sh` runs the authorization matrix as both users and prints PASS/FAIL for each check. Expected: 16 PASS, 0 FAIL. Alice can read in nginx-app but can't write, Bob can do everything in nginx-app, neither can touch kube-system because both Roles are namespace-scoped.

### 9. Deploy the Nginx app — as bob

A user whose access is governed entirely by the CSR-signed cert can apply the workload manifests, and they show up working with valid TLS.

```bash
kubectl --kubeconfig=out/bob.kubeconfig apply -f manifests/nginx-app/
kubectl --kubeconfig=out/bob.kubeconfig apply -f manifests/network-policies/
```

Then verify:

```bash
kubectl --kubeconfig=out/bob.kubeconfig get pods,svc,ingress,certificate -n nginx-app
```

The Certificate should transition to `READY=True` within about 30 seconds. cert-manager picks it up from the Ingress annotation and signs it with the self-signed ClusterIssuer.

To hit the app in a browser, add an entry to your local `/etc/hosts` (or Windows `C:\Windows\System32\drivers\etc\hosts`):

```
<master-public-ip>  nginx.demo.local
```

Then browse to `https://nginx.demo.local:<NodePort>`. The cert will trigger a "Not secure" warning (it's self-signed, expected), click through, and the custom HTML loads.

### 10. Bonus — Flux GitOps reconciliation

Bootstrap Flux pointing at this repo:

```bash
export GITHUB_TOKEN=ghp_xxx   # a PAT with repo scope
flux bootstrap github \
  --owner=fabiorollin \
  --repository=teleport-takehome \
  --branch=main \
  --path=clusters/demo \
  --personal
```

Flux installs its four controllers in the `flux-system` namespace and commits its own config to `clusters/demo/flux-system/` in this repo. The `clusters/demo/nginx-app.yaml` Kustomization (already in the repo) tells Flux to reconcile `manifests/nginx-app/` into the cluster.

Once it's running, `flux get kustomizations` shows both `flux-system` (Flux managing itself) and `nginx-app` (Flux managing the workload). Edit `manifests/nginx-app/deployment.yaml` in Git, commit, push, and within about a minute Flux applies the change. Conversely, scale the deployment manually with `kubectl scale` — Flux will revert it on the next reconciliation pass. Git is the source of truth.

## Validation

After install, these should all work:

```bash
kubectl get nodes                                                          # 3 Ready
kubectl get pods -A                                                        # nothing CrashLoopBackOff
kubectl --kubeconfig=out/bob.kubeconfig get pods -n nginx-app              # bob can read
kubectl --kubeconfig=out/alice.kubeconfig create deployment foo \
  --image=nginx -n nginx-app                                               # alice forbidden
curl -k --resolve nginx.demo.local:<NodePort>:127.0.0.1 \
  https://nginx.demo.local:<NodePort>/                                     # returns custom HTML
```

## Security notes

- `out/` is gitignored — generated user keys and kubeconfigs never leave the operator's machine. The Roles use **no `*` verbs anywhere**; every verb is explicit.
- All user certificates are issued with a 30-day TTL (`expirationSeconds: 2592000` in the script). Past that, you re-onboard.
- NetworkPolicy enforces default-deny in `nginx-app`; only the Ingress controller can reach app pods on port 80, only DNS egress is permitted.
- Self-signed TLS is intentional for this lab. The Let's Encrypt + DNS-01 production path is documented in `design.md` along with the trade-off.
- SSH is open to 0.0.0.0/0 on these instances for operator convenience during the lab — production would use SSM Session Manager, an identity-aware proxy, or Teleport itself.

## Known limitations

Called out honestly in `design.md`, but the headline ones:

- **Single-master control plane.** No HA. Production would be 3 masters with stacked etcd behind an internal LB.
- **NodePort exposure.** Works for the demo, MetalLB or a cloud LB would be the production answer.
- **No audit log shipping.** Audit policy is unset; in production this would ship to Splunk via Fluent Bit.
- **No cert expiry monitoring.** Manual `kubectl get csr` is the only visibility into who's near expiry. Production would alert.



## Author

Fabio Rollin — submitted for the Teleport Professional Services take-home, May 2026.