#!/usr/bin/env bash
set -e

#将网口分配给四个命名空间，使其机内互相隔离
#chmod +x setup-4nic-netns.sh
#sudo ./setup-4nic-netns.sh

IF101="enp65s0f0np0"
IF102="enp65s0f1np1"
IF103="enp193s0f0np0"
IF104="enp193s0f1np1"

NS101="ns101"
NS102="ns102"
NS103="ns103"
NS104="ns104"

IP101="10.0.0.101/24"
IP102="10.0.0.102/24"
IP103="10.0.0.103/24"
IP104="10.0.0.104/24"

for ns in "$NS101" "$NS102" "$NS103" "$NS104"; do
    ip netns del "$ns" 2>/dev/null || true
done

sleep 1

ip addr flush dev "$IF101" 2>/dev/null || true
ip addr flush dev "$IF102" 2>/dev/null || true
ip addr flush dev "$IF103" 2>/dev/null || true
ip addr flush dev "$IF104" 2>/dev/null || true

ip link set "$IF101" down 2>/dev/null || true
ip link set "$IF102" down 2>/dev/null || true
ip link set "$IF103" down 2>/dev/null || true
ip link set "$IF104" down 2>/dev/null || true

ip netns add "$NS101"
ip netns add "$NS102"
ip netns add "$NS103"
ip netns add "$NS104"

ip link set "$IF101" netns "$NS101"
ip link set "$IF102" netns "$NS102"
ip link set "$IF103" netns "$NS103"
ip link set "$IF104" netns "$NS104"

ip netns exec "$NS101" ip link set lo up
ip netns exec "$NS102" ip link set lo up
ip netns exec "$NS103" ip link set lo up
ip netns exec "$NS104" ip link set lo up

ip netns exec "$NS101" ip addr add "$IP101" dev "$IF101"
ip netns exec "$NS102" ip addr add "$IP102" dev "$IF102"
ip netns exec "$NS103" ip addr add "$IP103" dev "$IF103"
ip netns exec "$NS104" ip addr add "$IP104" dev "$IF104"

ip netns exec "$NS101" ip link set "$IF101" up
ip netns exec "$NS102" ip link set "$IF102" up
ip netns exec "$NS103" ip link set "$IF103" up
ip netns exec "$NS104" ip link set "$IF104" up

echo "Done."
echo
ip netns exec "$NS101" ip -br addr
ip netns exec "$NS102" ip -br addr
ip netns exec "$NS103" ip -br addr
ip netns exec "$NS104" ip -br addr
