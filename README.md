# DevOps Beby Cloud - Cozystack Cluster Setup

This project aims to build the first self-hosted public arm64 cozystack cluster for Cozy Summit 2026.

## Network Information
- **Host:** devops3 (192.168.2.197)
- **Subnet:** 192.168.2.0/24
- **Gateway:** 192.168.2.254

## Inventory (Discovered)
| Hostname | IP | MAC | Type |
|----------|----|-----|------|
| bb001 | 192.168.2.1 | e4:5f:01:22:d6:e1 | RPi |
| bb004 | 192.168.2.4 | e4:5f:01:22:c4:6d | RPi |
| bb005 | 192.168.2.5 | e4:5f:01:22:d7:ec | RPi |
| bb006 | 192.168.2.6 | e4:5f:01:22:c4:af | RPi |
| bb007 | 192.168.2.7 | e4:5f:01:e1:0b:11 | RPi |
| bb008 | 192.168.2.8 | e4:5f:01:22:c3:33 | RPi |
| bb009 | 192.168.2.9 | e4:5f:01:22:d6:e2 | RPi |
| bb010 | 192.168.2.10 | e4:5f:01:22:da:bc | RPi |
| bb011 | 192.168.2.11 | e4:5f:01:22:d7:3c | RPi |
| bb012 | 192.168.2.12 | 2c:cf:67:c2:33:a9 | Giga-Byte |
| longhorn | 192.168.2.220 | e4:5f:01:22:c3:33 | RPi (Alias?) |
| devops1 | 192.168.2.199 | e4:5f:01:31:2d:91 | RPi |
| devops2 | 192.168.2.198 | dc:a6:32:f2:f9:25 | RPi |
| devops3 | 192.168.2.197 | e4:5f:01:31:23:e9 | RPi (Current Host) |
| devops4 | 192.168.2.196 | e4:5f:01:e5:ed:72 | RPi |

## Discovery
Use `scripts/scan_network.sh` for basic IP/Port scanning.
Use `scripts/discover_nodes.sh` for ARP and IPv6 neighbor discovery.
Use `scripts/check_talos.sh` to verify Talos API presence on discovered hosts.

### DHCP Check
To confirm if `devops3` is using DHCP, run:
```bash
cat /etc/netplan/*.yaml
# or
ip addr show eth0 | grep dynamic
```
