#!/usr/bin/env bash
# Prerequisites Check - Run before the demo to ensure everything is ready.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-llm-vmware-hybrid}"
REGION="${AWS_REGION:-sa-east-1}"
NAMESPACE="demo-stone"
HYBRID_LABEL="eks.amazonaws.com/compute-type=hybrid"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }

echo "══════════════════════════════════════════════════"
echo "  Prerequisites Check"
echo "  Cluster: ${CLUSTER_NAME} | Region: ${REGION}"
echo "══════════════════════════════════════════════════"
echo ""

# 1. kubectl connectivity
echo "─── kubectl ───"
if kubectl cluster-info &>/dev/null; then
  pass "Connected to cluster"
else
  fail "Cannot reach cluster. Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
  exit 1
fi

# 2. Hybrid node
echo ""
echo "─── Hybrid Node ───"
HYBRID_COUNT=$(kubectl get nodes -l ${HYBRID_LABEL} --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$HYBRID_COUNT" -ge 1 ]]; then
  HYBRID_STATUS=$(kubectl get nodes -l ${HYBRID_LABEL} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
  if [[ "$HYBRID_STATUS" == "True" ]]; then
    pass "Hybrid node Ready (${HYBRID_COUNT} node(s))"
  else
    fail "Hybrid node exists but NOT Ready (status: ${HYBRID_STATUS})"
    echo "    → Power on the VM in vCenter and wait ~2min"
  fi
else
  fail "No hybrid nodes found"
  echo "    → Register a node with nodeadm (see README Path A, Step 5)"
fi

# 3. Gateway pods
echo ""
echo "─── Hybrid Node Gateway ───"
GW_READY=$(kubectl get pods -n eks-hybrid-nodes-gateway --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$GW_READY" -ge 1 ]]; then
  pass "Hybrid Node Gateway: ${GW_READY} pod(s) running"
else
  warn "Hybrid Node Gateway not running"
  echo "    → Ensure gateway node group has desiredSize >= 2"
fi

# 4. AWS LB Controller
echo ""
echo "─── AWS Load Balancer Controller ───"
LBC=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LBC" -ge 1 ]]; then
  pass "AWS LB Controller: ${LBC} replica(s)"
else
  fail "AWS LB Controller not running"
  echo "    → Install via Helm (see README)"
fi

# 5. Cilium
echo ""
echo "─── Cilium CNI ───"
CILIUM=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$CILIUM" -ge 1 ]]; then
  pass "Cilium agents: ${CILIUM} running"
else
  warn "Cilium agents: ${CILIUM} (may need Gateway Nodes for full mesh)"
fi

# 6. VPN
echo ""
echo "─── VPN Connectivity ───"
VPN_UP=$(aws ec2 describe-vpn-connections --region ${REGION} \
  --query 'VpnConnections[].VgwTelemetry[?Status==`UP`]' \
  --output json 2>/dev/null | jq 'length')
if [[ "$VPN_UP" -ge 1 ]]; then
  pass "VPN tunnels UP: ${VPN_UP}"
else
  warn "No VPN tunnels UP - checking for dynamic IP mismatch..."
  # Dynamic residential IP check: compare current public IP vs registered CGWs
  MY_IP=$(curl -s -4 --max-time 8 ifconfig.me 2>/dev/null || echo "unknown")
  CGW_IPS=$(aws ec2 describe-customer-gateways --region ${REGION} \
    --query 'CustomerGateways[?State==`available`].IpAddress' --output text 2>/dev/null)
  if [[ "$MY_IP" != "unknown" ]] && ! echo "$CGW_IPS" | grep -q "$MY_IP"; then
    fail "PUBLIC IP MISMATCH: current=${MY_IP}, registered CGWs=[${CGW_IPS}]"
    echo "    → Your residential IP changed. Fix with the runbook in README:"
    echo "      'Dynamic Residential IP - VPN Recovery Runbook'"
    echo "      (create-customer-gateway + modify-vpn-connection, no pfSense changes)"
  else
    echo "    → IP matches a CGW. Check pfSense IPsec status and ISP connectivity."
  fi
fi

# 7. Namespace
echo ""
echo "─── Demo Namespace ───"
if kubectl get ns ${NAMESPACE} &>/dev/null; then
  pass "Namespace '${NAMESPACE}' exists"
  PODS=$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "    ${PODS} pod(s) deployed"
else
  warn "Namespace '${NAMESPACE}' does not exist (will be created on deploy)"
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Done. Fix any ✗ items before running the demo."
echo "══════════════════════════════════════════════════"
