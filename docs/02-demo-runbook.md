---
title: "Parte 2 - Demo Runbook (ao vivo com o cliente)"
weight: 2
---

Este é o roteiro apresentado **ao vivo para o cliente**. Cada fase tem: o que
mostrar, o comando, o resultado esperado e o ponto de fala. Apresente comando a
comando, explicando cada um - não use o validador automatizado aqui.

::alert[Pré-requisito: ambiente já preparado e validado pela Parte 1. Tenha o ALB DNS e o FIS_TEMPLATE_ID à mão.]{type="info"}

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

## Fase 1: Estado atual (5 min)

**O que mostrar ao cliente:**

Os nodes do cluster - destacar o hybrid node (hostname `mi-xxxx`, OS Ubuntu, IP on-prem):

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl get nodes -o wide
:::

Os pods rodando dos dois lados (verde = on-prem, azul = cloud):

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl get pods -n demo-stone -o wide
:::

As tolerations que mantêm os pods vivos na desconexão:

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl get deploy server-hybrid-1 -n demo-stone \
  -o jsonpath='{.spec.template.spec.tolerations}' | jq '.'
:::

::alert[Ponto de fala: "Sem tolerations, o Kubernetes faz eviction dos pods em 300s (5min) quando o node fica unreachable. Com elas, os pods sobrevivem pelo tempo configurado - ou indefinidamente."]{type="info"}

## Fase 2: Testes de LB - happy path (10 min)

### 2a. Região → Hybrid Nodes (Ingress via ALB)

:::code{showCopyAction=true showLineNumbers=false language=bash}
ALB=$(kubectl get ingress demo-ingress -n demo-stone \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://${ALB}/" | jq '{hostname, message}'
:::

**Ponto de fala:** tráfego da internet → ALB (região) → Gateway → VXLAN → pod on-prem.

### 2b. Hybrid Nodes → Externo (Egress)

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl exec -n demo-stone deploy/server-hybrid-1 -- curl -s httpbin.org/ip
:::

### 2c. LB On-Premises (MetalLB VIP)

O VIP local (192.168.3.240) é o papel que o F5 exerce no design de produção da Stone:

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Da LAN on-prem (ou do próprio node):
curl -s http://192.168.3.240/ | jq '{hostname, message}'
:::

## Fase 3: Desconexão em estado estável (10 min) - NÚCLEO DA DEMO

Abra três terminais com os logs dos clients lado a lado:

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Terminal 1 - LOCAL (Node1 → Node1)
kubectl logs -n demo-stone deploy/client-hybrid -f
# Terminal 2 - CROSS-NODE (Node1 → Node2)
kubectl logs -n demo-stone deploy/client-hybrid-to-hybrid -f
# Terminal 3 - CROSS-CLUSTER (Cloud → Node1)
kubectl logs -n demo-stone deploy/client-cloud-to-hybrid -f
:::

::alert[Os logs dos clients no hybrid node podem falhar via kubectl (control plane alcança o kubelet só pela VPN). Alternativa: SSH no node e ver via jornal do container, ou focar no client-cloud (kubelet cloud sempre acessível). Ver environment-status.]{type="warning"}

Iniciar a falha via FIS:

:::code{showCopyAction=true showLineNumbers=false language=bash}
aws fis start-experiment \
  --experiment-template-id ${FIS_TEMPLATE_ID} \
  --region sa-east-1
:::

::alert[Comportamento por tipo de endpoint EKS: se o kubelet alcança o endpoint PÚBLICO do cluster via internet (caso deste lab), o node PERMANECE Ready durante o FIS - a falha derruba apenas o data path (cross-cluster/VXLAN). Para demonstrar o NotReady + tolerations, desconecte a NIC da VM no vCenter (corta tudo). Em ambientes com endpoint privado + Direct Connect (produção típica), o FIS derruba ambos.]{type="warning"}

Acompanhar o estado do node (NotReady apenas se o control plane path cair - ver alerta acima):

:::code{showCopyAction=true showLineNumbers=false language=bash}
watch -n 5 'kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid'
:::

**O contraste é a prova (após ~40s):**

:::code{showCopyAction=false showLineNumbers=false language=text}
Terminal 1 (LOCAL):        200 ✓  200 ✓  200 ✓   <- ininterrupto
Terminal 2 (CROSS-NODE):   200 ✓  200 ✓  200 ✓   <- ininterrupto (mesh on-prem)
Terminal 3 (CROSS-CLUSTER): 200 ✓  TIMEOUT ✗  TIMEOUT ✗  <- esperado (link caiu)
:::

::alert[Ponto de fala: "O datacenter continua operando de forma independente, incluindo comunicação ENTRE nodes on-prem. Só o link cross-cluster é afetado - e isso é aceitável, porque o DC é autônomo. É exatamente o requisito do Rogério: se a AWS cair, o DC não para."]{type="info"}

## Fase 4: Desconexão durante provisioning (10 min)

Ainda desconectado, tentar escalar de 2 para 4 réplicas:

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl scale deploy server-hybrid-1 -n demo-stone --replicas=4
sleep 15
kubectl get pods -n demo-stone -l location=hybrid -o wide
:::

**Resultado esperado:**

:::code{showCopyAction=false showLineNumbers=false language=text}
server-hybrid-1-xxxxx   Running   (existentes - processando)
server-hybrid-1-yyyyy   Running   (existentes - processando)
server-hybrid-1-zzzzz   Pending   (NOVO - scheduler não alcança o node)
server-hybrid-1-wwwww   Pending   (NOVO - scheduler não alcança o node)
:::

::alert[Ponto de fala: "Esta é a limitação conhecida. Durante a desconexão, ações do control plane (novo scheduling, HPA, rollout) ficam indisponíveis. MAS os pods existentes continuam processando. A mitigação é dimensionar as réplicas iniciais para a carga esperada (N+1 ou N+2)."]{type="info"}

## Fase 5: Recovery (5 min)

Parar o FIS (ou aguardar auto-revert em 5min):

:::code{showCopyAction=true showLineNumbers=false language=bash}
aws fis stop-experiment --id <EXPERIMENT_ID> --region sa-east-1
:::

O client-cloud-to-hybrid volta a 200 sozinho (auto-heal), o node volta Ready,
os pods Pending são agendados. Zero intervenção manual.

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid
kubectl scale deploy server-hybrid-1 -n demo-stone --replicas=2
:::

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

## Cleanup

:::code{showCopyAction=true showLineNumbers=false language=bash}
kubectl delete ns demo-stone
cd terraform/ && terraform destroy
:::
