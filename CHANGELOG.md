# Changelog

Formato baseado em Keep a Changelog. Datas em YYYY-MM-DD.

## [1.2.0] - 2026-08-02
### Changed
- Conteúdo público 100% genérico: namespace da demo renomeado para
  `demo-resilience` (manifests, docs, scripts, lab HTML) e removidas as
  referências de contexto específico de cliente (cidades dos datacenters,
  "the customer's design"). O caso de uso agora é descrito como IDP em dois
  datacenters on-premises.
- Acentuação PT-BR corrigida na prosa do runbook (Fases 3b e 3-cache):
  comunicação, não, é, cenário, autônomo, dúvida, inalcançável, sobrevivência,
  imutável/mutável, réplicas, pré-requisito.
- README: outputs reais do Terraform (`prefix_list_id`, `fis_role_arn`) no lugar
  do `ssm_document_name` obsoleto do desenho antigo baseado em SSM.

## [1.1.0] - 2026-07-29
### Added
- Alinhamento ao formato demo-factory: `scripts/lib.sh` (helpers narrados
  banner/step/ok/talk/pause/run), `scripts/validate-spring-clean.sh`,
  `scripts/99-cleanup.sh` (teardown reverso + audit), `CHANGELOG.md`,
  `docs/architecture-decisions.md` (ADRs), `assets/demo-style.css` no repo.
- `default_tags` no provider AWS (Spring Clean from birth).

## [1.0.0] - 2026-07-27
### Added
- Ambiente completo validado end-to-end (2 hybrid nodes + cloud nodes).
- Cenários: LB (ALB + VIP MetalLB on-prem + egress), desconexão data-path
  (FIS disrupt-connectivity), desconexão control-plane (NotReady + tolerations
  via bloqueio iptables cirúrgico), image cache (crash de pod), provisioning
  durante disconnect, recovery, cloud bursting (overflow hybrid->cloud).
- Manifests: server-hybrid-1/2, server-cloud, 3 clients (local/cross-node/
  cross-cluster), ALB ingress, MetalLB, static pod, cloud bursting.
- Terraform: FIS role, prefix list, experiment template (aws:network:
  disrupt-connectivity), CloudWatch log group.
- Docs pt-BR: 01-preparacao-setup, 02-demo-runbook (com PONTO DE FALA),
  FAQ com 7 perguntas prováveis do cliente. Renders HTML com Mermaid.
- Segunda VM criada 100% via CLI no ESXi Free (seed cloud-init + vim-cmd).

### Fixed (gaps encontrados no e2e)
- FIS design: `aws:network:disrupt-connectivity` nas subnets do cluster (o
  blackhole nos gateway nodes não derrubaria o control plane path).
- IAM: AddTags no LB controller, CreateLogDelivery no FIS role.
- Rota do pod CIDR (10.201/16) nas 3 route tables (bug do join no helm gateway).
- SSM credentials 1h / IRA até 12h (corrigido vs meeting note que dizia 12-24h).
- Node re-registro após snapshot revert (nodeadm v1.0.19, flag --config-source).
