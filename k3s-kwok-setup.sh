#!/bin/bash
set -e

# Configuration
CONTAINER_NAME="clab-dual-switch-topology-client1"
TOPOLOGY_DIR="$HOME/Topologies/Scaled-Network"

echo "=================================================="
echo "K3s + KWOK + Liqo Setup with Fake Nodes and Pods"
echo "=================================================="

# Navigate to topology directory 
cd "$TOPOLOGY_DIR" 2>/dev/null || echo "[INFO] Using current directory"

# Check if container exists
if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "[WARNING] Container $CONTAINER_NAME not found. Please ensure containerlab topology is deployed first"
  exit 1
fi

echo "[INFO] Deploying setup script to container $CONTAINER_NAME..."

# Create the setup script that will run inside the container
cat > /tmp/k3s-kwok-setup.sh <<'INNER_SCRIPT'
#!/bin/bash
set -e

HOSTNAME=$(hostname)
echo "[$(date -Iseconds)] Starting setup on $HOSTNAME..."

# ============================================
# STEP 1: K3s Installation and Startup
# ============================================
echo "[$(date -Iseconds)] Installing/starting k3s..."
export K3S_KUBECONFIG_MODE=644
export INSTALL_K3S_SKIP_ENABLE=true
export INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --node-name $HOSTNAME"

if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -s -
else
  echo "[k3s] binary already present"
fi

# Start server if not running
if ! pgrep -x k3s >/dev/null 2>&1; then
  nohup /usr/local/bin/k3s server --disable traefik --disable servicelb --write-kubeconfig-mode 644 \
    --node-name "$HOSTNAME" >/var/log/k3s.log 2>&1 &
  echo "[k3s] server launched"
fi

# Create restart helper script
cat > /usr/local/bin/restart-k3s.sh <<'RESTART_SCRIPT'
#!/bin/bash
echo "Stopping k3s..."
pkill -9 k3s 2>/dev/null || true
sleep 2

echo "Starting k3s server..."
nohup /usr/local/bin/k3s server --disable traefik --disable servicelb \
  --write-kubeconfig-mode 644 --node-name $(hostname) \
  >/var/log/k3s.log 2>&1 &

echo "Waiting for k3s API..."
for i in {1..30}; do
  if kubectl get nodes >/dev/null 2>&1; then
    echo "K3s is ready!"
    kubectl get nodes
    break
  fi
  sleep 1
done
RESTART_SCRIPT

chmod +x /usr/local/bin/restart-k3s.sh
echo "[k3s] Helper script created at /usr/local/bin/restart-k3s.sh"

# Setup kubeconfig and wait for API
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

KUBECTL="k3s kubectl"

# ============================================
# STEP 2: Patch Metrics-Server
# ============================================
echo "[$(date -Iseconds)] Patching metrics-server for KWOK..."
if $KUBECTL -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  
  # Add --kubelet-insecure-tls if not present
  if ! $KUBECTL -n kube-system get deployment metrics-server -o yaml | grep -q "kubelet-insecure-tls"; then
    echo "[metrics-server] Adding --kubelet-insecure-tls flag"
    $KUBECTL -n kube-system patch deploy metrics-server \
      --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true
  fi
  
  # Ensure all required flags are present
  $KUBECTL -n kube-system patch deploy metrics-server \
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

  $KUBECTL -n kube-system rollout restart deploy/metrics-server || true
  $KUBECTL -n kube-system rollout status deploy/metrics-server --timeout=180s || true
  echo "[metrics-server] Patched and restarted"
else
  echo "[metrics-server] Not found — skipping patch"
fi

# ============================================
# STEP 3: Install KWOK
# ============================================
echo "[$(date -Iseconds)] Installing KWOK (manifests)..."
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

# ============================================
# STEP 4: Create 3 Fake Nodes
# ============================================
echo "[$(date -Iseconds)] Creating 3 fake nodes..."
for NODE_NUM in 1 2 3; do
  NODENAME="${HOSTNAME}-fake-node-${NODE_NUM}"
  echo "[$(date -Iseconds)] Creating fake node: ${NODENAME}"
  
  cat > /tmp/fake-node-${NODE_NUM}.yaml <<EOF
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
    kwok.x-k8s.io/usage-cpu: "$(($NODE_NUM * 1000))m"
    kwok.x-k8s.io/usage-memory: "$(($NODE_NUM * 4))Gi"
    node.alpha.kubernetes.io/ttl: "0"
spec:
  taints:
  - key: kwok.x-k8s.io/node
    value: fake
    effect: NoSchedule
status:
  capacity:
    cpu: "8"
    memory: "16Gi"
    pods: "110"
  allocatable:
    cpu: "8"
    memory: "16Gi"
    pods: "110"
  nodeInfo:
    architecture: amd64
    kubeProxyVersion: fake
    kubeletVersion: fake
    operatingSystem: linux
  conditions:
  - type: Ready
    status: "True"
    reason: KubeletReady
    message: kubelet is posting ready status
  - type: MemoryPressure
    status: "False"
  - type: DiskPressure
    status: "False"
  - type: PIDPressure
    status: "False"
  - type: NetworkUnavailable
    status: "False"
EOF

  $KUBECTL apply -f /tmp/fake-node-${NODE_NUM}.yaml
  
  echo "[$(date -Iseconds)] Waiting for ${NODENAME} to become Ready..."
  for i in {1..60}; do
    cond="$($KUBECTL get node "${NODENAME}" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
    [[ "$cond" == "True" ]] && { echo "[kwok] ${NODENAME} is Ready"; break; }
    sleep 2
  done
done

# ============================================
# STEP 5: Add Node Addresses (CRITICAL!)
# ============================================
echo "[$(date -Iseconds)] Adding addresses to fake nodes..."
HOST_IP=$(hostname -I | grep -oE "172\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
echo "[INFO] Host IP: $HOST_IP"

for NODE_NUM in 1 2 3; do
  NODENAME="${HOSTNAME}-fake-node-${NODE_NUM}"
  $KUBECTL patch node "$NODENAME" --subresource=status --type=json -p="[
    {\"op\":\"add\",\"path\":\"/status/addresses\",\"value\":[
      {\"type\":\"InternalIP\",\"address\":\"$HOST_IP\"},
      {\"type\":\"Hostname\",\"address\":\"$NODENAME\"}
    ]}
  ]" || echo "[WARN] Failed to patch $NODENAME addresses"
done

echo "[$(date -Iseconds)] Node addresses configured"

# ============================================
# STEP 6: Create 30 Test Pods
# ============================================
echo "[$(date -Iseconds)] Creating 30 pods across fake nodes..."

cat > /tmp/test-pods.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: test-workloads
---
EOF

for POD_NUM in {1..30}; do
  NODE_INDEX=$(( (POD_NUM - 1) % 3 + 1 ))
  NODENAME="${HOSTNAME}-fake-node-${NODE_INDEX}"
  
  cat >> /tmp/test-pods.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-${POD_NUM}
  namespace: test-workloads
  labels:
    app: test-workload
    pod-number: "pod-${POD_NUM}"
  annotations:
    kwok.x-k8s.io/usage-cpu: "100m"
    kwok.x-k8s.io/usage-memory: "128Mi"
spec:
  nodeName: ${NODENAME}
  tolerations:
  - key: kwok.x-k8s.io/node
    operator: Exists
    effect: NoSchedule
  containers:
  - name: nginx
    image: nginx:alpine
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
      limits:
        cpu: "200m"
        memory: "256Mi"
---
EOF
done

$KUBECTL apply -f /tmp/test-pods.yaml

echo "[$(date -Iseconds)] Waiting for pods to become Running..."
sleep 5
$KUBECTL -n test-workloads wait --for=condition=Ready pod --all --timeout=120s || true

# ============================================
# STEP 7: Install Liqo 
# ============================================
echo "[$(date -Iseconds)] Installing Liqo..."
if ! command -v liqoctl >/dev/null 2>&1; then
  curl -sL https://get.liqo.io | bash || echo "[liqo] liqoctl install script failed"
fi

if command -v liqoctl >/dev/null 2>&1; then
  if ! $KUBECTL get ns liqo >/dev/null 2>&1; then
    liqoctl install k3s \
      --cluster-id "$HOSTNAME" \
      --disable-telemetry \
      --disable-kernel-version-check >/var/log/liqo-install.log 2>&1 || true
  else
    echo "[liqo] already installed — skipping"
  fi

  $KUBECTL -n liqo wait --for=condition=Available deploy --all --timeout=180s >/dev/null 2>&1 || true
else
  echo "[liqo] liqoctl not available — skipping"
fi

# ============================================
# STEP 8: Wait for Metrics
# ============================================
echo "[$(date -Iseconds)] Waiting for metrics to be available (30 seconds)..."
sleep 30

# Restart metrics-server one more time to ensure it picks up nodes
$KUBECTL -n kube-system rollout restart deploy/metrics-server >/dev/null 2>&1 || true
sleep 15

echo "========================================="
echo " Setup complete on $HOSTNAME!"
echo "========================================="


INNER_SCRIPT

# Copy script to container
sudo docker cp /tmp/k3s-kwok-setup.sh "$CONTAINER_NAME:/tmp/k3s-kwok-setup.sh"

# Execute the script inside the container
echo "[INFO] Executing setup inside container $CONTAINER_NAME..."
sudo docker exec -it "$CONTAINER_NAME" bash -c "chmod +x /tmp/k3s-kwok-setup.sh && /tmp/k3s-kwok-setup.sh"
