#!/usr/bin/env bash
# 99-cleanup.sh - reverse-order teardown of the demo.
# Removes the demo workloads and AWS demo-specific infra. Does NOT touch the
# EKS cluster, the hybrid nodes, or the VPN (those are long-lived lab infra).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

banner "Cleanup - Demo EKS Hybrid Nodes Resilience"
aws_identity_check
use_cluster

step "1. Stop any running FIS experiment"
for exp in $(aws fis list-experiments --region "$AWS_REGION" \
    --query "experiments[?state.status=='running'].id" --output text); do
  run aws fis stop-experiment --id "$exp" --region "$AWS_REGION" >/dev/null || true
  ok "FIS $exp parado"
done

step "2. Remove demo workloads (namespace demo-stone)"
run kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s || true
ok "namespace $NAMESPACE removido (servers, clients, burst-app, ALB ingress, MetalLB svc)"

step "3. Static pod no Node 2 (fora do controle do kubectl)"
note "O static pod é gerenciado pelo kubelet via disco local. Remover manualmente:"
note "  ssh lopbruno@${NODE2_IP} 'sudo rm /etc/kubernetes/manifests/static-web.yaml'"
if [[ -z "${NONINTERACTIVE:-}" ]]; then
  read -r -p "   Remover o static pod do Node 2 agora? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    node_ssh "$NODE2_IP" "echo 'lab2vmware' | sudo -S -p '' rm -f /etc/kubernetes/manifests/static-web.yaml" && ok "static pod removido"
  fi
fi

step "4. MetalLB (opcional - deixar instalado não gera custo AWS)"
note "Para remover: helm uninstall metallb -n metallb-system"

step "5. FIS infra via Terraform (role, prefix list, experiment template, log group)"
note "cd terraform/ && terraform destroy -var=cluster_name=$CLUSTER_NAME -var=region=$AWS_REGION"

step "6. IAM policies inline adicionadas no troubleshooting (se quiser reverter)"
note "  aws iam delete-role-policy --role-name llm-vmware-hybrid-alb-* --policy-name alb-addtags-fix"
note "  aws iam delete-role-policy --role-name hybrid-resilience-demo-fis-role --policy-name fis-log-delivery"

step "7. Rotas do pod CIDR adicionadas manualmente (10.201/16 nas RTs do ALB)"
note "  rtb-0bc978572f17e8db2 e rtb-0edeff571fcb9bb15 - remover se destruir o gateway"

echo ""
banner "Workloads da demo removidos. Infra de lab (cluster, nodes, VPN) preservada."
note "Rode ./scripts/validate-spring-clean.sh para confirmar zero órfãos sem tag."
