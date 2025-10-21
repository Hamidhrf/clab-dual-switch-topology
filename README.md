
# Multi-Cluster K3s + KWOK + Liqo Environment

This repository contains an automated lab environment for **K3s**, **KWOK**, and **Liqo**, orchestrated using **Containerlab**.  

---

## Overview

Each simulated **client node** runs:
-  A lightweight **K3s** control plane (standalone)
-  A **KWOK** controller (fake Kubernetes nodes)
-  **Liqo** for inter-cluster peering and offloading
-  Optional metrics-server and log output for diagnostics

KWOK creates **fake worker nodes** so you can simulate scale without heavy CPU overhead.

---

##  Getting Started

###  1. Prerequisites
Install:
```bash
sudo apt install docker.io -y
bash -c "$(curl -fsSL https://get.containerlab.dev)"


Verify:

containerlab version
docker ps

 2. Deploy the lab

⚠️ Always use deploy.sh instead of containerlab deploy directly —
it creates required directories and shared volumes automatically.

./deploy.sh deploy


This script will:

Create subfolders under client-data/ for each node (client1–client10)

Create shared files (peering-config.txt, peering-tokens.txt)

Deploy the full topology with Containerlab

 3. Connect to a client container

Each client runs its own K3s cluster.
To open an interactive shell:

./deploy.sh connect 3


Then inside:

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes

 4. Check status or destroy
# Show running nodes and links
./deploy.sh status

# Tear down the lab cleanly
./deploy.sh destroy

 Internals — What Happens Inside Each Client

When a client container starts, it executes client-init.sh which:

Step	Action
 1	Configures eth1 with static IP for inter-VLAN communication
 2	Installs & launches K3s (standalone mode)
 3	Installs KWOK from GitHub releases
 4	Creates one fake node per client (Ready state)
 5	Installs Liqo for multi-cluster peering
 6	Exports kubeconfig and keeps container alive for observation
 Fake Node Configuration (KWOK)

Each client creates one fake node named <hostname>-fake-node-1.
Example specs:

Property	Value
CPU	24 cores
Memory	32 GiB
Pods capacity	200
Architecture	amd64
Kubelet version	fake
Taints	kwok.x-k8s.io/node=fake:NoSchedule
Annotation	kwok.x-k8s.io/node: fake (used by KWOK controller)

These nodes are simulated, so they appear as Ready but consume no actual compute resources — ideal for scaling experiments or scheduler testing.

 Verification Commands

Once deployed, you can verify each component:

 K3s
kubectl get nodes -o wide

 KWOK
kubectl get nodes | grep fake

 Liqo
liqoctl info

 Metrics
kubectl top nodes

Group	VLAN	CIDR	Gateway
Clients 1–5	10	192.168.10.0/24	192.168.10.1
Clients 6–10	20	192.168.20.0/24	192.168.20.1

Each client uses eth0 for Docker/internet, and eth1 for inter-VLAN communication.

 Customization

To change fake node resources, edit inside client-init.sh:

status:
  capacity:
    cpu: "24"
    memory: "32Gi"
    pods: "200"


You can also create multiple fake nodes per client by duplicating the YAML block with new names.

Example Workflows
Check all Liqo deployments
for i in {1..10}; do
  echo "== client$i =="
  docker exec clab-dual-switch-topology-client$i bash -lc '
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    liqoctl info || true
  '
done

Cleanup everything
./deploy.sh destroy
sudo rm -rf client-data/*
