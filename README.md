
# Multi-Cluster K3s + KWOK + Liqo Lab Environment

An automated lab environment for testing **K3s**, **KWOK**, and **Liqo** multi-cluster scenarios, orchestrated with **Containerlab**.

---

## Overview

This lab simulates a multi-cluster Kubernetes environment where each client node runs:

- **K3s** - Lightweight Kubernetes control plane (standalone mode)
- **KWOK** - Kubernetes WithOut Kubelet (fake worker nodes for scale testing)
- **Liqo** - Multi-cluster resource sharing and workload offloading
- **Metrics Server** - Optional resource monitoring

KWOK creates simulated worker nodes that appear as `Ready` in the cluster without consuming actual compute resources, enabling large-scale testing scenarios.

---

## Quick Start

### Prerequisites

Install required dependencies:

```bash
# Install Docker
sudo apt install docker.io -y

# Install Containerlab
bash -c "$(curl -fsSL https://get.containerlab.dev)"

# Verify installations
containerlab version
docker ps
```

### Deploy the Lab

**⚠️ Important:** Always use `deploy.sh` instead of `containerlab deploy` directly to ensure proper initialization.

```bash
./deploy.sh deploy
```

This script automatically:
- Creates subdirectories under `client-data/` for each client (client1–client10)
- Generates shared configuration files (`peering-config.txt`, `peering-tokens.txt`)
- Deploys the complete topology via Containerlab

### Connect to a Client

Each client runs an independent K3s cluster. To access a client's shell:

```bash
./deploy.sh connect 3
```

Inside the container:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

### Manage the Lab

```bash
# View cluster status
./deploy.sh status

# Destroy the lab
./deploy.sh destroy
```

---

## Architecture

### Network Topology

| Group | VLAN | CIDR | Gateway |
|-------|------|------|---------|
| Clients 1–5 | 10 | 192.168.10.0/24 | 192.168.10.1 |
| Clients 6–10 | 20 | 192.168.20.0/24 | 192.168.20.1 |

- **eth0** - Docker management and internet connectivity
- **eth1** - Inter-VLAN communication

### Client Initialization

When a client container starts, `client-init.sh` performs the following:

| Step | Action |
|------|--------|
| 1 | Configure eth1 with static IP for inter-VLAN communication |
| 2 | Install and launch K3s in standalone mode |
| 3 | Install KWOK controller from GitHub releases |
| 4 | Create one simulated node per client (Ready state) |
| 5 | Install Liqo for multi-cluster peering |
| 6 | Export kubeconfig and keep container alive |

---

## KWOK Fake Nodes

Each client creates one simulated node: `<hostname>-fake-node-1`

### Default Node Specifications

| Property | Value |
|----------|-------|
| CPU | 24 cores |
| Memory | 32 GiB |
| Pod Capacity | 200 |
| Architecture | amd64 |
| Kubelet Version | fake |
| Taints | `kwok.x-k8s.io/node=fake:NoSchedule` |
| Annotation | `kwok.x-k8s.io/node: fake` |

These nodes appear as `Ready` in `kubectl get nodes` but consume no actual compute resources.

---

## Verification

Verify each component after deployment:

### K3s Cluster

```bash
kubectl get nodes -o wide
```

### KWOK Nodes

```bash
kubectl get nodes | grep fake
```

### Liqo Status

```bash
liqoctl info
```

### Resource Metrics

```bash
kubectl top nodes
```

---

## Customization

### Modify Fake Node Resources

Edit the resource specifications in `client-init.sh`:

```yaml
status:
  capacity:
    cpu: "24"
    memory: "32Gi"
    pods: "200"
```

### Add Multiple Fake Nodes

Duplicate the YAML node definition block in `client-init.sh` with unique node names to create additional simulated nodes per client.

---

## Example Workflows

### Check All Liqo Deployments

```bash
for i in {1..10}; do
  echo "== client$i =="
  docker exec clab-dual-switch-topology-client$i bash -lc '
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    liqoctl info || true
  '
done
```

### Complete Cleanup

```bash
./deploy.sh destroy
sudo rm -rf client-data/*
```

---

##  Additional Resources

- [K3s Documentation](https://docs.k3s.io/)
- [KWOK Documentation](https://kwok.sigs.k8s.io/)
- [Liqo Documentation](https://docs.liqo.io/)
- [Containerlab Documentation](https://containerlab.dev/)
