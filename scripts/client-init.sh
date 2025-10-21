#!/bin/bash
# Client initialization script for k3s, kwok, and liqo (container friendly)
set -Eeuo pipefail

# ---- logging to file + stdout
mkdir -p /var/log
exec > >(tee -a /var/log/client-init.log)
exec 2>&1

echo "=== Starting initialization for $(hostname) ==="

# ---- identify client + addressing
HOSTNAME="$(hostname)"
CLIENT_NUM="$(echo "$HOSTNAME" | grep -o '[0-9]\+' || true)"
if [[ -z "${CLIENT_NUM}" ]]; then
  echo "[err] Cannot parse client number from hostname=$HOSTNAME"; exit 1
fi

if [[ $CLIENT_NUM -le 5 ]]; then
  IP_ADDR="192.168.10.$((CLIENT_NUM + 10))/24"
  GW="192.168.10.1"
  OTHER_NET="192.168.20.0/24"
  OTHER_GW="192.168.10.1"
else
  IP_ADDR="192.168.20.$((CLIENT_NUM + 4))/24"
  GW="192.168.20.1"
  OTHER_NET="192.168.10.0/24"
  OTHER_GW="192.168.20.1"
fi

echo "[$(date -Iseconds)] Configuring eth1: $IP_ADDR, gw=$GW"

# ---- network config (do NOT override Docker's default via eth0)
ip addr add "$IP_ADDR" dev eth1 2>/dev/null || echo "[net] IP already configured on eth1"
ip link set eth1 up
ip route replace "$OTHER_NET" via "$OTHER_GW" dev eth1

# ---- sanity: gateway ping
for _ in {1..10}; do
  if ping -c1 -W1 "$GW" >/dev/null 2>&1; then
    echo "[net] gateway reachable"; break
  fi
  sleep 1
done

# ---- K3s install/start (no systemd)
echo "[$(date -Iseconds)] Installing/starting k3s..."
export K3S_KUBECONFIG_MODE=644
export INSTALL_K3S_SKIP_ENABLE=true
export INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --node-name $HOSTNAME"

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -s -
else
  echo "[k3s] binary already present"
fi

# start server if not running
if ! pgrep -x k3s >/dev/null 2>&1; then
  /usr/local/bin/k3s server --disable traefik --disable servicelb --write-kubeconfig-mode 644 \
    >/var/log/k3s.log 2>&1 &
  echo "[k3s] server launched"
fi

# kubeconfig + wait for API
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /root/.kube && cp -f "$KUBECONFIG" /root/.kube/config || true

echo "[$(date -Iseconds)] Waiting for k3s API..."
for i in {1..120}; do
  if /usr/local/bin/kubectl --kubeconfig="$KUBECONFIG" get nodes >/dev/null 2>&1; then
    /usr/local/bin/kubectl --kubeconfig="$KUBECONFIG" get nodes
    break
  fi
  sleep 1
  [[ $i -eq 120 ]] && { echo "[k3s] ERROR: API not ready after 120s"; tail -n 80 /var/log/k3s.log || true; exit 1; }
done

# ---- PATCH METRICS-SERVER (important for KWOK/Liqo) ----
echo "[$(date -Iseconds)] Patching metrics-server for KWOK/Liqo..."
if k3s kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  k3s kubectl -n kube-system patch deploy metrics-server \
    --type=json \
    -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[
        "--cert-dir=/tmp",
        "--secure-port=4443",
        "--kubelet-use-node-status-port",
        "--kubelet-insecure-tls",
        "--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP",
        "--metric-resolution=15s"
      ]}
    ]' || true

  k3s kubectl -n kube-system rollout restart deploy/metrics-server || true
  k3s kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s || true
else
  echo "[metrics-server] Not found — skipping patch"
fi
# ---------------------------------------------------------

# ---- KWOK via manifests (controller inside the cluster)
echo "[$(date -Iseconds)] Installing KWOK (manifests)..."
KUBECTL="k3s kubectl"
KWOK_REPO="kubernetes-sigs/kwok"
KWOK_TAG="$(
  curl -fsSL "https://api.github.com/repos/${KWOK_REPO}/releases/latest" |
  grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true
)"
if [[ -z "$KWOK_TAG" ]]; then
  KWOK_TAG="v0.7.0"
  echo "[kwok] fallback to ${KWOK_TAG}"
else
  echo "[kwok] Latest release: ${KWOK_TAG}"
fi

$KUBECTL apply -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_TAG}/kwok.yaml"
$KUBECTL apply -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_TAG}/stage-fast.yaml" || true

KWOK_NS="$($KUBECTL get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
  awk '$2=="kwok-controller"{print $1; exit}')"

if [[ -z "$KWOK_NS" ]]; then
  for ns in kwok-system kube-system; do
    echo "[kwok] Trying rollout status in $ns..."
    $KUBECTL -n "$ns" rollout status deploy/kwok-controller --timeout=180s && KWOK_NS="$ns" && break || true
  done
else
  echo "[kwok] Controller detected in namespace: $KWOK_NS"
  $KUBECTL -n "$KWOK_NS" rollout status deploy/kwok-controller --timeout=180s || true
fi

NODENAME="${HOSTNAME}-fake-node-1"
echo "[$(date -Iseconds)] Applying fake node: ${NODENAME}"
cat > /tmp/fake-node.yaml <<EOF
apiVersion: v1
kind: Node
metadata:
  name: ${NODENAME}
  labels:
    node-role.kubernetes.io/worker: ""
    kubernetes.io/arch: amd64
    kubernetes.io/os: linux
    type: kwok
  annotations:
    kwok.x-k8s.io/node: "fake"
    metrics.k8s.io/resource-metrics-path: "/metrics/nodes/${NODENAME}/metrics/resource"
    node.alpha.kubernetes.io/ttl: "0"
spec:
  taints:
  - key: kwok.x-k8s.io/node
    value: fake
    effect: NoSchedule
status:
  capacity:
    cpu: "24"
    memory: "32Gi"
    pods: "200"
  allocatable:
    cpu: "24"
    memory: "32Gi"
    pods: "200"
  nodeInfo:
    architecture: amd64
    kubeProxyVersion: fake
    kubeletVersion: fake
    operatingSystem: linux
EOF

$KUBECTL apply -f /tmp/fake-node.yaml

echo "[$(date -Iseconds)] Waiting for ${NODENAME} to become Ready..."
for i in {1..60}; do
  cond="$($KUBECTL get node "${NODENAME}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
  [[ "$cond" == "True" ]] && { echo "[kwok] ${NODENAME} is Ready ✅"; break; }
  sleep 2
done

# ---- Liqo install
echo "[$(date -Iseconds)] Installing Liqo..."
if ! command -v liqoctl >/dev/null 2>&1; then
  curl -sL https://get.liqo.io | bash || echo "[liqo] liqoctl install script failed"
fi

if command -v liqoctl >/dev/null 2>&1; then
  if ! k3s kubectl get ns liqo >/dev/null 2>&1; then
    liqoctl install k3s \
      --cluster-id "$HOSTNAME" \
      --disable-telemetry \
      --disable-kernel-version-check >/var/log/liqo-install.log 2>&1 || true
  else
    echo "[liqo] already installed — skipping"
  fi

  k3s kubectl -n liqo wait --for=condition=Available deploy --all --timeout=180s >/dev/null 2>&1 || true
else
  echo "[liqo] liqoctl not available — skipping"
fi

# ---- summary
echo ""
echo "========================================="
echo "Client $HOSTNAME initialization complete!"
echo "IP address (eth1): $IP_ADDR"
echo "Inter-VLAN route: $OTHER_NET via $OTHER_GW (eth1)"
echo "K3s nodes:"
k3s kubectl get nodes || true
echo "========================================="

# Keep container alive
tail -f /dev/null
