#!/bin/bash

# Configuration
CONTAINER_NAME="clab-dual-switch-topology-client1"

echo "=================================================="
echo "K3s + KWOK Cleanup Script"
echo "=================================================="
echo ""
echo "This script will clean up:"
echo "  - 30 test pods (test-workloads namespace)"
echo "  - 3 fake KWOK nodes"
echo "  - Optionally: K3s, KWOK, Liqo (full reset)"
echo ""
read -p "Choose cleanup level [1=Pods+Nodes only, 2=Everything including K3s]: " CLEANUP_LEVEL

if [[ "$CLEANUP_LEVEL" != "1" && "$CLEANUP_LEVEL" != "2" ]]; then
  echo "Invalid choice. Exiting."
  exit 1
fi

# Create cleanup script for inside container
cat > /tmp/k3s-cleanup-inner.sh <<'CLEANUP_SCRIPT'
#!/bin/bash
set -e

HOSTNAME=$(hostname)
KUBECTL="k3s kubectl"

echo "[$(date -Iseconds)] Starting cleanup on $HOSTNAME..."

# Check if K3s is running
if ! pgrep -x k3s >/dev/null 2>&1; then
  echo "[WARN] K3s is not running. Starting it for cleanup..."
  nohup /usr/local/bin/k3s server --disable traefik --disable servicelb \
    --write-kubeconfig-mode 644 --node-name "$HOSTNAME" >/var/log/k3s.log 2>&1 &
  sleep 10
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait for API
echo "Waiting for K3s API..."
for i in {1..30}; do
  if $KUBECTL get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

CLEANUP_LEVEL="$1"

# ---- Level 1: Delete pods and fake nodes ----
if [[ "$CLEANUP_LEVEL" == "1" || "$CLEANUP_LEVEL" == "2" ]]; then
  echo ""
  echo "========================================="
  echo "Deleting test pods and fake nodes..."
  echo "========================================="
  
  # Delete test-workloads namespace (removes all 30 pods)
  if $KUBECTL get namespace test-workloads >/dev/null 2>&1; then
    echo "[1/4] Deleting test-workloads namespace (all 30 pods)..."
    $KUBECTL delete namespace test-workloads --timeout=60s || true
    echo " Pods deleted"
  else
    echo "[1/4] test-workloads namespace not found"
  fi
  
  # Delete fake nodes
  echo "[2/4] Deleting fake KWOK nodes..."
  for NODE_NUM in 1 2 3; do
    NODENAME="${HOSTNAME}-fake-node-${NODE_NUM}"
    if $KUBECTL get node "$NODENAME" >/dev/null 2>&1; then
      $KUBECTL delete node "$NODENAME" || true
      echo "   Deleted $NODENAME"
    fi
  done
  
  echo "Fake nodes deleted"
fi

# ---- Level 2: Full cleanup (K3s, KWOK, Liqo) ----
if [[ "$CLEANUP_LEVEL" == "2" ]]; then
  echo ""
  echo "========================================="
  echo "Full cleanup: Removing K3s, KWOK, Liqo..."
  echo "========================================="
  
  # Delete Liqo
  echo "[3/4] Uninstalling Liqo..."
  if $KUBECTL get namespace liqo >/dev/null 2>&1; then
    if command -v liqoctl >/dev/null 2>&1; then
      liqoctl uninstall --skip-confirm || true
    fi
    $KUBECTL delete namespace liqo --timeout=60s || true
    echo " Liqo removed"
  else
    echo "  Liqo not installed"
  fi
  
  # Delete KWOK
  echo "[4/4] Uninstalling KWOK..."
  KWOK_REPO="kubernetes-sigs/kwok"
  KWOK_TAG="v0.7.0"
  
  $KUBECTL delete -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_TAG}/stage-fast.yaml" 2>/dev/null || true
  $KUBECTL delete -f "https://github.com/${KWOK_REPO}/releases/download/${KWOK_TAG}/kwok.yaml" 2>/dev/null || true
  echo " KWOK removed"
  
  # Stop and kill K3s
  echo ""
  echo "Stopping K3s server..."
  pkill -9 k3s 2>/dev/null || true
  sleep 2
  
  # Remove K3s data
  echo "Removing K3s data directories..."
  rm -rf /var/lib/rancher/k3s/server/db 2>/dev/null || true
  rm -rf /etc/rancher/k3s/*.yaml 2>/dev/null || true
  
  echo " K3s stopped and data cleared"
  
  echo ""
  echo "========================================="
  echo "Full cleanup complete!"
  echo "========================================="
  echo "You can now re-run the setup script."
  
else
  echo ""
  echo "========================================="
  echo "Partial cleanup complete!"
  echo "========================================="
  echo "Pods and fake nodes removed."
  echo "K3s, KWOK, and Liqo are still installed."
  echo "You can now re-run the setup script to create new nodes/pods."
fi

echo ""
echo "Current cluster state:"
$KUBECTL get nodes 2>/dev/null || echo "K3s not running"

CLEANUP_SCRIPT

# Copy and execute cleanup script
echo "[INFO] Copying cleanup script to container..."
sudo docker cp /tmp/k3s-cleanup-inner.sh "$CONTAINER_NAME:/tmp/k3s-cleanup-inner.sh"

echo "[INFO] Executing cleanup in container $CONTAINER_NAME..."
sudo docker exec -it "$CONTAINER_NAME" bash -c "chmod +x /tmp/k3s-cleanup-inner.sh && /tmp/k3s-cleanup-inner.sh $CLEANUP_LEVEL"

echo ""
echo "=================================================="
echo "Cleanup completed!"
echo "=================================================="
echo ""
if [[ "$CLEANUP_LEVEL" == "1" ]]; then
  echo "You can now re-run the setup script to create new nodes and pods."
elif [[ "$CLEANUP_LEVEL" == "2" ]]; then
  echo "Full cleanup done. Re-run the setup script for fresh installation."
fi
echo ""