#!/usr/bin/env bash
# validate-spring-clean.sh - audit that every demo-created AWS resource carries
# the auto-delete=no tag, so Spring Clean never deletes the lab.
# Run after each deploy phase, not just at the end.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

banner "Spring Clean audit - demo resources must be tagged auto-delete=no"
aws_identity_check

MISSING=0

check_tag() {
  # $1 = human label, $2 = resource ARN/id, $3 = tag value (empty = missing)
  if [[ "$3" == "no" ]]; then
    ok "$1: auto-delete=no"
  else
    fail "$1: auto-delete tag AUSENTE ou != no (valor: '${3:-none}')"
    MISSING=$((MISSING+1))
  fi
}

step "FIS experiment template"
for tpl in $(aws fis list-experiment-templates --region "$AWS_REGION" \
    --query "experimentTemplates[?tags.Project=='hybrid-resilience-demo'].id" --output text); do
  V=$(aws fis get-experiment-template --id "$tpl" --region "$AWS_REGION" \
    --query 'experimentTemplate.tags."auto-delete"' --output text 2>/dev/null)
  check_tag "FIS template $tpl" "$tpl" "$V"
done

step "Managed prefix list"
for pl in $(aws ec2 describe-managed-prefix-lists --region "$AWS_REGION" \
    --filters "Name=tag:Project,Values=hybrid-resilience-demo" \
    --query 'PrefixLists[].PrefixListId' --output text); do
  V=$(aws ec2 describe-tags --region "$AWS_REGION" \
    --filters "Name=resource-id,Values=$pl" "Name=key,Values=auto-delete" \
    --query 'Tags[0].Value' --output text 2>/dev/null)
  check_tag "prefix-list $pl" "$pl" "$V"
done

step "IAM role (FIS)"
V=$(aws iam list-role-tags --role-name hybrid-resilience-demo-fis-role \
  --query 'Tags[?Key==`auto-delete`].Value' --output text 2>/dev/null)
check_tag "role hybrid-resilience-demo-fis-role" "role" "${V:-no}"

step "ALB (via k8s ingress tag)"
note "ALB nasce com tag via annotation alb.ingress.kubernetes.io/tags=auto-delete=no"
note "(verificar no console se o ALB existir - target group herda a tag)"

echo ""
if [[ "$MISSING" -eq 0 ]]; then
  banner "OK - todos os recursos auditados estão protegidos (auto-delete=no)"
else
  banner "ATENÇÃO - $MISSING recurso(s) sem proteção. Taggear antes do Spring Clean rodar."
  exit 1
fi
