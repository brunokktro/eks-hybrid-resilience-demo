---
title: "Estado do Ambiente e Troubleshooting Log"
weight: 90
---

Registro do estado do ambiente de demo e das lições de troubleshooting da
sessão de setup (2026-07-27). Serve de referência para o dry-run e para
reproduzir/recuperar o ambiente.

## Estado validado do ambiente

| Componente | Estado | Validação |
|-----------|--------|-----------|
| Hybrid Node 1 (`mi-0aae33d56c9e12da5`) | ✓ Ready | kubelet 1.35.6, Cilium Running |
| Gateway Nodes (2x) + Hybrid Node Gateway | ✓ Running | VTEP do node adicionado |
| VPN Site-to-Site (underlay) | ✓ 1/2 tunnels UP | `54.232.26.158` UP |
| server-hybrid-1 (2 réplicas) | ✓ Running | node 1 |
| server-cloud (2 réplicas) | ✓ Running | cloud nodes |
| clients (local, cross-node, cross-cluster) | ✓ Running | - |
| **Path LOCAL** (Node1→Node1) | ✓ HTTP 200 | curl pod IP + ClusterIP |
| **Path CROSS-CLUSTER** (cloud→hybrid) | ✓ HTTP 200 | client-cloud-to-hybrid logs |
| **Path CROSS-NODE** (Node1→Node2) | ✓ HTTP 200 | Node 2 `mi-0d8945ada3cc4f12b` Ready |
| **On-prem LB** (MetalLB VIP 192.168.3.240) | ✓ HTTP 200 | curl da LAN |
| FIS experiment template | ✓ `EXTCnS3KTdAc2AEME` | terraform apply |
| **ALB ingress** (Cenário 3a) | ⚠ parcial | cloud target healthy; hybrid target unhealthy |

## Pendências para o dry-run

1. ~~**VM 2**~~ ✓ CONCLUÍDO - VM 2 criada VIA GOVC/SSH no ESXi (sem UI!):
   seed ISO cloud-init (autoinstall) + vmkfstools + vim-cmd registervm.
   Node 2 = `mi-0d8945ada3cc4f12b` (192.168.3.52) Ready, server-hybrid-2
   Running, static pod Running (hostPort 8080 HTTP 200), cross-node HTTP 200.
2. **ALB → hybrid target** - health check falha porque a rota do pod CIDR
   (10.201.0.0/16) existe em apenas 1 das 3 route tables da VPC; as subnets do
   ALB precisam da rota apontando para o gateway leader ENI. Não-bloqueante: a
   doc AWS indica que tráfego region-originated cai no disconnect de qualquer
   forma, e o LB primário da história Stone é o on-prem (MetalLB/F5), que funciona.
3. **ALB /cloud rule** - retorna 404 com target healthy; revisar listener rule
   (path-pattern `/cloud` vs pathType Prefix) no dry-run.
4. **VPN tunnel 2** (`18.230.7.157`) DOWN - 1 tunnel UP já dá conectividade;
   subir o segundo dá redundância (reativar IPsec P1 no pfSense).

## Lições de Troubleshooting (ordem cronológica dos problemas resolvidos)

### 1. IP residencial dinâmico quebrou a VPN
O IP público de casa mudou; o Customer Gateway apontava para o IP antigo, então
os tunnels IPsec ficaram DOWN. **Fix sem tocar no pfSense:** criar CGW com o IP
novo e mover a VPN via `modify-vpn-connection` (preserva tunnel IPs e PSKs).
Runbook completo no README (seção "Dynamic Residential IP").

### 2. VM revertida para snapshot pré-registro
A VM do node 1 tinha sido revertida para um snapshot antigo, sem kubelet /
containerd / SSM / nodeConfig - apenas o binário nodeadm. O node object
`mi-0ee2ff...` aparecia NotReady no cluster (fantasma de 08/jun).
**Diagnóstico-chave:** node NotReady eterno + VPN OK → checar NA VM se
`/var/lib/kubelet` e `/etc/nodeadm` existem ANTES de debugar rede.
**Fix:** deletar node object + desregistrar instância SSM + nova activation +
`nodeadm install` + `nodeadm init`.

### 3. nodeadm antigo (v1.0.18) falhava no SSM installer
Erro "validating ssm-setup-cli signature: No matching signature". **Fix:**
baixar a versão latest do nodeadm (v1.0.19). Atenção: o flag mudou de
`--config` para `--config-source` nessa versão.

### 4. pfSense: acesso à UI trancado + IPsec DOWN
Após o easyrule recarregar o filtro, a UI do pfSense (192.168.1.5 na WAN) ficou
inacessível. **Fix engenhoso:** usar o hybrid node (192.168.3.51) como jump host
- ele alcança a UI do pfSense pela LAN (192.168.2.1:80 e 192.168.3.1:80). Via
esse caminho, login + `pfSsh.php playback restartipsec` reativou o IPsec e 1
tunnel subiu, restaurando o underlay.

### 5. Cross-cluster timeout mesmo sem falha injetada
O node era Ready (endpoint EKS público, kubelet via internet) MAS o underlay VPN
estava DOWN, então o VXLAN cloud↔hybrid não passava tráfego. **Causa raiz:** VPN
tunnels DOWN (problema #1 + #4). Após subir o tunnel, cross-cluster voltou a 200.
**Lição:** node Ready NÃO garante underlay VPN - o endpoint EKS público mascara.
Sempre validar VgwTelemetry (tunnels UP) para paths que dependem do VXLAN.

### 6. ALB targets unhealthy (Target.Timeout)
O node/cluster security group não permitia o SG do ALB na porta dos pods (9898).
**Fix:** `authorize-security-group-ingress` liberando os SGs do ALB no cluster SG
e node SG. Cloud target ficou healthy. Hybrid target ainda depende da rota do
pod CIDR nas subnets do ALB (pendência #2).

### 7. ALB IAM AddTags negado
O role do AWS Load Balancer Controller não tinha
`elasticloadbalancing:AddTags` no recurso targetgroup (versão nova do controller
taggeia on-create). **Fix:** policy inline `alb-addtags-fix` no role
`llm-vmware-hybrid-alb-*`.

## Método de validação na demo (importante)

`kubectl logs` e `kubectl exec` para pods NO HYBRID NODE **falham com timeout**
(o control plane alcança o kubelet do hybrid node na porta 10250 apenas pela
VPN, que nem sempre está estável). Para ver logs dos clients no hybrid node
durante a demo, use SSH direto no node ou valide via os pods no lado cloud
(cujo kubelet é alcançável). Os clients no lado cloud (`client-cloud-to-hybrid`)
têm logs acessíveis via `kubectl logs` normalmente.

### 8. Criação da VM 2 100% via CLI (ESXi Free)
ESXi Free bloqueia writes via API (govc vm.create falha com licença). O caminho
é WRITE via SSH no host: `vmkfstools -c 60G` (disco), `.vmx` gerado + scp,
`vim-cmd solo/registervm` + `vim-cmd vmsvc/power.on`. O boot da ISO do Ubuntu
live-server com um seed ISO CIDATA (user-data autoinstall) instala o SO sem
interação: hostname, IP estático, usuário, chave SSH e até o download do nodeadm
(late-commands). Réplica exata do método usado na VM 1 (lab2-seed.iso).
