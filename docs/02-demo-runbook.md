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

> Ferramentas recomendadas: `kubectl`, `jq`, `k9s` (painel visual) e `kube-ps1`
> no prompt (mostra o contexto atual, evita rodar no cluster errado). Layout:
> HTML do runbook na esquerda, iTerm2 na direita; na Fase 3, divida o terminal
> em 3 panes para os 3 clients lado a lado.

## Fase 1: Estado atual (5 min)

Abra as duas URLs do podinfo no browser ANTES de tudo, e deixe abertas o tempo
todo - o cliente vê a app viva e o load balancing entre os pods (recarregue e o
hostname alterna entre as réplicas):

```bash
# ALB (entrada pela regiao AWS) - abrir no browser
echo "http://$(kubectl get ingress demo-ingress -n demo-stone -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"

# VIP on-prem (MetalLB, entrada local do DC) - abrir no browser
echo "http://192.168.3.240/"
```

> Recarregue cada URL algumas vezes: o campo hostname alterna entre server-hybrid-1-*
> (as duas réplicas). Mostra o LB distribuindo. Guarde estas abas - na Fase 3
> a URL do ALB vai parar de responder e a do VIP vai continuar, ao vivo.


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

> Dica k9s: deixe um `k9s` aberto num pane ao lado durante toda a demo. Abra com `k9s`, confirme o cluster com `:ctx`, veja `:nodes` e `:pods` (digite `demo-stone` para filtrar). Nesta fase ele já dá o panorama dos dois lados.

## Fase 2: Testes de LB - happy path (10 min)

### 2a. Região → Hybrid Nodes (Ingress via ALB)

```bash
ALB=$(kubectl get ingress demo-ingress -n demo-stone \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://${ALB}/" | jq '{hostname, message}'
```

**O que acontece:** tráfego da internet → ALB (região) → Gateway → VXLAN → pod on-prem.

### 2b. Hybrid Nodes → Externo (Egress)

O teste de egress roda melhor via `crictl exec` no próprio node: `kubectl exec`
em pods de hybrid node é instável (passa pelo API server -> kubelet:10250 pela
VPN). E use um endpoint confiável - `checkip.amazonaws.com` (AWS-owned) em vez
do `httpbin.org`, que retorna 503 com frequência.

```bash
# logar no node 1 primeiro
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51

# entao, no node:
CID=$(sudo crictl ps --name podinfo -q | head -1)
sudo crictl exec $CID curl -s https://checkip.amazonaws.com
```

> Resultado esperado: o IP público de egress do datacenter. Mostra que o pod
> on-prem sai para a internet pelo caminho do próprio DC, não pela AWS.

### 2c. LB On-Premises (MetalLB VIP)

O VIP local (192.168.3.240) é o papel que o F5 exerce no design de produção do cliente:

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

### Fase 3b: NotReady + Tolerations (2 nodes)

Para demonstrar os hybrid nodes NotReady SEM afetar a LAN local (nao desconecte
a NIC - isso mataria os paths locais), bloqueie o acesso do kubelet ao endpoint
do EKS nos DOIS nodes. Assim o datacenter inteiro fica "perdido" para o control
plane, que e o cenario real de "a AWS caiu para o DC".

Resolver os IPs do endpoint (mudam - sempre re-resolver):

```bash
dig +short $(aws eks describe-cluster --name llm-vmware-hybrid \
  --region sa-east-1 --query 'cluster.endpoint' --output text | sed 's|https://||')
```

Bloquear nos DOIS nodes (via SSH em cada um):

```bash
# Node 1
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51 \
  "sudo iptables -I OUTPUT -d <IP1> -j DROP; sudo iptables -I OUTPUT -d <IP2> -j DROP"

# Node 2
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.52 \
  "sudo iptables -I OUTPUT -d <IP1> -j DROP; sudo iptables -I OUTPUT -d <IP2> -j DROP"
```

Acompanhar os dois virarem NotReady:

```bash
watch -n5 'kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid'
```

> Resultado esperado: AMBOS os hybrid nodes NotReady em ~60s, taint
> unreachable:NoExecute aplicado, pods continuam Running (tolerations). E o mais
> forte: a comunicacao CROSS-NODE (Node1 para Node2) continua 200 - o mesh VXLAN
> on-prem nao depende do control plane. O DC inteiro opera autonomo.

Reverter (nos dois nodes):

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51 \
  "sudo iptables -D OUTPUT -d <IP1> -j DROP; sudo iptables -D OUTPUT -d <IP2> -j DROP"
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.52 \
  "sudo iptables -D OUTPUT -d <IP1> -j DROP; sudo iptables -D OUTPUT -d <IP2> -j DROP"
```

> Nota (duvida comum): NAO da para alterar Tolerations durante a desconexao -
> e campo do pod spec, exige o kube-apiserver (inalcancavel offline). A janela de
> sobrevivencia (tolerationSeconds) tem que ser definida ANTES. Ja o TTL/GC de
> imagem do containerd e config LOCAL do node, entao esse SIM pode ser alterado
> via SSH + restart do containerd mesmo offline. Regra: objeto da API = imutavel
> offline; config local do node = mutavel offline. Ref:
> https://docs.aws.amazon.com/eks/latest/best-practices/hybrid-nodes-kubernetes-pod-failover.html

## Fase 3-cache: Pod crash durante a desconexão - image cache (5 min)

**Ponto BÁSICO e crítico:** um pod que crasha durante a desconexão REINICIA?
SIM - o kubelet gerencia `restartPolicy` localmente, sem API server, DESDE QUE
a imagem esteja no cache local do containerd.

O restart e SUB-SEGUNDO (imagem em cache), entao um curl no VIP nao pega o blip
- com 2 replicas nem cai. A forma de MOSTRAR na tela e pelo restart count do
container (coluna ATTEMPT do crictl), em dois terminais no node.

Pre-requisito: `crictl` instalado no node (uma vez):

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
sudo curl -sL "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.1/crictl-v1.31.1-linux-amd64.tar.gz" | sudo tar -C /usr/local/bin -xz
echo "runtime-endpoint: unix:///run/containerd/containerd.sock" | sudo tee /etc/crictl.yaml
```

Terminal A (no node) - painel ao vivo do restart count:

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
sudo watch -n1 'crictl ps -a --name podinfo'
```

Terminal B (no node) - UM kill unico (nao repita, senao entra em CrashLoopBackOff):

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
sudo crictl stop $(sudo crictl ps --name podinfo -q | head -1)
```

> No Terminal A o cliente ve o container ir para Exited e, em ~2-5s, um novo
> container Running com ATTEMPT +1 - o kubelet reiniciou da imagem em cache, sem
> falar com a AWS. Se repetir o kill varias vezes, o backoff exponencial
> (10s->20s->40s) atrasa o retorno - isso tambem e um bom ponto: o Kubernetes
> aplica crash-loop backoff localmente, mesmo offline. Para a demo, faca 1 kill.

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

> Dica k9s: em `:pods` filtrado em `demo-stone`, pressione `w` para exibir a coluna NODE. Ao escalar o burst-app, veja os pods nascendo e se espalhando: a maioria nos hybrid nodes e o excedente nos cloud nodes. Bursting visível pod a pod.

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

## Fase 7: Observabilidade on-premises (5 min)

Monitoring "à moda antiga" rodando 100% NOS hybrid nodes (Prometheus + Grafana +
blackbox), independente da nuvem. Cobre a visibilidade que o Container Insights
(cloud-side) não dá: a visão DO ON-PREM enxergando a nuvem, e que SOBREVIVE à
desconexão porque roda localmente.

Abra o Grafana on-prem (acesso anônimo, dashboard já provisionado):

```bash
# VIP on-prem do Grafana - abrir no browser
echo "http://192.168.3.242/  (dashboard: On-Prem - Saude dos Nodes + Conectividade com a Nuvem)"
```

O dashboard mostra:
- Conectividade On-Prem para Nuvem (probe ICMP ao VPC): CONECTADO / DESCONECTADO
- Hybrid Nodes UP (monitorados localmente pelo Prometheus on-prem)
- CPU e memória por hybrid node

> Durante a Fase 3 (FIS ativo), o painel "Conectividade On-Prem para Nuvem" muda
> para DESCONECTADO (vermelho), enquanto os hybrid nodes seguem UP e o Grafana
> continua respondendo - porque o stack inteiro roda on-prem. É a prova de que o
> DC mantém observabilidade própria mesmo cego para a AWS. Deixe este dashboard
> aberto desde o início, ao lado das URLs do podinfo.

## Perguntas prováveis do cliente (preparação)

### 1. "E storage persistente? Nossos workloads stateful?"
Stateful FUNCIONA em Hybrid Nodes - o que NÃO funciona é EBS (o EBS CSI não
está na lista de add-ons compatíveis; volume é preso à AZ). Opções locais:
(1) **hostPath** - simples, preso ao node (é como o sample oficial de GPU
burst persiste modelos LLM de ~3GB localmente); (2) **local PersistentVolumes**
com nodeAffinity; (3) **CSI de terceiros** (Longhorn/Ceph/OpenEBS ou o CSI do
storage array do DC). FSx CSI está na lista, mas é storage de rede dependente
da região (falha na desconexão). Ação: validar com o time de storage do cliente
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
webhooks da plataforma (Kyverno/OPA/etc) nesse critério.

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
