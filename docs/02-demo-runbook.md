---
title: "Parte 2 - Demo Runbook"
weight: 2
---

Cada fase tem um objetivo, os comandos e o resultado esperado. Execute comando a
comando e acompanhe a saída - o próprio passo elucida o comportamento. Não use o
validador automatizado aqui.

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

![Componentes do Kubernetes no pod failover durante desconexões de rede](https://docs.aws.amazon.com/images/eks/latest/best-practices/images/hybrid/k8s-components-pod-failover.png)

*Componentes envolvidos no comportamento de failover de pods durante desconexões (fonte: [EKS Best Practices - Pod Failover](https://docs.aws.amazon.com/eks/latest/best-practices/hybrid-nodes-kubernetes-pod-failover.html)).*

## Fase 0: Preparar o ambiente (2 min)

Antes de tudo, confirmar em qual cluster estamos apontando. Numa rotina de
várias demos, apontar para o cluster errado é o erro mais comum - sempre valide.

Selecionar a conta/região da demo. Este é o passo mais importante: a demo inteira
roda na conta e região específicas, e o profile default costuma apontar para outra
conta - o que causa "template not found" no FIS e "not found" no kubectl. Aponte
o profile com acesso ao cluster e ao FIS:

```bash
export AWS_PROFILE=devops-saopaulo
aws sts get-caller-identity --query Account --output text   # confirme a conta da demo
```

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

Exportar o ID do template do FIS para a sessão (auto-resolve - sobrevive a mudança de ID). A Fase 3 usa esta variável:

```bash
export FIS_TEMPLATE_ID=$(aws fis list-experiment-templates --region sa-east-1 \
  --query "experimentTemplates[?contains(description,'on-premises')].id | [0]" --output text)
echo "FIS_TEMPLATE_ID=$FIS_TEMPLATE_ID"
```

### Links e acessos do ambiente (deixe abertos)

| Recurso | Endereço | Uso |
|---------|----------|-----|
| App via ALB (região AWS) | `kubectl get ingress demo-ingress -n demo-stone -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` | Ingress region-originated - cai no disconnect |
| App via VIP on-prem (MetalLB) | [http://192.168.3.240/](http://192.168.3.240/) | Entrada local - sobrevive ao disconnect |
| Grafana on-prem | [http://192.168.3.242/](http://192.168.3.242/) | Dashboard de saúde dos nodes + conectividade com a nuvem (anônimo) |
| SSH Node 1 / Node 2 | `ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51` / `...52` | Comandos no node (crictl, iptables) |
| Cluster EKS | `aws eks update-kubeconfig --name llm-vmware-hybrid --region sa-east-1` | kubectl |



> Ferramentas recomendadas: `kubectl`, `jq`, `k9s` (painel visual) e `kube-ps1`
> no prompt (mostra o contexto atual, evita rodar no cluster errado). Layout:
> HTML do runbook na esquerda, iTerm2 na direita; na Fase 3, divida o terminal
> em 3 panes para os 3 clients lado a lado.

> Pré-requisito nos nodes: `crictl` instalado nos DOIS hybrid nodes (v1.31.1 em
> `/usr/local/bin`, config em `/etc/crictl.yaml`) - usado nas Fases 2b e 3-cache.
> O nodeadm NÃO o instala (ele é tooling de debug, não faz parte do bootstrap).
> Instalação: ver o passo único na Fase 3-cache.

> Nota sobre sudo no node: os hybrid nodes já estão com **NOPASSWD** configurado
> para `crictl` e `iptables` (`/etc/sudoers.d/demo`), então os comandos com `sudo`
> nas Fases 2b, 3b e 3-cache rodam sem pedir senha - fluxo limpo na frente do
> cliente. Se precisar reaplicar num node novo:
> `echo "lopbruno ALL=(ALL) NOPASSWD: /usr/local/bin/crictl, /usr/sbin/iptables" | sudo tee /etc/sudoers.d/demo`

## Fase 1: Estado atual (5 min)

Abra as duas URLs do podinfo no browser ANTES de tudo e deixe abertas o tempo
todo. A app fica viva e o load balancing entre os pods aparece ao recarregar (o
hostname alterna entre as réplicas):

URL do ALB (entrada pela região AWS) - abrir no browser:

```bash
echo "http://$(kubectl get ingress demo-ingress -n demo-stone -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/"
```

URL do VIP on-prem (MetalLB, entrada local do DC) - abrir no browser:

```bash
echo "http://192.168.3.240/"
```

> Recarregue cada URL algumas vezes: o campo hostname alterna entre server-hybrid-1-*
> (as duas réplicas) - é o LB distribuindo. Guarde estas abas - na Fase 3
> a URL do ALB vai parar de responder e a do VIP vai continuar, ao vivo.


Os nodes do cluster - repare no hybrid node (hostname `mi-xxxx`, IP on-prem `192.168.x`). A coluna LOCATION deixa claro o lado: `lab2-dc1` = datacenter on-prem, `sa-east-1x` = região AWS. Saída enxuta para caber em terminal com split:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,LOCATION:.metadata.labels.topology\.kubernetes\.io/zone,IP:.status.addresses[?(@.type=="InternalIP")].address'
```

> Para focar só nos hybrid nodes (ex: na Fase 3, acompanhando eles caírem), filtre por label - saída mínima, ideal para split de tela:
> ```bash
> kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid \
>   -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,IP:.status.addresses[?(@.type=="InternalIP")].address'
> ```

Os pods rodando dos dois lados (verde = on-prem, azul = cloud):

```bash
kubectl get pods -n demo-stone -o wide
```

As tolerations que mantêm os pods vivos na desconexão. O manifesto abaixo revela
o mecanismo, não só o efeito:

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

Primeiro, logue no node 1:

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
```

Já no node, rode o teste de egress:

```bash
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

## Fase 3: Desconexão em estado estável (10 min)

Abra três terminais com os logs dos clients lado a lado.

Terminal 1 - LOCAL (Node1 → Node1):

```bash
kubectl logs -n demo-stone deploy/client-hybrid -f
```

Terminal 2 - CROSS-NODE (Node1 → Node2):

```bash
kubectl logs -n demo-stone deploy/client-hybrid-to-hybrid -f
```

Terminal 3 - CROSS-CLUSTER (Cloud → Node1):

```bash
kubectl logs -n demo-stone deploy/client-cloud-to-hybrid -f
```

> Os logs dos clients no hybrid node podem falhar via kubectl (control plane alcança o kubelet só pela VPN). Alternativa: SSH no node e ver via jornal do container, ou focar no client-cloud (kubelet cloud sempre acessível). Ver environment-status.

Iniciar a falha via FIS. O comando captura o `EXPERIMENT_ID` (usado no stop da Fase 5) e tem fallback para o ID do template caso o `export` da Fase 0 não tenha sido feito:

```bash
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id ${FIS_TEMPLATE_ID:-EXTCnS3KTdAc2AEME} \
  --region sa-east-1 --query 'experiment.id' --output text)
echo "FIS iniciado: $EXPERIMENT_ID"
```

> Comportamento por tipo de endpoint EKS: se o kubelet alcança o endpoint PÚBLICO do cluster via internet (caso deste lab), o node PERMANECE Ready durante o FIS - a falha derruba apenas o data path (cross-cluster/VXLAN). Em ambientes com endpoint privado + Direct Connect (produção típica), o FIS derruba ambos os paths de uma vez.

### Fase 3b: NotReady + Tolerations (2 nodes)

Para demonstrar os hybrid nodes NotReady SEM afetar a LAN local (nao desconecte
a NIC - isso mataria os paths locais), bloqueie o acesso do kubelet ao endpoint
do EKS nos DOIS nodes. Assim o datacenter inteiro fica "perdido" para o control
plane, que e o cenario real de "a AWS caiu para o DC".

Resolver os IPs do endpoint e guardar na variável (mudam - sempre re-resolver). A remoção das regras, na Fase 5 (Recovery), reutiliza a mesma variável:

```bash
export EKS_EP_IPS=$(dig +short $(aws eks describe-cluster --name llm-vmware-hybrid \
  --region sa-east-1 --query 'cluster.endpoint' --output text | sed 's|https://||') | grep -E '^[0-9]' | tr '\n' ' ')
echo "IPs do endpoint: $EKS_EP_IPS"
```

Criar as regras de bloqueio nos dois nodes de uma vez. O loop externo percorre os
nodes (literais, seguro no zsh) e o loop dos IPs roda NO node (o bash do node faz
o split), então funciona igual seja o seu shell zsh ou bash:

```bash
for node in 192.168.3.51 192.168.3.52; do
  ssh -i ~/.ssh/id_ecdsa lopbruno@$node "for ip in $EKS_EP_IPS; do sudo iptables -I OUTPUT -d \$ip -j DROP; done"
done
```

> Dica: alternativa - logar em cada node e criar as regras por dentro. Logue no node:
>
> ```bash
> ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
> ```
>
> Já no node, criar as regras (use os IPs que o resolve retornou; repita no .52):
>
> ```bash
> sudo iptables -I OUTPUT -d 18.229.16.130 -j DROP
> sudo iptables -I OUTPUT -d 18.229.34.27 -j DROP
> ```

Acompanhar os dois virarem NotReady:

```bash
watch -n5 'kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid'
```

> Resultado esperado: AMBOS os hybrid nodes NotReady em ~60s, taint
> unreachable:NoExecute aplicado, pods continuam Running (tolerations). E o mais
> forte: a comunicacao CROSS-NODE (Node1 para Node2) continua 200 - o mesh VXLAN
> on-prem nao depende do control plane. O DC inteiro opera autonomo.

A remoção destas regras é um passo explícito da Fase 5 (Recovery) - o ambiente permanece desconectado pelas próximas fases de teste.

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
- com 2 replicas nem cai. A forma de visualizar na tela é pelo restart count do
container (coluna ATTEMPT do crictl), em dois terminais no node.

Pre-requisito: `crictl` instalado no node (uma vez). Logue no node:

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
```

Já no node, instale o crictl:

```bash
sudo curl -sL "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.1/crictl-v1.31.1-linux-amd64.tar.gz" | sudo tar -C /usr/local/bin -xz
echo "runtime-endpoint: unix:///run/containerd/containerd.sock" | sudo tee /etc/crictl.yaml
```

Terminal A (no node) - painel ao vivo do restart count. Logue no node:

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
```

E abra o watch do restart count:

```bash
sudo watch -n1 'crictl ps -a --name podinfo'
```

Terminal B (no node) - UM kill único (não repita, senão entra em CrashLoopBackOff). Logue no node (segundo terminal):

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
```

E dê um único kill no container:

```bash
sudo crictl stop $(sudo crictl ps --name podinfo -q | head -1)
```

> No Terminal A o container vai para Exited e, em ~2-5s, sobe um novo container
> Running com ATTEMPT +1 - o kubelet reiniciou da imagem em cache, sem falar com a
> AWS. Se o kill se repetir várias vezes, o backoff exponencial (10s->20s->40s)
> atrasa o retorno: o Kubernetes aplica crash-loop backoff localmente, mesmo
> offline. Faça 1 kill apenas.

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

## Fase 4b: DNS Resiliency - a dependência escondida (10 min)

Último teste de falha, e o mais sutil. Ainda desconectado (FIS + iptables ativos),
uma pergunta: o monitoring on-prem da Fase 7 sobrevive? Ele roda 100% nos hybrid
nodes... mas o Grafana consulta o Prometheus pelo NOME (`prometheus.onprem-monitoring`),
e resolver esse nome exige o CoreDNS. Onde roda o CoreDNS?

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

No deploy padrão do EKS, as réplicas do CoreDNS ficam nos nodes da NUVEM. Durante a
desconexão, o hybrid node não alcança o CoreDNS - o DNS dá timeout e TODA aplicação
on-prem que resolve nomes quebra, mesmo com o workload inteiro rodando local. O
dashboard fica lento e sem dados, não porque o Prometheus caiu, mas porque o nome
dele não resolve. O monitoring "local" tinha uma dependência escondida da nuvem.

> Só um teste de caos revela esse tipo de dependência. A stack foi desenhada para
> sobreviver ao disconnect, mas a camada mais básica - resolução de nomes - ainda
> morava na nuvem.

### O fix: réplicas de CoreDNS on-prem (recomendação oficial)

Para clusters mixed-mode, a AWS recomenda pelo menos uma réplica de CoreDNS nos
hybrid nodes e uma nos nodes da nuvem. Neste ambiente o fix JÁ está aplicado na
preparação - ele não pode ser aplicado durante a desconexão, porque o scheduler
não consegue colocar novas réplicas em nodes NotReady.

> Referência - fix já aplicado no prep (não reaplicar aqui; comandos para reproduzir em outro ambiente):
>
> ```bash
> kubectl -n kube-system patch deploy coredns --type merge -p '{"spec":{"replicas":3,"template":{"spec":{"topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]}}}}'
> kubectl -n kube-system annotate svc kube-dns service.kubernetes.io/topology-mode=Auto --overwrite
> ```

Confirmar a distribuição (deve haver réplica em node `mi-*`):

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName'
```

> A annotation `topology-mode: Auto` habilita Topology Aware Routing: quando ativa,
> os nodes preferem endpoints de DNS da própria zona (hybrid consulta a réplica
> local). Em clusters pequenos os hints podem não ativar (heurística de número
> mínimo de endpoints) - as réplicas locais continuam valendo, com retry do
> resolver. O CoreDNS local serve do cache de informer mesmo sem alcançar o API
> server - nomes existentes continuam resolvendo offline.

### Testar durante a desconexão

Com a réplica local no ar, o mesmo teste que falhava agora responde:

```bash
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
```

Já no node, resolução + query de dentro do container do Grafana:

```bash
GID=$(sudo crictl ps --name grafana -q | head -1)
sudo crictl exec $GID wget -qO- --timeout=5 http://prometheus.onprem-monitoring:9090/-/healthy
```

Resultado: `Prometheus Server is Healthy` - o Grafana volta a popular os painéis,
resolvendo o nome via CoreDNS on-prem, sem tocar a nuvem. O Prometheus continua
configurado por DNS (idiomático) - quem ficou resiliente foi a plataforma.

### E o Route 53? (dúvida comum)

Três camadas de resolução, três comportamentos na falha da região:

- **Nomes internos do cluster** (`*.svc.cluster.local`): resolvidos SÓ pelo CoreDNS - nunca tocam o Route 53. Fix: réplica local (acima).
- **Nomes públicos via resolver próprio do DC** (internet): sobrevivem - o data plane do Route 53 é global (edge locations anycast, SLA 100%), desenhado para manter disponibilidade mesmo quando o control plane degrada. Falha em sa-east-1 NÃO derruba a resolução pública.
- **Nomes resolvidos via Route 53 Resolver endpoint na VPC**: o endpoint é REGIONAL e alcançado pelo link privado - a falha da região ou do link quebra esse caminho, mesmo com o R53 global saudável. Recomendação: o DC resolve nomes públicos pelo resolver local dele, sem depender do caminho da VPC.

Refs: [Resilience in Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/disaster-recovery-resiliency.html) | [Control and data plane concepts](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/route-53-concepts.html) | [CoreDNS em hybrid nodes](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-add-ons.html)

## Fase 5: Recovery (5 min)

O Recovery desfaz as duas falhas na ordem inversa: primeiro o FIS, depois as
regras de iptables da Fase 3b.

Parar o FIS (ou aguardar o auto-revert - o template tem duração de 1h):

```bash
aws fis stop-experiment --id ${EXPERIMENT_ID} --region sa-east-1
```

Remover as regras de iptables nos dois nodes de uma vez (par simétrico do bloqueio
da Fase 3b, mesma variável `EKS_EP_IPS`, loop rodando no node):

```bash
for node in 192.168.3.51 192.168.3.52; do
  ssh -i ~/.ssh/id_ecdsa lopbruno@$node "for ip in $EKS_EP_IPS; do sudo iptables -D OUTPUT -d \$ip -j DROP; done"
done
```

> Dica: alternativa - logar em cada node e remover por dentro. Logue no node:
>
> ```bash
> ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.51
> ```
>
> Já no node, remover as regras (use os IPs do resolve; repita no .52):
>
> ```bash
> sudo iptables -D OUTPUT -d 18.229.16.130 -j DROP
> sudo iptables -D OUTPUT -d 18.229.34.27 -j DROP
> ```

Conferir que não sobrou regra (deve retornar 0 nos dois nodes):

```bash
for node in 192.168.3.51 192.168.3.52; do
  echo -n "$node DROPs: "
  ssh -i ~/.ssh/id_ecdsa lopbruno@$node "sudo iptables -L OUTPUT -n | grep -c DROP"
done
```

O client-cloud-to-hybrid volta a 200 sozinho (auto-heal), os nodes voltam Ready
em ~10-30s, os pods Pending são agendados. Zero intervenção manual.

```bash
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid
kubectl scale deploy server-hybrid-1 -n demo-stone --replicas=2
```

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

Para ver pod a pod (agrupado por node - `mi-*` = on-prem, `ip-*` = cloud), saída
compacta que cabe em terminal com split:

```bash
kubectl get pods -n demo-stone -l app=burst-app \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' \
  --sort-by=.spec.nodeName
```

**Resultado validado:** ~7 pods permanecem no DC (hybrid), ~3 transbordam para
os cloud nodes da AWS. O overflow é automático - `preferred` affinity, não
`required`: o scheduler prefere on-prem, mas usa a nuvem quando o DC enche.

> Na prática: a carga normal roda no datacenter, com o custo e a latência do hardware já existente. Num pico - Black Friday, campanha - a capacidade transborda para a AWS automaticamente, sem reconfigurar nada. Elasticidade sob demanda mantendo o baseline no DC.

> Dica k9s: em `:pods` filtrado em `demo-stone`, pressione `w` para exibir a coluna NODE. Ao escalar o burst-app, veja os pods nascendo e se espalhando: a maioria nos hybrid nodes e o excedente nos cloud nodes. Bursting visível pod a pod.

### Fim do pico: consolidação de volta ao DC

```bash
kubectl scale deploy burst-app -n demo-stone --replicas=2
```

> Nuance importante: o scale-down remove pods mas NÃO move os sobreviventes de volta - a affinity só age no scheduling. Para consolidar ativamente no DC use `kubectl rollout restart deploy/burst-app` (recria os pods, que voltam pro hybrid por preferência) ou o Descheduler em produção. Validado: pós rollout restart, 100% de volta ao hybrid.

### Evolução em produção

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
- Nodes da Nuvem alcançáveis do on-prem (um tile por node, verde OK / vermelho INALCANÇÁVEL)

> Durante a Fase 3, o painel "Conectividade On-Prem para Nuvem" e os tiles de
> "Nodes da Nuvem" ficam vermelhos, enquanto os hybrid nodes seguem UP e o Grafana
> continua respondendo - porque o stack inteiro roda on-prem. É a prova de que o
> DC mantém observabilidade própria mesmo cego para a AWS. Deixe este dashboard
> aberto desde o início, ao lado das URLs do podinfo.

## Trade-off das Tolerations

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

## Limitações conhecidas

| Limitação | Mitigação |
|-----------|-----------|
| Control plane na região (sem scheduling na desconexão) | Pré-dimensionar réplicas |
| SSM credentials: 1h / IAM Roles Anywhere: até 12h | Usar IRA com durationSeconds alto |
| Cilium pode reiniciar na desconexão (BGP) | v1.17+ tem o fix; usar VXLAN (nosso caso) |
| Restart de node offline: pods não voltam | Réplicas multi-node (Cenário 4) |
| ALB region-originated cai na desconexão | LB local (MetalLB/F5) para tráfego do DC |
| CoreDNS default fica só na nuvem (DNS morre no disconnect) | Réplicas on-prem via topologySpread (Fase 4b - DNS Resiliency) |

## F.A.Q

### E storage persistente? Nossos workloads stateful?

Stateful **funciona** em Hybrid Nodes - o que **não** funciona é EBS (preso à AZ, e o EBS CSI não está na lista de add-ons compatíveis). Opções locais:

- **hostPath** - simples, preso ao node (é como o [sample oficial de GPU burst](https://github.com/aws-samples/sample-eks-hybrid-nodes-gpu-burst-scaling) persiste modelos LLM localmente)
- **local PersistentVolumes** com `nodeAffinity`
- **CSI de terceiros** - Longhorn, Ceph, OpenEBS, ou o CSI do storage array do próprio DC
- **FSx CSI** está na lista de compatíveis, mas é storage de rede dependente da região (falha na desconexão)

**Ação:** validar com o time de storage do cliente qual CSI o array deles oferece. Ref: [add-ons compatíveis](https://docs.aws.amazon.com/eks/latest/userguide/hybrid-nodes-add-ons.html).

### Como fica a observabilidade DURANTE a desconexão? Ficamos cegos?

Métricas/logs para CloudWatch/AMP **param de fluir** durante o disconnect (dependência regional). Mitigações:

- **Backend local** secundário: Prometheus on-prem + ADOT com dual-exporter (é o que a Fase 7 demonstra)
- **`crictl`** para troubleshooting local sem control plane
- Do lado AWS: alarme **CloudWatch em NodeNotReady** (control plane logs) detecta a desconexão

Ref: [best practices - network disconnections](https://docs.aws.amazon.com/eks/latest/best-practices/hybrid-nodes-network-disconnections.html).

### Pod que CRASHA durante a desconexão reinicia?

**Sim** - diferente do restart de **node** (Cenário 4). O kubelet gerencia o `restartPolicy` localmente, sem API server, **desde que a imagem esteja no cache do containerd**. Pré-requisitos em produção:

- **Pre-pull** das imagens críticas em todos os nodes
- GC do containerd com `discard_unpacked_layers=false` (não descartar imagens)

### E se a desconexão durar mais de 12 horas?

Os **pods continuam rodando** independente de credencial expirada - ela afeta só a comunicação node↔AWS, não o workload local. Sobre as credenciais:

- **SSM Hybrid Activation:** credencial de 1h; para de renovar offline (reconexão pode levar até 30min de backoff - `systemctl restart` do agent força)
- **IAM Roles Anywhere:** até 12h configurável, reconexão em segundos

**Para janelas longas:** IRA com `durationSeconds` alto. Ref: [host credentials](https://docs.aws.amazon.com/eks/latest/best-practices/hybrid-nodes-host-creds.html).

### Nosso IDP usa admission webhooks (policy engines). O que acontece?

**Gotcha de produção importante:** se um webhook backend roda nos hybrid nodes e o DC desconecta, o API server não o alcança.

- Com `failurePolicy: Fail`, isso **bloqueia operações no cluster INTEIRO** (não só on-prem)
- **Recomendações:** rodar webhooks críticos em nodes cloud, ou usar `failurePolicy: Ignore` + réplicas nos dois lados
- **Ação:** revisar os webhooks da plataforma (Kyverno/OPA/Gatekeeper) sob esse critério

### E o cloud bursting?

Demonstrado na **Fase 6** (overflow) e evoluível para **Karpenter + Spot** disparado por KEDA/Prometheus. Nota: bursting **depende** da conectividade com a região - é complementar à resiliência (um usa a nuvem quando ela está lá, o outro sobrevive quando não está).

### O DNS não vira ponto único de falha no disconnect?

Vira, se o CoreDNS rodar só na nuvem - foi um achado deste lab (Fase 4b - DNS Resiliency):

- **Nomes internos** (`*.svc.cluster.local`): exigem CoreDNS. Fix: **réplica on-prem** via `topologySpreadConstraints` (recomendação oficial para mixed-mode)
- **Nomes públicos**: o data plane do Route 53 é **global** (SLA 100%) - mas se o DC resolve via **Resolver endpoint na VPC** (regional, via link privado), o caminho morre com o disconnect. Resolver local no DC para nomes públicos
- O CoreDNS local serve do cache mesmo sem API server - nomes existentes resolvem offline

### Chicago e Atlanta: um cluster para os dois DCs?

**Recomendação: um cluster por DC** (blast radius menor, upgrades independentes, menor latência). Se optarem por cluster único com nodes nos dois DCs:

- **Zone labels obrigatórias** (`topology.kubernetes.io/zone` por DC) - o Kubernetes cancela evictions quando uma zona INTEIRA fica unreachable, protegendo cada DC
- Requisito de rede: até **200ms RTT** e **100Mbps+** por DC

## Cleanup

```bash
kubectl delete ns demo-stone
cd terraform/ && terraform destroy
```
