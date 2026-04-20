#!/bin/bash
#
# ACM + ArgoCD Drift Prevention Demo
# OpenShift 4.20 | OpenShift GitOps 1.20 | ACM 2.12
#
# Prerequisites:
#   - Logged into an OCP 4.20 cluster as cluster-admin
#   - This git repo pushed to a remote accessible by the cluster
#   - Update <YOUR_ORG> placeholders (run with --setup <org> to do this automatically)
#
# Usage: ./demo/demo-script.sh [--setup <github-org-or-user>]

set -e

# --- Setup mode: replace <YOUR_ORG> placeholders ---
if [ "$1" = "--setup" ]; then
  if [ -z "$2" ]; then
    echo "Usage: $0 --setup <github-org-or-user>"
    exit 1
  fi
  ORG="$2"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "Replacing <YOUR_ORG> with '${ORG}' in all manifests..."
  sed -i'' -e "s|<YOUR_ORG>|${ORG}|g" \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-appproject.yaml" \
    "${SCRIPT_DIR}/bootstrap/argocd-config/cluster-config-application.yaml" \
    "${SCRIPT_DIR}/cluster-config/console-banner/console-notification.yaml"
  echo "Done. Verify with: grep -r '${ORG}' ${SCRIPT_DIR}/bootstrap/ ${SCRIPT_DIR}/cluster-config/"
  exit 0
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pause() {
  echo ""
  echo -e "${YELLOW}>>> Press ENTER to continue...${NC}"
  read -r
}

narrate() {
  echo ""
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}============================================================${NC}"
}

run_cmd() {
  echo ""
  echo -e "${GREEN}\$ $1${NC}"
  eval "$1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ============================================================
# PART 0: INSTALL OPERATORS
# ============================================================
narrate "PART 0: Installing Operators (OpenShift GitOps and ACM)"

echo -e "${BOLD}Step 0.1: Install OpenShift GitOps Operator${NC}"
echo "Subscribes to OpenShift GitOps 1.20. This automatically creates"
echo "an ArgoCD instance in the openshift-gitops namespace."
pause

run_cmd "oc apply -k ${SCRIPT_DIR}/bootstrap/operators/openshift-gitops/"

echo ""
echo "Waiting for the GitOps operator CSV to succeed..."
run_cmd "oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-gitops-operator -n openshift-operators --timeout=120s || true"

echo ""
echo "Waiting for ArgoCD server pod to be ready..."
for i in $(seq 1 30); do
  if oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server 2>/dev/null | grep -q Running; then
    echo -e "${GREEN}ArgoCD server is running!${NC}"
    break
  fi
  echo "  ...waiting (${i}/30)"
  sleep 10
done

pause

echo -e "${BOLD}Step 0.2: Install ACM Operator${NC}"
echo "Creates the namespace, operator group, subscription, and MultiClusterHub."
echo "Note: MultiClusterHub takes 5-10 minutes to fully deploy."
pause

run_cmd "oc apply -k ${SCRIPT_DIR}/bootstrap/operators/acm/"

echo ""
echo "ACM is deploying. The MultiClusterHub will take several minutes."
echo "You can monitor progress with:"
echo "  oc get multiclusterhub -n open-cluster-management -w"

pause

# ============================================================
# PART 1: VERIFY OPERATOR HEALTH
# ============================================================
narrate "PART 1: Verify Operators Are Healthy"

echo -e "${BOLD}Step 1.1: Check OpenShift GitOps${NC}"
run_cmd "oc get subscription openshift-gitops-operator -n openshift-operators"
echo ""
run_cmd "oc get pods -n openshift-gitops"

pause

echo -e "${BOLD}Step 1.2: Check ACM${NC}"
run_cmd "oc get subscription advanced-cluster-management -n open-cluster-management"
echo ""
run_cmd "oc get multiclusterhub -n open-cluster-management || echo 'MultiClusterHub not yet available'"

pause

# ============================================================
# PART 2: DEPLOY ARGOCD CONFIGURATION
# ============================================================
narrate "PART 2: Configure ArgoCD with Cluster Config Application"

echo -e "${BOLD}Step 2.1: Create the AppProject and Application${NC}"
echo ""
echo "The Application is configured with:"
echo "  - selfHeal: true  (auto-revert manual changes)"
echo "  - prune: true     (remove resources deleted from Git)"
echo ""
echo "This means ANY manual change to managed resources will be"
echo "detected and automatically corrected by ArgoCD."
pause

run_cmd "oc apply -k ${SCRIPT_DIR}/bootstrap/argocd-config/"

echo ""
echo "Waiting for initial sync..."
sleep 15

pause

echo -e "${BOLD}Step 2.2: Verify the Application is synced${NC}"
run_cmd "oc get application cluster-config -n openshift-gitops"

pause

# ============================================================
# PART 3: VERIFY CLUSTER CONFIGURATION
# ============================================================
narrate "PART 3: Verify All Cluster Configuration Is Applied"

echo -e "${BOLD}Step 3.1: Console Banner${NC}"
echo "A blue banner should now appear at the top of the OpenShift web console."
run_cmd "oc get consolenotification gitops-managed-cluster"

pause

echo -e "${BOLD}Step 3.2: RBAC Resources${NC}"
run_cmd "oc get clusterrole gitops-demo-viewer"
run_cmd "oc get clusterrolebinding gitops-demo-viewer-binding"

pause

echo -e "${BOLD}Step 3.3: Network Policy${NC}"
run_cmd "oc get networkpolicy deny-all-egress -n gitops-demo-secured"

pause

echo -e "${BOLD}Step 3.4: Resource Quotas and Limits${NC}"
run_cmd "oc get limitrange default-container-limits -n gitops-demo-quotas"
run_cmd "oc get resourcequota compute-quota -n gitops-demo-quotas"

pause

echo -e "${BOLD}Step 3.5: ArgoCD Application Sync Status${NC}"
run_cmd "oc get application cluster-config -n openshift-gitops -o jsonpath='{.status.sync.status}'"
echo ""
run_cmd "oc get application cluster-config -n openshift-gitops -o jsonpath='{.status.health.status}'"
echo ""

pause

# ============================================================
# PART 4: DRIFT PREVENTION DEMO
# ============================================================
narrate "PART 4: Demonstrate Drift Prevention"

echo -e "${RED}${BOLD}Now we intentionally break things and watch ArgoCD fix them!${NC}"

pause

# --- Drift Test 1: Delete the Console Banner ---
echo -e "${BOLD}Drift Test 1: Delete the Console Banner${NC}"
echo ""
echo "Scenario: An admin accidentally deletes the console banner."
echo "Expected: ArgoCD detects the drift and recreates it."
pause

run_cmd "oc delete consolenotification gitops-managed-cluster"
echo ""
echo -e "${YELLOW}Banner deleted! Refresh the OpenShift console to see it's gone.${NC}"
echo "Now watch ArgoCD restore it..."
echo ""

for i in $(seq 1 12); do
  if oc get consolenotification gitops-managed-cluster &>/dev/null; then
    echo -e "${GREEN}Banner restored by ArgoCD after ~$((i * 5)) seconds!${NC}"
    break
  fi
  echo "  ...not yet (${i}/12)"
  sleep 5
done

run_cmd "oc get consolenotification gitops-managed-cluster"
echo -e "${GREEN}Refresh your browser -- the banner is back.${NC}"

pause

# --- Drift Test 2: Modify the LimitRange ---
echo -e "${BOLD}Drift Test 2: Modify the LimitRange${NC}"
echo ""
echo "Scenario: A developer edits the LimitRange to allow 10 CPU cores"
echo "(bypassing the 2-core maximum defined in Git)."
echo "Expected: ArgoCD reverts it to the 2-core max."
pause

run_cmd "oc patch limitrange default-container-limits -n gitops-demo-quotas --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/limits/0/max/cpu\",\"value\":\"10\"}]'"
echo ""
echo "Verifying drift was introduced:"
run_cmd "oc get limitrange default-container-limits -n gitops-demo-quotas -o jsonpath='{.spec.limits[0].max.cpu}'"
echo ""
echo -e "${YELLOW}CPU max is now '10' -- this is drift!${NC}"
echo ""
echo "Waiting for ArgoCD to heal..."

for i in $(seq 1 12); do
  CURRENT=$(oc get limitrange default-container-limits -n gitops-demo-quotas -o jsonpath='{.spec.limits[0].max.cpu}' 2>/dev/null)
  if [ "$CURRENT" = "2" ]; then
    echo -e "${GREEN}LimitRange restored to max CPU '2' after ~$((i * 5)) seconds!${NC}"
    break
  fi
  echo "  ...current value: $CURRENT (${i}/12)"
  sleep 5
done

pause

# --- Drift Test 3: Delete the Network Policy ---
echo -e "${BOLD}Drift Test 3: Delete the NetworkPolicy${NC}"
echo ""
echo "Scenario: Someone removes the deny-all-egress policy,"
echo "opening up all egress traffic. This is a SECURITY ISSUE."
echo "Expected: ArgoCD immediately restores the policy."
pause

run_cmd "oc delete networkpolicy deny-all-egress -n gitops-demo-secured"
echo ""
echo -e "${RED}NetworkPolicy deleted! All egress traffic is now allowed!${NC}"
echo "Watching for ArgoCD to restore the security baseline..."

for i in $(seq 1 12); do
  if oc get networkpolicy deny-all-egress -n gitops-demo-secured &>/dev/null; then
    echo -e "${GREEN}NetworkPolicy restored after ~$((i * 5)) seconds!${NC}"
    break
  fi
  echo "  ...not yet (${i}/12)"
  sleep 5
done

run_cmd "oc get networkpolicy deny-all-egress -n gitops-demo-secured"

pause

# --- Drift Test 4: Escalate RBAC Permissions ---
echo -e "${BOLD}Drift Test 4: Attempt RBAC Privilege Escalation${NC}"
echo ""
echo "Scenario: An attacker adds 'delete secrets' permission"
echo "to the viewer ClusterRole."
echo "Expected: ArgoCD reverts the ClusterRole to read-only."
pause

run_cmd "oc patch clusterrole gitops-demo-viewer --type=json -p='[{\"op\":\"add\",\"path\":\"/rules/-\",\"value\":{\"apiGroups\":[\"\"],\"resources\":[\"secrets\"],\"verbs\":[\"get\",\"list\",\"delete\"]}}]'"
echo ""
echo -e "${RED}ClusterRole now allows deleting secrets!${NC}"
echo "Waiting for ArgoCD to revert..."

for i in $(seq 1 12); do
  RULES=$(oc get clusterrole gitops-demo-viewer -o jsonpath='{.rules}' 2>/dev/null)
  if ! echo "$RULES" | grep -q "secrets"; then
    echo -e "${GREEN}ClusterRole restored -- 'secrets' access removed after ~$((i * 5)) seconds!${NC}"
    break
  fi
  echo "  ...still contains 'secrets' rule (${i}/12)"
  sleep 5
done

run_cmd "oc get clusterrole gitops-demo-viewer -o yaml"

pause

# ============================================================
# PART 5: ARGOCD UI WALKTHROUGH
# ============================================================
narrate "PART 5: ArgoCD UI"

echo -e "${BOLD}ArgoCD Console URL:${NC}"
run_cmd "oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'"
echo ""
echo ""
echo "In the ArgoCD UI, show:"
echo "  1. 'cluster-config' Application is Synced and Healthy"
echo "  2. Resource tree with all four config categories"
echo "  3. Last Sync Result and self-heal events"
echo "  4. Diff tab on any resource to see what ArgoCD corrected"

pause

# ============================================================
# PART 6: ACM POLICY COMPLIANCE (Optional)
# ============================================================
narrate "PART 6: ACM Policy Compliance (Optional)"

echo -e "${BOLD}Step 6.1: Apply ACM Policies${NC}"
echo "These policies monitor compliance independently of ArgoCD."
echo "ACM provides a governance view -- even if ArgoCD heals drift,"
echo "ACM records the compliance events for audit."
pause

echo "To apply ACM policies (requires PolicyGenerator kustomize plugin):"
echo "  oc apply -k ${SCRIPT_DIR}/acm-policies/"
echo ""
echo "Then check compliance in the ACM console:"
echo "  Governance -> Policies -> policy-console-banner"
echo ""
echo "ACM will show:"
echo "  - Compliant: when the ConsoleNotification matches the desired state"
echo "  - NonCompliant: during the brief window when drift exists"

pause

# ============================================================
# WRAP UP
# ============================================================
narrate "DEMO COMPLETE"

echo -e "${BOLD}Key Takeaways:${NC}"
echo ""
echo "  1. ${GREEN}GitOps as Single Source of Truth${NC}"
echo "     All cluster configuration is version-controlled in Git."
echo ""
echo "  2. ${GREEN}Automatic Drift Prevention${NC}"
echo "     ArgoCD selfHeal + prune immediately corrects unauthorized changes."
echo ""
echo "  3. ${GREEN}Security Guardrails${NC}"
echo "     RBAC, NetworkPolicies, and ResourceQuotas cannot be bypassed."
echo ""
echo "  4. ${GREEN}Compliance Auditing${NC}"
echo "     ACM policies provide a governance layer with compliance history."
echo ""
echo "  5. ${GREEN}No Manual Intervention${NC}"
echo "     Drift was detected and healed automatically."
echo ""
echo -e "${BLUE}Thank you for attending the demo!${NC}"
