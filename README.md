# DevOps Beby Cloud - Cozystack Cluster Setup

This project aims to build the first self-hosted public arm64 cozystack cluster for Cozy Summit 2026.

## Network Information
- **Host:** devops3 (192.168.2.197)
- **Subnet:** 192.168.2.0/24
- **Gateway:** 192.168.2.254

## Discovery
Use `scripts/scan_network.sh` for basic IP/Port scanning.
Use `scripts/discover_nodes.sh` for ARP and IPv6 neighbor discovery (useful if nodes didn't get DHCP).
Talos nodes in maintenance mode often won't respond to pings if they haven't configured their network correctly, but may be visible if they use a default static IP or if we can see their ARP traffic.

### DHCP Check
To confirm if `devops3` is using DHCP, run:
```bash
cat /etc/netplan/*.yaml
# or
ip addr show eth0 | grep dynamic
```
