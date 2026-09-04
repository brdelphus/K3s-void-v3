#!/bin/bash
# =============================================================================
# K3s SERVER adicional (HA) no cluster — Void Linux (OpenRC)
# =============================================================================
# Projeto: ~/projects/k3s-void-v3 (terraform)
# Uso:     templatefile do main.tf -> cloud-init do rmaster-XX (master HA)
#
# v3.3 (22/ago/2026) — fixes pro join HA que falhava 2x no rmaster-01:
#  1. sysctls do 90-kubelet.conf (protect-kernel-defaults: true derrubava o
#     kubelet: "invalid kernel flag: vm/overcommit_memory...")
#  2. psa.yaml + eventconfig.yaml + audit.yaml gerados localmente
#     (enable-admission-plugins=EventRateLimit sem admission-control-config-file
#     derrubava o apiserver) — espelha o /var/lib/rancher/k3s/server do
#     master seed
#  3. tls-san com domínio do cluster + IP privado do próprio node
#  4. $${...} escapados: vars de SHELL (PRIV4/PRIV6/EXT4/CNI6) precisam do
#     double-dollar pro templatefile do terraform não tentar interpolá-las
#     (lição 22/ago: "vars map does not contain key PRIV4" quebra o plan)
# =============================================================================
exec > >(tee -a /var/log/k3s-join.log) 2>&1
echo "=== K3s Server Join Started at $(date) ==="

# Garante sudo NOPASSWD pro usuário admin (void) — sem isso a operação
# remota (join/restart/diagnóstico via SSH) trava pedindo senha. O arquivo
# vem de fábrica na imagem void-oci, mas o template NÃO pode depender disso.
mkdir -p /etc/sudoers.d
if [ ! -f /etc/sudoers.d/void ]; then
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/void
    chmod 440 /etc/sudoers.d/void
fi

# --- TIMING (fase 22/ago: medir cloud-init/rede/ext4/install em ciclos
# destroy/apply — pedido do Rodrigo). T0 = início do user-data; as etapas
# gravam [+Ns] com delta acumulado. CUIDADO: este arquivo é template do
# terraform (interpola dolar+chave) — usar só variavel shell, subshell
# duplo-parenteses e aritmetica duplo-parenteses, nunca dolar+chave. ---
T0=$(date +%s)
step() { echo "[+$(( $(date +%s) - T0 ))s] $*"; }
step "SCRIPT_INICIO — cloud-init user-data começou"

# --- DIAGNÓSTICO DE REDE (22/ago: eth0 sem IP/rota por 15+ min — gargalo do
# boot). Imprime o estado real da rede + dhcpcd pra serial/log a cada ciclo. ---
step "DIAG rede:"
ip -br addr 2>/dev/null || true
ip route 2>/dev/null || true
echo "--- dhcpcd: $(ps aux 2>/dev/null | grep -c '[d]hcpcd') processo(s)"
ps aux 2>/dev/null | grep '[d]hcpcd' || true
rc-status boot 2>/dev/null | grep -iE 'dhcpcd|cloud' || true
echo "--- fim diag rede ---"

# join = registra no cluster (default) | test = instala o k3s sem contatar nada
# (validação de timing em ciclos destroy/apply — lição 22/ago)
JOIN_MODE='${k3s_join_mode}'

# Cluster v3 STANDALONE (lição 22/ago): o rmaster-01 é o SEED (cluster-init,
# cria o etcd); rmaster-02 faz join HA no rmaster-01. NUNCA contata o
# cluster principal.
if [ "${node_name}" = "rmaster-01" ]; then
    K3S_IS_SEED=true
else
    K3S_IS_SEED=false
fi

# Aguarda a rede subir DE VERDADE antes de detectar IPs (lição 22/ago:
# a imagem void-oci demora até ~15 min pro DNS do OCI responder — o loop
# antigo (10 min + getent estrito) estourava com ext4 vazio. Agora 90x10s
# e sem getent: o eth0+rota basta; o DNS real é testado no loop do EXT4.)
for i in $(seq 1 90); do
    ip -4 -o addr show dev eth0 2>/dev/null | grep -q "inet " && \
    ip route 2>/dev/null | grep -q "^default" && break
    if [ $(( i % 10 )) -eq 1 ]; then
        echo "--- diag rede ao vivo (iter $${i}/90, $(date '+%H:%M:%S')) ---"
        ip -br addr 2>/dev/null || true
        ip route 2>/dev/null || true
        if ps aux 2>/dev/null | grep -q '[d]hcpcd'; then
            ps aux 2>/dev/null | grep '[d]hcpcd' | head -2
        else
            echo "dhcpcd: NENHUM processo rodando"
        fi
        rc-status boot 2>/dev/null | grep -iE 'dhcpcd|sshd' || true
        echo "--- fim diag ---"
    fi
    echo "aguardando rede ($${i}/90)..."
    sleep 10
done
T_NET=$(date +%s)
step "REDE_OK — eth0 + rota default (após $${i} iterações, +$(( T_NET - T0 ))s)"

# Espera o SEED (rmaster-01, 10.2.1.3:6443) ficar pronto ANTES do join
# (ordem obrigatória — pedido do Rodrigo 22/ago: o join HA/agent antes do
# seed subir falha ou entra pela metade). Só o seed pula esta espera.
if [ "$K3S_IS_SEED" != "true" ]; then
    echo "Aguardando o seed 10.2.1.3:6443 responder..."
    for i in $(seq 1 180); do
        if timeout 3 bash -c 'echo > /dev/tcp/10.2.1.3/6443' 2>/dev/null; then
            echo "Seed pronto (tentativa $${i})"
            break
        fi
        sleep 10
    done
fi

mkdir -p /etc/rancher/k3s
mkdir -p /var/lib/rancher/k3s/server/logs

# -----------------------------------------------------------------------------
# SEÇÃO 0 — sysctls exigidos pelo protect-kernel-defaults
# (espelha o /etc/sysctl.d/90-kubelet.conf do master seed; sem eles o kubelet
# morre com "invalid kernel flag" e o flannel nunca sobe)
# -----------------------------------------------------------------------------
cat > /etc/sysctl.d/90-kubelet.conf << 'SYSCTLEOF'
vm.panic_on_oom=0
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTLEOF
sysctl --system >/dev/null 2>&1

# -----------------------------------------------------------------------------
# SEÇÃO 0.5 — arquivos de admission/audit do apiserver
# (EventRateLimit + PodSecurity exigem o config file apontado por
# admission-control-config-file; sem eles o apiserver não sobe)
# -----------------------------------------------------------------------------
cat > /var/lib/rancher/k3s/server/psa.yaml << 'PSAEOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1beta1
    kind: PodSecurityConfiguration
    defaults:
      enforce: "restricted"
      enforce-version: "latest"
      audit: "restricted"
      audit-version: "latest"
      warn: "restricted"
      warn-version: "latest"
    exemptions:
      usernames: []
      runtimeClasses: []
      namespaces: [kube-system, monitoring, cis-operator-system, traefik, dns, metallb-system, cert-manager, nextcloud, velero, mail]
- name: EventRateLimit
  path: /var/lib/rancher/k3s/server/eventconfig.yaml
PSAEOF
cat > /var/lib/rancher/k3s/server/eventconfig.yaml << 'EVTEOF'
apiVersion: eventratelimit.admission.k8s.io/v1alpha1
kind: Configuration
limits:
- type: Namespace
  qps: 50
  burst: 100
  cacheSize: 2000
- type: User
  qps: 10
  burst: 50
- type: Server
  qps: 5
  burst: 15
EVTEOF
cat > /var/lib/rancher/k3s/server/audit.yaml << 'AUDITEOF'
apiVersion: audit.k8s.io/v1
kind: Policy
metadata:
  name: policy
rules:
- level: None
  users: ["system:kube-proxy"]
  verbs: ["watch"]
  resources:
  - group: ""
    resources: ["endpoints", "services", "services/status"]
- level: None
  users: ["system:unsecured"]
  namespaces: ["kube-system"]
  verbs: ["get"]
  resources:
  - group: ""
    resources: ["configmaps"]
- level: None
  users: ["kubelet"]
  verbs: ["get"]
  resources:
  - group: ""
    resources: ["nodes", "nodes/status"]
- level: None
  userGroups: ["system:nodes"]
  verbs: ["get"]
  resources:
  - group: ""
    resources: ["nodes", "nodes/status"]
- level: None
  users:
  - system:kube-controller-manager
  - system:kube-scheduler
  - system:serviceaccount:kube-system:endpoint-controller
  verbs: ["get", "update"]
  namespaces: ["kube-system"]
  resources:
  - group: ""
    resources: ["endpoints"]
- level: None
  users: ["system:apiserver"]
  verbs: ["get"]
  resources:
  - group: ""
    resources: ["namespaces", "namespaces/status", "namespaces/finalize"]
- level: None
  users: ["cluster-autoscaler"]
  verbs: ["get", "update"]
  namespaces: ["kube-system"]
  resources:
  - group: ""
    resources: ["configmaps", "endpoints"]
- level: None
  users: ["system:serviceaccount:kube-system:cluster-autoscaler"]
  verbs: ["get", "update"]
  namespaces: ["kube-system"]
  resources:
  - group: ""
    resources: ["configmaps", "endpoints"]
- level: Request
  omitStages:
  - RequestReceived
  users: ["kubelet", "system:node-problem-detector", "system:serviceaccount:kube-system:node-problem-detector"]
  verbs: ["update","patch"]
  resources:
  - group: ""
    resources: ["nodes/status", "pods/status"]
- level: Request
  omitStages:
  - RequestReceived
  userGroups: ["system:nodes"]
  verbs: ["update","patch"]
  resources:
  - group: ""
    resources: ["nodes/status", "pods/status"]
- level: Request
  omitStages:
  - RequestReceived
  users: ["system:serviceaccount:kube-system:namespace-controller"]
  verbs: ["deletecollection"]
- level: Metadata
  omitStages:
  - RequestReceived
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
  - group: authentication.k8s.io
    resources: ["tokenreviews"]
- level: Request
  omitStages:
  - RequestReceived
  users: ["system:serviceaccount:kube-system:endpoint-controller"]
  verbs: ["update"]
  resources:
  - group: ""
    resources: ["endpoints"]
- level: Metadata
  omitStages:
  - RequestReceived
  users: ["system:serviceaccount:kube-system:default"]
  verbs: ["get", "list", "watch"]
  resources:
  - group: ""
    resources: ["configmaps"]
- level: Request
  omitStages:
  - RequestReceived
  users: ["system:serviceaccount:kube-system:certificate-controller"]
  verbs: ["update"]
  resources:
  - group: "certificates.k8s.io"
    resources: ["certificatesigningrequests/status"]
- level: None
  userGroups: ["system:nodes"]
  verbs: ["create"]
  resources:
  - group: ""
    resources: ["pods"]
- level: None
  userGroups: ["system:nodes"]
  verbs: ["get"]
  resources:
  - group: ""
    resources: ["nodes"]
AUDITEOF

# -----------------------------------------------------------------------------
# metrics-server do k3s com IPs INTERNOS sempre (lição 22/ago: o default
# ExternalIP,InternalIP tentava os IPs públicos e dava timeout — kubectl top
# e o KPS ficavam sem métricas). O k3s usa este manifest em vez do embutido.
# -----------------------------------------------------------------------------
mkdir -p /var/lib/rancher/k3s/server/manifests
cat > /var/lib/rancher/k3s/server/manifests/metrics-server.yaml << 'MSEOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-server
  namespace: kube-system
  labels:
    kubernetes.io/name: "Metrics-server"
spec:
  selector:
    k8s-app: metrics-server
  ports:
  - port: 443
    protocol: TCP
    targetPort: https
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-server
  namespace: kube-system
  labels:
    k8s-app: metrics-server
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  template:
    metadata:
      labels:
        k8s-app: metrics-server
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
        image: rancher/mirrored-metrics-server:v0.8.1
        imagePullPolicy: IfNotPresent
        livenessProbe:
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 1
        name: metrics-server
        ports:
        - containerPort: 10250
          name: https
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          periodSeconds: 2
          timeoutSeconds: 1
        resources:
          requests:
            cpu: 100m
            memory: 70Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
        volumeMounts:
        - mountPath: /tmp
          name: tmp-dir
      dnsPolicy: ClusterFirst
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-node-critical
      serviceAccountName: metrics-server
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/control-plane
        operator: Exists
      volumes:
      - emptyDir: {}
        name: tmp-dir
MSEOF

# -----------------------------------------------------------------------------
# SEÇÃO 1 — Detecta IPs do node
# -----------------------------------------------------------------------------
# PRIV4: IPv4 privado (eth0, ex: 10.2.1.3) -> InternalIP v4
# PRIV6: IPv6 global da interface (ex: 2603:...:f467) -> InternalIP v6 (fase 1)
#        (exclui 2001:cafe = faixa do flannel, que só existe pós-join)
# EXT4:  IPv4 público (via serviço externo de echo) -> ExternalIP v4
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
T_EXT=$(date +%s)
step "EXT4_OK — IPv4 público detectado ($${i}/300, +$(( T_EXT - T0 ))s, delta rede→ext4 $(( T_EXT - T_NET ))s)"

echo "Privado: $${PRIV4} / $${PRIV6}"
echo "Público IPv4: $${EXT4}"

# Sem os 3 IPs o join não faz sentido — aborta com log claro
if [ -z "$${PRIV4}" ] || [ -z "$${PRIV6}" ] || [ -z "$${EXT4}" ]; then
    echo "ERRO: IPs não detectados (priv4=$${PRIV4} priv6=$${PRIV6} ext4=$${EXT4})" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# SEÇÃO 2 — Escreve config.yaml COMPLETA do server e faz o join
# -----------------------------------------------------------------------------
# SEED (rmaster-01) leva cluster-init: true (cria o etcd do v3). Os demais
# (rmaster-02) joinam HA no rmaster-01 (10.2.1.3:6443).
if [ "$K3S_IS_SEED" = "true" ]; then
    CLUSTER_INIT_LINE="cluster-init: true"
else
    CLUSTER_INIT_LINE=""
fi
# Fase 1 usa o v6 global no node-ip: o cni0 (2001:cafe:42:X::1) só existe
# DEPOIS que o flannel sobe, então não dá pra usá-lo no primeiro boot.
# O node-external-ip já nasce com v4 público + v6 global (os dois, como o
# Rodrigo pediu).
cat > /etc/rancher/k3s/config.yaml << K3SCONFIG
# --- básico ---
write-kubeconfig-mode: "0644"
tls-san:
  - "$${PRIV4}"
$${CLUSTER_INIT_LINE}
# --- redes (dual-stack, valores do terraform) ---
cluster-cidr: ${cluster_cidr},${cluster_cidr_ipv6}
service-cidr: ${service_cidr},${service_cidr_ipv6}
# --- observabilidade (espelha o master original) ---
etcd-expose-metrics: true
supervisor-metrics: true
kube-controller-expose-metrics: true
kube-proxy-expose-metrics: true
kube-scheduler-expose-metrics: true
# --- desabilita addons gerenciados fora do k3s (traefik/servicelb via Helm) ---
disable:
  - traefik
  - servicelb
  - metrics-server
# --- segurança ---
secrets-encryption: true
kube-apiserver-arg:
  - "enable-admission-plugins=NodeRestriction,EventRateLimit"
  - 'admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml'
  - 'audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log'
  - 'audit-policy-file=/var/lib/rancher/k3s/server/audit.yaml'
  - 'audit-log-maxage=30'
  - 'audit-log-maxbackup=10'
  - 'audit-log-maxsize=100'
kube-controller-manager-arg:
  - '--bind-address=0.0.0.0'
  - 'terminated-pod-gc-threshold=10'
  - 'node-cidr-mask-size-ipv6=64'
kube-scheduler-arg:
  - '--bind-address=0.0.0.0'
kube-proxy-arg:
  - '--metrics-bind-address=0.0.0.0'
kubelet-arg:
  - 'streaming-connection-idle-timeout=5m'
  - "tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305"
protect-kernel-defaults: true
# --- flannel: backend wireguard (mesmo do master original) ---
flannel-backend: wireguard-native
flannel-external-ip: true
flannel-iface: eth0
flannel-ipv6-masq: true
prefer-bundled-bin: true
# --- identidade/join (vars do terraform) ---
token: "${k3s_token}"
node-name: ${node_name}
node-ip: "$${PRIV4},$${PRIV6}"
node-external-ip: "$${EXT4},$${PRIV6}"
K3SCONFIG

# SEED (rmaster-01) cria o cluster; rmaster-02 join HA no seed via K3S_URL.
# NUNCA aponta pro cluster principal — cluster v3 standalone.
# --- Manifesto custom do metrics-server (fix OCI 22/ago) ---
# O k3s v1.36 instala o addon built-in com
# --kubelet-preferred-address-types=ExternalIP,... -> o metrics-server tenta
# o IP PUBLICO do kubelet -> security list drop (timeout) -> kubectl top
# <unknown>. O addon esta desabilitado no config.yaml (disable metrics-server)
# e este manifesto (InternalIP primeiro) e aplicado pelo k3s no bootstrap a
# partir de /var/lib/rancher/k3s/server/manifests/.
mkdir -p /var/lib/rancher/k3s/server/manifests
cat > /var/lib/rancher/k3s/server/manifests/metrics-server.yaml << 'MSEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: metrics-server
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      labels:
        k8s-app: metrics-server
      name: metrics-server
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        # OCI fix (22/ago): k3s usa ExternalIP,InternalIP por padrão — o
        # metrics-server tenta o IP público do kubelet e o security list drop
        # (timeout, kubectl top = <unknown>). InternalIP primeiro resolve.
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
        image: rancher/mirrored-metrics-server:v0.8.1
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /livez
            port: https
            scheme: HTTPS
          initialDelaySeconds: 60
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        name: metrics-server
        ports:
        - containerPort: 10250
          name: https
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /readyz
            port: https
            scheme: HTTPS
          periodSeconds: 2
          successThreshold: 1
          timeoutSeconds: 1
        resources:
          requests:
            cpu: 100m
            memory: 70Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /tmp
          name: tmp-dir
      dnsPolicy: ClusterFirst
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-node-critical
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      serviceAccount: metrics-server
      serviceAccountName: metrics-server
      terminationGracePeriodSeconds: 30
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/control-plane
        operator: Exists
      volumes:
      - emptyDir: {}
        name: tmp-dir
---
apiVersion: v1
kind: Service
metadata:
  labels:
    kubernetes.io/cluster-service: 'true'
    kubernetes.io/name: Metrics-server
  name: metrics-server
  namespace: kube-system
spec:
  internalTrafficPolicy: Cluster
  ipFamilies:
  - IPv4
  - IPv6
  ipFamilyPolicy: PreferDualStack
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    k8s-app: metrics-server
  sessionAffinity: None
  type: ClusterIP
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    rbac.authorization.k8s.io/aggregate-to-admin: 'true'
    rbac.authorization.k8s.io/aggregate-to-edit: 'true'
    rbac.authorization.k8s.io/aggregate-to-view: 'true'
  name: system:aggregated-metrics-reader
rules:
- apiGroups:
  - metrics.k8s.io
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:metrics-server
rules:
- apiGroups:
  - ''
  resources:
  - nodes/metrics
  verbs:
  - get
- apiGroups:
  - ''
  resources:
  - pods
  - nodes
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
    port: 443
  version: v1beta1
  versionPriority: 100
---
# Extra RBAC (fix 24/aug): the metrics-server aggregator does
# get/list/watch on the extension-apiserver-authentication configmap
# (kube-system); the k3s built-in addon granted that via its own role,
# the custom manifest did not -> panic "unable to load configmap based
# request-header-client-ca-file" + apiservice FailedDiscoveryCheck.
# Role scoped to kube-system only.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: metrics-server-auth-reader
  namespace: kube-system
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: metrics-server-auth-reader
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
MSEOF

# Sem INSTALL_K3S_VERSION o install.sh do k3s pega a stable mais recente
# (canal default; mesma política do SUC — nada hardcoded).
if [ "$JOIN_MODE" = "test" ]; then
    # MODO TESTE: sem K3S_URL e sem start — o k3s instala mas NUNCA
    # sobe (nenhum cluster criado/contatado)
    export INSTALL_K3S_SKIP_START=true
    export INSTALL_K3S_EXEC='server'
elif [ "$K3S_IS_SEED" = "true" ]; then
    # SEED: cluster-init no config.yaml — sobe sozinho, sem K3S_URL
    export INSTALL_K3S_EXEC='server'
else
    export K3S_TOKEN='${k3s_token}'
    export K3S_URL='${server_url}'
    export INSTALL_K3S_EXEC='server'
fi

# Retry do download/install (a rede pode oscilar no boot — lição 22/ago)
T_K3S=$(date +%s)
step "K3S_INSTALL_INICIO — baixando get.k3s.io (stable mais recente, delta ext4→install $(( T_K3S - T_EXT ))s)"
for i in $(seq 1 5); do
    curl -sfL https://get.k3s.io | sh - && break
    echo "install k3s falhou ($${i}/5) — retry em 15s"
    sleep 15
done
T_K3S_END=$(date +%s)
step "K3S_INSTALL_FIM — k3s instalado em $(( T_K3S_END - T_K3S ))s (tentativa $${i})"

# [fix 1/set/2026] Hardening do init.d do k3s server (marca k3s-mountns-guard):
# o serviço passa a rodar SEMPRE no mount ns do init via `nsenter -t 1 -m`
# (no-op no boot — validado em node real 1/set/2026: pid no ns do init com
# shared). Sem isso, um restart vindo de contexto com mount ns separado — ex:
# upgrade k3s via chroot de pod (kubectl debug/SUC roda o rc-service DENTRO do
# ns do container) — nascia o k3s num ns clone com / private e hostPath de
# pods novos quebrava (node-exporter/metrics-server, pivot_root do runc; pods
# antigos seguiam Running). Formato CANÔNICO do openrc: command = binário
# limpo, prefixo nsenter vai no command_args (command com espaços quebra o
# supervise-daemon).
if ! grep -q 'k3s-mountns-guard' /etc/init.d/k3s 2>/dev/null; then
    sed -i 's|^command="/usr/local/bin/k3s"$|command="/usr/bin/nsenter"  # k3s-mountns-guard|; s|^command_args="server|command_args="-t 1 -m -- /usr/local/bin/k3s server|' /etc/init.d/k3s
    echo "init.d k3s blindado com k3s-mountns-guard"
fi

if [ "$JOIN_MODE" = "test" ]; then
    echo "=== MODO TESTE: k3s instalado (SKIP_START) — join NÃO executado, master não contatado ==="
    k3s --version 2>/dev/null | head -1
    echo "--- config.yaml (validação dos IPs) ---"
    grep -E '^(node-name|node-ip|node-external-ip):' /etc/rancher/k3s/config.yaml
    # Resumo de timing do ciclo (parse: grep -E '^\[+[0-9]+s\] (REDE|EXT4|K3S)')
    T_END=$(date +%s)
    step "FIM — total do user-data: $(( T_END - T0 ))s (do boot do user-data ao fim)"
    echo "=== TIMING RESUMO (segundos) ==="
    echo "  cloud-init total: $(( T_END - T0 ))s"
    echo "  rede (eth0+rota): $(( T_NET - T0 ))s"
    echo "  ext4 (IPv4 pub):  $(( T_EXT - T_NET ))s (acumulado +$(( T_EXT - T0 ))s)"
    echo "  k3s install:      $(( T_K3S_END - T_K3S ))s (acumulado +$(( T_K3S_END - T0 ))s)"
    exit 0
fi

# -----------------------------------------------------------------------------
# SEÇÃO 3 — Fase 2: troca o node-ip v6 global pelo cni0 (sem colisão)
# -----------------------------------------------------------------------------
# O cni0 é criado pelo flannel quando sobe — mas SÓ se houver rede de pod
# ativa. Em join limpo (sem pods no node), o cni0 nunca aparecia e o loop
# de 300s estourava, deixando o node com ExternalIP só v6 (bug 23/ago,
# rworker-02). Fix: criar o cni0 a partir do /run/flannel/subnet.env (o
# flannel grava os IPs de overlay ao subir) e usar o v6 dele no node-ip,
# sem depender de pod agendado. Depois reescreve SÓ a linha node-ip — o
# v4 (ex: 10.2.1.3) não muda, então o member address do etcd continua o
# mesmo (seguro reiniciar o server HA).
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
    echo "cni0 IPv6: $${CNI6} — reescrevendo node-ip (ExternalIP = v4 + v6)"
    sed -i "s|^node-ip:.*|node-ip: \"$${PRIV4},$${CNI6}\"|" /etc/rancher/k3s/config.yaml
    echo "--- config.yaml final ---"
    grep -E '^(node-name|node-ip|node-external-ip):' /etc/rancher/k3s/config.yaml
    sudo rc-service k3s restart
else
    echo "AVISO: cni0 não apareceu em 300s — node registrado com ExternalIP só v4+v6 global (colisão); rodar o fix manualmente"
fi

echo "=== K3s server join done at $(date) ==="
