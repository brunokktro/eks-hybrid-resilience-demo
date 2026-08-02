---
title: "Architecture Decision Records"
weight: 3
---

ADRs da demo de resiliência EKS Hybrid Nodes. Cada decisão registra alternativas
rejeitadas e QUANDO a rejeitada venceria - dá nuance para responder o cliente.

## ADR-01: FIS via aws:network:disrupt-connectivity (não SSM blackhole)

**Status:** Aceito (validado e2e).

**Contexto:** precisávamos injetar falha de rede AWS↔on-prem de forma controlada
e auditável.

**Decisão:** `aws:network:disrupt-connectivity` (scope=prefix-list) nas subnets
do cluster, negando tráfego para os CIDRs on-prem via NACL temporária.

**Justificativa:** o desenho inicial (SSM blackhole/iptables nos gateway nodes)
NÃO derrubaria o control plane path - o heartbeat do kubelet (hybrid node -> EKS
API) não passa pelos gateway nodes. Targetar as subnets bloqueia ambos os
caminhos (control plane E data VXLAN).

**Alternativa rejeitada:** SSM `AWSFIS-Run-Network-Blackhole-Port` (só por porta,
não por CIDR de destino). Venceria se o objetivo fosse bloquear uma porta
específica em vez do path inteiro para o on-prem.

**Gaps encontrados no e2e:** neste lab o kubelet usa o endpoint PÚBLICO do EKS,
então o FIS derruba só o data path - o node não fica NotReady. Para NotReady,
adicionamos o bloqueio iptables cirúrgico (ADR-04). Em produção com endpoint
privado + Direct Connect, o FIS derruba os dois.

## ADR-02: MetalLB L2 como LB on-premises (não F5 na PoC)

**Status:** Aceito.

**Contexto:** demonstrar entrada de tráfego local no DC, independente da AWS,
análoga ao design de produção do cliente (NodePort + F5 + Gateway API).

**Decisão:** MetalLB em modo L2 (VIP anunciado por ARP na LAN).

**Justificativa:** é o padrão validado pela AWS nas best practices ("remains
stable during network disconnections"), gratuito, sem expiração, roda no cluster
sem VM extra. Demonstra o CONCEITO (VIP local estável) sem o custo/complexidade
do F5 trial (30 dias, VM dedicada).

**Alternativa rejeitada:** F5 trial. Venceria numa PoC que precise validar
especificamente a integração com o F5 que o cliente já tem em produção - aí o
esforço se justifica.

## ADR-03: Cilium (VXLAN) e o comportamento durante disconnect

**Status:** Aceito (herdado do cluster existente).

**Contexto:** a doc AWS alerta que o Cilium pode reiniciar durante disconnect
(health acoplado ao kube-api), derrubando sessões BGP.

**Decisão/Justificativa:** usamos Cilium v1.17 (tem o fix do issue #31702) em
modo VXLAN (não BGP). O datapath VXLAN é kernel-level (eBPF) e persiste mesmo se
o agent reiniciar. BGP não habilitado = não há sessão BGP para cair.

**Quando o BGP venceria:** se o cliente publicar services via BGP direto do Cilium
(estilo MetalLB-BGP), aí precisa do v1.17 + `k8s-heartbeat-timeout` configurado.

## ADR-04: NotReady via bloqueio iptables cirúrgico (não NIC disconnect)

**Status:** Aceito (validado: NotReady ~60s, recovery ~16s).

**Contexto:** demonstrar node NotReady + tolerations SEM matar a LAN local (o
que não refletiria o cenário real de "só o link com a AWS caiu").

**Decisão:** bloquear no node apenas os IPs do endpoint EKS
(`iptables -I OUTPUT -d <ip> -j DROP`).

**Justificativa:** corta só o path node->control plane. A LAN local segue
intacta (LOCAL, CROSS-NODE, VIP = 200), provando que o DC opera autônomo.

**Alternativa rejeitada:** desconectar a NIC no vCenter. Mataria TODOS os paths
locais - não reflete a demo (o cliente quer ver o DC operando enquanto o cluster
o vê como perdido). Venceria só para simular falha total de hardware do node.

## ADR-05: Cloud bursting por overflow (não Karpenter provisioning)

**Status:** Aceito para a demo (validado: scale 2->12 = 7 on-prem + 3 cloud).

**Contexto:** mostrar elasticidade DC->AWS de forma simples e confiável ao vivo,
sem GPU/LLM.

**Decisão:** `nodeAffinity preferred=hybrid` + `kubectl scale`. Pods preferem
on-prem e transbordam para os cloud nodes existentes sob carga.

**Justificativa:** demonstra o conceito com scheduling nativo, sem dependência
de metrics-server (ausente) nem do kubelet:10250 do hybrid. Confiável ao vivo.

**Alternativa rejeitada:** Karpenter + Spot + KEDA (provisiona nó novo sob
demanda). Venceria em produção real (elasticidade de capacidade, não só de
réplicas) - é a evolução natural, referência no sample gpu-burst-scaling.

**Nuance:** scale-down não reconsolida pods sobreviventes (affinity só age no
scheduling). Consolidação ativa via `rollout restart` ou Descheduler.


## ADR: DNS resiliente nos hybrid nodes (Fase 4b)

**Decisão (validada 8/8 no disconnect):** CoreDNS rodando em CADA node schedulable
(topology spread por `kubernetes.io/hostname`, `nodeTaintsPolicy: Honor`) +
`internalTrafficPolicy: Local` no service kube-dns. Cada pod resolve pelo CoreDNS
do próprio node - sem depender de alcançar a nuvem no disconnect.

**Por que não topology hints (Topology Aware Routing / trafficDistribution):** em
cluster pequeno/assimétrico os hints não populam (validado - annotation e
trafficDistribution, ambos com hints vazios). `internalTrafficPolicy: Local` não
depende de hints.

**Regra crítica:** o fix TEM que estar pré-aplicado (ambiente conectado). O Cilium
do node não atualiza service/rotas offline - patch durante o disconnect não propaga.

**Cilium:** NodeLocal DNSCache "vanilla" (iptables) não funciona com Cilium (bypassa
iptables); exige `CiliumLocalRedirectPolicy` (LRP).

### Pendências (próxima janela dedicada)

1. **Tornar o fix durável (addon):** CoreDNS é managed addon do EKS (NÃO Auto Mode -
   `computeConfig: null`). Os `kubectl patch` sobrevivem (o addon só reconcilia em
   update), MAS um `aws eks update-addon` futuro pode sobrescrever. Migrar a config
   (replicas, topologySpread, e - se o schema suportar - internalTrafficPolicy) para
   `configurationValues` do addon + `resolveConflicts: PRESERVE`. VALIDAR o schema do
   addon CoreDNS antes (probe inicial veio inconclusivo).
2. **NodeLocal DNSCache (opcional, camada de cache):** via Cilium LRP - menos latência
   e QPS no CoreDNS, serve_stale. Não é necessário para a resiliência (já garantida
   por internalTrafficPolicy Local), é evolução.

### Lição operacional

Resiliência de DNS / infra crítica se constrói e TESTA numa janela dedicada, com
folga de CPU e sem os nodes flapando - NUNCA ao vivo no meio do fluxo da demo.
Patchar CoreDNS ao vivo (durante os testes) degradou a rede pod-a-pod hybrid->cloud;
recuperação exigiu rollout completo do Cilium. Fix pré-baked + testado offline.
