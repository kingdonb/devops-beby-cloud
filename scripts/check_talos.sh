#!/bin/bash
# check_talos.sh - Probes a list of IPs for Talos API presence

IPS=${@:-"192.168.2.101 192.168.2.102 192.168.2.103"}

echo "Checking for Talos API on potential nodes..."
printf "%-15s %-10s %-10s\n" "IP" "Port 50000" "Port 50001"
echo "------------------------------------------"

for ip in $IPS; do
    # Use timeout and bash's built-in /dev/tcp for quick checks
    timeout 1 bash -c "echo > /dev/tcp/$ip/50000" 2>/dev/null
    P50000=$?
    timeout 1 bash -c "echo > /dev/tcp/$ip/50001" 2>/dev/null
    P50001=$?
    
    RES50000="CLOSED"
    [[ $P50000 -eq 0 ]] && RES50000="OPEN"
    
    RES50001="CLOSED"
    [[ $P50001 -eq 0 ]] && RES50001="OPEN"
    
    printf "%-15s %-10s %-10s\n" "$ip" "$RES50000" "$RES50001"
done
