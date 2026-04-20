#!/bin/bash
#
# ACM + ArgoCD Demo Teardown
# Removes all resources created by the demo in the correct order.
#
# Usage: ./demo/teardown.sh

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

narrate() {
  echo ""
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}============================================================${NC}"
}

run_cmd() {
  echo -e "${GREEN}\$ $1${NC}"
  eval "$1" || true
}

remove_finalizers() {
  local resource=$1
  local name=$2
  local namespace=$3
  if [ -n "$namespace" ]; then
    if oc get "$resource" "$name" -n "$namespace" &>/dev/null; then
      echo -e "${YELLOW}Removing finalizers from $resource/$name in $namespace${NC}"
      oc patch "$resource" "$name" -n "$namespace" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    fi
  else
    if oc get "$resource" "$name" &>/dev/null; then
      echo -e "${YELLOW}Removing finalizers from $resource/$name${NC}"
      oc patch "$resource" "$name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    fi
  fi
}

remove_ns_finalizers() {
  local ns=$1
  if oc get namespace "$ns" &>/dev/null; then
    echo -e "${YELLOW}Removing finalizers from namespace $ns${NC}"
    oc get namespace "$ns" -o json | \
      python3 -c "import sys,json; o=json.load(sys.stdin); o['spec']['finalizers']=[]; print(json.dumps(o))" | \
      oc replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
  fi
}

# ============================================================
# STEP 1: Remove ArgoCD Application (stop self-healing)
# ============================================================
narrate "Step 1: Remove ArgoCD Application (stops self-healing)"

run_cmd "oc delete application.argoproj.io cluster-config -n openshift-gitops --timeout=60s"

echo ""

# ============================================================
# STEP 2: Remove cluster-config managed resources
# ============================================================
narrate "Step 2: Remove cluster-config managed resources"

echo -e "${BOLD}Console Banner${NC}"
run_cmd "oc delete consolenotification gitops-managed-cluster"

echo -e "${BOLD}RBAC${NC}"
run_cmd "oc delete clusterrolebinding gitops-demo-viewer-binding"
run_cmd "oc delete clusterrole gitops-demo-viewer"

echo -e "${BOLD}Network Policy${NC}"
run_cmd "oc delete networkpolicy deny-all-egress -n gitops-demo-secured"

echo -e "${BOLD}Resource Quotas and Limits${NC}"
run_cmd "oc delete resourcequota compute-quota -n gitops-demo-quotas"
run_cmd "oc delete limitrange default-container-limits -n gitops-demo-quotas"

echo ""

# ============================================================
# STEP 3: Remove ArgoCD AppProject and ClusterRoleBinding
# ============================================================
narrate "Step 3: Remove ArgoCD config"

run_cmd "oc delete appproject cluster-config -n openshift-gitops"
run_cmd "oc delete clusterrolebinding argocd-application-controller-cluster-config"

echo ""

# ============================================================
# STEP 4: Remove MultiClusterHub (before removing ACM operator)
# ============================================================
narrate "Step 4: Remove MultiClusterHub"

if oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null; then
  echo -e "${GREEN}\$ oc delete multiclusterhub multiclusterhub -n open-cluster-management --wait=false${NC}"
  oc delete multiclusterhub multiclusterhub -n open-cluster-management --wait=false 2>/dev/null || true

  echo "Waiting for MultiClusterHub to be removed (up to 5 minutes)..."
  for i in $(seq 1 30); do
    if ! oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null; then
      echo -e "${GREEN}MultiClusterHub removed.${NC}"
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo -e "${YELLOW}MultiClusterHub stuck in Uninstalling — clearing finalizers...${NC}"
      remove_finalizers multiclusterhub multiclusterhub open-cluster-management
      sleep 5
      if ! oc get multiclusterhub multiclusterhub -n open-cluster-management &>/dev/null; then
        echo -e "${GREEN}MultiClusterHub removed after clearing finalizers.${NC}"
      else
        echo -e "${RED}MultiClusterHub may still be deleting. Continuing teardown.${NC}"
      fi
    else
      echo "  ...waiting (${i}/30)"
      sleep 10
    fi
  done
else
  echo "MultiClusterHub not found, skipping."
fi

echo ""

# ============================================================
# STEP 5: Remove ACM Operator
# ============================================================
narrate "Step 5: Remove ACM Operator"

run_cmd "oc delete subscription.operators.coreos.com advanced-cluster-management -n open-cluster-management"

ACM_CSV=$(oc get csv -n open-cluster-management -o name 2>/dev/null | grep advanced-cluster-management || true)
if [ -n "$ACM_CSV" ]; then
  run_cmd "oc delete $ACM_CSV -n open-cluster-management --timeout=120s"
fi

run_cmd "oc delete operatorgroup acm-operator-group -n open-cluster-management"

echo ""

# ============================================================
# STEP 6: Remove OpenShift GitOps Operator
# ============================================================
narrate "Step 6: Remove OpenShift GitOps Operator"

run_cmd "oc delete subscription.operators.coreos.com openshift-gitops-operator -n openshift-operators"

GITOPS_CSV=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep gitops || true)
if [ -n "$GITOPS_CSV" ]; then
  run_cmd "oc delete $GITOPS_CSV -n openshift-operators --timeout=120s"
fi

echo ""

# ============================================================
# STEP 7: Delete namespaces (last)
# ============================================================
narrate "Step 7: Delete namespaces"

NAMESPACES=(gitops-demo-rbac gitops-demo-secured gitops-demo-quotas)

for ns in "${NAMESPACES[@]}"; do
  run_cmd "oc delete namespace $ns --timeout=60s"
done

echo ""
echo "Deleting open-cluster-management namespace (may take a few minutes)..."
run_cmd "oc delete namespace open-cluster-management --timeout=300s"

# Check for stuck namespaces and clear finalizers if needed
echo ""
echo "Checking for stuck namespaces..."
for ns in "${NAMESPACES[@]}" open-cluster-management; do
  STATUS=$(oc get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$STATUS" = "Terminating" ]; then
    echo -e "${YELLOW}Namespace $ns is stuck in Terminating — clearing finalizers...${NC}"
    remove_ns_finalizers "$ns"
  fi
done

echo ""

# ============================================================
# STEP 8: Restore <YOUR_ORG> placeholders
# ============================================================
narrate "Step 8: Restore <YOUR_ORG> placeholders in manifests"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CURRENT_ORG=$(grep -oP 'github\.com/\K[^/]+(?=/ACMGitOps)' \
  "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-application.yaml" 2>/dev/null || true)

if [ -n "$CURRENT_ORG" ] && [ "$CURRENT_ORG" != '<YOUR_ORG>' ]; then
  echo "Detected org '${CURRENT_ORG}', replacing with '<YOUR_ORG>'..."
  sed -i'' -e "s|${CURRENT_ORG}/ACMGitOps|<YOUR_ORG>/ACMGitOps|g" \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-appproject.yaml" \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-application.yaml" \
    "${SCRIPT_DIR}/cluster-config/console-banner/console-notification.yaml"
  rm -f \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-appproject.yaml-e" \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-application.yaml-e" \
    "${SCRIPT_DIR}/cluster-config/console-banner/console-notification.yaml-e"
  echo -e "${GREEN}Placeholders restored.${NC}"
else
  echo "Placeholders already set or could not detect org, skipping."
fi

echo ""

# ============================================================
# DONE
# ============================================================
narrate "TEARDOWN COMPLETE"

echo -e "${GREEN}All demo resources have been removed and placeholders restored.${NC}"
echo ""
echo "Verify with:"
echo "  oc get namespaces | grep -E 'gitops-demo|open-cluster-management'"
echo "  oc get consolenotification gitops-managed-cluster"
echo "  oc get clusterrole gitops-demo-viewer"
echo "  grep '<YOUR_ORG>' bootstrap/argocd-config/*.yaml cluster-config/console-banner/*.yaml"
echo ""
