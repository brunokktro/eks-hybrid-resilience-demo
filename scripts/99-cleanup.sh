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

step "2. Force-delete dos pods (pods em node NotReady nao confirmam o delete)"
note "Sem isso o namespace trava em Terminating: o kubelet inalcancavel nunca"
note "confirma a remocao. Cenario garantido depois da demo de desconexao."
run kubectl delete pods --all -n "$NAMESPACE" --force --grace-period=0 \
  --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
ok "pods removidos (force)"

step "3. Liberar o SG gerenciado do ALB (senao o finalizer do ingress trava o ns)"
note "As rules tcp/9898 no node SG e no cluster SG referenciam o SG gerenciado do"
note "ALB. Enquanto existirem, o LB controller nao consegue deletar esse SG, falha"
note "com 'failed to delete securityGroup: timed out' e mantem o finalizer"
note "ingress.k8s.aws/resources - o namespace fica preso em Terminating."
ALB_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=k8s-${NAMESPACE:0:8}-*" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -n "$ALB_SG" && "$ALB_SG" != "None" ]]; then
  VPC_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$ALB_SG" \
    --query 'SecurityGroups[0].VpcId' --output text)
  # SGs que possuem rule referenciando o SG do ALB
  REFS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='$ALB_SG']]].GroupId" \
    --output text)
  for sg in $REFS; do
    run aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --protocol tcp --port 9898 --source-group "$ALB_SG" >/dev/null 2>&1 && \
      ok "rule 9898 revogada em $sg (referenciava $ALB_SG)" || true
  done
  [[ -z "$REFS" ]] && note "nenhuma rule referenciando $ALB_SG"
else
  note "SG gerenciado do ALB nao encontrado (ingress ja removido?) - seguindo"
fi

step "4. Remove demo workloads (namespace $NAMESPACE)"
run kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=180s || true
if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  fail "namespace ainda em Terminating"
  note "Diagnostico: kubectl get ns $NAMESPACE -o jsonpath='{.status.conditions}'"
  note "Se o ALB/TG/SG ja estiverem deletados na AWS, o finalizer esta preso em"
  note "cache do controller. Remocao segura (confirme a limpeza AWS antes):"
  note "  kubectl patch ingress demo-ingress -n $NAMESPACE --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
else
  ok "namespace $NAMESPACE removido (servers, clients, burst-app, ALB ingress, MetalLB svc)"
fi

step "5. Static pod no Node 2 (fora do controle do kubectl)"
note "O static pod é gerenciado pelo kubelet via disco local. Remover manualmente:"
note "  ssh -t lopbruno@${NODE2_IP} 'sudo rm /etc/kubernetes/manifests/static-web.yaml'"
if [[ -z "${NONINTERACTIVE:-}" ]]; then
  read -r -p "   Remover o static pod do Node 2 agora? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    # -t aloca tty para o sudo pedir a senha interativamente.
    # NUNCA hardcodar credencial aqui - este repo e publico.
    ssh -t -i ~/.ssh/id_ecdsa -o ConnectTimeout=8 "lopbruno@${NODE2_IP}" \
      "sudo rm -f /etc/kubernetes/manifests/static-web.yaml" && ok "static pod removido"
  fi
fi

step "6. MetalLB (opcional - deixar instalado não gera custo AWS)"
note "Para remover: helm uninstall metallb -n metallb-system"

step "7. FIS infra via Terraform (role, prefix list, experiment template, log group)"
note "cd terraform/ && terraform destroy -var=cluster_name=$CLUSTER_NAME -var=region=$AWS_REGION"

step "8. IAM policies inline adicionadas no troubleshooting (se quiser reverter)"
note "  aws iam delete-role-policy --role-name llm-vmware-hybrid-alb-* --policy-name alb-addtags-fix"
note "  aws iam delete-role-policy --role-name hybrid-resilience-demo-fis-role --policy-name fis-log-delivery"

step "9. Rotas do pod CIDR adicionadas manualmente (10.201/16 nas RTs do ALB)"
note "  Remover as rotas para o RemotePodNetwork se destruir o Hybrid Nodes Gateway"

echo ""
banner "Workloads da demo removidos. Infra de lab (cluster, nodes, VPN) preservada."
note "Rode ./scripts/validate-spring-clean.sh para confirmar zero órfãos sem tag."
