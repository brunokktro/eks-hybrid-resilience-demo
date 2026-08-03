# Changelog

Formato baseado em Keep a Changelog. Datas em YYYY-MM-DD.

## [1.2.2] - 2026-08-02
### Added
- Fase 3: callout explícito separando os DOIS gatilhos de falha - FIS corta o
  **data path** (cross-cluster e ALB caem, node segue Ready neste lab) e o
  iptables da Fase 3b corta o **control plane** (node NotReady + tolerations).
  Inclui a dependência que confunde ao vivo: **o ALB só fica fora do ar enquanto
  o FIS estiver ATIVO** - com o experimento expirado ele responde 200 e parece
  falha da demo. Comando de checagem do status do experimento incluído.

### Fixed
- README: referência morta a `scripts/demo-live.sh` (arquivo nunca existiu)
  corrigida para `scripts/validate-demo.sh`, com o `FIS_TEMPLATE_ID` necessário.

## [1.2.1] - 2026-08-02
### Security
- Removida credencial hardcoded (senha de sudo do node) do `99-cleanup.sh`. O
  step do static pod agora usa `ssh -t`, deixando o sudo pedir a senha
  interativamente. Nenhuma credencial deve existir neste repo.

### Fixed
- `99-cleanup.sh` não trava mais em `Terminating` ao remover o namespace. Duas
  causas tratadas na ordem: (1) `delete pods --force --grace-period=0` antes,
  porque pods em node NotReady nunca confirmam a remoção; (2) revoke automático
  das rules tcp/9898 que referenciam o SG gerenciado do ALB - enquanto existem, o
  LB controller não consegue deletar o SG e mantém o finalizer
  `ingress.k8s.aws/resources`. Inclui diagnóstico e a remediação do finalizer.
- Acentuação PT-BR no dashboard Grafana on-prem (visível ao público na Fase 7):
  "Saúde dos Nodes", "Latência do probe", "Memória disponível", "alcançáveis",
  "INALCANÇÁVEL". Nomes de painéis do runbook alinhados ao dashboard.
- Removidos IDs de route table específicos do lab das notas do cleanup.

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
