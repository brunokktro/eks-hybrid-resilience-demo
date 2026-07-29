#!/usr/bin/env bash
# lib.sh - shared helpers for the interactive demo scripts.
# Design: the presenter NARRATES while the script pauses. Every step prints
# WHAT it will do before doing it, and validates AFTER doing it.
set -euo pipefail

export DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-sa-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-llm-vmware-hybrid}"
export DEMO_ACCOUNT="923739522526"
export NAMESPACE="demo-stone"
export HYBRID_LABEL="eks.amazonaws.com/compute-type=hybrid"

# --- colors ---
C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'

banner()  { printf "\n${C_BLUE}==========================================================${C_RESET}\n${C_BLUE}  %s${C_RESET}\n${C_BLUE}==========================================================${C_RESET}\n" "$1"; }
step()    { printf "\n${C_YELLOW}>> %s${C_RESET}\n" "$1"; }
ok()      { printf "${C_GREEN}   [OK] %s${C_RESET}\n" "$1"; }
fail()    { printf "${C_RED}   [FAIL] %s${C_RESET}\n" "$1"; }
note()    { printf "${C_DIM}   %s${C_RESET}\n" "$1"; }
talk()    { printf "\n${C_GREEN}   PONTO DE FALA: %s${C_RESET}\n" "$1"; }

pause() {
  # NONINTERACTIVE=1 skips pauses (CI / automated validation runs)
  [[ -n "${NONINTERACTIVE:-}" ]] && return 0
  printf "\n${C_DIM}   [ENTER para continuar]${C_RESET}"
  read -r
}

run() {
  # Show the command before running it - the audience must SEE what happens
  printf "${C_DIM}   $ %s${C_RESET}\n" "$*"
  "$@"
}

require() {
  command -v "$1" >/dev/null 2>&1 || { fail "'$1' não encontrado no PATH"; exit 1; }
}

# Load AWS creds via isengardcli (the demo account) into the environment
load_aws_creds() {
  local creds
  creds=$(~/.toolbox/bin/isengardcli credentials "$DEMO_ACCOUNT" --role admin --awscli 2>/dev/null) || {
    fail "isengardcli falhou para a conta $DEMO_ACCOUNT"; exit 1; }
  export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.SessionToken')
}

aws_identity_check() {
  load_aws_creds
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    fail "Credenciais AWS inválidas."; exit 1; }
  [[ "$acct" == "$DEMO_ACCOUNT" ]] || { fail "Conta errada ($acct). Esperado: $DEMO_ACCOUNT (DevOps)"; exit 1; }
  ok "Conta AWS: $acct (DevOps)"
}

use_cluster() {
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1
  ok "kubectl context: $CLUSTER_NAME"
}

# SSH into the hybrid node (logs/exec on hybrid pods fail via kube-apiserver:10250)
NODE1_IP="${NODE1_IP:-192.168.3.51}"
NODE2_IP="${NODE2_IP:-192.168.3.52}"
node_ssh() {
  # $1 = node IP, rest = command
  local ip="$1"; shift
  ssh -i ~/.ssh/id_ecdsa -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    "lopbruno@${ip}" "$@" 2>/dev/null
}

# Resolve the current EKS public endpoint IPs (change over time - always re-resolve)
eks_endpoint_ips() {
  local ep
  ep=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.endpoint' --output text | sed 's|https://||')
  dig +short "$ep" | grep -E '^[0-9]'
}
