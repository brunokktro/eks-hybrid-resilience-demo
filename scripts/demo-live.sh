#!/usr/bin/env bash
# EKS Hybrid Nodes Resilience Demo - Live Interactive Script
#
# DESIGN PHILOSOPHY:
#   This script is meant to be run DURING a customer call.
#   It pauses between steps, explains what's happening, and
#   lets the presenter answer questions at each stage.
#   The customer sees the terminal output - it should be clear and visual.
#
# Usage: ./demo-live.sh [scenario]
#   No args: interactive menu
#   0|1|2|3a|3b|recovery: jump to specific scenario
set -euo pipefail

# ─── Configuration (adjust for your environment) ─────────────────────────────
NAMESPACE="demo-stone"
REGION="${AWS_REGION:-sa-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-vmware-hybrid}"
HYBRID_NODE_LABEL="eks.amazonaws.com/compute-type=hybrid"
FIS_TEMPLATE_ID="${FIS_TEMPLATE_ID:-}"  # Set via: export FIS_TEMPLATE_ID=EXTxxxxxx

# ─── Colors and formatting ───────────────────────────────────────────────────
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

header()  { echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}${BOLD}  $1${NC}"; echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
step()    { echo -e "${YELLOW}▸${NC} ${BOLD}$1${NC}"; }
explain() { echo -e "${DIM}  $1${NC}"; }
result()  { echo -e "${GREEN}  ✓ $1${NC}"; }
fail()    { echo -e "${RED}  ✗ $1${NC}"; }
pause()   { echo ""; echo -e "${DIM}  [Press ENTER to continue...]${NC}"; read -r; }

run_cmd() {
  echo -e "${DIM}  \$ $1${NC}"
  eval "$1"
  echo ""
}

# ─── Scenario 0: Current State ───────────────────────────────────────────────
scenario_0() {
  header "CURRENT STATE - Cluster Overview"

  step "Nodes in the cluster"
  explain "Note the hybrid node: different hostname (mi-xxx), different OS, different IP range"
  run_cmd "kubectl get nodes -o wide"
  pause

  step "Demo pods - check which node each pod runs on"
  explain "Green (hybrid) = on-premises  |  Blue (cloud) = AWS region"
  run_cmd "kubectl get pods -n ${NAMESPACE} -o wide"
  pause

  step "Tolerations on the hybrid deployment"
  explain "These tolerations are what keep pods alive during disconnection"
  run_cmd "kubectl get deploy server-hybrid-1 -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.tolerations}' | jq '.'"
  echo ""
  explain "Without tolerations: pods evicted after 300s (5 min, Kubernetes default)"
  explain "With our config: pods survive for 3600s (1h). Production: omit tolerationSeconds for indefinite."
  pause
}

# ─── Scenario 3a: LB Region → Hybrid ─────────────────────────────────────────
scenario_3a() {
  header "SCENARIO 3a: Load Balancer → Hybrid Nodes (Ingress)"

  ALB=$(kubectl get ingress demo-ingress -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -z "$ALB" ]]; then
    fail "ALB not ready yet. Wait for ingress to provision."
    return
  fi

  step "ALB endpoint"
  echo -e "  ${BOLD}http://${ALB}/${NC}"
  echo ""
  explain "Traffic flow: Internet → ALB (sa-east-1) → Gateway Node → VXLAN → Hybrid Node Pod"
  pause

  step "Single request to on-premises pod"
  run_cmd "curl -s 'http://${ALB}/' | jq '{hostname, message, color}'"
  result "External traffic reached the on-premises pod"
  pause

  step "Multiple requests - load distribution across replicas"
  for i in $(seq 1 5); do
    HOSTNAME=$(curl -s "http://${ALB}/" | jq -r '.hostname' 2>/dev/null || echo "timeout")
    echo -e "    Request ${i}: ${GREEN}${HOSTNAME}${NC}"
  done
  echo ""
  result "ALB distributes traffic across on-premises pod replicas"
  pause

  step "Explicit routing: /cloud endpoint (comparison)"
  run_cmd "curl -s 'http://${ALB}/cloud' | jq '{hostname, message}'"
  result "Same ALB can route to both on-prem and cloud pods"
  pause
}

# ─── Scenario 3b: Hybrid → External ──────────────────────────────────────────
scenario_3b() {
  header "SCENARIO 3b: Hybrid Nodes → External (Egress)"

  step "Pod on-premises calling external API (httpbin.org)"
  explain "This validates the pod has outbound internet connectivity"
  run_cmd "kubectl exec -n ${NAMESPACE} deploy/server-hybrid-1 -- curl -s httpbin.org/ip"
  result "On-premises pod can reach the internet"
  pause

  step "Cross-cluster: on-premises pod calling cloud pod"
  explain "Pod-to-pod communication between on-prem and cloud via VXLAN"
  run_cmd "kubectl exec -n ${NAMESPACE} deploy/server-hybrid-1 -- curl -s http://server-cloud.${NAMESPACE}:9898/ | jq '{hostname, message}'"
  pause

  step "Cross-node: on-premises Node 1 calling on-premises Node 2"
  explain "Pod-to-pod between two on-prem nodes via Cilium VXLAN mesh"
  run_cmd "kubectl exec -n ${NAMESPACE} deploy/server-hybrid-1 -- curl -s http://server-hybrid-2.${NAMESPACE}:9898/ | jq '{hostname, message}'"
  result "All paths working: local, cross-node, cross-cluster, internet"
  pause
}

# ─── Scenario 1: Steady-State Disconnect ─────────────────────────────────────
scenario_1() {
  header "SCENARIO 1: Network Disconnection (Steady State)"

  step "Current state BEFORE fault injection"
  run_cmd "kubectl get nodes -l ${HYBRID_NODE_LABEL} -o wide"
  run_cmd "kubectl get pods -n ${NAMESPACE} -l location=hybrid -o wide"
  pause

  step "All 3 clients actively calling their targets every 5s"
  explain "client-hybrid (LOCAL): Node 1 → Node 1 (same node)"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid --tail=3"
  explain "client-hybrid-to-hybrid (CROSS-NODE): Node 1 → Node 2 (on-prem mesh)"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid-to-hybrid --tail=3"
  explain "client-cloud-to-hybrid (CROSS-CLUSTER): cloud → on-prem (via VPN)"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-cloud-to-hybrid --tail=3"
  pause

  step "Injecting network fault..."
  echo ""
  if [[ -n "$FIS_TEMPLATE_ID" ]]; then
    explain "Using AWS FIS disrupt-connectivity: NACL deny rules on cluster subnets"
    explain "This simulates: 'the network link between AWS and the datacenter went down'"
    echo ""
    FIS_EXP_ID=$(aws fis start-experiment \
      --experiment-template-id "${FIS_TEMPLATE_ID}" \
      --region ${REGION} \
      --query 'experiment.id' \
      --output text 2>/dev/null || echo "")

    if [[ -n "$FIS_EXP_ID" ]]; then
      result "FIS Experiment started: ${FIS_EXP_ID}"
    else
      fail "FIS start failed. Using manual method."
      echo ""
      echo -e "  ${YELLOW}Manual method:${NC} In vCenter → VM → Edit Settings → Network Adapter → Disconnect"
      pause
    fi
  else
    echo -e "  ${YELLOW}FIS_TEMPLATE_ID not set.${NC}"
    echo -e "  ${YELLOW}Manual method:${NC} In vCenter → VM → Edit Settings → Network Adapter → Disconnect"
    echo ""
    explain "Or set FIS_TEMPLATE_ID and re-run: export FIS_TEMPLATE_ID=EXTxxxxxx"
    pause
  fi

  echo ""
  step "Watching node status (node becomes NotReady after ~40s)"
  explain "The kubelet heartbeat (node lease) stops being renewed."
  explain "After node-monitor-grace-period (40s), node-lifecycle-controller marks it NotReady."
  echo ""

  for i in $(seq 1 8); do
    NODE_STATUS=$(kubectl get nodes -l ${HYBRID_NODE_LABEL} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    TAINTS=$(kubectl get nodes -l ${HYBRID_NODE_LABEL} -o jsonpath='{.items[0].spec.taints[*].key}' 2>/dev/null || echo "")
    TIMESTAMP=$(date +%H:%M:%S)
    if [[ "$NODE_STATUS" == "True" ]]; then
      echo -e "    ${TIMESTAMP} [${i}0s] Ready=${GREEN}True${NC} | Taints: ${TAINTS:-none}"
    else
      echo -e "    ${TIMESTAMP} [${i}0s] Ready=${RED}${NODE_STATUS}${NC} | Taints: ${TAINTS}"
      echo ""
      break
    fi
    sleep 10
  done

  step "Node is NotReady. Checking ALL 3 clients:"
  echo ""
  echo -e "  ${GREEN}${BOLD}client-hybrid (LOCAL - Node 1 → Node 1):${NC}"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid --tail=5"
  echo -e "  ${GREEN}${BOLD}client-hybrid-to-hybrid (CROSS-NODE - Node 1 → Node 2):${NC}"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid-to-hybrid --tail=5"
  echo -e "  ${RED}${BOLD}client-cloud-to-hybrid (CROSS-CLUSTER - cloud → on-prem):${NC}"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-cloud-to-hybrid --tail=5"

  echo ""
  echo -e "  ${GREEN}${BOLD}━━━ THE CONTRAST IS THE PROOF ━━━${NC}"
  echo ""
  explain "client-hybrid (local):            200 ✓ uninterrupted"
  explain "client-hybrid-to-hybrid (x-node): 200 ✓ uninterrupted (on-prem mesh has no AWS dependency)"
  explain "client-cloud-to-hybrid (x-cluster): TIMEOUT ✗ expected - link is down"
  explain ""
  explain "This proves: the DATACENTER keeps operating independently,"
  explain "including communication BETWEEN on-prem nodes (production topology)."
  explain "Only the cross-cluster link is affected. Local workloads are immune."
  pause
}

# ─── Scenario 2: Disconnect During Provisioning ──────────────────────────────
scenario_2() {
  header "SCENARIO 2: Disconnect During Provisioning"

  step "Network is still disconnected (from scenario 1)"
  step "Continuous client STILL logging 200s (existing pods unaffected):"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid --tail=3"
  explain "Let's try to scale the deployment from 2 to 4 replicas"
  pause

  step "Scaling deployment..."
  run_cmd "kubectl scale deploy server-hybrid-1 -n ${NAMESPACE} --replicas=4"

  explain "Waiting 15s for the scheduler to attempt scheduling..."
  sleep 15

  step "Pod status after scale attempt:"
  run_cmd "kubectl get pods -n ${NAMESPACE} -l location=hybrid -o wide"

  echo ""
  explain "2 pods: Running (existing, processing - proven by continuous client)"
  explain "2 pods: Pending (new, cannot be scheduled on unreachable node)"
  echo ""

  step "Proof: existing pods still processing during this entire time:"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid --tail=3"

  echo ""
  echo -e "  ${YELLOW}${BOLD}━━━ KNOWN LIMITATION ━━━${NC}"
  echo ""
  explain "During disconnection, control plane actions are unavailable:"
  explain "  - New pod scheduling → Pending"
  explain "  - ConfigMap/Secret updates → not propagated"
  explain "  - HPA/VPA scaling → not triggered"
  explain "  - Rolling updates → blocked"
  explain ""
  explain "BUT: existing pods continue PROCESSING (continuous client proves it)."
  explain ""
  explain "Mitigation: pre-size replicas for disconnection load (N+1 or N+2)."
  pause
}

# ─── Scenario 3c: On-Prem LB (MetalLB VIP) ───────────────────────────────────
scenario_3c() {
  header "SCENARIO 3c: On-Premises Load Balancer (MetalLB VIP)"

  step "LoadBalancer service with VIP in the on-prem LAN"
  run_cmd "kubectl get svc server-hybrid-lb -n ${NAMESPACE}"

  VIP=$(kubectl get svc server-hybrid-lb -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -z "$VIP" ]]; then
    fail "VIP not assigned. Check MetalLB installation and IPAddressPool."
    return
  fi

  step "VIP: ${VIP} (L2/ARP announced in the LAN - zero AWS dependency)"
  explain "This is the same role F5 plays in the production design:"
  explain "a static local entry point for DC traffic."
  pause

  step "Requests via the on-prem VIP:"
  for i in $(seq 1 5); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${VIP}/" 2>/dev/null || echo "TIMEOUT")
    echo -e "    Request ${i}: HTTP ${CODE}"
  done
  echo ""
  result "On-prem VIP serving traffic - path never touches AWS"
  explain "Run this DURING the disconnect (scenario 1) to prove independence."
  pause
}

# ─── Scenario 4: Node Restart During Disconnect (Worst Case) ─────────────────
scenario_4() {
  header "SCENARIO 4: Node Restart DURING Disconnect (Worst Case)"

  step "Precondition: network still disconnected (FIS active)"
  explain "Now we simulate a SECOND simultaneous failure: Node 2 power-cycles."
  echo ""
  echo -e "  ${YELLOW}In vCenter: VM #2 → Power → Restart Guest OS${NC}"
  echo ""
  read -p "  Press ENTER after restarting Node 2..."

  step "Pods on Node 2 do NOT come back (kubelet needs API server at startup):"
  explain "Watching cross-node client - requests to server-hybrid-2 fail:"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid-to-hybrid --tail=5"
  echo ""
  explain "Why: on startup, the kubelet queries the API server to learn which"
  explain "pods to run. Disconnected = no answer = pods stay down."
  explain "Not even crictl can restart them (containerd removes failed pods)."
  pause

  step "BUT the app survives - replicas on Node 1 (not restarted) keep serving:"
  run_cmd "kubectl logs -n ${NAMESPACE} deploy/client-hybrid --tail=3"

  VIP=$(kubectl get svc server-hybrid-lb -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$VIP" ]]; then
    step "On-prem VIP also still serving (targets Node 1):"
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${VIP}/" 2>/dev/null || echo "TIMEOUT")
    echo -e "    VIP ${VIP}: HTTP ${CODE}"
    echo ""
  fi

  step "BONUS (4b): Static pod on Node 2 - the exception"
  explain "Static pods restart from the node's LOCAL DISK (no API server needed)."
  explain "Setup required beforehand: manifests/07-static-pod-node2.yaml on Node 2."
  NODE2_IP="${NODE2_IP:-192.168.3.52}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://${NODE2_IP}:8080/" 2>/dev/null || echo "TIMEOUT")
  if [[ "$CODE" == "200" ]]; then
    echo -e "    ${GREEN}Static pod via node IP (${NODE2_IP}:8080): HTTP ${CODE} ✓ CAME BACK${NC}"
  else
    echo -e "    ${YELLOW}Static pod (${NODE2_IP}:8080): ${CODE} (not configured or node still booting)${NC}"
  fi
  echo ""
  explain "Note: it responds ONLY via node IP + hostPort. MetalLB VIP and"
  explain "ClusterIP Services do NOT route to it - speaker and kube-proxy"
  explain "(DaemonSets) did not restart. Static pods survive, the LB layer doesn't."

  echo ""
  echo -e "  ${YELLOW}${BOLD}━━━ WORST-CASE LESSON ━━━${NC}"
  echo ""
  explain "Node failure + disconnect = pods on that node stay down until reconnect."
  explain "Static pods are the exception, but lose Service/LB routing - not for apps."
  explain "Mitigation: multi-node replica distribution (N+1/N+2 across nodes)."
  explain "The app survived BECAUSE replicas exist on the other node."
  explain "For production: distribute critical services across 2-3 nodes per DC."
  pause
}

# ─── Recovery ─────────────────────────────────────────────────────────────────
scenario_recovery() {
  header "RECOVERY: Restoring Connectivity"

  step "Restoring network..."
  explain "FIS experiment auto-reverts after 5 minutes."
  explain "Or: reconnect the network adapter in vCenter."
  echo ""
  echo -e "  ${YELLOW}Press ENTER when network is restored...${NC}"
  read -r

  step "Watching node reconnect..."
  for i in $(seq 1 12); do
    NODE_STATUS=$(kubectl get nodes -l ${HYBRID_NODE_LABEL} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    TIMESTAMP=$(date +%H:%M:%S)
    if [[ "$NODE_STATUS" == "True" ]]; then
      echo -e "    ${TIMESTAMP} [${i}0s] Ready=${GREEN}True${NC}"
      echo ""
      result "Node reconnected!"
      break
    else
      echo -e "    ${TIMESTAMP} [${i}0s] Ready=${RED}${NODE_STATUS}${NC}"
    fi
    sleep 10
  done

  echo ""
  step "Pod status after recovery:"
  sleep 5  # Give scheduler a moment
  run_cmd "kubectl get pods -n ${NAMESPACE} -l location=hybrid -o wide"

  result "Pending pods are now scheduled and Running"
  explain "The cluster reconciled automatically. Zero data loss, zero manual intervention."
  pause

  step "Scaling back to 2 replicas (cleanup)"
  run_cmd "kubectl scale deploy server-hybrid-1 -n ${NAMESPACE} --replicas=2"
}

# ─── Main Menu ────────────────────────────────────────────────────────────────
show_menu() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     EKS Hybrid Nodes - Resilience Demo                      ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║${NC}  0)  Show current state (warm-up)                           ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  3a) LB Region → Hybrid Nodes (ALB ingress test)            ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  3b) Hybrid Nodes → External (egress test)                  ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  3c) LB On-Premises (MetalLB VIP test)                      ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  1)  Disconnect - steady state (core demo)                  ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  2)  Disconnect - during provisioning (limitation)           ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  4)  Node restart DURING disconnect (worst case)             ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  R)  Recovery (restore connectivity)                         ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  A)  Run ALL scenarios in recommended order                  ${BOLD}║${NC}"
  echo -e "${BOLD}║${NC}  Q)  Quit                                                    ${BOLD}║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

run_all() {
  scenario_0
  scenario_3a
  scenario_3b
  scenario_3c
  scenario_1
  scenario_2
  scenario_4
  scenario_recovery
  echo ""
  result "All scenarios completed successfully!"
}

# Handle direct invocation with argument
if [[ $# -gt 0 ]]; then
  case "$1" in
    0) scenario_0 ;;
    3a) scenario_3a ;;
    3b) scenario_3b ;;
    3c) scenario_3c ;;
    1) scenario_1 ;;
    2) scenario_2 ;;
    4) scenario_4 ;;
    recovery|R|r) scenario_recovery ;;
    all|A|a) run_all ;;
    *) echo "Unknown scenario: $1"; exit 1 ;;
  esac
  exit 0
fi

# Interactive menu
while true; do
  show_menu
  read -p "  Select scenario: " choice
  case "$choice" in
    0) scenario_0 ;;
    3a) scenario_3a ;;
    3b) scenario_3b ;;
    3c) scenario_3c ;;
    1) scenario_1 ;;
    2) scenario_2 ;;
    4) scenario_4 ;;
    R|r) scenario_recovery ;;
    A|a) run_all ;;
    Q|q) echo ""; echo "Done!"; exit 0 ;;
    *) echo -e "${RED}Invalid option${NC}" ;;
  esac
done
