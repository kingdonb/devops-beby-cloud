#!/bin/bash
# discover_nodes.sh - Advanced discovery using ARP and IPv6

echo "--- ARP Discovery ---"
if command -v arp-scan &> /dev/null; then
    sudo arp-scan --interface=eth0 --localnet
else
    echo "arp-scan not found. Checking local ARP table..."
    arp -a
fi

echo ""
echo "--- IPv6 Neighbor Discovery ---"
# Talos nodes often use IPv6 link-local
ip -6 neighbor show

echo ""
echo "--- Listening for ARP traffic (5 seconds) ---"
if command -v tcpdump &> /dev/null; then
    sudo timeout 5 tcpdump -i eth0 arp -n
else
    echo "tcpdump not found."
fi
