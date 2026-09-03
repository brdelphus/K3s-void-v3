#!/bin/bash
# K3s AGENT no cluster — Void Linux (OpenRC)
# v3.3 (22/ago/2026): $${...} escapados pro templatefile do terraform
# (vars de SHELL PRIV4/PRIV6/EXT4/CNI6 — lição do plan quebrado 22/ago)
# v3.2: detecta IPs via curl/ip e registra node com ExternalIP = v4 + v6.
# Método v2: testar IPs com curl e colocar no config.yaml antes do join.
#
# POR QUE node-ip usa o IPv6 do cni0 e NÃO o global (lição 20/ago):
# o CCM (k8s cloud-provider GetNodeAddressesFromNodeIP) filtra os addresses
# pelo provided-node-ip: cada IP do node-ip marca o TIPO dele (Internal/External)
# e descarta os demais do mesmo tipo. Se o MESMO IPv6 global estiver em
# node-ip E node-external-ip, o tipo ExternalIP é marcado pelo v6 e o
# IPv4 externo é DESCARTADO do status. O worker velho só tem os dois porque
# o v6 interno dele (fake) != v6 externo (real). Aqui usamos o v6 real do
# cni0 (overlay flannel, alcançável via WireGuard) como interno — sem fake.
exec > >(tee -a /var/log/k3s-join.log) 2>&1
echo "=== K3s Agent Join Started at $(date) ==="

# Garante sudo NOPASSWD pro usuário admin (void) — sem isso a operação
# remota (join/restart/diagnóstico via SSH) trava pedindo senha. O arquivo
# vem de fábrica na imagem void-oci, mas o template NÃO pode depender disso.
mkdir -p /etc/sudoers.d
if [ ! -f /etc/sudoers.d/void ]; then
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/void
    chmod 440 /etc/sudoers.d/void
fi

# join = registra no cluster (default) | test = instala o k3s sem contatar o
# master (validação de timing em ciclos destroy/apply — lição 22/ago)
JOIN_MODE='${k3s_join_mode}'

# Aguarda a rede subir DE VERDADE antes de detectar IPs (lição 22/ago:
# a imagem void-oci demora até ~15 min pro DNS do OCI responder — o loop
# antigo (10 min + getent estrito) estourava com ext4 vazio. Agora 90x10s
# e sem getent: o eth0+rota basta; o DNS real é testado no loop do EXT4.)
for i in $(seq 1 90); do
    ip -4 -o addr show dev eth0 2>/dev/null | grep -q "inet " && \
    ip route 2>/dev/null | grep -q "^default" && break
    echo "aguardando rede ($${i}/90)..."
    sleep 10
done

# Espera o SEED (rmaster-01, 10.2.1.3:6443) ficar pronto ANTES do join
# (ordem obrigatória — pedido do Rodrigo 22/ago: workers só depois dos
# masters; o seed demora no primeiro boot: rede + download + cluster-init)
echo "Aguardando o seed 10.2.1.3:6443 responder..."
for i in $(seq 1 180); do
    if timeout 3 bash -c 'echo > /dev/tcp/10.2.1.3/6443' 2>/dev/null; then
        echo "Seed pronto (tentativa $${i})"
        break
    fi
    sleep 10
done

mkdir -p /etc/rancher/k3s

# --- Detecta IPs ---
PRIV4=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
PRIV6=$(ip -6 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1 | grep -v '^2001:cafe' | head -1)
# DNS PÚBLICO rápido, SÓ IPv4 (lição 22/ago: o 169.254.169.254 do OCI
# demora ~15 min pra responder no boot; o Rodrigo mandou nada de IPv6
# no DNS — o nameserver v6 atrasa as resoluções quando o v6 de saída
# ainda não subiu).
cat > /etc/resolv.conf << 'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
DNSEOF

# EXT4 precisa ser IPv4 REAL (lição 22/ago: o api64.ipify.org sem -4
# retorna o IPv6 da conexão — duplicou o node-external-ip). O IPv4 de
# SAÍDA da VM (rota default v4 + IGW) demora até ~30 min pra subir na
# OCI (medido 22/ago: seed com DNS público ainda falhou a janela de
# 20 min). Janela: 300x5s = 25 min além dos 15 de rede = ~40 min total.
EXT4=""
for i in $(seq 1 300); do
    EXT4=$(curl -4 -s --max-time 8 --connect-timeout 5 http://checkip.amazonaws.com/ 2>/dev/null || curl -4 -s --max-time 8 --connect-timeout 5 http://api4.ipify.org/ 2>/dev/null)
    echo "$EXT4" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && break
    echo "aguardando IPv4 público ($${i}/300)..."
    sleep 5
done

echo "Privado: $${PRIV4} / $${PRIV6}"
echo "Público IPv4: $${EXT4}"

if [ -z "$${PRIV4}" ] || [ -z "$${PRIV6}" ] || [ -z "$${EXT4}" ]; then
    echo "ERRO: IPs não detectados (priv4=$${PRIV4} priv6=$${PRIV6} ext4=$${EXT4})" >&2
    exit 1
fi

# --- Fase 1: join com node-ip dual-stack (v4 + v6 global) ---
# O k3s exige node-ip com as duas versões (cluster dual-stack). O cni0 v6
# (2001:cafe:42:X::1) só existe DEPOIS que o flannel sobe, então o primeiro
# join usa o v6 global; na fase 2 trocamos pelo cni0 e ganhamos o v4 externo.
cat > /etc/rancher/k3s/config.yaml << K3SCONFIG
node-name: ${node_name}
node-ip: "$${PRIV4},$${PRIV6}"
node-external-ip: "$${EXT4},$${PRIV6}"
# Expõe métricas do kube-proxy em 0.0.0.0 (padrão dos masters; sem isso o
# bind nasce 127.0.0.1 e o kube-prometheus-stack não scrapeia — fix 23/ago)
kube-proxy-arg:
- --metrics-bind-address=0.0.0.0
K3SCONFIG

# Sem INSTALL_K3S_VERSION o install.sh do k3s pega a stable mais recente
# (canal default; mesma política do SUC — nada hardcoded).
if [ "$JOIN_MODE" = "test" ]; then
    # MODO TESTE: sem K3S_URL e sem start — o k3s instala mas NUNCA
    # contata o master (etcd do cluster intocado)
    export INSTALL_K3S_SKIP_START=true
    export INSTALL_K3S_EXEC='agent'
else
    export K3S_TOKEN='${k3s_token}'
    export K3S_URL='${server_url}'
    export INSTALL_K3S_EXEC='agent'
fi

# Retry do download/install (a rede pode oscilar no boot — lição 22/ago)
for i in $(seq 1 5); do
    curl -sfL https://get.k3s.io | sh - && break
    echo "install k3s falhou ($${i}/5) — retry em 15s"
    sleep 15
done

# [fix 1/set/2026] Hardening do init.d do k3s-agent (marca k3s-mountns-guard):
# o serviço passa a rodar SEMPRE no mount ns do init via `nsenter -t 1 -m`
# (no-op no boot — validado em node real 1/set/2026: pid no ns do init com
# shared). Sem isso, um restart vindo de contexto com mount ns separado — ex:
# upgrade k3s via chroot de pod (kubectl debug/SUC roda o rc-service DENTRO do
# ns do container) — nascia o k3s-agent num ns clone com / private e hostPath
# de pods novos quebrava (node-exporter/metrics-server, pivot_root do runc;
# pods antigos seguiam Running). Formato CANÔNICO do openrc: command = binário
# limpo, prefixo nsenter vai no command_args (command com espaços quebra o
# supervise-daemon).
if ! grep -q 'k3s-mountns-guard' /etc/init.d/k3s-agent 2>/dev/null; then
    sed -i 's|^command="/usr/local/bin/k3s"$|command="/usr/bin/nsenter"  # k3s-mountns-guard|; s|^command_args="agent|command_args="-t 1 -m -- /usr/local/bin/k3s agent|' /etc/init.d/k3s-agent
    echo "init.d k3s-agent blindado com k3s-mountns-guard"
fi

if [ "$JOIN_MODE" = "test" ]; then
    echo "=== MODO TESTE: k3s instalado (SKIP_START) — join NÃO executado, master não contatado ==="
    k3s --version 2>/dev/null | head -1
    echo "--- config.yaml (validação dos IPs) ---"
    grep -E '^(node-name|node-ip|node-external-ip):' /etc/rancher/k3s/config.yaml
    exit 0
fi

# --- Fase 2: reescreve config com node-ip do cni0 (sem colisão com external) ---
# O node-ip v6 global no external marca o tipo ExternalIP e derruba o v4;
# trocar o interno pelo cni0 desmarca. O cni0 é criado pelo flannel quando
# ele sobe — mas SÓ se houver rede de pod ativa. Em join limpo (sem pods no
# node), o cni0 nunca aparecia e o loop de 300s estourava, deixando o node
# com ExternalIP só v6 (bug 23/ago, rworker-02). Fix: criar o cni0 a partir
# do /run/flannel/subnet.env (o flannel grava os IPs de overlay ao subir) e
# usar o v6 dele no node-ip, sem depender de pod agendado.
for i in $(seq 1 30); do
    [ -s /run/flannel/subnet.env ] && break
    sleep 10
done

CNI6=""
if [ -s /run/flannel/subnet.env ]; then
    # FLANNEL_IPV6_SUBNET=2001:cafe:42:X::1/64 — pega o IP sem o prefixo
    CNI6=$(awk -F= '/^FLANNEL_IPV6_SUBNET=/{print $2}' /run/flannel/subnet.env | cut -d/ -f1)
    CNI4=$(awk -F= '/^FLANNEL_SUBNET=/{print $2}' /run/flannel/subnet.env | cut -d/ -f1)
    CNIMTU=$(awk -F= '/^FLANNEL_MTU=/{print $2}' /run/flannel/subnet.env)
    # Cria o cni0 (bridge do CNI) com os IPs do overlay, se ainda não existir.
    # MTU do subnet.env (1420 no backend WireGuard) — sem isso o bridge nasce
    # com 1500 e a PMTU do overlay quebra (lição 23/ago).
    if [ -n "$${CNI6}" ] && ! ip link show cni0 >/dev/null 2>&1; then
        # ip link add NÃO aceita "mtu" após "type bridge" (iproute2 do Void)
        # — cria, sobe e seta MTU em passos separados (testado 23/ago).
        ip link add cni0 type bridge 2>/dev/null && {
            ip link set cni0 up
            ip link set cni0 mtu "$${CNIMTU:-1420}"
            ip addr add "$${CNI4}/24" dev cni0 2>/dev/null || true
            ip -6 addr add "$${CNI6}/64" dev cni0 2>/dev/null || true
            echo "cni0 criado manualmente: $${CNI4}/24 + $${CNI6}/64 (mtu $${CNIMTU:-1420})"
        }
    fi
fi

if [ -n "$${CNI6}" ]; then
    echo "cni0 IPv6: $${CNI6} — reescrevendo config (ExternalIP = v4 + v6)"
    cat > /etc/rancher/k3s/config.yaml << K3SCONFIG
node-name: ${node_name}
node-ip: "$${PRIV4},$${CNI6}"
node-external-ip: "$${EXT4},$${PRIV6}"
# Expõe métricas do kube-proxy (mesmo da fase 1 — reescrita completa)
kube-proxy-arg:
- --metrics-bind-address=0.0.0.0
K3SCONFIG
    echo "--- config.yaml final ---"
    cat /etc/rancher/k3s/config.yaml
    sudo rc-service k3s-agent restart
else
    echo "AVISO: cni0 não apareceu em 300s — node registrado com ExternalIP só v4+v6 global (colisão); rodar o fix manualmente"
fi

echo "=== K3s agent join done at $(date) ==="
