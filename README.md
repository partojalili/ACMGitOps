# ACM + ArgoCD Drift Prevention Demo

Demonstrates that OpenShift cluster configuration managed via GitOps (ArgoCD) is immune to configuration drift. Manual changes to cluster resources are automatically detected and reverted.

## Components

| Component | Version | Channel |
|---|---|---|
| OpenShift | 4.20 | N/A |
| OpenShift GitOps | 1.20 | `gitops-1.20` |
| ACM | 2.12 | `release-2.12` |

## Prerequisites

- OpenShift 4.20 cluster with cluster-admin access
- `oc` CLI logged in
- This repo pushed to a Git remote accessible from the cluster

## Repository Structure

```
bootstrap/           # Applied manually (one-time setup)
  operators/         # Operator subscriptions (ACM, GitOps)
  argocd-config/     # ArgoCD Application with selfHeal + prune

cluster-config/      # Managed by ArgoCD (drift-protected)
  console-banner/    # Visual: blue "GitOps managed" banner
  rbac/              # Security: read-only ClusterRole + binding
  network-policy/    # Security: deny-all egress NetworkPolicy
  resource-quota/    # Operational: LimitRange + ResourceQuota

acm-policies/        # Optional: ACM governance policies
demo/                # Interactive demo script
```

## Quick Start

1. **Replace `<YOUR_ORG>` placeholders** with your GitHub org or username:
   ```bash
   ./demo/demo-script.sh --setup <your-github-org>
   ```

2. **Push to Git remote**
   ```bash
   git init && git add -A && git commit -m "Initial commit"
   git remote add origin https://github.com/<your-github-org>/ACMGitOps.git
   git push -u origin main
   ```

3. **Run the demo**
   ```bash
   ./demo/demo-script.sh
   ```

## What the Demo Shows

The demo walks through 4 drift scenarios, each automatically healed by ArgoCD:

| Test | What Breaks | Impact | Self-Heal |
|---|---|---|---|
| Delete console banner | `oc delete consolenotification` | Visual change | Recreated in ~30s |
| Modify LimitRange | CPU max 2 -> 10 | Resource limits bypassed | Reverted in ~30s |
| Delete NetworkPolicy | Egress deny removed | Security policy gone | Recreated in ~30s |
| RBAC escalation | Add secrets/delete to viewer role | Privilege escalation | Reverted in ~30s |

## ArgoCD Self-Healing

The core mechanism is in `bootstrap/argocd-config/cluster-config-application.yaml`:

```yaml
syncPolicy:
  automated:
    selfHeal: true   # Revert manual changes
    prune: true      # Remove orphaned resources
```

ArgoCD continuously compares the cluster state against Git. When drift is detected, it automatically syncs the cluster back to the desired state defined in Git.
