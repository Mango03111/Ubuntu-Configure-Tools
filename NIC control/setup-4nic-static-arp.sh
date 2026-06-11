#!/usr/bin/env bash
set -e

#配置四个命名空间中的四个网口的arp
#chmod +x setup-4nic-static-arp.sh
#sudo ./setup-4nic-static-arp.sh

# namespace
NS101="ns101"
NS102="ns102"
NS103="ns103"
NS104="ns104"

# interface inside namespace
IF101="enp65s0f0np0"
IF102="enp65s0f1np1"
IF103="enp193s0f0np0"
IF104="enp193s0f1np1"

# IP address
IP101="10.0.0.101"
IP102="10.0.0.102"
IP103="10.0.0.103"
IP104="10.0.0.104"

# MAC address
MAC101="10:70:fd:06:fa:4c"
MAC102="10:70:fd:06:fa:4d"
MAC103="08:c0:eb:32:1d:16"
MAC104="08:c0:eb:32:1d:17"

echo "Flush old ARP entries..."

ip netns exec "$NS101" ip neigh flush dev "$IF101" || true
ip netns exec "$NS102" ip neigh flush dev "$IF102" || true
ip netns exec "$NS103" ip neigh flush dev "$IF103" || true
ip netns exec "$NS104" ip neigh flush dev "$IF104" || true

echo "Configure static ARP for ns101..."

ip netns exec "$NS101" ip neigh replace "$IP102" lladdr "$MAC102" dev "$IF101" nud permanent
ip netns exec "$NS101" ip neigh replace "$IP103" lladdr "$MAC103" dev "$IF101" nud permanent
ip netns exec "$NS101" ip neigh replace "$IP104" lladdr "$MAC104" dev "$IF101" nud permanent

echo "Configure static ARP for ns102..."

ip netns exec "$NS102" ip neigh replace "$IP101" lladdr "$MAC101" dev "$IF102" nud permanent
ip netns exec "$NS102" ip neigh replace "$IP103" lladdr "$MAC103" dev "$IF102" nud permanent
ip netns exec "$NS102" ip neigh replace "$IP104" lladdr "$MAC104" dev "$IF102" nud permanent

echo "Configure static ARP for ns103..."

ip netns exec "$NS103" ip neigh replace "$IP101" lladdr "$MAC101" dev "$IF103" nud permanent
ip netns exec "$NS103" ip neigh replace "$IP102" lladdr "$MAC102" dev "$IF103" nud permanent
ip netns exec "$NS103" ip neigh replace "$IP104" lladdr "$MAC104" dev "$IF103" nud permanent

echo "Configure static ARP for ns104..."

ip netns exec "$NS104" ip neigh replace "$IP101" lladdr "$MAC101" dev "$IF104" nud permanent
ip netns exec "$NS104" ip neigh replace "$IP102" lladdr "$MAC102" dev "$IF104" nud permanent
ip netns exec "$NS104" ip neigh replace "$IP103" lladdr "$MAC103" dev "$IF104" nud permanent

echo
echo "Static ARP configuration completed."
echo

echo "===== ns101 ARP table ====="
ip netns exec "$NS101" ip neigh show dev "$IF101"

echo
echo "===== ns102 ARP table ====="
ip netns exec "$NS102" ip neigh show dev "$IF102"

echo
echo "===== ns103 ARP table ====="
ip netns exec "$NS103" ip neigh show dev "$IF103"

echo
echo "===== ns104 ARP table ====="
ip netns exec "$NS104" ip neigh show dev "$IF104"
