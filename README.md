# Dual-Switch Topology: K3s + KWOK + Liqo Lab

A containerlab-based lab environment for testing **K3s**, **KWOK (fake nodes)**, and **Liqo** multi-cluster scenarios with automated setup scripts.

---

## Overview

This lab provides:
- **K3s** lightweight Kubernetes cluster
- **KWOK** simulated worker nodes (scale testing without resources)
- **Liqo** multi-cluster resource sharing
- **Metrics Server** with support for KWOK nodes
- **Automated setup & cleanup scripts**

---

## Prerequisites
```bash
# Install Docker
sudo apt install docker.io -y

# Install Containerlab
bash -c "$(curl -fsSL https://get.containerlab.dev)"

# Verify installations
containerlab version
docker ps
```

---

## Quick Start

### 1. Deploy the Topology
```bash
# Deploy containerlab topology
sudo containerlab deploy -t dual-switch-topology.yml

# Verify containers are running
sudo containerlab inspect
```

### 2. Run the Setup Script

The main setup script installs K3s, KWOK, creates 3 fake nodes and 30 test pods:
```bash
chmod +x k3s-kwok-setup.sh
./k3s-kwok-setup.sh
```

**What it does:**
- Installs K3s (if not present)
- Patches metrics-server with `--kubelet-insecure-tls` flag
- Installs KWOK controller
- Creates 3 fake worker nodes
- Adds node addresses for metrics-server scraping
- Creates 30 test pods across fake nodes
- Installs Liqo

### 3. Verify the Setup
```bash
# Access the container
sudo docker exec -it clab-dual-switch-topology-client1 bash

# Inside container - check nodes
k3s kubectl get nodes

# Check pods
k3s kubectl get pods -n test-workloads

# Check node metrics 
k3s kubectl top nodes

# Check pod metrics (requires kwok-exporter)
k3s kubectl top pods -n test-workloads
```

---

## Architecture

### Network Setup

| Component | IP | Notes |
|-----------|----|----|
| client1 (real node) | 172.20.20.41 | K3s control plane |
| client1-fake-node-1 | 172.20.20.41 | KWOK simulated node |
| client1-fake-node-2 | 172.20.20.41 | KWOK simulated node |
| client1-fake-node-3 | 172.20.20.41 | KWOK simulated node |

All nodes share the same IP (real node's IP) because fake nodes don't run real kubelets.

### KWOK Node Specifications

| Property | Value |
|----------|-------|
| CPU | 8 cores |
| Memory | 16 GiB |
| Pod Capacity | 110 |
| Architecture | amd64 |
| Kubelet Version | fake |
| Taints | `kwok.x-k8s.io/node=fake:NoSchedule` |

---

## Cleanup

Use the cleanup script to remove resources:
```bash
chmod +x k3s-kwok-cleanup.sh
./k3s-kwok-cleanup.sh
```

**Cleanup Levels:**
- **Level 1**: Remove pods + fake nodes only (keeps K3s/KWOK/Liqo)
- **Level 2**: Complete cleanup (removes everything including K3s)

---

## Scripts Reference

### k3s-kwok-setup.sh

Main setup script that configures the entire environment.

**Key Features:**
- Automated K3s installation
- Metrics-server TLS configuration
- KWOK controller deployment
- Fake node creation with addresses
- Test pod deployment

### k3s-kwok-cleanup.sh

Interactive cleanup script with two levels.

**Usage:**
```bash
./k3s-kwok-cleanup.sh
# Choose: 1 (partial) or 2 (full cleanup)
```

---


## Troubleshooting

### K3s Not Running
```bash
# Inside container
/usr/local/bin/restart-k3s.sh
```

### Metrics Server Issues
```bash
# Check metrics-server logs
k3s kubectl -n kube-system logs deploy/metrics-server --tail=20

# Verify TLS flag is present
k3s kubectl -n kube-system get deploy metrics-server -o yaml | grep kubelet-insecure-tls
```

### Fake Nodes Show Unknown Metrics
```bash
# Verify node addresses
k3s kubectl get nodes -o wide

# Check if addresses are set
k3s kubectl get node client1-fake-node-1 -o jsonpath='{.status.addresses}'

# Re-patch addresses if needed
HOST_IP=$(hostname -I | grep -oE "172\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
k3s kubectl patch node client1-fake-node-1 --subresource=status --type=json -p="[{\"op\":\"add\",\"path\":\"/status/addresses\",\"value\":[{\"type\":\"InternalIP\",\"address\":\"$HOST_IP\"},{\"type\":\"Hostname\",\"address\":\"client1-fake-node-1\"}]}]"
```

