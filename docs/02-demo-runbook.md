---
title: "Parte 2 - Demo Runbook (ao vivo com o cliente)"
weight: 2
---

Este é o roteiro apresentado **ao vivo para o cliente**. Cada fase tem: o que
mostrar, o comando, o resultado esperado e o ponto de fala. Apresente comando a
comando, explicando cada um - não use o validador automatizado aqui.

> Pré-requisito: ambiente já preparado e validado pela Parte 1. Tenha o ALB DNS e o FIS_TEMPLATE_ID à mão.

## Cenários

| # | Cenário | Método de falha | Prova |
|---|---------|-----------------|-------|
| 1 | Desconexão em estado estável | FIS (disrupt-connectivity) | Pods existentes continuam; node NotReady; tolerations impedem eviction |
| 1b | Comunicação multi-node on-prem | FIS (mesmo do 1) | Node1→Node2 continua funcionando |
| 2 | Desconexão durante provisioning | FIS + `kubectl scale` | Pods novos ficam Pending; existentes intactos |
| 3a | LB Região → Hybrid Nodes | ALB + curl | Tráfego externo alcança pods on-prem |
| 3b | Hybrid Nodes → Externo | `exec` + curl | Pods on-prem acessam APIs externas |
| 3c | LB On-Premises (MetalLB VIP) | curl ao VIP | Entrada local independente da AWS |
| 4 | Restart de node DURANTE desconexão | vCenter restart | Pods não voltam até reconectar; réplicas multi-node salvam |

## Fase 0: Preparar o ambiente (2 min)

Antes de tudo, confirmar em qual cluster estamos apontando. Numa rotina de
várias demos, apontar para o cluster errado é o erro mais comum - sempre valide.

Listar os contextos do kubeconfig:

```bash
kubectl config get-contexts
```

Garantir/renovar o contexto do cluster da demo (define o contexto ativo):

```bash
aws eks update-kubeconfig --name llm-vmware-hybrid --region sa-east-1
```

Confirmar o contexto atual antes de seguir:

```bash
kubectl config current-context
```

## Fase 1: Estado atual (5 min)

**O que mostrar ao cliente:**

Os nodes do cluster - destacar o hybrid node (hostname `mi-xxxx`, OS Ubuntu, IP on-prem):

```bash
kubectl get nodes -o wide
```

Os pods rodando dos dois lados (verde = on-prem, azul = cloud):

```bash
kubectl get pods -n demo-stone -o wide
```

As tolerations que mantêm os pods vivos na desconexão. Mostre o manifesto para
o cliente entender o mecanismo, não só o efeito:

```yaml
tolerations:
  # Quando o node fica unreachable, o controller-manager adiciona o taint
  # node.kubernetes.io/unreachable. Sem toleration, o pod e' evictado em 300s.
  # Com toleration + tolerationSeconds, o pod sobrevive pelo tempo definido.
  - key: "node.kubernetes.io/unreachable"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 3600   # 1h no demo; producao: omitir para indefinido
  - key: "node.kubernetes.io/not-ready"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 3600
  - key: "node.cilium.io/agent-not-ready"
    operator: "Exists"
    effect: "NoSchedule"
```

Confirmar que os pods em execução têm essas tolerations aplicadas:

```bash
kubectl get deploy server-hybrid-1 -n demo-stone \
  -o jsonpath='{.spec.template.spec.tolerations}' | jq '.'
```

> Sem tolerations, o Kubernetes faz eviction dos pods em 300s (5min) quando o node fica unreachable. Com elas, os pods sobrevivem pelo tempo configurado - ou indefinidamente.

## Fase 2: Testes de LB - happy path (10 min)

### 2a. Região → Hybrid Nodes (Ingress via ALB)

```bash
ALB=$(kubectl get ingress demo-ingress -n demo-stone \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://${ALB}/" | jq '{hostname, message}'
```

**O que acontece:** tráfego da internet → ALB (região) → Gateway → VXLAN → pod on-prem.

### 2b. Hybrid Nodes → Externo (Egress)

```bash
kubectl exec -n demo-stone deploy/server-hybrid-1 -- curl -s httpbin.org/ip
```

### 2c. LB On-Premises (MetalLB VIP)

O VIP local (192.168.3.240) é o papel que o F5 exerce no design de produção da Stone:

```bash
# Da LAN on-prem (ou do próprio node):
curl -s http://192.168.3.240/ | jq '{hostname, message}'
```

## Fase 3: Desconexão em estado estável (10 min) - NÚCLEO DA DEMO

Abra três terminais com os logs dos clients lado a lado:

```bash
# Terminal 1 - LOCAL (Node1 → Node1)
kubectl logs -n demo-stone deploy/client-hybrid -f
# Terminal 2 - CROSS-NODE (Node1 → Node2)
kubectl logs -n demo-stone deploy/client-hybrid-to-hybrid -f
# Terminal 3 - CROSS-CLUSTER (Cloud → Node1)
kubectl logs -n demo-stone deploy/client-cloud-to-hybrid -f
```

> Os logs dos clients no hybrid node podem falhar via kubectl (control plane alcança o kubelet só pela VPN). Alternativa: SSH no node e ver via jornal do container, ou focar no client-cloud (kubelet cloud sempre acessível). Ver environment-status.

Iniciar a falha via FIS:

```bash
aws fis start-experiment \
  --experiment-template-id ${FIS_TEMPLATE_ID} \
  --region sa-east-1
```

> Comportamento por tipo de endpoint EKS: se o kubelet alcança o endpoint PÚBLICO do cluster via internet (caso deste lab), o node PERMANECE Ready durante o FIS - a falha derruba apenas o data path (cross-cluster/VXLAN). Em ambientes com endpoint privado + Direct Connect (produção típica), o FIS derruba ambos os paths de uma vez.

### Fase 3-extra: NotReady + Tolerations (bloqueio cirúrgico do control plane)

Para demonstrar o node NotReady SEM afetar a LAN local (NÃO desconecte a NIC -
isso mataria os paths locais e não reflete o cenário real), bloqueie apenas o
acesso do kubelet ao endpoint do EKS, no próprio node:

```bash
# Descobrir os IPs do endpoint EKS
dig +short <ID_DO_CLUSTER>.gr7.sa-east-1.eks.amazonaws.com

# No node (via SSH): bloquear os 2 IPs
sudo iptables -I OUTPUT -d <IP1> -j DROP
sudo iptables -I OUTPUT -d <IP2> -j DROP
```

**Resultado validado (teste real):** node NotReady em ~60s, taint
`unreachable:NoExecute` aplicado, pods continuam Running (tolerations!) e a LAN
local segue 100% (LOCAL, CROSS-NODE e VIP = HTTP 200). Reverter:

```bash
sudo iptables -D OUTPUT -d <IP1> -j DROP
sudo iptables -D OUTPUT -d <IP2> -j DROP
# Node volta a Ready em ~15-20s
```

> Bloqueamos APENAS o caminho do node até o control plane - exatamente o que acontece quando o link com a AWS cai. O node fica NotReady na visão do cluster, mas o datacenter continua 100% operacional: os pods processam, o LB local responde e a comunicação entre nodes segue intacta.

Acompanhar o estado do node:

```bash
watch -n 5 'kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid'
```

**O contraste é a prova (após ~40s):**

```text
Terminal 1 (LOCAL):        200 ✓  200 ✓  200 ✓   <- ininterrupto
Terminal 2 (CROSS-NODE):   200 ✓  200 ✓  200 ✓   <- ininterrupto (mesh on-prem)
Terminal 3 (CROSS-CLUSTER): 200 ✓  TIMEOUT ✗  TIMEOUT ✗  <- esperado (link caiu)
```

> O datacenter continua operando de forma independente, incluindo comunicação ENTRE nodes on-prem. Só o link cross-cluster é afetado - e isso é aceitável, porque o DC é autônomo. É exatamente o requisito do Rogério: se a AWS cair, o DC não para.

## Fase 3-cache: Pod crash durante a desconexão - image cache (5 min)

**Ponto BÁSICO e crítico:** um pod que crasha durante a desconexão REINICIA?
SIM - o kubelet gerencia `restartPolicy` localmente, sem API server, DESDE QUE
a imagem esteja no cache local do containerd.

Com a desconexão ativa (FIS ou bloqueio iptables), mate o container no node:

```bash
# Via SSH no node 1 - matar o processo do podinfo (simula crash da app)
ssh lopbruno@192.168.3.51
sudo pkill -f "podinfo" && echo "container morto"
```

Observe o restart local (segundos depois):

```bash
# O kubelet reinicia o container com a imagem do cache - sem falar com a AWS
curl -s -o /dev/null -w "app de volta: HTTP %{http_code}\n" \
  --max-time 5 http://192.168.3.240/healthz
```

> O kubelet é autônomo para reiniciar containers - restartPolicy funciona sem control plane. O requisito é a IMAGEM estar no cache local do containerd. Por isso duas configurações são obrigatórias em produção: pre-pull das imagens críticas em todos os nodes, e GC do containerd configurado para não descartar imagens (discard_unpacked_layers=false). Sem isso, um crash durante desconexão vira indisponibilidade - o node não consegue puxar do ECR.

**Configuração do containerd via nodeadm (prep - já aplicável no nodeConfig):**

```yaml
spec:
  containerd:
    config: |
      [plugins."io.containerd.grpc.v1.cri".containerd]
      discard_unpacked_layers = false
```

## Fase 4: Desconexão durante provisioning (10 min)

Ainda desconectado, tentar escalar de 2 para 4 réplicas:

```bash
kubectl scale deploy server-hybrid-1 -n demo-stone --replicas=4
sleep 15
kubectl get pods -n demo-stone -l location=hybrid -o wide
```

**Resultado esperado:**

```text
server-hybrid-1-xxxxx   Running   (existentes - processando)
server-hybrid-1-yyyyy   Running   (existentes - processando)
server-hybrid-1-zzzzz   Pending   (NOVO - scheduler não alcança o node)
server-hybrid-1-wwwww   Pending   (NOVO - scheduler não alcança o node)
```

> Esta é a limitação conhecida. Durante a desconexão, ações do control plane (novo scheduling, HPA, rollout) ficam indisponíveis. MAS os pods existentes continuam processando. A mitigação é dimensionar as réplicas iniciais para a carga esperada (N+1 ou N+2).

## Fase 5: Recovery (5 min)

Parar o FIS (ou aguardar auto-revert em 5min):

```bash
aws fis stop-experiment --id <EXPERIMENT_ID> --region sa-east-1
```

O client-cloud-to-hybrid volta a 200 sozinho (auto-heal), o node volta Ready,
os pods Pending são agendados. Zero intervenção manual.

```bash
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid
kubectl scale deploy server-hybrid-1 -n demo-stone --replicas=2
```

## Trade-off das Tolerations (discutir abertamente)

A demo usa `tolerationSeconds: 3600` (1h). **Não existe valor universal** - o
mesmo mecanismo que protege na desconexão ATRASA a recuperação numa falha real
de node (o control plane não distingue "rede caiu" de "node morreu").

| Perfil da app | tolerationSeconds sugerido |
|---------------|----------------------------|
| Stateless com réplicas em vários nodes | 300-900 (failover rápido importa mais) |
| Stateful singleton | Longo/indefinido (evita split-brain) |
| DC-crítica ("se a AWS cair") | Longo + réplicas em múltiplos nodes |

**Insight:** com zone labels (`topology.kubernetes.io/zone` por DC), o Kubernetes
CANCELA evictions quando a zona inteira fica unreachable - o cenário "AWS caiu"
já fica protegido por design.

## Limitações conhecidas (transparência com o cliente)

| Limitação | Mitigação |
|-----------|-----------|
| Control plane na região (sem scheduling na desconexão) | Pré-dimensionar réplicas |
| SSM credentials: 1h / IAM Roles Anywhere: até 12h | Usar IRA com durationSeconds alto |
| Cilium pode reiniciar na desconexão (BGP) | v1.17+ tem o fix; usar VXLAN (nosso caso) |
| Restart de node offline: pods não voltam | Réplicas multi-node (Cenário 4) |
| ALB region-originated cai na desconexão | LB local (MetalLB/F5) para tráfego do DC |

## Fase 6: Cloud Bursting - overflow do DC para a AWS (10 min)

Cenário complementar (não é resiliência, é elasticidade): a app da plataforma
roda no DATACENTER e, sob pico de carga, transborda para a AWS. Simples e
realista - sem GPU/LLM, apenas scheduling nativo do Kubernetes.

> Este cenário DEPENDE da conectividade com a AWS (oposto da resiliência). Bursting e resiliência são complementares: um usa a nuvem quando ela está lá, o outro sobrevive quando ela não está.

### Estado normal: app roda no DC

```bash
kubectl apply -f manifests/08-cloud-bursting.yaml
kubectl get pods -n demo-stone -l app=burst-app -o wide
```

As 2 réplicas ficam no hybrid node (nodeAffinity `preferred` para on-prem).

### Pico de carga: burst para a AWS

```bash
# Simula o pico escalando a app
kubectl scale deploy burst-app -n demo-stone --replicas=12
sleep 30
# Ver a distribuição: hybrid enche, o excedente vai pros cloud nodes
kubectl get pods -n demo-stone -l app=burst-app -o wide \
  --no-headers | awk '{print $7}' | sort | uniq -c
```

**Resultado validado:** ~7 pods permanecem no DC (hybrid), ~3 transbordam para
os cloud nodes da AWS. O overflow é automático - `preferred` affinity, não
`required`: o scheduler prefere on-prem, mas usa a nuvem quando o DC enche.

> Sua plataforma serve a carga normal no datacenter, com o custo e a latência do hardware que vocês já têm. Quando chega um pico - Black Friday, campanha - a capacidade transborda para a AWS automaticamente, sem reconfigurar nada. É elasticidade sob demanda mantendo o baseline no DC.

### Fim do pico: consolidação de volta ao DC

```bash
kubectl scale deploy burst-app -n demo-stone --replicas=2
```

> Nuance importante (seja transparente): o scale-down remove pods mas NÃO move os sobreviventes de volta - a affinity só age no scheduling. Para consolidar ativamente no DC use `kubectl rollout restart deploy/burst-app` (recria os pods, que voltam pro hybrid por preferência) ou o Descheduler em produção. Validado: pós rollout restart, 100% de volta ao hybrid.

### Evolução em produção (mencionar, não demonstrar)

Este demo usa cloud nodes já existentes (overflow). Em produção, para provisionar
capacidade cloud SOB DEMANDA e destruir depois: **Karpenter + Spot** disparado
por **KEDA/Prometheus** monitorando a carga local. É a mesma estratégia do
sample oficial aws-samples/sample-eks-hybrid-nodes-gpu-burst-scaling, aplicável
a workloads web (não só LLM). Pode ser uma demo dedicada.

## Perguntas prováveis do cliente (preparação)

### 1. "E storage persistente? Nossos workloads stateful?"
Stateful FUNCIONA em Hybrid Nodes - o que NÃO funciona é EBS (o EBS CSI não
está na lista de add-ons compatíveis; volume é preso à AZ). Opções locais:
(1) **hostPath** - simples, preso ao node (é como o sample oficial de GPU
burst persiste modelos LLM de ~3GB localmente); (2) **local PersistentVolumes**
com nodeAffinity; (3) **CSI de terceiros** (Longhorn/Ceph/OpenEBS ou o CSI do
storage array do DC). FSx CSI está na lista, mas é storage de rede dependente
da região (falha na desconexão). Ação: validar com o time de storage da Stone
qual CSI o array deles oferece.
Fonte: docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-add-ons.html

### 2. "Como fica a observabilidade DURANTE a desconexão? Ficamos cegos?"
Métricas/logs para CloudWatch/AMP param de fluir durante o disconnect
(dependência regional). Mitigação (best practices): backend LOCAL secundário
(Prometheus local + ADOT dual-exporter) e `crictl` para troubleshooting sem
control plane. Do lado AWS, alarme CloudWatch em NodeNotReady (control plane
logs) detecta a desconexão.

### 3. "Pod que CRASHA durante a desconexão reinicia?"
SIM - diferente do restart de NODE (Cenário 4). O kubelet gerencia restartPolicy
localmente, sem API server, DESDE QUE a imagem esteja no cache do containerd.
Por isso: pre-pull de imagens críticas + GC do containerd configurado para não
descartar imagens (`discard_unpacked_layers=false`).

### 4. "E se a desconexão durar mais de 12 horas?"
SSM: credencial de 1h, para de renovar desconectado (reconexão pode levar até
30min de backoff - restart do agent força). IAM Roles Anywhere: até 12h
configurável, reconexão em segundos. IMPORTANTE: os PODS continuam rodando
independente de credencial expirada - ela afeta só a comunicação node↔AWS.
Para janelas longas: IRA com durationSeconds alto.

### 5. "Nosso IDP usa admission webhooks (policy engines). O que acontece?"
**Gotcha de produção:** se um webhook backend roda nos hybrid nodes e o DC
desconecta, o API server não o alcança. Com `failurePolicy: Fail`, isso BLOQUEIA
operações no cluster INTEIRO (não só on-prem). Recomendações: webhooks críticos
em nodes cloud, ou `failurePolicy: Ignore` + réplicas nos dois lados. Revisar os
webhooks do Karavela (Kyverno/OPA/etc) nesse critério.

### 6. "E o cloud bursting que discutimos na reunião?"
Estratégia validada em outro lab (Karpenter + Spot quando o hardware local
satura, via KEDA/Prometheus). Não faz parte desta demo de resiliência - pode ser
uma demo #2. Nota: bursting DEPENDE da conectividade com a região - complementar
à resiliência, não substituto.

### 7. "Chicago e Atlanta: um cluster para os dois DCs?"
Recomendação: **um cluster por DC** (blast radius, upgrades independentes,
latência). Se optarem por cluster único com nodes nos dois DCs: zone labels por
DC são OBRIGATÓRIAS - o Kubernetes cancela evictions quando uma zona INTEIRA
fica unreachable, protegendo cada DC. Requisito de rede: até 200ms RTT e
100Mbps+ por DC (docs oficiais).

## Cleanup

```bash
kubectl delete ns demo-stone
cd terraform/ && terraform destroy
```
