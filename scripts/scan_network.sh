#!/bin/bash
# scan_network.sh - Simple ping sweep and port scan for Talos nodes

SUBNET=${1:-"192.168.2.0/24"}

echo "Scanning subnet: $SUBNET"

# Check if nmap is installed, otherwise use a simple ping loop
if command -v nmap &> /dev/null; then
    echo "Using nmap for discovery..."
    # Scan for live hosts and common Talos ports:
    # 50000: Talos API
    # 50001: Talos API (mTLS)
    # 6443: Kubernetes API
    sudo nmap -sn $SUBNET -oG - | awk '/Up$/{print $2}' > live_hosts.txt
    
    echo "Live hosts found:"
    cat live_hosts.txt
    
    echo "Checking for Talos API (port 50000/50001) on live hosts..."
    nmap -p 50000,50001 -iL live_hosts.txt --open
else
    echo "nmap not found, using ping sweep..."
    # Simple ping sweep for /24 subnets
    BASE_IP=$(echo $SUBNET | cut -d/ -f1 | cut -d. -f1-3)
    for i in {1..254}; do
        ping -c 1 -W 1 $BASE_IP.$i &> /dev/null && echo "$BASE_IP.$i is UP" &
    done
    wait
fi
