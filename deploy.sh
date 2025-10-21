#!/bin/bash

TOPOLOGY_FILE="topology.yml"
LAB_NAME="dual-switch-topology"

function setup_directories() {
    echo "Setting up directories..."
    mkdir -p scripts shared client-data
    
    for i in {1..10}; do
        mkdir -p client-data/client${i}/{k3s,etc-rancher,kubelet,liqo,etc-liqo}
    done
    
    touch shared/peering-config.txt
    touch shared/peering-tokens.txt
    chmod 666 shared/peering-{config,tokens}.txt
    
    echo "Directory structure ready!"
}

function deploy() {
    echo "Deploying topology..."
    setup_directories
    sudo containerlab deploy -t $TOPOLOGY_FILE
}

function destroy() {
    echo "Destroying topology..."
    sudo containerlab destroy -t $TOPOLOGY_FILE
}

function status() {
    echo "Checking status..."
    sudo containerlab inspect -t $TOPOLOGY_FILE
}

function connect() {
    local client=$1
    echo "Connecting to client${client}..."
    sudo docker exec -it clab-${LAB_NAME}-client${client} /bin/bash
}

# Main
case $1 in
    deploy) deploy ;;
    destroy) destroy ;;
    status) status ;;
    connect) connect $2 ;;
    *) 
        echo "Usage: $0 [deploy|destroy|status|connect <N>]"
        echo "  deploy  - Setup and deploy topology"
        echo "  destroy - Destroy topology"
        echo "  status  - Check topology status"
        echo "  connect N - Connect to client N (1-10)"
        ;;
esac
