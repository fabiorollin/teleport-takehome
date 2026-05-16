# Flux GitOps

This directory documents the Flux v2 reconciliation setup for the Nginx
application.

## Why Flux

Pull-based GitOps reconciliation. The Git repository is the source of truth;
the cluster reconciles itself to whatever the repo says, on a schedule
(default 1 minute) or on demand. Drift in the cluster is reverted on the
next pass. This is the same operating model used at IPC Systems to manage
hundreds of customer Kubernetes clusters via Flux + Gitea.

## Bootstrap

After the cluster is up (scripts `00`–`05` complete), bootstrap Flux on the
master. The command installs the four Flux controllers
(source-controller, kustomize-controller, helm-controller,
notification-controller) into the `flux-system` namespace, and commits its
own configuration to the repository at `clusters/demo/flux-system/`.

```bash
# Set a GitHub Personal Access Token with repo scope.
export GITHUB_TOKEN=ghp_xxxxx

flux bootstrap github \
  --owner=<your-github-user> \
  --repository=<this-repo-name> \
  --branch=main \
  --path=clusters/demo \
  --personal
```

Flux verifies the controllers are healthy before exiting.

## Reconcile the Nginx app

Copy `nginx-app-kustomization.yaml` from this directory into `clusters/demo/`
in your repo, commit, and push:

```bash
cp flux/nginx-app-kustomization.yaml clusters/demo/
git add clusters/demo/nginx-app-kustomization.yaml
git commit -m "Flux: reconcile nginx-app from manifests/nginx-app"
git push
```

Flux's source-controller fetches the new commit on the next reconciliation
cycle (default 1 minute) and the kustomize-controller applies the manifests
at `manifests/nginx-app/` into the `nginx-app` namespace.

## Verify

```bash
flux get all
kubectl get gitrepository -A
kubectl get kustomization -A
```

You should see two Kustomizations: `flux-system` (the bootstrap source) and
`nginx-app` (this app). Both should be `Ready=True`.

## Live demo move

To prove GitOps reconciliation during the interview demo:

1. Edit `manifests/nginx-app/deployment.yaml` — change `replicas: 2` to `replicas: 3`
2. `git add`, `git commit`, `git push`
3. In a second terminal, `kubectl get pods -n nginx-app -w`
4. Within ~1 minute, a third Nginx pod appears — applied by Flux, not by the operator

This proves the cluster's state is governed by the repo, not by ad-hoc
`kubectl apply` commands.

## Drift detection

To prove Flux reverts drift:

1. `kubectl scale deployment/nginx --replicas=0 -n nginx-app`
2. Watch the pods get deleted
3. Within ~1 minute, the pods come back — Flux reconciled the cluster to
   the desired state in Git

## Why this matters for production

GitOps gives you four things native `kubectl apply` doesn't:

- **Source of truth in Git** — every change is reviewable, attributable, revertable
- **Continuous reconciliation** — manual drift is repaired automatically
- **Multi-cluster fleet management** — the same repo can drive many clusters
- **Audit trail in commits** — who changed what, when, and why (via commit messages)

The pluses-and-minuses section of `design.md` discusses how GitOps changes
the operational picture for `kubectl`-style access — short version: GitOps
removes the need for human `kubectl` access to most production resources,
which is a meaningful reduction in attack surface.
