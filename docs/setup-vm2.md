---
title: "Provisionar o Segundo Hybrid Node (VM 2)"
weight: 10
---

Este guia adiciona um **segundo hybrid node** ao cluster, rodando como uma VM no
mesmo ambiente vSphere on-premises. Com dois nodes on-prem podemos demonstrar o
cenário mais próximo de produção: microserviços distribuídos entre nodes do
datacenter, comunicando via Cilium VXLAN de forma independente da AWS.

::alert[Este é o único passo que exige ação manual no vCenter. Todo o resto do setup (nodeadm, registro no cluster, labels, static pod) é feito via SSH depois que a VM existir.]{type="info"}

## O que você (Bruno) precisa fazer no vCenter

### Passo 1: Criar a VM

Crie uma VM nova no vCenter (NÃO clone a VM existente - o clone duplica a
identidade SSM e o estado do nodeadm, causando conflito no cluster).

Especificações (iguais à VM 1, `eks-hybrid-lab2`):

| Parâmetro | Valor |
|-----------|-------|
| Nome | `eks-hybrid-lab2-node2` |
| SO | Ubuntu Server 24.04 LTS |
| vCPU | 2 |
| RAM | 4 GB |
| Disco | 40 GB |
| Rede | mesma da VM 1 (LAN 192.168.3.0/24) |
| IP | **192.168.3.52** (estático, fora do range DHCP e do pool MetalLB 240-250) |

### Passo 2: Configurar acesso SSH

Durante a instalação do Ubuntu, crie o usuário `lopbruno` e habilite SSH.
Adicione a chave pública para acesso sem senha:

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Na VM 2, adicionar a chave pública do Mac (mesma da VM 1)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "<conteúdo de ~/.ssh/id_ecdsa.pub do Mac>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
:::

### Passo 3: Me avisar

Quando a VM estiver de pé com SSH acessível, me passe:

- **Confirmação do IP** (192.168.3.52 ou outro que você tenha usado)
- **Senha do sudo** do usuário `lopbruno` nessa VM

A partir daí eu assumo e faço todo o resto via SSH.

## O que eu (R2D2) faço depois - referência do que será executado

Estes comandos NÃO precisam ser rodados por você - são o que eu executarei via
SSH assim que a VM existir. Documentados aqui para transparência e reprodução.

### Verificar acesso e conectividade

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Do Mac (rota estática para a LAN já configurada)
ssh -i ~/.ssh/id_ecdsa lopbruno@192.168.3.52 "hostname && ip a | grep 192.168.3"
:::

### Instalar o nodeadm (última versão)

O `nodeadm` é o CLI oficial do EKS Hybrid Nodes. Baixamos a versão mais recente
para evitar o bug de validação de assinatura do SSM installer presente em
versões antigas.

:::code{showCopyAction=true showLineNumbers=false language=bash}
curl -sL -o /usr/local/bin/nodeadm \
  "https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm"
chmod +x /usr/local/bin/nodeadm
nodeadm version
:::

### Criar o nodeConfig.yaml

O node 2 usa a MESMA SSM Hybrid Activation criada para o node 1
(registration-limit 3 já cobre múltiplos nodes). A diferença é a `zone` label,
que identifica o node como parte do mesmo DC.

:::code{showCopyAction=true showLineNumbers=false language=yaml}
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: llm-vmware-hybrid
    region: sa-east-1
  kubelet:
    config:
      staticPodPath: /etc/kubernetes/manifests   # habilita static pods (Cenário 4b)
    flags:
      - --node-labels=topology.kubernetes.io/zone=lab2-dc1
  hybrid:
    ssm:
      activationId: <ACTIVATION_ID>
      activationCode: <ACTIVATION_CODE>
:::

### Instalar componentes e registrar no cluster

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Instala kubelet, containerd, SSM agent, CNI plugins, kubectl
nodeadm install 1.35 --credential-provider ssm

# Registra o node no cluster EKS
nodeadm init --config-source file:///etc/nodeadm/nodeConfig.yaml
:::

::alert[Na versão v1.0.19+ do nodeadm o flag correto é `--config-source` (não `--config`, que era usado em versões antigas).]{type="warning"}

### Rotular o node e fazer deploy do cross-node

Do Mac (kubectl no cluster):

:::code{showCopyAction=true showLineNumbers=false language=bash}
# Identificar o novo node (nome mi-XXXX)
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid

# Rotular como node2
kubectl label node <NOME_DO_NODE_2> hybrid-node-id=node2

# Deploy do server no node 2 + static pod
kubectl apply -f manifests/02-server-hybrid-2.yaml
:::

### Validar comunicação cross-node

:::code{showCopyAction=true showLineNumbers=false language=bash}
# O client-hybrid-to-hybrid (já rodando no node 1) deve começar a receber 200
kubectl logs -n demo-stone deploy/client-hybrid-to-hybrid --tail=5
# Esperado: [HH:MM:SS] #N CROSS-NODE -> server-hybrid-2 | 200 ✓
:::

## Resultado esperado

Após estes passos, o cluster terá:

| Node | Zona | Papel |
|------|------|-------|
| mi-XXXX (node 1) | lab2-dc1 | server-hybrid-1, clients, static workloads |
| mi-YYYY (node 2) | lab2-dc1 | server-hybrid-2, static pod |

E o terceiro path de comunicação (CROSS-NODE, Node 1 → Node 2) ficará ativo,
completando a matriz de testes da demo.
